#include "orca_bridge.h"

#include "libslic3r/I18N.hpp"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

#include <sys/stat.h>

// --- adapter: translation hook --------------------------------------
// Desktop OrcaSlicer defines I18N::translate_fn in utils.cpp (which needs
// macOS-only libproc.h) and the GUI reassigns it at startup. iOS port:
// identity default, assigned here. Upstream untouched.
namespace Slic3r { namespace I18N {
static std::string identity_translate(const char *s) { return s; }
translate_fn_type translate_fn = &identity_translate;
}}

// --- C ABI result ownership ---------------------------------------------

static orca_owned_string orcapad_empty_string() noexcept {
    return { nullptr, 0 };
}

static bool orcapad_copy_string(const char *source, orca_owned_string *out) noexcept {
    if (!out) return false;
    *out = orcapad_empty_string();
    if (!source) source = "";
    const size_t length = std::strlen(source);
    if (length == std::numeric_limits<size_t>::max() ||
        length > static_cast<size_t>(std::numeric_limits<uint64_t>::max()))
        return false;
    char *copy = static_cast<char *>(std::malloc(length + 1));
    if (!copy) return false;
    std::memcpy(copy, source, length + 1);
    out->data = copy;
    out->length = static_cast<uint64_t>(length);
    return true;
}

static orca_result orcapad_ok() noexcept {
    return { ORCA_STATUS_OK, orcapad_empty_string() };
}

static orca_result orcapad_fail(orca_status_code code, const char *operation,
                                const char *detail) noexcept {
    orca_result result { code, orcapad_empty_string() };
    if (!operation) operation = "Bridge";
    if (!detail) detail = "failure";
    const size_t operation_length = std::strlen(operation);
    const size_t detail_length = std::strlen(detail);
    if (detail_length > std::numeric_limits<size_t>::max() - 3 ||
        operation_length >
            std::numeric_limits<size_t>::max() - detail_length - 3) {
        result.code = ORCA_STATUS_OUT_OF_MEMORY;
        return result;
    }
    const size_t length = operation_length + 2 + detail_length;
    char *diagnostic = static_cast<char *>(std::malloc(length + 1));
    if (!diagnostic) {
        result.code = ORCA_STATUS_OUT_OF_MEMORY;
        return result;
    }
    std::memcpy(diagnostic, operation, operation_length);
    diagnostic[operation_length] = ':';
    diagnostic[operation_length + 1] = ' ';
    std::memcpy(diagnostic + operation_length + 2, detail, detail_length + 1);
    result.diagnostic = { diagnostic, static_cast<uint64_t>(length) };
    return result;
}

// Upstream ObjectBase ID allocation and multiple other engine globals assume
// single-threaded entry. Swift session locks protect handles, while this
// recursive process lock protects the untouched engine across all handles and
// permits same-thread progress callbacks to re-enter the Bridge deliberately.
static std::recursive_mutex orcapad_engine_mutex;

template <class Function>
static orca_result orcapad_guard(const char *operation, Function &&function) noexcept {
    try {
        std::lock_guard<std::recursive_mutex> engine_lock(orcapad_engine_mutex);
        return function();
    } catch (const std::bad_alloc &) {
        return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation, "allocation failed");
    } catch (const std::exception &error) {
        return orcapad_fail(ORCA_STATUS_ENGINE_FAILURE, operation, error.what());
    } catch (...) {
        return orcapad_fail(ORCA_STATUS_ENGINE_FAILURE, operation,
                            "unknown C++ exception");
    }
}

uint32_t orca_bridge_abi_version(void) { return ORCA_BRIDGE_ABI_VERSION; }

void orca_owned_string_dispose(orca_owned_string *string) {
    if (!string) return;
    std::free(string->data);
    *string = orcapad_empty_string();
}

void orca_result_dispose(orca_result *result) {
    if (!result) return;
    orca_owned_string_dispose(&result->diagnostic);
    result->code = ORCA_STATUS_OK;
}

// --- full slice pipeline ------------------------------------------------

#include "libslic3r/GCode/GCodeProcessor.hpp"
#include "libslic3r/Model.hpp"
#include "libslic3r/Print.hpp"
#include "libslic3r/PrintConfig.hpp"
#include "libslic3r/AppConfig.hpp"
#include "libslic3r/PresetBundle.hpp"
#include "libslic3r/Utils.hpp"

#include "nlohmann/json.hpp"

#include <fstream>
#include <sstream>

