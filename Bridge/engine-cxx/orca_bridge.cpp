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

/// Listed presets: every non-default preset (system, user, project-embedded,
/// external), sorted by name — the canonical stable order shared by
/// orca_presets_list_name and orca_presets_list_entry.
static std::vector<const Slic3r::Preset *> orcapad_listed_presets(
    const Slic3r::PresetCollection &collection) {
    std::vector<const Slic3r::Preset *> presets;
    for (const Slic3r::Preset &preset : collection)
        if (!preset.is_default) presets.push_back(&preset);
    std::sort(presets.begin(), presets.end(),
              [](const Slic3r::Preset *a, const Slic3r::Preset *b) {
                  return a->name < b->name;
              });
    return presets;
}

static uint8_t orcapad_preset_origin(const Slic3r::Preset &preset) {
    if (preset.is_system) return ORCA_PRESET_ORIGIN_SYSTEM;
    if (preset.is_project_embedded) return ORCA_PRESET_ORIGIN_PROJECT;
    if (preset.is_external) return ORCA_PRESET_ORIGIN_EXTERNAL;
    return ORCA_PRESET_ORIGIN_USER;
}

static bool orcapad_has_listed_preset(
    Slic3r::PresetCollection &collection, const char *name) {
    const Slic3r::Preset *preset = collection.find_preset(name, false, true);
    return preset && !preset->is_default && preset->name == name;
}

// --- plate (bed) type: desktop Sidebar::update_presets / reset_bed_type_combox_choices

static orca_bed_type_state orcapad_bed_type_state(Slic3r::PresetBundle &bundle) {
    orca_bed_type_state state{};
    state.count = static_cast<int32_t>(Slic3r::btCount);
    const Slic3r::Preset &printer = bundle.printers.get_selected_preset();
    Slic3r::Preset &edited = bundle.printers.get_edited_preset();
    state.machine_default = static_cast<int32_t>(edited.get_default_bed_type(&bundle));
    const Slic3r::DynamicPrintConfig &config = edited.config;
    const bool multi = config.has("support_multi_bed_types") &&
                       config.opt_bool("support_multi_bed_types");
    state.selectable = (bundle.is_bbl_vendor() || multi) ? 1 : 0;

    const Slic3r::VendorProfile::PrinterModel *model =
        Slic3r::PresetUtils::system_printer_model(printer);
    if (!model) {
        if (const Slic3r::Preset *parent = bundle.printers.get_selected_preset_parent())
            model = Slic3r::PresetUtils::system_printer_model(*parent);
    }
    const Slic3r::ConfigOptionDef *def = Slic3r::print_config_def.get("curr_bed_type");
    if (!def)
        throw std::logic_error("curr_bed_type is not defined by print_config_def");
    int32_t value = 0;
    for (const std::string &label : def->enum_labels) {
        ++value;
        if (value >= state.count) break;
        const bool unsupported = model &&
            std::find(model->not_support_bed_types.begin(),
                      model->not_support_bed_types.end(), label) !=
                model->not_support_bed_types.end();
        if (!unsupported) state.supported_mask |= (1u << value);
    }

    const auto *current = bundle.project_config.option<
        Slic3r::ConfigOptionEnum<Slic3r::BedType>>("curr_bed_type");
    state.current = current ? static_cast<int32_t>(current->value) : 0;
    return state;
}

static void orcapad_apply_bed_type(Slic3r::PresetBundle &bundle, Slic3r::BedType type) {
    bundle.project_config.set_key_value(
        "curr_bed_type", new Slic3r::ConfigOptionEnum<Slic3r::BedType>(type));
}

static void orcapad_apply_default_bed_type(Slic3r::PresetBundle &bundle) {
    const orca_bed_type_state state = orcapad_bed_type_state(bundle);
    if (state.machine_default <= 0 || state.machine_default >= state.count)
        throw std::logic_error("machine default bed type is out of range");
    orcapad_apply_bed_type(bundle, static_cast<Slic3r::BedType>(state.machine_default));
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
        orcapad_apply_default_bed_type(*presets->bundle);
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
            orcapad_listed_presets(presets->collection(kind)).size();
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
        const auto listed =
            orcapad_listed_presets(presets->collection(kind));
        if (index < 0 || static_cast<size_t>(index) >= listed.size())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "preset index was not found");
        if (!orcapad_copy_string(listed[static_cast<size_t>(index)]->name.c_str(), out_name))
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
        if (!orcapad_has_listed_preset(
                presets->bundle->printers, machine))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "machine preset was not found");
        if (!orcapad_has_listed_preset(
                presets->bundle->filaments, filament))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "filament preset was not found");
        if (!orcapad_has_listed_preset(
                presets->bundle->prints, process))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "process preset was not found");

        auto candidate =
            std::make_unique<Slic3r::PresetBundle>(*presets->bundle);
        candidate->printers.select_preset_by_name(machine, false);
        candidate->update_compatible(
            Slic3r::PresetSelectCompatibleType::Always);
        candidate->filaments.select_preset_by_name(filament, false);
        // desktop Sidebar filament combo: the bundle's per-extruder filament
        // list drives full_config metadata (inherits, settings ids)
        candidate->set_filament_preset(0, filament);
        candidate->prints.select_preset_by_name(process, false);
        if (candidate->printers.get_selected_preset().name != machine ||
            candidate->filaments.get_selected_preset().name != filament ||
            candidate->filament_presets.empty() ||
            candidate->filament_presets.front() != filament ||
            candidate->prints.get_selected_preset().name != process)
            return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                "preset combination is not selectable");

        if (presets->bundle->printers.get_selected_preset().name != machine)
            orcapad_apply_default_bed_type(*candidate);

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
    entry->origin = 0;
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
        const auto list = orcapad_listed_presets(presets->collection(kind));
        if (index < 0 || static_cast<size_t>(index) >= list.size())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "preset index was not found");
        const Slic3r::Preset &preset = *list[static_cast<size_t>(index)];

        // Vendor: walk parents via the collection so inherited profiles
        // (variants, user/project presets inheriting a system preset) still
        // report their manufacturer.
        const Slic3r::VendorProfile *vendor = presets->collection(kind)
            .get_preset_with_vendor_profile(preset).vendor;
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
        entry.origin = orcapad_preset_origin(preset);
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

// --- user presets (desktop Tab::save_preset / delete_preset) ----------------