// --- data_dir adapter ----------------------------------------------------
// Upstream defines set_data_dir/data_dir in utils.cpp (needs macOS-only
// libproc.h). Swift owns the path: the app bundle's read-only resource dir
// with the shipped profile tree (<bundle>/system/…).
namespace Slic3r {
static std::mutex  orcapad_data_dir_mutex;
static std::string orcapad_data_dir;

static bool orcapad_initialize_data_dir(const std::string &path) {
    std::lock_guard<std::mutex> lock(orcapad_data_dir_mutex);
    if (orcapad_data_dir.empty()) {
        orcapad_data_dir = path;
        return true;
    }
    return orcapad_data_dir == path;
}

void set_data_dir(const std::string &path) {
    if (!orcapad_initialize_data_dir(path))
        throw std::logic_error("OrcaBridge data directory is already initialized");
}

// Safe without locking: initialization occurs once and the string is never
// mutated afterward.
const std::string &data_dir() { return orcapad_data_dir; }

// --- utils.cpp adapters (same reason: macOS-only bits in the real TU) ----

local_encoded_string encode_path(const char *src) { return local_encoded_string(src); }

std::vector<std::string> split_string(const std::string &str, char delimiter) {
    std::vector<std::string> result;
    std::stringstream ss(str);
    std::string substr;
    while (std::getline(ss, substr, delimiter))
        result.push_back(substr);
    return result;
}

// Upstream: copy to temp + rename so targets are never half-written.
CopyFileResult copy_file(const std::string &from, const std::string &to,
                         std::string &error_message, const bool with_check) {
    std::ifstream src(from, std::ios::in | std::ios::binary);
    if (!src) {
        error_message = "OrcaBridge copy_file: cannot open " + from;
        return CopyFileResult::FAIL_CHECK_ORIGIN_NOT_OPENED;
    }
    const std::string tmp = to + ".orcapad-tmp";
    {
        std::ofstream dst(tmp, std::ios::out | std::ios::binary);
        if (!dst) {
            error_message = "OrcaBridge copy_file: cannot create " + tmp;
            return CopyFileResult::FAIL_COPY_FILE;
        }
        dst << src.rdbuf();
        if (!dst.good()) {
            error_message = "OrcaBridge copy_file: write failed " + tmp;
            return CopyFileResult::FAIL_COPY_FILE;
        }
    }
    if (with_check) {
        struct stat a, b;
        if (stat(from.c_str(), &a) != 0 || stat(tmp.c_str(), &b) != 0 || a.st_size != b.st_size) {
            error_message = "OrcaBridge copy_file: size check failed " + tmp;
            return CopyFileResult::FAIL_FILES_DIFFERENT;
        }
    }
    if (std::rename(tmp.c_str(), to.c_str()) != 0) {
        error_message = "OrcaBridge copy_file: rename failed → " + to;
        return CopyFileResult::FAIL_RENAMING;
    }
    return CopyFileResult::SUCCESS;
}

bool is_shapes_dir(const std::string &dir) {
    (void)dir; // OrcaPad ships no shapes gallery yet — nothing is a shapes dir.
    return false;
}

std::string header_gcodeviewer_generated() {
    return std::string(GCODEVIEWER_APP_NAME " ") + SoftFever_VERSION;
}

bool install_vendor_bundles_from_resources(const std::vector<std::string> &bundle_names,
                                           const std::string &resource_subdir,
                                           const std::string &data_subdir) {
    // OrcaPad adapter: data_dir() points straight at the bundled, read-only
    // resource tree — the "installation" this function performs on desktop
    // already happened at app-build time. Nothing to do; success.
    (void)bundle_names; (void)resource_subdir; (void)data_subdir;
    return true;
}
} // namespace Slic3r

// --- system preset bundle ------------------------------------------------

struct orca_presets {
    Slic3r::AppConfig app_config;
    std::unique_ptr<Slic3r::PresetBundle> bundle;

    orca_presets() : bundle(std::make_unique<Slic3r::PresetBundle>()) {}

    Slic3r::PresetCollection &collection(int32_t kind) {
        switch (kind) {
        case 0: return bundle->printers;
        case 1: return bundle->filaments;
        default: return bundle->prints;
        }
    }
};

static bool orcapad_valid_preset_kind(int32_t kind) {
    return kind >= 0 && kind <= 2;
}

static std::vector<std::string> orcapad_system_preset_names(
    const Slic3r::PresetCollection &collection) {
    std::vector<std::string> names;
    for (const Slic3r::Preset &preset : collection)
        if (preset.is_system) names.push_back(preset.name);
    std::sort(names.begin(), names.end());
    return names;
}

/// System presets sorted by name — the canonical stable order shared by
/// orca_presets_list_name and orca_presets_list_entry.
static std::vector<const Slic3r::Preset *> orcapad_system_presets(
    const Slic3r::PresetCollection &collection) {
    std::vector<const Slic3r::Preset *> presets;
    for (const Slic3r::Preset &preset : collection)
        if (preset.is_system) presets.push_back(&preset);
    std::sort(presets.begin(), presets.end(),
              [](const Slic3r::Preset *a, const Slic3r::Preset *b) {
                  return a->name < b->name;
              });
    return presets;
}

static bool orcapad_has_exact_system_preset(
    Slic3r::PresetCollection &collection, const char *name) {
    const Slic3r::Preset *preset = collection.find_preset(name, false, true);
    return preset && preset->is_system && preset->name == name;
}

orca_result orca_presets_new(const char *data_dir_path, orca_presets **out) {
    constexpr const char *operation = "orca_presets_new";
    if (out) *out = nullptr;
    if (!out)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!data_dir_path || !data_dir_path[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "data directory is empty");

    return orcapad_guard(operation, [&]() -> orca_result {
        if (!Slic3r::orcapad_initialize_data_dir(data_dir_path))
            return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                "data directory differs from the initialized runtime");
        auto presets = std::make_unique<orca_presets>();
        auto substitutions = presets->bundle->load_presets(
            presets->app_config,
            Slic3r::ForwardCompatibilitySubstitutionRule::EnableSilent,
            Slic3r::PresetBundle::PresetPreferences());
        (void)substitutions;
        // OrcaPad = desktop "show all presets": vendor machines without
        // declared nozzle variants stay invisible after a headless load.
        for (auto &preset : presets->bundle->printers)
            if (preset.is_system) preset.is_visible = true;
        presets->bundle->update_compatible(
            Slic3r::PresetSelectCompatibleType::Always);
        *out = presets.release();
        return orcapad_ok();
    });
}

void orca_presets_free(orca_presets *presets) { delete presets; }

orca_result orca_presets_list_count(orca_presets *presets, int32_t kind,
                                    int32_t *out_count) {
    constexpr const char *operation = "orca_presets_list_count";
    if (out_count) *out_count = 0;
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!out_count)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!orcapad_valid_preset_kind(kind))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        const size_t count =
            orcapad_system_preset_names(presets->collection(kind)).size();
        if (count > static_cast<size_t>(std::numeric_limits<int32_t>::max()))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "preset count exceeds ABI range");
        *out_count = static_cast<int32_t>(count);
        return orcapad_ok();
    });
}

orca_result orca_presets_list_name(orca_presets *presets, int32_t kind,
                                   int32_t index, orca_owned_string *out_name) {
    constexpr const char *operation = "orca_presets_list_name";
    if (out_name) *out_name = orcapad_empty_string();
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!out_name)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!orcapad_valid_preset_kind(kind))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        const auto names =
            orcapad_system_preset_names(presets->collection(kind));
        if (index < 0 || static_cast<size_t>(index) >= names.size())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "preset index was not found");
        if (!orcapad_copy_string(names[static_cast<size_t>(index)].c_str(), out_name))
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate preset name");
        return orcapad_ok();
    });
}

orca_result orca_presets_select(orca_presets *presets, const char *machine,
                                const char *filament, const char *process) {
    constexpr const char *operation = "orca_presets_select";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!machine || !machine[0] || !filament || !filament[0] ||
        !process || !process[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset name is empty");

    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_has_exact_system_preset(
                presets->bundle->printers, machine))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "machine preset was not found");
        if (!orcapad_has_exact_system_preset(
                presets->bundle->filaments, filament))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "filament preset was not found");
        if (!orcapad_has_exact_system_preset(
                presets->bundle->prints, process))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "process preset was not found");

        auto candidate =
            std::make_unique<Slic3r::PresetBundle>(*presets->bundle);
        candidate->printers.select_preset_by_name(machine, false);
        candidate->update_compatible(
            Slic3r::PresetSelectCompatibleType::Always);
        candidate->filaments.select_preset_by_name(filament, false);
        candidate->prints.select_preset_by_name(process, false);
        if (candidate->printers.get_selected_preset().name != machine ||
            candidate->filaments.get_selected_preset().name != filament ||
            candidate->prints.get_selected_preset().name != process)
            return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                "preset combination is not selectable");

        presets->bundle.swap(candidate);
        return orcapad_ok();
    });
}

orca_result orca_presets_current(orca_presets *presets, int32_t kind,
                                 orca_owned_string *out_name) {
    constexpr const char *operation = "orca_presets_current";
    if (out_name) *out_name = orcapad_empty_string();
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!out_name)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!orcapad_valid_preset_kind(kind))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        const std::string &name =
            presets->collection(kind).get_selected_preset().name;
        if (name.empty())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "no preset is selected");
        if (!orcapad_copy_string(name.c_str(), out_name))
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate preset name");
        return orcapad_ok();
    });
}

void orca_preset_entry_dispose(orca_preset_entry *entry) {
    if (!entry) return;
    orca_owned_string_dispose(&entry->name);
    orca_owned_string_dispose(&entry->vendor);
    entry->compatible = 0;
}

orca_result orca_presets_list_entry(orca_presets *presets, int32_t kind,
                                    int32_t index,
                                    orca_preset_entry *out_entry) {
    constexpr const char *operation = "orca_presets_list_entry";
    if (out_entry) {
        *out_entry = orca_preset_entry{};
        out_entry->name = orcapad_empty_string();
        out_entry->vendor = orcapad_empty_string();
    }
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!out_entry)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!orcapad_valid_preset_kind(kind))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        const auto list = orcapad_system_presets(presets->collection(kind));
        if (index < 0 || static_cast<size_t>(index) >= list.size())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "preset index was not found");
        const Slic3r::Preset &preset = *list[static_cast<size_t>(index)];

        // Vendor: walk parents via the collection so inherited profiles
        // (e.g. variant presets) still report their manufacturer.
        const Slic3r::VendorProfile *vendor = nullptr;
        if (preset.is_system) {
            const auto with_vendor = presets->collection(kind)
                .get_preset_with_vendor_profile(preset);
            vendor = with_vendor.vendor;
        }
        const std::string &vendor_name =
            vendor && !vendor->name.empty() ? vendor->name
                                            : (vendor ? vendor->id : "");

        orca_preset_entry entry;
        entry.name = orcapad_empty_string();
        entry.vendor = orcapad_empty_string();
        if (!orcapad_copy_string(preset.name.c_str(), &entry.name) ||
            !orcapad_copy_string(vendor_name.c_str(), &entry.vendor)) {
            orca_preset_entry_dispose(&entry);
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate preset entry");
        }
        entry.compatible = preset.is_compatible ? 1 : 0;
        *out_entry = entry;
        return orcapad_ok();
    });
}