static bool orcapad_preset_kind_collection(int32_t kind, orca_presets *presets,
                                           Slic3r::PresetCollection **out);

static const char *orcapad_invalid_preset_name(Slic3r::PresetCollection &collection,
                                               const std::string &name) {
    // SavePresetDialog::Item::update (src/slic3r/GUI/SavePresetDialog.cpp)
    if (name.empty()) return "The name is not allowed to be empty.";
    if (name.find_first_of("<>[]:/\\|?*\"") != std::string::npos)
        return "Name is invalid; illegal characters: <>[]:/\\|?*\"";
    if (name.find(Slic3r::PresetCollection::get_suffix_modified()) != std::string::npos)
        return "Name is invalid; illegal suffix: (modified)";
    if (name == "Default Setting" || name == "Default Printer" ||
        name == Slic3r::PresetBundle::ORCA_DEFAULT_FILAMENT_PLACEHOLDER)
        return "Name is unavailable.";
    if (name.front() == ' ') return "The name is not allowed to start with space character.";
    if (name.back() == ' ') return "The name is not allowed to end with space character.";
    if (collection.get_preset_name_by_alias(name) != name)
        return "The name cannot be the same as a preset alias name.";
    return nullptr;
}

orca_result orca_presets_save_user(orca_presets *presets, int32_t kind,
                                   const char *name, uint8_t detach) {
    constexpr const char *operation = "orca_presets_save_user";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "presets handle is null");
    if (!name)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "name is null");
    Slic3r::PresetCollection *collection = nullptr;
    if (!orcapad_preset_kind_collection(kind, presets, &collection))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::PresetBundle &bundle = *presets->bundle;
        const std::string preset_name(name);
        if (const char *invalid = orcapad_invalid_preset_name(*collection, preset_name))
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, invalid);
        Slic3r::Preset *existing = collection->find_preset(preset_name, false);
        if (existing && existing->name == preset_name && !existing->can_overwrite())
            return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                "Overwriting a system profile is not allowed.");
        const bool exists = existing && existing->name == preset_name;

        // Orca (Tab::save_preset): a new filament derived from a system
        // preset is restricted to the current printer unless already scoped
        Slic3r::Preset &edited = collection->get_edited_preset();
        if (kind == 1 && !exists && edited.is_system) {
            const Slic3r::Preset &printer = bundle.printers.get_selected_preset_base();
            auto *compatible = edited.config.option<Slic3r::ConfigOptionStrings>("compatible_printers");
            if (compatible && compatible->values.empty())
                compatible->values.push_back(printer.name);
        }

        collection->save_current_preset(preset_name, detach != 0, false, nullptr);
        Slic3r::Preset *saved = collection->find_preset(preset_name, false, true);
        if (!saved || saved->name != preset_name || saved->is_system)
            return orcapad_fail(ORCA_STATUS_ENGINE_FAILURE, operation,
                                "engine did not create the user preset");
        saved->sync_info = exists ? "update" : "create";
        saved->save_info();
        if (kind == 1) bundle.set_filament_preset(0, preset_name);
        bundle.update_compatible(Slic3r::PresetSelectCompatibleType::Never);
        return orcapad_ok();
    });
}

orca_result orca_presets_delete_user(orca_presets *presets, int32_t kind,
                                     const char *name) {
    constexpr const char *operation = "orca_presets_delete_user";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "presets handle is null");
    if (!name || !name[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "name is empty");
    Slic3r::PresetCollection *collection = nullptr;
    if (!orcapad_preset_kind_collection(kind, presets, &collection))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::PresetBundle &bundle = *presets->bundle;
        Slic3r::Preset *preset = collection->find_preset(name, false, true);
        if (!preset || preset->name != name)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "preset was not found");
        if (!preset->can_overwrite() || preset->is_external)
            return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                "only user presets can be deleted");
        for (const Slic3r::Preset &other : *collection)
            if (other.inherits() == preset->name)
                return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                    "Presets inherited by other presets cannot be deleted!");
        const bool selected = collection->get_selected_preset().name == preset->name;
        if (selected) {
            if (!collection->delete_current_preset())
                return orcapad_fail(ORCA_STATUS_ENGINE_FAILURE, operation,
                                    "engine refused to delete the selected preset");
        } else if (!collection->delete_preset(preset->name)) {
            return orcapad_fail(ORCA_STATUS_ENGINE_FAILURE, operation,
                                "engine refused to delete the preset");
        }
        if (kind == 1)
            bundle.set_filament_preset(0, bundle.filaments.get_selected_preset_name());
        bundle.update_compatible(Slic3r::PresetSelectCompatibleType::Never);
        return orcapad_ok();
    });
}

orca_result orca_presets_bed_type(orca_presets *presets,
                                  orca_bed_type_state *out_state) {
    constexpr const char *operation = "orca_presets_bed_type";
    if (out_state) *out_state = orca_bed_type_state{};
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!out_state)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        const orca_bed_type_state state = orcapad_bed_type_state(*presets->bundle);
        if (state.current <= 0 || state.current >= state.count)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "project curr_bed_type is unset or out of range");
        *out_state = state;
        return orcapad_ok();
    });
}

orca_result orca_presets_set_bed_type(orca_presets *presets, int32_t bed_type) {
    constexpr const char *operation = "orca_presets_set_bed_type";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        const orca_bed_type_state state = orcapad_bed_type_state(*presets->bundle);
        if (bed_type <= 0 || bed_type >= state.count)
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "bed type is out of range");
        if (!(state.supported_mask & (1u << bed_type)))
            return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                "printer model does not support this bed type");
        if (!state.selectable && bed_type != state.machine_default)
            return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                "machine does not offer selectable bed types");
        orcapad_apply_bed_type(*presets->bundle, static_cast<Slic3r::BedType>(bed_type));
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
    const double values[] = {
        transform.offset_x, transform.offset_y, transform.offset_z,
        transform.rotation_x, transform.rotation_y, transform.rotation_z,
        transform.scale_x, transform.scale_y, transform.scale_z,
    };
    for (double value : values)
        if (!std::isfinite(value)) return false;
    return transform.scale_x > 0.0 && transform.scale_y > 0.0 &&
           transform.scale_z > 0.0;
}