orca_result orca_presets_print_volume(orca_presets *presets,
                                      double *out_min_x, double *out_min_y,
                                      double *out_max_x, double *out_max_y) {
    constexpr const char *operation = "orca_presets_print_volume";
    if (out_min_x) *out_min_x = 0.0;
    if (out_min_y) *out_min_y = 0.0;
    if (out_max_x) *out_max_x = 0.0;
    if (out_max_y) *out_max_y = 0.0;
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!out_min_x || !out_min_y || !out_max_x || !out_max_y)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");

    return orcapad_guard(operation, [&]() -> orca_result {
        const auto *area = presets->bundle->printers.get_selected_preset()
                               .config.option<Slic3r::ConfigOptionPoints>(
                                   "printable_area");
        if (!area || area->values.empty())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "selected machine defines no printable area");
        double min_x = area->values.front().x(), max_x = min_x;
        double min_y = area->values.front().y(), max_y = min_y;
        for (const auto &point : area->values) {
            min_x = std::min(min_x, point.x());
            max_x = std::max(max_x, point.x());
            min_y = std::min(min_y, point.y());
            max_y = std::max(max_y, point.y());
        }
        if (!(max_x > min_x) || !(max_y > min_y))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "printable area is degenerate");
        *out_min_x = min_x;
        *out_min_y = min_y;
        *out_max_x = max_x;
        *out_max_y = max_y;
        return orcapad_ok();
    });
}

orca_result orca_presets_resolved_config(orca_presets *presets,
                                         orca_owned_string *out_json) {
    constexpr const char *operation = "orca_presets_resolved_config";
    if (out_json) *out_json = orcapad_empty_string();
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!out_json)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");

    return orcapad_guard(operation, [&]() -> orca_result {
        const Slic3r::DynamicPrintConfig config =
            presets->bundle->full_config();
        nlohmann::json out = nlohmann::json::object();
        for (const std::string &key : config.keys())
            out[key] = config.opt_serialize(key);
        const std::string serialized = out.dump();
        if (!orcapad_copy_string(serialized.c_str(), out_json))
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate resolved config");
        return orcapad_ok();
    });
}

static orca_result orcapad_dump_config(const char *operation,
                                       const Slic3r::DynamicPrintConfig &config,
                                       orca_owned_string *out_json) {
    nlohmann::json out = nlohmann::json::object();
    for (const std::string &key : config.keys())
        out[key] = config.opt_serialize(key);
    const std::string serialized = out.dump();
    if (!orcapad_copy_string(serialized.c_str(), out_json))
        return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                            "could not allocate config dump");
    return orcapad_ok();
}

static bool orcapad_preset_kind_collection(int32_t kind,
                                          orca_presets *presets,
                                          Slic3r::PresetCollection **out) {
    if (!orcapad_valid_preset_kind(kind)) return false;
    *out = &presets->collection(kind);
    return true;
}

orca_result orca_presets_set_value(orca_presets *presets, int32_t kind,
                                   const char *key,
                                   const char *serialized_value) {
    constexpr const char *operation = "orca_presets_set_value";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!key || !key[0] || !serialized_value)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "key or value is empty");
    Slic3r::PresetCollection *collection = nullptr;
    if (!orcapad_preset_kind_collection(kind, presets, &collection))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::Preset &edited = collection->get_edited_preset();
        Slic3r::ConfigOption *option = edited.config.option(key, true);
        if (!option)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "unknown configuration key");
        option->deserialize(serialized_value, false);
        return orcapad_ok();
    });
}

orca_result orca_presets_reset_value(orca_presets *presets, int32_t kind,
                                     const char *key) {
    constexpr const char *operation = "orca_presets_reset_value";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!key || !key[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "key is empty");
    Slic3r::PresetCollection *collection = nullptr;
    if (!orcapad_preset_kind_collection(kind, presets, &collection))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::Preset &edited = collection->get_edited_preset();
        const Slic3r::ConfigOption *source =
            collection->get_selected_preset().config.option(key);
        if (source)
            edited.config.set_key_value(key, source->clone());
        else
            edited.config.erase(key);
        return orcapad_ok();
    });
}

orca_result orca_presets_reset_kind(orca_presets *presets, int32_t kind) {
    constexpr const char *operation = "orca_presets_reset_kind";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    Slic3r::PresetCollection *collection = nullptr;
    if (!orcapad_preset_kind_collection(kind, presets, &collection))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::Preset &edited = collection->get_edited_preset();
        edited.config = collection->get_selected_preset().config;
        return orcapad_ok();
    });
}

orca_result orca_presets_config_dump(orca_presets *presets, int32_t kind,
                                    uint8_t edited,
                                    orca_owned_string *out_json) {
    constexpr const char *operation = "orca_presets_config_dump";
    if (out_json) *out_json = orcapad_empty_string();
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!out_json)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    Slic3r::PresetCollection *collection = nullptr;
    if (!orcapad_preset_kind_collection(kind, presets, &collection))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        const Slic3r::Preset &preset = edited
            ? collection->get_edited_preset()
            : collection->get_selected_preset();
        return orcapad_dump_config(operation, preset.config, out_json);
    });
}

// --- plater session ------------------------------------------------------

struct orca_plater {
    Slic3r::Model model;
    orca_revision revision = 0;
    std::unordered_map<orca_object_id, uint64_t> mesh_revisions;
};

static Slic3r::ModelObject *plater_obj(orca_plater *plater,
                                      orca_object_id id) {
    if (!plater || id == 0 || id > std::numeric_limits<size_t>::max())
        return nullptr;
    for (Slic3r::ModelObject *object : plater->model.objects)
        if (object->id().id == static_cast<size_t>(id)) return object;
    return nullptr;
}

static Slic3r::ModelInstance *plater_instance(Slic3r::ModelObject *object,
                                              orca_instance_id id,
                                              size_t *out_index = nullptr) {
    if (!object || id == 0 || id > std::numeric_limits<size_t>::max())
        return nullptr;
    for (size_t index = 0; index < object->instances.size(); ++index) {
        Slic3r::ModelInstance *instance = object->instances[index];
        if (instance->id().id == static_cast<size_t>(id)) {
            if (out_index) *out_index = index;
            return instance;
        }
    }
    return nullptr;
}

static bool orcapad_revision_available(const orca_plater &plater) {
    return plater.revision < std::numeric_limits<orca_revision>::max();
}

static bool orcapad_valid_transform(const orca_instance_transform &transform) {
    return std::isfinite(transform.offset_x) &&
           std::isfinite(transform.offset_y) &&
           std::isfinite(transform.offset_z) &&
           std::isfinite(transform.rotation_z) &&
           std::isfinite(transform.scale) && transform.scale > 0.0;
}

orca_result orca_plater_new(orca_plater **out) {
    constexpr const char *operation = "orca_plater_new";
    if (out) *out = nullptr;
    if (!out)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        *out = new orca_plater();
        return orcapad_ok();
    });
}

void orca_plater_free(orca_plater *plater) { delete plater; }

orca_result orca_plater_add_stl(orca_plater *plater, const char *path,
                                double bed_center_x, double bed_center_y,
                                orca_object_id *out_object_id,
                                orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_add_stl";
    if (out_object_id) *out_object_id = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!path || !path[0] || !out_object_id || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "path is empty or output pointer is null");
    if (!std::isfinite(bed_center_x) || !std::isfinite(bed_center_y))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "bed center contains a non-finite value");
    struct stat path_status;
    if (stat(path, &path_status) != 0)
        return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                            "input file is not accessible");

    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        Slic3r::Model temporary = Slic3r::Model::read_from_file(path);
        if (temporary.objects.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "input contains no model object");
        Slic3r::ModelObject *imported = temporary.objects[0];
        // Desktop import parity: rotation/translation operate around the
        // object's bbox center, so recentre the mesh on the origin and place
        // the instance at the caller's bed center (selected machine's volume).
        imported->center_around_origin();
        if (!imported->instances.empty()) {
            Slic3r::ModelInstance *instance = imported->instances[0];
            const Slic3r::Vec3d offset = instance->get_offset();
            instance->set_offset(Slic3r::Vec3d(bed_center_x, bed_center_y,
                                               offset.z()));
        }
        imported->ensure_on_bed(false);
        Slic3r::ModelObject *object =
            plater->model.add_object(*imported);
        if (!object)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine did not create a document object");
        const orca_object_id id = static_cast<orca_object_id>(object->id().id);
        if (id == 0) {
            plater->model.delete_object(object);
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine returned an invalid object ID");
        }
        try {
            const auto inserted = plater->mesh_revisions.emplace(id, 1);
            if (!inserted.second) {
                plater->model.delete_object(object);
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine reused an existing object ID");
            }
        } catch (...) {
            plater->model.delete_object(object);
            throw;
        }
        ++plater->revision;
        *out_object_id = id;
        *out_revision = plater->revision;
        return orcapad_ok();
    });
}

orca_result orca_plater_object_delete(orca_plater *plater,
                                      orca_object_id object_id,
                                      orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_object_delete";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (!plater_obj(plater, object_id))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "object was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        if (!plater->model.delete_object(
                Slic3r::ObjectID(static_cast<size_t>(object_id))))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine did not delete the object");
        plater->mesh_revisions.erase(object_id);
        *out_revision = ++plater->revision;
        return orcapad_ok();
    });
}

orca_result orca_plater_instance_add(orca_plater *plater,
                                     orca_object_id object_id,
                                     orca_instance_id *out_instance_id,
                                     orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_instance_add";
    if (out_instance_id) *out_instance_id = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_instance_id || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "object was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        const size_t original_count = object->instances.size();
        Slic3r::ModelInstance *instance = object->instances.empty()
            ? object->add_instance()
            : object->add_instance(*object->instances.back());
        if (!instance)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine did not create an instance");
        try {
            instance->set_offset(instance->get_offset() +
                                 Slic3r::Vec3d(10.0, 10.0, 0.0));
            object->invalidate_bounding_box();
        } catch (...) {
            if (object->instances.size() > original_count)
                object->delete_instance(object->instances.size() - 1);
            throw;
        }
        const orca_instance_id id =
            static_cast<orca_instance_id>(instance->id().id);
        if (id == 0) {
            object->delete_instance(object->instances.size() - 1);
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine returned an invalid instance ID");
        }
        *out_instance_id = id;
        *out_revision = ++plater->revision;
        return orcapad_ok();
    });
}

orca_result orca_plater_instance_delete(orca_plater *plater,
                                        orca_object_id object_id,
                                        orca_instance_id instance_id,
                                        orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_instance_delete";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "object was not found");
        size_t instance_index = 0;
        if (!plater_instance(object, instance_id, &instance_index))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "instance was not found");
        if (object->instances.size() == 1)
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "last instance requires deleting the object");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        object->delete_instance(instance_index);
        *out_revision = ++plater->revision;
        return orcapad_ok();
    });
}