/// Desktop manipulation parity: after any transform the instance rests on
/// the bed — its exact transformed bounding box (upstream
/// ModelObject::instance_bounding_box) touches z = 0.
static void orcapad_rest_on_bed(Slic3r::ModelObject *object,
                                Slic3r::ModelInstance *instance) {
    object->invalidate_bounding_box();
    const Slic3r::BoundingBoxf3 box = object->instance_bounding_box(*instance);
    if (!box.defined) return;
    Slic3r::Vec3d offset = instance->get_offset();
    offset.z() -= box.min.z();
    instance->set_offset(offset);
    object->invalidate_bounding_box();
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

orca_result orca_plater_import_model(orca_plater *plater, const char *path,
                                     double bed_center_x, double bed_center_y,
                                     orca_object_id *out_first_object_id,
                                     uint32_t *out_object_count,
                                     orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_import_model";
    if (out_first_object_id) *out_first_object_id = 0;
    if (out_object_count) *out_object_count = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!path || !path[0] || !out_first_object_id || !out_object_count ||
        !out_revision)
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
        // Geometry import (desktop "Import 3MF/STL/OBJ/AMF"): configs inside
        // project files are NOT applied here — that is project open.
        Slic3r::Model temporary = Slic3r::Model::read_from_file(
            path, nullptr, nullptr,
            Slic3r::LoadStrategy::AddDefaultInstances | Slic3r::LoadStrategy::LoadModel);
        if (temporary.objects.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "input contains no model object");

        // 1) center meshes (desktop rotation/scale pivot) while preserving
        //    each instance's world placement: o' = o - L * shift
        Slic3r::BoundingBoxf3 group;
        for (Slic3r::ModelObject *object : temporary.objects) {
            if (object->instances.empty())
                return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                    "imported object has no instance");
            const Slic3r::Vec3d shift = -object->raw_mesh_bounding_box().center();
            object->center_around_origin();
            for (Slic3r::ModelInstance *instance : object->instances) {
                const Slic3r::Vec3d delta = instance->get_matrix().linear() * shift;
                instance->set_offset(instance->get_offset() - delta);
            }
            for (size_t i = 0; i < object->instances.size(); ++i)
                group.merge(object->instance_bounding_box(i));
        }
        if (!group.defined)
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "imported geometry has no bounds");
        // 2) move the group's XY center to the bed center, 3) drop to bed
        const Slic3r::Vec3d move(bed_center_x - group.center().x(),
                                 bed_center_y - group.center().y(), 0.0);
        for (Slic3r::ModelObject *object : temporary.objects) {
            object->translate_instances(move);
            object->ensure_on_bed(false);
        }

        std::vector<Slic3r::ModelObject *> added;
        auto rollback = [&]() {
            for (Slic3r::ModelObject *object : added) {
                plater->mesh_revisions.erase(
                    static_cast<orca_object_id>(object->id().id));
                plater->model.delete_object(object);
            }
        };
        try {
            for (Slic3r::ModelObject *source : temporary.objects) {
                Slic3r::ModelObject *object = plater->model.add_object(*source);
                if (!object) {
                    rollback();
                    return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                        "engine did not create a document object");
                }
                added.push_back(object);
                const orca_object_id id = static_cast<orca_object_id>(object->id().id);
                if (id == 0 || !plater->mesh_revisions.emplace(id, 1).second) {
                    rollback();
                    return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                        "engine returned an invalid or reused object ID");
                }
            }
        } catch (...) {
            rollback();
            throw;
        }
        ++plater->revision;
        *out_first_object_id = static_cast<orca_object_id>(added.front()->id().id);
        *out_object_count = static_cast<uint32_t>(added.size());
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
        const Slic3r::Geometry::Transformation original =
            instance->get_transformation();
        Slic3r::Geometry::Transformation candidate = original;
        candidate.set_offset(Slic3r::Vec3d(
            transform->offset_x, transform->offset_y, transform->offset_z));
        candidate.set_rotation(Slic3r::Vec3d(
            transform->rotation_x, transform->rotation_y, transform->rotation_z));
        candidate.set_scaling_factor(Slic3r::Vec3d(
            transform->scale_x, transform->scale_y, transform->scale_z));
        try {
            instance->set_transformation(candidate);
            orcapad_rest_on_bed(object, instance);
        } catch (...) {
            instance->set_transformation(original);
            object->invalidate_bounding_box();
            throw;
        }
        *out_revision = ++plater->revision;
        return orcapad_ok();
    });
}

orca_result orca_plater_instance_rotate(orca_plater *plater,
                                        orca_object_id object_id,
                                        orca_instance_id instance_id,
                                        int32_t axis, double radians,
                                        orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_instance_rotate";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (axis < 0 || axis > 2)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "axis must be 0 (X), 1 (Y), or 2 (Z)");
    if (!std::isfinite(radians))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "rotation angle is not finite");
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
        const Slic3r::Vec3d world_axis = axis == 0 ? Slic3r::Vec3d::UnitX()
            : axis == 1 ? Slic3r::Vec3d::UnitY() : Slic3r::Vec3d::UnitZ();
        const Slic3r::Geometry::Transformation original =
            instance->get_transformation();
        try {
            instance->rotate(Eigen::AngleAxisd(radians, world_axis)
                                 .toRotationMatrix());
            orcapad_rest_on_bed(object, instance);
        } catch (...) {
            instance->set_transformation(original);
            object->invalidate_bounding_box();
            throw;
        }
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
                if (model_instance->is_left_handed())
                    return fail_snapshot(
                        ORCA_STATUS_UNSUPPORTED_CAPABILITY,
                        "mirrored instances are not supported");
                const Slic3r::Vec3d offset = model_instance->get_offset();
                instance.transform.offset_x = offset.x();
                instance.transform.offset_y = offset.y();
                instance.transform.offset_z = offset.z();
                instance.transform.rotation_x = rotation.x();
                instance.transform.rotation_y = rotation.y();
                instance.transform.rotation_z = rotation.z();
                instance.transform.scale_x = scaling.x();
                instance.transform.scale_y = scaling.y();
                instance.transform.scale_z = scaling.z();
                const Slic3r::Transform3d matrix = model_instance->get_matrix();
                for (int column = 0; column < 4; ++column)
                    for (int row = 0; row < 4; ++row) {
                        const double value = matrix(row, column);
                        if (!std::isfinite(value))
                            return fail_snapshot(ORCA_STATUS_INTERNAL_INVARIANT,
                                                 "engine returned a non-finite matrix");
                        instance.matrix[column * 4 + row] = value;
                    }
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