orca_result orca_plater_instance_set(orca_plater *plater,
                                     orca_object_id object_id,
                                     orca_instance_id instance_id,
                                     const orca_instance_transform *transform,
                                     orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_instance_set";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!transform || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "transform or output pointer is null");
    if (!orcapad_valid_transform(*transform))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "transform contains a non-finite value or invalid scale");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "object was not found");
        Slic3r::ModelInstance *instance = plater_instance(object, instance_id);
        if (!instance)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "instance was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        Slic3r::Geometry::Transformation candidate =
            instance->get_transformation();
        candidate.set_offset(Slic3r::Vec3d(
            transform->offset_x, transform->offset_y, transform->offset_z));
        candidate.set_rotation(
            Slic3r::Vec3d(0.0, 0.0, transform->rotation_z));
        candidate.set_scaling_factor(Slic3r::Vec3d(
            transform->scale, transform->scale, transform->scale));
        instance->set_transformation(candidate);
        object->invalidate_bounding_box();
        *out_revision = ++plater->revision;
        return orcapad_ok();
    });
}

orca_result orca_plater_ensure_on_bed(orca_plater *plater,
                                      orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_ensure_on_bed";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        Slic3r::Model candidate(plater->model);
        for (Slic3r::ModelObject *object : candidate.objects)
            object->ensure_on_bed(false);
        plater->model = std::move(candidate);
        *out_revision = ++plater->revision;
        return orcapad_ok();
    });
}

static orca_scene_snapshot orcapad_empty_snapshot() noexcept {
    return { 0, 0, nullptr, 0 };
}

void orca_scene_snapshot_dispose(orca_scene_snapshot *snapshot) {
    if (!snapshot) return;
    if (snapshot->objects) {
        for (int32_t index = 0; index < snapshot->object_count; ++index) {
            orca_scene_object &object = snapshot->objects[index];
            orca_owned_string_dispose(&object.name);
            std::free(object.positions);
            std::free(object.indices);
            std::free(object.instances);
        }
    }
    std::free(snapshot->objects);
    *snapshot = orcapad_empty_snapshot();
}