// --- G-code toolpath preview ----------------------------------------------

struct orca_gcode {
    Slic3r::GCodeProcessorResult result;
};

/// Sniffs which feature-tag dialect the file uses ("; FEATURE:" BBL style
/// vs ";TYPE:" compatible) so the processor parses roles written by either
/// exporter configuration.
static bool orcapad_gcode_uses_bbl_tags(const char *path) {
    std::ifstream file(path, std::ios::in | std::ios::binary);
    if (!file) return false;
    std::string chunk;
    chunk.resize(1 << 20); // 1 MiB is far beyond any header block
    file.read(chunk.data(), static_cast<std::streamsize>(chunk.size()));
    chunk.resize(static_cast<size_t>(file.gcount()));
    return chunk.find(";FEATURE:") != std::string::npos ||
           chunk.find("; FEATURE:") != std::string::npos;
}

orca_result orca_gcode_load(const char *path, orca_gcode **out_gcode) {
    constexpr const char *operation = "orca_gcode_load";
    if (out_gcode) *out_gcode = nullptr;
    if (!out_gcode)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!path || !path[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "path is empty");
    struct stat path_status;
    if (stat(path, &path_status) != 0)
        return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                            "input file is not accessible");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::GCodeProcessor::s_IsBBLPrinter =
            orcapad_gcode_uses_bbl_tags(path);
        Slic3r::GCodeProcessor processor;
        processor.init_filament_maps_and_nozzle_type_when_import_only_gcode();
        processor.process_file(path);
        auto handle = std::make_unique<orca_gcode>();
        handle->result = processor.extract_result();
        if (handle->result.moves.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "gcode contains no moves");
        *out_gcode = handle.release();
        return orcapad_ok();
    });
}

void orca_gcode_free(orca_gcode *gcode) { delete gcode; }

void orca_toolpath_dispose(orca_toolpath *toolpath) {
    if (!toolpath) return;
    std::free(toolpath->segments);
    std::free(toolpath->layers);
    *toolpath = orca_toolpath{};
}

orca_result orca_gcode_toolpath(orca_gcode *gcode,
                                orca_toolpath *out_toolpath) {
    constexpr const char *operation = "orca_gcode_toolpath";
    if (out_toolpath) *out_toolpath = orca_toolpath{};
    if (!gcode)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "gcode handle is null");
    if (!out_toolpath)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");

    return orcapad_guard(operation, [&]() -> orca_result {
        const auto &moves = gcode->result.moves;

        size_t segment_count = 0;
        size_t layer_count = 0;
        uint32_t previous_layer = std::numeric_limits<uint32_t>::max();
        for (size_t i = 1; i < moves.size(); ++i) {
            const auto type = moves[i].type;
            if (type != Slic3r::EMoveType::Extrude &&
                type != Slic3r::EMoveType::Travel)
                continue;
            ++segment_count;
            if (moves[i].layer_id != previous_layer) {
                ++layer_count;
                previous_layer = moves[i].layer_id;
            }
        }
        if (segment_count == 0 || layer_count == 0)
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "gcode contains no printable moves");
        if (segment_count > std::numeric_limits<uint32_t>::max() ||
            layer_count > std::numeric_limits<uint32_t>::max())
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "toolpath exceeds ABI count range");

        orca_toolpath toolpath = orca_toolpath{};
        toolpath.segment_count = static_cast<uint32_t>(segment_count);
        toolpath.layer_count = static_cast<uint32_t>(layer_count);
        toolpath.segments = static_cast<orca_tp_segment *>(
            std::malloc(segment_count * sizeof(orca_tp_segment)));
        toolpath.layers = static_cast<orca_tp_layer *>(
            std::calloc(layer_count, sizeof(orca_tp_layer)));
        if (!toolpath.segments || !toolpath.layers) {
            orca_toolpath_dispose(&toolpath);
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate toolpath");
        }

        size_t out = 0;
        uint32_t layer_index = 0;
        bool layer_open = false;
        uint32_t open_layer_id = 0;
        for (size_t i = 1; i < moves.size(); ++i) {
            const auto &move = moves[i];
            if (move.type != Slic3r::EMoveType::Extrude &&
                move.type != Slic3r::EMoveType::Travel)
                continue;
            if (move.layer_id > std::numeric_limits<uint16_t>::max()) {
                orca_toolpath_dispose(&toolpath);
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "layer id exceeds ABI range");
            }
            // Layers are keyed by the engine's layer_id (z can climb within a
            // layer — spiral vase); the layer record carries its first z.
            if (!layer_open || move.layer_id != open_layer_id) {
                if (layer_open) ++layer_index;
                open_layer_id = move.layer_id;
                toolpath.layers[layer_index].z = move.print_z;
                toolpath.layers[layer_index].first_segment =
                    static_cast<uint32_t>(out);
                toolpath.layers[layer_index].segment_count = 0;
                toolpath.layers[layer_index].time_seconds = 0.0f;
                layer_open = true;
            }
            const auto &previous = moves[i - 1].position;
            orca_tp_segment &segment = toolpath.segments[out];
            segment.start[0] = previous.x();
            segment.start[1] = previous.y();
            segment.start[2] = previous.z();
            segment.end[0] = move.position.x();
            segment.end[1] = move.position.y();
            segment.end[2] = move.position.z();
            segment.feedrate = move.feedrate;
            segment.width = move.width;
            segment.height = move.height;
            segment.mm3_per_mm = move.mm3_per_mm;
            segment.move_type = static_cast<uint8_t>(move.type);
            segment.role = static_cast<uint8_t>(move.extrusion_role);
            segment.extruder = move.extruder_id;
            segment.flags = move.internal_only ? 1 : 0;
            segment.layer_id = static_cast<uint16_t>(move.layer_id);
            segment.reserved = 0;
            segment.print_z = move.print_z;
            segment.time_seconds = move.time[static_cast<size_t>(
                Slic3r::PrintEstimatedStatistics::ETimeMode::Normal)];
            segment.fan_speed = move.fan_speed;
            segment.temperature = move.temperature;
            ++out;
            orca_tp_layer &layer = toolpath.layers[layer_index];
            layer.segment_count += 1;
            layer.time_seconds += move.time[static_cast<size_t>(
                Slic3r::PrintEstimatedStatistics::ETimeMode::Normal)];
        }

        toolpath.estimated_time_seconds =
            gcode->result.print_statistics
                .modes[static_cast<size_t>(
                    Slic3r::PrintEstimatedStatistics::ETimeMode::
                        Normal)]
                .time;
        toolpath.printable_height = gcode->result.printable_height;
        *out_toolpath = toolpath;
        return orcapad_ok();
    });
}


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
    // vector on load; GCodeProcessor::update_slice_warnings()
    // then indexes nozzle_hrc_lists (sized by nozzle_type) through
    // m_filament_maps → out-of-bounds read → segfault (gdb-verified
    // 2026-10-03, re-verified on the OrcaPad host loader 2026-10-06).
    // Desktop presets always set a concrete value.
    // CORRECTION 2026-10-06: ConfigOptionEnumsGenericTempl derives from
    // ConfigOptionINTS and serializes through keys_map — the old Strings
    // cast never matched AND full_print_config()'s static default instance
    // carries a NULL keys_map, so "brass" silently never landed in exported
    // gcode (re-verified: empty `; nozzle_type =` → loader OOB). Set the enum
    // ordinal AND wire keys_map from the pinned def; dynamic type stays
    // EnumsGenericNullable.
    if (auto *nt = dynamic_cast<Slic3r::ConfigOptionEnumsGenericNullable *>(
            config.option("nozzle_type", true))) {
        if (nt->keys_map == nullptr) {
            const auto def = Slic3r::print_config_def.options.find(
                "nozzle_type");
            if (def != Slic3r::print_config_def.options.end())
                nt->keys_map = def->second.enum_keys_map;
        }
        nt->values = { int(Slic3r::NozzleType::ntBrass) };
    }
    // Raw defaults use relative E without a per-layer reset, which
    // Print::validate rejects (Print.cpp: G92 E0 required in
    // before/layer_change_gcode for Marlin flavours). Common system
    // profiles carry exactly this layer_change_gcode.
    config.set_key_value("layer_change_gcode", new Slic3r::ConfigOptionString("G92 E0"));
}

// --- slice jobs (cancellation) -------------------------------------------

struct orca_slice_job {
    std::mutex mutex;
    bool cancelled = false;
    Slic3r::PrintBase *active = nullptr;
};

orca_result orca_slice_job_new(orca_slice_job **out_job) {
    constexpr const char *operation = "orca_slice_job_new";
    if (out_job) *out_job = nullptr;
    if (!out_job)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    try {
        *out_job = new orca_slice_job();
        return orcapad_ok();
    } catch (const std::bad_alloc &) {
        return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                            "allocation failed");
    }
}

void orca_slice_job_cancel(orca_slice_job *job) {
    if (!job) return;
    std::lock_guard<std::mutex> lock(job->mutex);
    job->cancelled = true;
    if (job->active) job->active->cancel(); // atomic store, thread safe
}

void orca_slice_job_free(orca_slice_job *job) { delete job; }

/// Registers `print` with the job for the duration of a slice.
class OrcapadJobRegistration {
public:
    OrcapadJobRegistration(orca_slice_job *job, Slic3r::PrintBase &print)
        : m_job(job) {
        if (!m_job) return;
        std::lock_guard<std::mutex> lock(m_job->mutex);
        m_job->active = &print;
        if (m_job->cancelled) print.cancel();
    }
    ~OrcapadJobRegistration() {
        if (!m_job) return;
        std::lock_guard<std::mutex> lock(m_job->mutex);
        m_job->active = nullptr;
    }
    OrcapadJobRegistration(const OrcapadJobRegistration &) = delete;
    OrcapadJobRegistration &operator=(const OrcapadJobRegistration &) = delete;

private:
    orca_slice_job *m_job;
};

// --- slice report ---------------------------------------------------------

struct OrcapadWarning {
    int32_t level;
    int32_t source;
    std::string code;
    std::string message;
    std::string detail;
};

void orca_slice_report_dispose(orca_slice_report *report) {
    if (!report) return;
    for (uint32_t i = 0; i < report->warning_count && report->warnings; ++i) {
        orca_owned_string_dispose(&report->warnings[i].code);
        orca_owned_string_dispose(&report->warnings[i].message);
        orca_owned_string_dispose(&report->warnings[i].detail);
    }
    std::free(report->warnings);
    *report = orca_slice_report{};
}

static int32_t orcapad_warning_level(Slic3r::PrintStateBase::WarningLevel level) {
    return level == Slic3r::PrintStateBase::WarningLevel::CRITICAL
               ? ORCA_SLICE_WARNING_CRITICAL
               : ORCA_SLICE_WARNING_WARNING;
}

static void orcapad_collect_step_warnings(const Slic3r::Print &print,
                                          std::vector<OrcapadWarning> &out) {
    for (int step = 0; step < int(Slic3r::psCount); ++step)
        for (const auto &warning :
             print.step_state_with_warnings(Slic3r::PrintStep(step)).warnings)
            out.push_back({orcapad_warning_level(warning.level),
                           ORCA_SLICE_SOURCE_PRINT_STEP, "", warning.message, ""});
    for (const Slic3r::PrintObject *object : print.objects()) {
        const std::string name =
            object->model_object() ? object->model_object()->name : std::string();
        for (int step = 0; step < int(Slic3r::posCount); ++step)
            for (const auto &warning : object->step_state_with_warnings(
                     Slic3r::PrintObjectStep(step)).warnings)
                out.push_back({orcapad_warning_level(warning.level),
                               ORCA_SLICE_SOURCE_OBJECT_STEP, "", warning.message, name});
    }
}

static bool orcapad_fill_report(const std::vector<OrcapadWarning> &warnings,
                                double time_estimate, int64_t bytes,
                                orca_slice_report *out) {
    orca_slice_report report{};
    report.time_estimate_s = time_estimate;
    report.gcode_bytes = bytes;
    if (!warnings.empty()) {
        report.warnings = static_cast<orca_slice_warning *>(
            std::calloc(warnings.size(), sizeof(orca_slice_warning)));
        if (!report.warnings) return false;
    }
    for (const OrcapadWarning &warning : warnings) {
        orca_slice_warning &slot = report.warnings[report.warning_count++];
        slot.level = warning.level;
        slot.source = warning.source;
        slot.code = orcapad_empty_string();
        slot.message = orcapad_empty_string();
        slot.detail = orcapad_empty_string();
        if (!orcapad_copy_string(warning.code.c_str(), &slot.code) ||
            !orcapad_copy_string(warning.message.c_str(), &slot.message) ||
            !orcapad_copy_string(warning.detail.c_str(), &slot.detail)) {
            orca_slice_report_dispose(&report);
            return false;
        }
    }
    *out = report;
    return true;
}