orca_result orca_plater_snapshot(orca_plater *plater,
                                 orca_scene_snapshot *out_snapshot) {
    constexpr const char *operation = "orca_plater_snapshot";
    if (out_snapshot) *out_snapshot = orcapad_empty_snapshot();
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_snapshot)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");

    return orcapad_guard(operation, [&]() -> orca_result {
        if (plater->model.objects.size() >
            static_cast<size_t>(std::numeric_limits<int32_t>::max()))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "object count exceeds ABI range");

        orca_scene_snapshot snapshot = orcapad_empty_snapshot();
        std::unique_ptr<orca_scene_snapshot,
                        void (*)(orca_scene_snapshot *)> cleanup(
            &snapshot, &orca_scene_snapshot_dispose);
        snapshot.document_id =
            static_cast<orca_document_id>(plater->model.id().id);
        snapshot.revision = plater->revision;
        snapshot.object_count =
            static_cast<int32_t>(plater->model.objects.size());
        if (snapshot.document_id == 0) {
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine returned an invalid document ID");
        }
        if (snapshot.object_count > 0) {
            snapshot.objects = static_cast<orca_scene_object *>(std::calloc(
                static_cast<size_t>(snapshot.object_count),
                sizeof(orca_scene_object)));
            if (!snapshot.objects)
                return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                    "could not allocate snapshot objects");
        }

        auto fail_snapshot = [&](orca_status_code code,
                                 const char *detail) -> orca_result {
            orca_scene_snapshot_dispose(&snapshot);
            return orcapad_fail(code, operation, detail);
        };

        for (int32_t object_index = 0;
             object_index < snapshot.object_count; ++object_index) {
            const Slic3r::ModelObject *model_object =
                plater->model.objects[static_cast<size_t>(object_index)];
            orca_scene_object &object = snapshot.objects[object_index];
            object.id = static_cast<orca_object_id>(model_object->id().id);
            if (object.id == 0)
                return fail_snapshot(ORCA_STATUS_INTERNAL_INVARIANT,
                                     "engine returned an invalid object ID");
            const auto mesh_revision = plater->mesh_revisions.find(object.id);
            if (mesh_revision == plater->mesh_revisions.end())
                return fail_snapshot(ORCA_STATUS_INTERNAL_INVARIANT,
                                     "object mesh revision is missing");
            object.mesh_revision = mesh_revision->second;
            if (!orcapad_copy_string(model_object->name.c_str(), &object.name))
                return fail_snapshot(ORCA_STATUS_OUT_OF_MEMORY,
                                     "could not allocate object name");

            const auto &indexed = model_object->raw_mesh().its;
            if (indexed.vertices.empty() || indexed.indices.empty())
                return fail_snapshot(ORCA_STATUS_INVALID_MODEL,
                                     "object mesh is empty");
            if (indexed.vertices.size() >
                    static_cast<size_t>(std::numeric_limits<int32_t>::max()) ||
                indexed.indices.size() >
                    static_cast<size_t>(std::numeric_limits<int32_t>::max() / 3))
                return fail_snapshot(ORCA_STATUS_INTERNAL_INVARIANT,
                                     "mesh exceeds ABI count range");

            object.position_count =
                static_cast<int32_t>(indexed.vertices.size());
            object.index_count =
                static_cast<int32_t>(indexed.indices.size() * 3);
            object.positions = static_cast<float *>(std::malloc(
                static_cast<size_t>(object.position_count) * 3 * sizeof(float)));
            object.indices = static_cast<uint32_t *>(std::malloc(
                static_cast<size_t>(object.index_count) * sizeof(uint32_t)));
            if (!object.positions || !object.indices)
                return fail_snapshot(ORCA_STATUS_OUT_OF_MEMORY,
                                     "could not allocate snapshot mesh");

            for (int axis = 0; axis < 3; ++axis) {
                object.bbox_min[axis] = std::numeric_limits<float>::max();
                object.bbox_max[axis] = std::numeric_limits<float>::lowest();
            }
            for (int32_t vertex_index = 0;
                 vertex_index < object.position_count; ++vertex_index) {
                const auto &vertex =
                    indexed.vertices[static_cast<size_t>(vertex_index)];
                for (int axis = 0; axis < 3; ++axis) {
                    const float coordinate = vertex(axis);
                    if (!std::isfinite(coordinate))
                        return fail_snapshot(ORCA_STATUS_INVALID_MODEL,
                                             "mesh contains a non-finite vertex");
                    object.positions[static_cast<size_t>(vertex_index) * 3 + axis] =
                        coordinate;
                    object.bbox_min[axis] =
                        std::min(object.bbox_min[axis], coordinate);
                    object.bbox_max[axis] =
                        std::max(object.bbox_max[axis], coordinate);
                }
            }
            object.pivot[0] = 0.5f * (object.bbox_min[0] + object.bbox_max[0]);
            object.pivot[1] = 0.5f * (object.bbox_min[1] + object.bbox_max[1]);
            object.pivot[2] = 0.0f;

            size_t flat_index = 0;
            for (const auto &triangle : indexed.indices)
                for (int corner = 0; corner < 3; ++corner) {
                    if (triangle(corner) < 0 ||
                        triangle(corner) >= object.position_count)
                        return fail_snapshot(ORCA_STATUS_INVALID_MODEL,
                                             "mesh index is out of range");
                    object.indices[flat_index++] =
                        static_cast<uint32_t>(triangle(corner));
                }

            if (model_object->instances.size() >
                static_cast<size_t>(std::numeric_limits<int32_t>::max()))
                return fail_snapshot(ORCA_STATUS_INTERNAL_INVARIANT,
                                     "instance count exceeds ABI range");
            object.instance_count =
                static_cast<int32_t>(model_object->instances.size());
            if (object.instance_count > 0) {
                object.instances = static_cast<orca_scene_instance *>(std::calloc(
                    static_cast<size_t>(object.instance_count),
                    sizeof(orca_scene_instance)));
                if (!object.instances)
                    return fail_snapshot(ORCA_STATUS_OUT_OF_MEMORY,
                                         "could not allocate snapshot instances");
            }
            for (int32_t instance_index = 0;
                 instance_index < object.instance_count; ++instance_index) {
                const Slic3r::ModelInstance *model_instance =
                    model_object->instances[static_cast<size_t>(instance_index)];
                orca_scene_instance &instance = object.instances[instance_index];
                instance.id =
                    static_cast<orca_instance_id>(model_instance->id().id);
                if (instance.id == 0)
                    return fail_snapshot(ORCA_STATUS_INTERNAL_INVARIANT,
                                         "engine returned an invalid instance ID");
                const Slic3r::Vec3d rotation = model_instance->get_rotation();
                const Slic3r::Vec3d scaling =
                    model_instance->get_scaling_factor();
                const Slic3r::Vec3d mirror = model_instance->get_mirror();
                if (std::abs(rotation.x()) > 1e-12 ||
                    std::abs(rotation.y()) > 1e-12 ||
                    std::abs(scaling.x() - scaling.y()) > 1e-12 ||
                    std::abs(scaling.x() - scaling.z()) > 1e-12 ||
                    !mirror.isApprox(Slic3r::Vec3d::Ones(), 1e-12))
                    return fail_snapshot(
                        ORCA_STATUS_UNSUPPORTED_CAPABILITY,
                        "snapshot transform is not unmirrored z-rotation with uniform scale");
                instance.transform.offset_x = model_instance->get_offset().x();
                instance.transform.offset_y = model_instance->get_offset().y();
                instance.transform.offset_z = model_instance->get_offset().z();
                instance.transform.rotation_z = rotation.z();
                instance.transform.scale = scaling.x();
                if (!orcapad_valid_transform(instance.transform))
                    return fail_snapshot(ORCA_STATUS_INTERNAL_INVARIANT,
                                         "engine returned an invalid transform");
            }
        }

        *out_snapshot = snapshot;
        cleanup.release();
        return orcapad_ok();
    });
}

// --- config overlays + shared slice-pipeline tail -------------------------

static void orcapad_config_overlays(Slic3r::DynamicPrintConfig &config) {
    // The preset-free compatibility path starts from raw defaults, which
    // carry physical values the desktop never emits because presets normally
    // override them. Never apply these values to a preset-backed slice.
    // filament_density = 0 in the exported gcode
    // SEGFAULTS desktop OrcaSlicer's gcode viewer (division by zero in
    // filament stats — proven by mutation test on a desktop-sliced
    // file, 2026-10-03). Generic-PLA overlay until presets land.
    config.set_key_value("filament_density", new Slic3r::ConfigOptionFloats{1.24});
    // `; nozzle_type =` (empty coEnums) round-trips as a ZERO-length
    // vector on desktop load; GCodeProcessor::update_slice_warnings()
    // then indexes nozzle_hrc_lists (sized by nozzle_type) through
    // m_filament_maps → out-of-bounds read → segfault (gdb-verified
    // 2026-10-03). Desktop presets always set a concrete value.
    // Mutate the def-created option in place — replacing it with a raw
    // ConfigOptionStrings swaps the dynamic type away from
    // ConfigOptionEnumsGenericNullable (typed accessor = bad cast).
    if (auto *nt = dynamic_cast<Slic3r::ConfigOptionStrings *>(
            config.option("nozzle_type", true)))
        nt->values = { "brass" };
}