static orca_result orcapad_run_print(const char *operation,
                                     Slic3r::Print &print,
                                     const char *gcode_path,
                                     orca_progress_fn progress, void *ctx,
                                     orca_slice_job *job,
                                     orca_slice_report *out_report) {
    return orcapad_guard(operation, [&]() -> orca_result {
        OrcapadJobRegistration registration(job, print);
        if (print.canceled())
            return orcapad_fail(ORCA_STATUS_CANCELLED, operation,
                                "slice was cancelled before it started");
        std::vector<OrcapadWarning> warnings;
        try {
            // Desktop BackgroundSlicingProcess::validate: errors refuse the
            // slice, warnings are surfaced.
            Slic3r::StringObjectException validate_warning;
            const Slic3r::StringObjectException error = print.validate(&validate_warning);
            if (!error.string.empty())
                return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                    error.string.c_str());
            if (!validate_warning.string.empty())
                warnings.push_back({ORCA_SLICE_WARNING_WARNING, ORCA_SLICE_SOURCE_VALIDATE,
                                    validate_warning.opt_key, validate_warning.string, ""});

            print.set_status_callback(
                [progress, ctx](const Slic3r::PrintBase::SlicingStatus &status) {
                    // warning-update statuses carry percent -1 and no progress
                    if (progress && status.percent >= 0)
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

            orcapad_collect_step_warnings(print, warnings);
            for (const auto &warning : processor_result.warnings) {
                std::string detail;
                for (const std::string &param : warning.params)
                    detail += (detail.empty() ? "" : "\n") + param;
                warnings.push_back({warning.level, ORCA_SLICE_SOURCE_GCODE,
                                    warning.msg, "", detail});
            }
            if (const auto conflict = print.get_conflict_result()) {
                warnings.push_back({ORCA_SLICE_WARNING_CRITICAL, ORCA_SLICE_SOURCE_CONFLICT,
                                    "gcode_path_conflict", "",
                                    conflict->_objName1 + "\n" + conflict->_objName2 + "\n" +
                                        std::to_string(conflict->_height) + "\n" +
                                        std::to_string(conflict->layer)});
            }

            if (!orcapad_fill_report(
                    warnings, processor_result.print_statistics.modes.front().time,
                    static_cast<int64_t>(file_status.st_size), out_report))
                return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                    "could not allocate slice report");
            if (progress) progress(100, "done", ctx);
            return orcapad_ok();
        } catch (const Slic3r::CanceledException &) {
            return orcapad_fail(ORCA_STATUS_CANCELLED, operation,
                                "slice was cancelled");
        }
    });
}

orca_result orca_slice_to_gcode(const char *stl_path, const char *gcode_path,
                                orca_progress_fn progress, void *ctx,
                                orca_slice_job *job,
                                orca_slice_report *out_report) {
    constexpr const char *operation = "orca_slice_to_gcode";
    if (out_report) *out_report = orca_slice_report{};
    if (!stl_path || !stl_path[0] || !gcode_path || !gcode_path[0] ||
        !out_report)
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
                                 job, out_report);
    });
}

orca_result orca_plater_slice_to_gcode(orca_plater *plater,
                                       const char *gcode_path,
                                       orca_progress_fn progress, void *ctx,
                                       orca_slice_job *job,
                                       orca_slice_report *out_report) {
    constexpr const char *operation = "orca_plater_slice_to_gcode";
    if (out_report) *out_report = orca_slice_report{};
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!gcode_path || !gcode_path[0] || !out_report)
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
                                 job, out_report);
    });
}

orca_result orca_plater_slice_to_gcode_with_presets(
    orca_plater *plater, orca_presets *presets, const char *gcode_path,
    orca_progress_fn progress, void *ctx, orca_slice_job *job,
    orca_slice_report *out_report) {
    constexpr const char *operation =
        "orca_plater_slice_to_gcode_with_presets";
    if (out_report) *out_report = orca_slice_report{};
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!gcode_path || !gcode_path[0] || !out_report)
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
                                 job, out_report);
    });
}

// --- projects (3MF) -------------------------------------------------------

#include "libslic3r/Format/bbs_3mf.hpp"

namespace {
/// Owns the heap objects load_bbs_3mf hands back (desktop deletes them the
/// same way after loading — Plater.cpp:6263, release_PlateData_list).
struct OrcapadProjectLoadScratch {
    Slic3r::PlateDataPtrs plates;
    std::vector<Slic3r::Preset *> presets;
    ~OrcapadProjectLoadScratch() {
        Slic3r::release_PlateData_list(plates);
        for (Slic3r::Preset *preset : presets) delete preset;
    }
};
} // namespace

orca_result orca_project_open(orca_plater *plater, orca_presets *presets,
                              const char *path, orca_project_info *out_info) {
    constexpr const char *operation = "orca_project_open";
    if (out_info) *out_info = orca_project_info{};
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "presets handle is null");
    if (!path || !path[0] || !out_info)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "path is empty or output pointer is null");
    struct stat path_status;
    if (stat(path, &path_status) != 0)
        return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation, "project file is not accessible");

    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        // 1) load into temporaries (desktop Plater::priv::load_files, project)
        Slic3r::DynamicPrintConfig config;
        Slic3r::ConfigSubstitutionContext substitutions(
            Slic3r::ForwardCompatibilitySubstitutionRule::Enable);
        Slic3r::En3mfType file_type = Slic3r::En3mfType::From_Other;
        Slic3r::Semver file_version;
        OrcapadProjectLoadScratch scratch;
        Slic3r::Model loaded = Slic3r::Model::read_from_archive(
            path, &config, &substitutions, file_type,
            Slic3r::LoadStrategy::LoadModel | Slic3r::LoadStrategy::LoadConfig |
                Slic3r::LoadStrategy::AddDefaultInstances,
            &scratch.plates, &scratch.presets, &file_version);
        if (loaded.objects.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "project contains no model object");
        for (size_t plate = 1; plate < scratch.plates.size(); ++plate)
            if (scratch.plates[plate] && !scratch.plates[plate]->objects_and_instances.empty())
                return orcapad_fail(ORCA_STATUS_UNSUPPORTED_CAPABILITY, operation,
                                    "multi-plate projects are not supported yet "
                                    "(objects on plates beyond the first)");

        // 2) adopt presets + project settings into a candidate session
        auto candidate = std::make_unique<Slic3r::PresetBundle>(*presets->bundle);
        if (!scratch.presets.empty())
            candidate->load_project_embedded_presets(
                scratch.presets, Slic3r::ForwardCompatibilitySubstitutionRule::Enable);
        const bool has_config = !config.empty() && config.has("filament_colour");
        if (has_config)
            candidate->load_config_model(path, std::move(config), file_version);

        // 3) identity bookkeeping for the new document
        std::unordered_map<orca_object_id, uint64_t> revisions;
        for (const Slic3r::ModelObject *object : loaded.objects) {
            const orca_object_id id = static_cast<orca_object_id>(object->id().id);
            if (id == 0 || !revisions.emplace(id, 1).second)
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "project object has an invalid or duplicate ID");
        }
        const uint32_t object_count = static_cast<uint32_t>(loaded.objects.size());

        // 4) commit (no-throw): new document + session swap atomically
        plater->model = std::move(loaded);
        plater->mesh_revisions.swap(revisions);
        ++plater->revision;
        presets->bundle.swap(candidate);

        orca_project_info info{};
        info.revision = plater->revision;
        info.object_count = object_count;
        info.plate_count = static_cast<uint32_t>(scratch.plates.size());
        info.config_applied = has_config ? 1 : 0;
        switch (file_type) {
        case Slic3r::En3mfType::From_Orca: info.source = ORCA_PROJECT_FROM_ORCA; break;
        case Slic3r::En3mfType::From_BBS: info.source = ORCA_PROJECT_FROM_BBS; break;
        case Slic3r::En3mfType::From_Prusa: info.source = ORCA_PROJECT_FROM_PRUSA; break;
        case Slic3r::En3mfType::From_Other: info.source = ORCA_PROJECT_FROM_OTHER; break;
        }
        *out_info = info;
        return orcapad_ok();
    });
}

orca_result orca_project_save(orca_plater *plater, orca_presets *presets,
                              const char *path) {
    constexpr const char *operation = "orca_project_save";
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "presets handle is null");
    if (!path || !path[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "path is empty");
    const std::string target(path);
    if (target.size() < 4 || target.compare(target.size() - 4, 4, ".3mf") != 0)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "project path must end in .3mf");
    if (plater->model.objects.empty())
        return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                            "document contains no model object");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::PresetBundle &bundle = *presets->bundle;
        // desktop Plater::export_3mf: secure full config, embedded presets,
        // one plate (PartPlateList::store_to_3mf_structure, plate_index 0)
        Slic3r::DynamicPrintConfig config = bundle.full_config_secure();
        struct EmbeddedPresets {
            std::vector<Slic3r::Preset *> list;
            ~EmbeddedPresets() { for (Slic3r::Preset *p : list) delete p; }
        } embedded{bundle.get_current_project_embedded_presets()};

        Slic3r::PlateDataPtrs plates;
        struct PlateGuard {
            Slic3r::PlateDataPtrs &plates;
            ~PlateGuard() { Slic3r::release_PlateData_list(plates); }
        } plate_guard{plates};
        auto *plate = new Slic3r::PlateData();
        plates.push_back(plate);
        plate->plate_index = 0;
        plate->locked = false;
        for (size_t object = 0; object < plater->model.objects.size(); ++object)
            for (size_t instance = 0;
                 instance < plater->model.objects[object]->instances.size(); ++instance)
                plate->objects_and_instances.emplace_back(int(object), int(instance));
        plate->printer_model_id =
            bundle.printers.get_edited_preset().get_printer_type(&bundle);
        if (const auto *nozzles = config.option<Slic3r::ConfigOptionFloats>("nozzle_diameter"))
            plate->nozzle_diameters = nozzles->serialize();

        Slic3r::StoreParams params;
        params.path = target.c_str();
        params.model = &plater->model;
        params.plate_data_list = plates;
        params.project_presets = embedded.list;
        params.config = &config;
        params.strategy = Slic3r::SaveStrategy::Zip64;
        if (!Slic3r::store_bbs_3mf(params))
            return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                                "engine failed to write the project file");
        return orcapad_ok();
    });
}

// --- orient / arrange -------------------------------------------------------

#include "libslic3r/Orient.hpp"
#include "libslic3r/Arrange.hpp"
#include "libslic3r/ModelArrange.hpp"

static Slic3r::DynamicPrintConfig orcapad_arrange_config(orca_presets *presets) {
    if (presets) return presets->bundle->full_config();
    Slic3r::DynamicPrintConfig config =
        Slic3r::DynamicPrintConfig::full_print_config();
    orcapad_config_overlays(config);
    return config;
}

/// Selected instance, or every instance when both ids are 0.
static orca_result orcapad_target_instances(
    orca_plater *plater, orca_object_id object_id, orca_instance_id instance_id,
    const char *operation, std::vector<Slic3r::ModelInstance *> *out) {
    if (object_id == 0 && instance_id == 0) {
        for (Slic3r::ModelObject *object : plater->model.objects)
            for (Slic3r::ModelInstance *instance : object->instances)
                out->push_back(instance);
        return orcapad_ok();
    }
    Slic3r::ModelObject *object = plater_obj(plater, object_id);
    if (!object)
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                            "object was not found");
    Slic3r::ModelInstance *instance = plater_instance(object, instance_id);
    if (!instance)
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                            "instance was not found");
    out->push_back(instance);
    return orcapad_ok();
}