static orca_result orcapad_run_print(const char *operation,
                                     Slic3r::Print &print,
                                     const char *gcode_path,
                                     orca_progress_fn progress, void *ctx,
                                     double *out_time_estimate_s,
                                     int64_t *out_gcode_bytes) {
    return orcapad_guard(operation, [&]() -> orca_result {
        print.set_status_callback(
            [progress, ctx](const Slic3r::PrintBase::SlicingStatus &status) {
                if (progress)
                    progress(static_cast<int32_t>(status.percent),
                             status.text.c_str(), ctx);
            });

        if (progress) progress(3, "slicing", ctx);
        print.process();

        if (progress) progress(98, "exporting gcode", ctx);
        Slic3r::GCodeProcessorResult processor_result;
        const std::string final_path =
            print.export_gcode(gcode_path, &processor_result, nullptr);
        if (final_path.empty())
            return orcapad_fail(ORCA_STATUS_ENGINE_FAILURE, operation,
                                "engine returned an empty G-code path");

        struct stat file_status;
        if (stat(final_path.c_str(), &file_status) != 0)
            return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                                "exported G-code could not be inspected");
        if (file_status.st_size < 0)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "exported G-code has a negative size");
        if (processor_result.print_statistics.modes.empty())
            return orcapad_fail(ORCA_STATUS_ENGINE_FAILURE, operation,
                                "engine returned no print-time estimate");

        *out_gcode_bytes = static_cast<int64_t>(file_status.st_size);
        *out_time_estimate_s =
            processor_result.print_statistics.modes.front().time;
        if (progress) progress(100, "done", ctx);
        return orcapad_ok();
    });
}

orca_result orca_slice_to_gcode(const char *stl_path, const char *gcode_path,
                                orca_progress_fn progress, void *ctx,
                                double *out_time_estimate_s,
                                int64_t *out_gcode_bytes) {
    constexpr const char *operation = "orca_slice_to_gcode";
    if (out_time_estimate_s) *out_time_estimate_s = -1.0;
    if (out_gcode_bytes) *out_gcode_bytes = -1;
    if (!stl_path || !stl_path[0] || !gcode_path || !gcode_path[0] ||
        !out_time_estimate_s || !out_gcode_bytes)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "path is empty or output pointer is null");
    struct stat path_status;
    if (stat(stl_path, &path_status) != 0)
        return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                            "input file is not accessible");

    return orcapad_guard(operation, [&]() -> orca_result {
        if (progress) progress(1, "loading model", ctx);
        Slic3r::Model model = Slic3r::Model::read_from_file(stl_path);
        if (model.objects.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "input contains no model object");

        Slic3r::DynamicPrintConfig config =
            Slic3r::DynamicPrintConfig::full_print_config();
        orcapad_config_overlays(config);

        if (progress) progress(2, "applying config", ctx);
        Slic3r::Print print;
        print.apply(model, std::move(config));
        print.is_BBL_printer() = false;
        return orcapad_run_print(operation, print, gcode_path, progress, ctx,
                                 out_time_estimate_s, out_gcode_bytes);
    });
}

orca_result orca_plater_slice_to_gcode(orca_plater *plater,
                                       const char *gcode_path,
                                       orca_progress_fn progress, void *ctx,
                                       double *out_time_estimate_s,
                                       int64_t *out_gcode_bytes) {
    constexpr const char *operation = "orca_plater_slice_to_gcode";
    if (out_time_estimate_s) *out_time_estimate_s = -1.0;
    if (out_gcode_bytes) *out_gcode_bytes = -1;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!gcode_path || !gcode_path[0] || !out_time_estimate_s ||
        !out_gcode_bytes)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "path is empty or output pointer is null");
    if (plater->model.objects.empty())
        return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                            "document contains no model object");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::DynamicPrintConfig config =
            Slic3r::DynamicPrintConfig::full_print_config();
        orcapad_config_overlays(config);
        if (progress) progress(1, "applying plater", ctx);
        Slic3r::Print print;
        print.apply(plater->model, std::move(config));
        print.is_BBL_printer() = false;
        return orcapad_run_print(operation, print, gcode_path, progress, ctx,
                                 out_time_estimate_s, out_gcode_bytes);
    });
}

orca_result orca_plater_slice_to_gcode_with_presets(
    orca_plater *plater, orca_presets *presets, const char *gcode_path,
    orca_progress_fn progress, void *ctx, double *out_time_estimate_s,
    int64_t *out_gcode_bytes) {
    constexpr const char *operation =
        "orca_plater_slice_to_gcode_with_presets";
    if (out_time_estimate_s) *out_time_estimate_s = -1.0;
    if (out_gcode_bytes) *out_gcode_bytes = -1;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!gcode_path || !gcode_path[0] || !out_time_estimate_s ||
        !out_gcode_bytes)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "path is empty or output pointer is null");
    if (plater->model.objects.empty())
        return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                            "document contains no model object");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::DynamicPrintConfig config = presets->bundle->full_config();
        if (progress) progress(1, "applying presets", ctx);
        Slic3r::Print print;
        print.apply(plater->model, std::move(config));
        print.is_BBL_printer() = presets->bundle->is_bbl_vendor();
        return orcapad_run_print(operation, print, gcode_path, progress, ctx,
                                 out_time_estimate_s, out_gcode_bytes);
    });
}