orca_result orca_plater_orient(orca_plater *plater, orca_presets *presets,
                               orca_object_id object_id,
                               orca_instance_id instance_id,
                               orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_orient";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!plater->model.objects.empty() && object_id == 0 && instance_id != 0)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "instance id requires an object id");

    return orcapad_guard(operation, [&]() -> orca_result {
        if (plater->model.objects.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "document contains no model object");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        std::vector<Slic3r::ModelInstance *> targets;
        const orca_result found = orcapad_target_instances(
            plater, object_id, instance_id, operation, &targets);
        if (found.code != ORCA_STATUS_OK) return found;
        if (targets.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "no instance to orient");

        const Slic3r::DynamicPrintConfig config = orcapad_arrange_config(presets);
        const int overhang = config.has("support_threshold_angle")
                                 ? config.opt_int("support_threshold_angle")
                                 : 60;

        // desktop OrientJob::get_orient_mesh (min_area default on)
        Slic3r::orientation::OrientMeshs selected, unselected;
        for (Slic3r::ModelInstance *instance : targets) {
            Slic3r::ModelObject *obj = instance->get_object();
            Slic3r::orientation::OrientMesh om;
            om.name = obj->name;
            om.mesh = obj->mesh();
            om.overhang_angle = overhang;
            om.setter = [instance](const Slic3r::orientation::OrientMesh &p) {
                instance->rotate(p.rotation_matrix);
                instance->get_object()->invalidate_bounding_box();
                instance->get_object()->ensure_on_bed();
            };
            selected.emplace_back(std::move(om));
        }
        Slic3r::orientation::OrientParams params;
        Slic3r::orientation::OrientParamsArea params_area;
        memcpy(&params, &params_area, sizeof(params));
        params.min_volume = false;
        // OrientJob.cpp does the same: the area params carry EMPTY
        // std::function members, so both callbacks must be set after memcpy
        // (a null progressind would throw bad_function_call inside _orient).
        params.progressind = [](unsigned, std::string) {};
        params.stopcondition = []() { return false; };
        Slic3r::orientation::orient(selected, unselected, params);
        for (Slic3r::orientation::OrientMesh &mesh : selected) mesh.apply();

        ++plater->revision;
        *out_revision = plater->revision;
        return orcapad_ok();
    });
}

orca_result orca_plater_instance_lay_flat(orca_plater *plater,
                                          orca_object_id object_id,
                                          orca_instance_id instance_id,
                                          double nx, double ny, double nz,
                                          orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_instance_lay_flat";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!std::isfinite(nx) || !std::isfinite(ny) || !std::isfinite(nz))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "face normal contains a non-finite value");
    const Slic3r::Vec3d normal(nx, ny, nz);
    if (normal.squaredNorm() < 1e-12)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "face normal is degenerate");
    normal.normalized();

    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        Slic3r::ModelInstance *instance = plater_instance(object, instance_id);
        if (!instance)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "instance was not found");

        // desktop GLGizmoFlatten: rotate the chosen face normal to point
        // down; the object then rests on that face.
        Slic3r::Vec3d axis;
        double angle = 0.0;
        Slic3r::Matrix3d rotation = Slic3r::Matrix3d::Identity();
        Slic3r::Geometry::rotation_from_two_vectors(normal.normalized(),
                                                    -Slic3r::Vec3d::UnitZ(),
                                                    axis, angle, &rotation);
        // ModelInstance::rotate takes a matrix (like the orient setter)
        if (std::abs(angle) > 1e-9) instance->rotate(rotation);
        object->invalidate_bounding_box();
        object->ensure_on_bed();

        ++plater->revision;
        *out_revision = plater->revision;
        return orcapad_ok();
    });
}

orca_result orca_plater_arrange(orca_plater *plater, orca_presets *presets,
                                uint8_t allow_rotations,
                                uint32_t *out_unprintable,
                                orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_arrange";
    if (out_unprintable) *out_unprintable = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_unprintable || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");

    return orcapad_guard(operation, [&]() -> orca_result {
        if (plater->model.objects.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "document contains no model object");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");

        const Slic3r::DynamicPrintConfig config = orcapad_arrange_config(presets);
        // desktop ArrangeJob::prepare: every printable instance is selected
        Slic3r::ModelInstancePtrs instances;
        Slic3r::arrangement::ArrangePolygons input =
            Slic3r::get_arrange_polys(plater->model, instances);
        if (input.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "no arrangeable instance");

        Slic3r::arrangement::ArrangeParams params;
        params.allow_rotations = allow_rotations != 0;
        params.printable_height = config.opt_float("printable_height");
        params.clearance_height_to_rod =
            config.opt_float("extruder_clearance_height_to_rod");
        params.clearance_height_to_lid =
            config.opt_float("extruder_clearance_height_to_lid");
        params.clearance_radius = config.opt_float("extruder_clearance_radius");
        if (const auto *nozzle = config.option<Slic3r::ConfigOptionFloats>("nozzle_diameter"))
            if (!nozzle->values.empty())
                params.nozzle_height = nozzle->values.front();
        params.min_obj_distance =
            Slic3r::scaled(6.0); // desktop default arrange distance
        // desktop ArrangeJob::process step 2 (engine helpers)
        Slic3r::arrangement::update_arrange_params(params, &config, input);
        Slic3r::arrangement::update_selected_items_inflation(input, &config, params);
        Slic3r::arrangement::update_selected_items_axis_align(input, &config, params);
        const Slic3r::Points bed =
            Slic3r::arrangement::get_shrink_bedpts(&config, params);

        Slic3r::arrangement::arrange(input, {}, bed, params);

        // Virtual beds: the desktop creates new plates for overflow; OrcaPad
        // has one plate, so bed n>0 lands shifted beside the printable area
        // (vfn's own approach) and is reported as unprintable.
        const auto *area = config.option<Slic3r::ConfigOptionPoints>("printable_area");
        double bed_width = 200.0, bed_min_x = 0.0;
        if (area && !area->values.empty()) {
            Slic3r::BoundingBoxf bb;
            for (const auto &point : area->values) bb.merge(Slic3r::Vec2d(point.x(), point.y()));
            bed_width = std::max(bb.size().x(), 50.0);
            bed_min_x = bb.min.x();
        }
        uint32_t unprintable = 0;
        for (size_t i = 0; i < input.size(); ++i) {
            if (input[i].bed_idx < 0) continue; // not placed at all
            if (input[i].bed_idx > 0) {
                ++unprintable;
                const double shift = bed_min_x + bed_width * 1.25 * input[i].bed_idx;
                input[i].translation.x() += Slic3r::scaled(shift);
            }
            if (input[i].bed_idx >= 0)
                instances[i]->apply_arrange_result(
                    input[i].translation.cast<double>(), input[i].rotation);
        }
        for (Slic3r::ModelObject *object : plater->model.objects) {
            object->invalidate_bounding_box();
            object->ensure_on_bed();
        }

        ++plater->revision;
        *out_unprintable = unprintable;
        *out_revision = plater->revision;
        return orcapad_ok();
    });
}
