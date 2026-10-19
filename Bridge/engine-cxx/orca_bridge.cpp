// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

#include "orca_bridge.h"

#include "libslic3r/I18N.hpp"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
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
#include "libslic3r/Geometry/ConvexHull.hpp"
#include "libslic3r/ClipperUtils.hpp"
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
        // Desktop keeps physical printers in the preset bundle; this fork's
        // GUI loads them from its own dir. OrcaPad's convention (documented):
        // <data_dir>/user/default/physical_machine — loaded here.
        Slic3r::PresetsConfigSubstitutions physical_substitutions;
        presets->bundle->physical_printers.load_printers(
            data_dir_path, "user/default/physical_machine",
            physical_substitutions,
            Slic3r::ForwardCompatibilitySubstitutionRule::Enable);
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

// ABI v25: the desktop printer change. A fresh bundle has the "- default -"
// presets selected (not listed, not passable to orca_presets_select); a
// printer switch must instead let the engine resolve the process and
// filament, exactly like the desktop Sidebar combo (PresetBundle.cpp
// load_selections + update_compatible(Always)).
orca_result orca_presets_select_machine(orca_presets *presets,
                                         const char *machine) {
    constexpr const char *operation = "orca_presets_select_machine";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!machine || !machine[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "machine name is empty");

    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_has_listed_preset(presets->bundle->printers, machine))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "machine preset was not found");
        auto candidate =
            std::make_unique<Slic3r::PresetBundle>(*presets->bundle);
        candidate->printers.select_preset_by_name(machine, false);
        const Slic3r::Preset &printer = candidate->printers.get_selected_preset();
        if (printer.name != machine)
            return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                "machine preset is not selectable");

        // While the process/filament selection is still a default preset,
        // adopt the machine's declared defaults (upstream load_selections,
        // the ConfigWizard "BBS: set default print/filament profiles" path).
        if (candidate->prints.get_selected_preset().is_default &&
            printer.config.has("default_print_profile")) {
            const std::string preferred =
                printer.config.opt_string("default_print_profile");
            if (!preferred.empty() &&
                candidate->prints.find_preset(preferred, false, true) != nullptr)
                candidate->prints.select_preset_by_name(preferred, true);
        }
        if (candidate->filaments.get_selected_preset().is_default &&
            printer.config.has("default_filament_profile")) {
            const auto &preferred = printer.config.option<
                Slic3r::ConfigOptionStrings>("default_filament_profile")->values;
            if (!preferred.empty() &&
                candidate->filaments.find_preset(preferred.front(), false, true) != nullptr)
                candidate->filaments.select_preset_by_name(preferred.front(), true);
        }

        // Desktop printer change: swap any incompatible process/filament for
        // a compatible one (printer-preferred when declared).
        candidate->update_compatible(Slic3r::PresetSelectCompatibleType::Always);

        // Some machines declare no default process and nothing forces a swap;
        // never leave a "- default -" process selected (it slices with unsafe
        // engine defaults, e.g. relative E without a per-layer reset).
        if (candidate->prints.get_selected_preset().is_default) {
            Slic3r::Preset &compatible = candidate->prints.first_compatible();
            if (!compatible.is_default)
                candidate->prints.select_preset_by_name(compatible.name, true);
        }
        if (candidate->filaments.get_selected_preset().is_default) {
            Slic3r::Preset &compatible = candidate->filaments.first_compatible();
            if (!compatible.is_default)
                candidate->filaments.select_preset_by_name(compatible.name, true);
        }

        // Keep the per-extruder filament list valid (upstream fix-up).
        if (candidate->filament_presets.empty())
            candidate->set_filament_preset(
                0, candidate->filaments.get_selected_preset_name());
        else
            for (std::string &name : candidate->filament_presets)
                if (candidate->filaments.find_preset(name, false) == nullptr)
                    name = candidate->filaments.get_selected_preset_name();

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

// --- multi-filament (desktop Sidebar filament list, ABI v31) ---------------

void orca_filament_slots_dispose(orca_filament_slots *slots) {
    if (!slots) return;
    if (slots->preset_names)
        for (uint32_t i = 0; i < slots->count; ++i)
            orca_owned_string_dispose(&slots->preset_names[i]);
    if (slots->colours)
        for (uint32_t i = 0; i < slots->count; ++i)
            orca_owned_string_dispose(&slots->colours[i]);
    std::free(slots->preset_names);
    std::free(slots->colours);
    *slots = orca_filament_slots{};
}

orca_result orca_presets_filament_slots(orca_presets *presets,
                                        orca_filament_slots *out) {
    constexpr const char *operation = "orca_presets_filament_slots";
    if (out) *out = orca_filament_slots{};
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!out)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        const std::vector<std::string> &names = presets->bundle->filament_presets;
        if (names.empty())
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "preset bundle has no filament slot");
        const auto *colours =
            presets->bundle->project_config.option<Slic3r::ConfigOptionStrings>("filament_colour");
        const size_t count = names.size();
        orca_filament_slots result{};
        result.count = static_cast<uint32_t>(count);
        result.preset_names = static_cast<orca_owned_string *>(
            std::calloc(count, sizeof(orca_owned_string)));
        result.colours = static_cast<orca_owned_string *>(
            std::calloc(count, sizeof(orca_owned_string)));
        if (!result.preset_names || !result.colours) {
            orca_filament_slots_dispose(&result);
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate filament slots");
        }
        for (size_t i = 0; i < count; ++i) {
            const std::string &colour =
                colours && i < colours->values.size() ? colours->values[i] : "";
            if (!orcapad_copy_string(names[i].c_str(), &result.preset_names[i]) ||
                !orcapad_copy_string(colour.c_str(), &result.colours[i])) {
                orca_filament_slots_dispose(&result);
                return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                    "could not allocate a filament slot string");
            }
        }
        *out = result;
        return orcapad_ok();
    });
}

static bool orcapad_valid_filament_colour(const char *colour) {
    if (!colour || colour[0] != '#' || strlen(colour) != 7) return false;
    for (const char *c = colour + 1; *c; ++c)
        if (!isxdigit(static_cast<unsigned char>(*c))) return false;
    return true;
}

orca_result orca_presets_set_filament_count(orca_presets *presets,
                                            uint32_t count,
                                            const char *new_colour) {
    constexpr const char *operation = "orca_presets_set_filament_count";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (count < 1 || count > ORCA_FILAMENT_MAX)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "filament count is out of range");
    if (new_colour && !orcapad_valid_filament_colour(new_colour))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "new colour must be #rrggbb");
    return orcapad_guard(operation, [&]() -> orca_result {
        // Desktop rule (PresetBundle::set_num_filaments): new slots
        // duplicate the last filament preset; colors from the arg.
        presets->bundle->set_num_filaments(
            count, new_colour ? std::string(new_colour) : std::string());
        return orcapad_ok();
    });
}

orca_result orca_presets_select_filament(orca_presets *presets,
                                         uint32_t slot,
                                         const char *preset_name) {
    constexpr const char *operation = "orca_presets_select_filament";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!preset_name || !preset_name[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset name is empty");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (slot >= presets->bundle->filament_presets.size())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "filament slot is out of range");
        const Slic3r::Preset *preset =
            presets->bundle->filaments.find_preset(preset_name);
        if (!preset)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "filament preset was not found");
        presets->bundle->filament_presets[slot] = preset_name;
        return orcapad_ok();
    });
}

orca_result orca_presets_set_filament_colour(orca_presets *presets,
                                             uint32_t slot,
                                             const char *colour) {
    constexpr const char *operation = "orca_presets_set_filament_colour";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!orcapad_valid_filament_colour(colour))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "colour must be #rrggbb");
    return orcapad_guard(operation, [&]() -> orca_result {
        auto *colours = presets->bundle->project_config.option<Slic3r::ConfigOptionStrings>("filament_colour");
        if (!colours || slot >= colours->values.size())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "filament slot is out of range");
        colours->values[slot] = colour;
        return orcapad_ok();
    });
}

// --- plater session ------------------------------------------------------

/// One undo/redo step: the whole document as it was (Model copies share
/// meshes through shared_ptr and keep every ObjectID, so restoring a step
/// brings back the same stable object/instance IDs).
struct OrcapadHistoryStep {
    std::string label;
    Slic3r::Model model;
    std::unordered_map<orca_object_id, uint64_t> mesh_revisions;
    /// Plates are document state (ABI v27): names, locks and pins undo with
    /// the document; the SELECTED plate is session state and never restores.
    std::vector<struct OrcapadPlate> plates;
};

/// One plate of the document (desktop PartPlate, minus GUI state). Boxes
/// are derived from the bed geometry and the grid layout, never stored.
struct OrcapadPlate {
    orca_plate_id id = 0;
    std::string name;
    bool locked = false;
    /// Instances pinned at lock time: assignment keeps them here even when
    /// they move; arrange skips them.
    std::vector<std::pair<orca_object_id, orca_instance_id>> pinned;
};

struct orca_plater {
    Slic3r::Model model;
    orca_revision revision = 0;
    std::unordered_map<orca_object_id, uint64_t> mesh_revisions;
    /// Process-unique per plater: (object id, mesh revision) identifies mesh
    /// CONTENT, also across undo/redo, so client caches never alias.
    uint64_t next_mesh_revision = 1;
    std::deque<OrcapadHistoryStep> undo;
    std::deque<OrcapadHistoryStep> redo;
    /// Desktop clipboard: whole objects (volumes + instances), relative
    /// placement preserved (desktop Selection::copy_to_clipboard).
    std::optional<Slic3r::Model> clipboard;
    /// Plates in display order (>= 1 after the first set_bed/new).
    std::vector<OrcapadPlate> plates;
    orca_plate_id next_plate_id = 1;
    /// Selected plate INDEX (session state; clamped when plates shrink).
    int32_t current_plate = 0;
    /// Bed geometry from the selected printer (client-driven via
    /// orca_plater_set_bed; desktop resets plate size on machine change).
    double bed_origin_x = 0.0, bed_origin_y = 0.0;
    double bed_width = 200.0, bed_depth = 200.0, bed_height = 200.0;
};

/// Desktop keeps a memory-bounded undo stack; OrcaPad bounds it by steps.
static constexpr size_t kOrcapadHistoryLimit = 64;

// Forward declarations (defined with the model helpers below).
static Slic3r::ModelObject *plater_obj(orca_plater *plater, orca_object_id id);
static Slic3r::ModelInstance *plater_instance(Slic3r::ModelObject *object,
                                              orca_instance_id id,
                                              size_t *out_index);
static orca_scene_snapshot orcapad_empty_snapshot() noexcept;

// --- plate layout & assignment (ABI v27) ----------------------------------

/// Keeps the selected plate index inside the plate list after restores.
static void orcapad_clamp_current_plate(orca_plater &plater) {
    if (plater.plates.empty()) {
        plater.current_plate = 0;
        return;
    }
    plater.current_plate = std::min(
        plater.current_plate, static_cast<int32_t>(plater.plates.size()) - 1);
}

/// Desktop compute_colum_count: ceil(sqrt(count)) (perfect squares exact).
static int orcapad_plate_columns(int32_t count) {
    if (count <= 1) return 1;
    return static_cast<int>(std::ceil(std::sqrt(static_cast<double>(count)) - 1e-9));
}

/// Desktop compute_shape_position: grid with 1.2x stride (1 + 1/5 gap),
/// rows growing in -Y, relative to the bed origin.
static Slic3r::Vec3d orcapad_plate_origin(const orca_plater &plater,
                                          int32_t index) {
    const int cols = orcapad_plate_columns(static_cast<int32_t>(plater.plates.size()));
    const int row = index / cols;
    const int col = index % cols;
    const double stride_x = plater.bed_width * (1.0 + 1.0 / 5.0);
    const double stride_y = plater.bed_depth * (1.0 + 1.0 / 5.0);
    return Slic3r::Vec3d(
        plater.bed_origin_x + col * stride_x,
        plater.bed_origin_y - row * stride_y, 0.0);
}

static Slic3r::BoundingBoxf3 orcapad_plate_box(const orca_plater &plater,
                                               int32_t index) {
    const Slic3r::Vec3d origin = orcapad_plate_origin(plater, index);
    Slic3r::BoundingBoxf3 box;
    box.min = origin;
    box.max = origin + Slic3r::Vec3d(
        plater.bed_width, plater.bed_depth, plater.bed_height);
    return box;
}

static bool orcapad_boxes_overlap(const Slic3r::BoundingBoxf3 &a,
                                  const Slic3r::BoundingBoxf3 &b) {
    return a.min.x() <= b.max.x() && a.max.x() >= b.min.x() &&
           a.min.y() <= b.max.y() && a.max.y() >= b.min.y() &&
           a.min.z() <= b.max.z() && a.max.z() >= b.min.z();
}

/// World-space bounding box of one instance (raw mesh bbox transformed by
/// the instance matrix).
static Slic3r::BoundingBoxf3 orcapad_instance_box(
    const Slic3r::ModelInstance &instance) {
    const Slic3r::BoundingBoxf3 local =
        instance.get_object()->raw_mesh_bounding_box();
    const Slic3r::Transform3d matrix = instance.get_matrix();
    Slic3r::BoundingBoxf3 world;
    for (int sx = 0; sx < 2; ++sx)
        for (int sy = 0; sy < 2; ++sy)
            for (int sz = 0; sz < 2; ++sz)
                world.merge(matrix * Slic3r::Vec3d(
                    sx ? local.max.x() : local.min.x(),
                    sy ? local.max.y() : local.min.y(),
                    sz ? local.max.z() : local.min.z()));
    return world;
}

/// Desktop PartPlateList::find_instance: locked-plate pins first, then the
/// first plate whose box intersects the instance. -1 = on no plate.
static int orcapad_instance_plate(const orca_plater &plater,
                                  orca_object_id object_id,
                                  orca_instance_id instance_id,
                                  const Slic3r::BoundingBoxf3 &bbox) {
    for (size_t index = 0; index < plater.plates.size(); ++index) {
        const OrcapadPlate &plate = plater.plates[index];
        if (!plate.locked) continue;
        for (const auto &pin : plate.pinned)
            if (pin.first == object_id && pin.second == instance_id)
                return static_cast<int>(index);
    }
    for (size_t index = 0; index < plater.plates.size(); ++index)
        if (orcapad_boxes_overlap(orcapad_plate_box(plater, static_cast<int>(index)),
                                  bbox))
            return static_cast<int>(index);
    return -1;
}

static OrcapadPlate *orcapad_plate_by_id(orca_plater *plater, orca_plate_id id,
                                         size_t *out_index = nullptr) {
    if (!plater || id == 0) return nullptr;
    for (size_t index = 0; index < plater->plates.size(); ++index)
        if (plater->plates[index].id == id) {
            if (out_index) *out_index = index;
            return &plater->plates[index];
        }
    return nullptr;
}

/// Drops pins whose object or instance no longer exists (derived-state
/// maintenance; called before snapshots so pins never outlive instances).
static void orcapad_sweep_pins(orca_plater &plater) {
    for (OrcapadPlate &plate : plater.plates) {
        if (!plate.locked) {
            plate.pinned.clear();
            continue;
        }
        plate.pinned.erase(
            std::remove_if(plate.pinned.begin(), plate.pinned.end(),
                           [&](const std::pair<orca_object_id, orca_instance_id> &pin) {
                               Slic3r::ModelObject *object =
                                   plater_obj(&plater, pin.first);
                               return !object ||
                                      !plater_instance(object, pin.second, nullptr);
                           }),
            plate.pinned.end());
    }
}

/// Creates plates (default names) until index `needed` exists; caps at
/// ORCA_PLATE_MAX_COUNT. Returns the top created index or -1 when full.
static int orcapad_ensure_plates(orca_plater &plater, int32_t needed) {
    while (static_cast<int32_t>(plater.plates.size()) <= needed) {
        if (static_cast<int32_t>(plater.plates.size()) >= ORCA_PLATE_MAX_COUNT)
            return -1;
        OrcapadPlate plate;
        plate.id = plater.next_plate_id++;
        plate.name = "Plate " + std::to_string(plater.plates.size() + 1);
        plater.plates.push_back(std::move(plate));
        orcapad_clamp_current_plate(plater);
    }
    return needed;
}

/// Ensures plates exist for every instance's derived position (3MF load:
/// desktop projects carry plate metadata; OrcaPad derives it from the
/// absolute positions, which every 3MF preserves).
static void orcapad_cover_positions_with_plates(orca_plater &plater) {
    int32_t needed = 0;
    for (const Slic3r::ModelObject *object : plater.model.objects)
        for (const Slic3r::ModelInstance *instance : object->instances)
            for (size_t index = 0; index < plater.plates.size(); ++index)
                if (orcapad_boxes_overlap(
                        orcapad_plate_box(plater, static_cast<int>(index)),
                        orcapad_instance_box(*instance)))
                    needed = std::max<int32_t>(needed, static_cast<int32_t>(index));
    (void)orcapad_ensure_plates(plater, needed);
}

/// Transactional document mutation (desktop Plater::take_snapshot + the
/// Bridge's failure atomicity): the document is copied up front; commit()
/// files that copy as one undo step (clearing redo) and advances the
/// revision; leaving the scope WITHOUT commit (typed failure or exception)
/// restores the copy, so a failed mutation never leaves partial state.
class OrcapadMutation {
public:
    OrcapadMutation(orca_plater &plater, std::string label)
        : m_plater(plater), m_label(std::move(label)), m_model(plater.model),
          m_revisions(plater.mesh_revisions), m_plates(plater.plates) {}
    OrcapadMutation(const OrcapadMutation &) = delete;
    OrcapadMutation &operator=(const OrcapadMutation &) = delete;
    ~OrcapadMutation() {
        if (m_committed) return;
        m_plater.model = std::move(m_model);
        m_plater.mesh_revisions = std::move(m_revisions);
        m_plater.plates = std::move(m_plates);
        orcapad_clamp_current_plate(m_plater);
    }

    orca_revision commit() {
        m_plater.redo.clear();
        m_plater.undo.push_back(OrcapadHistoryStep{
            m_label, std::move(m_model), std::move(m_revisions),
            std::move(m_plates)});
        while (m_plater.undo.size() > kOrcapadHistoryLimit) m_plater.undo.pop_front();
        m_committed = true;
        orcapad_clamp_current_plate(m_plater);
        return ++m_plater.revision;
    }

private:
    orca_plater &m_plater;
    std::string m_label;
    Slic3r::Model m_model;
    std::unordered_map<orca_object_id, uint64_t> m_revisions;
    std::vector<OrcapadPlate> m_plates;
    bool m_committed = false;
};

/// Registers a newly created document object for snapshots.
static bool orcapad_register_object(orca_plater &plater, const Slic3r::ModelObject &object) {
    const orca_object_id id = static_cast<orca_object_id>(object.id().id);
    return id != 0 && plater.mesh_revisions.emplace(id, plater.next_mesh_revision++).second;
}

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

/// Volume role mapping between the ABI constants and the engine's own
/// ModelVolumeType (never an implicit int cast: the ABI owns its values).
static uint8_t orcapad_volume_role(Slic3r::ModelVolumeType type) {
    switch (type) {
    case Slic3r::ModelVolumeType::MODEL_PART: return ORCA_VOLUME_PART;
    case Slic3r::ModelVolumeType::NEGATIVE_VOLUME: return ORCA_VOLUME_NEGATIVE;
    case Slic3r::ModelVolumeType::PARAMETER_MODIFIER: return ORCA_VOLUME_MODIFIER;
    case Slic3r::ModelVolumeType::SUPPORT_BLOCKER: return ORCA_VOLUME_SUPPORT_BLOCKER;
    case Slic3r::ModelVolumeType::SUPPORT_ENFORCER: return ORCA_VOLUME_SUPPORT_ENFORCER;
    default: return 0xFF; // INVALID never occurs on live objects
    }
}

static bool orcapad_volume_type(uint8_t role, Slic3r::ModelVolumeType *out) {
    switch (role) {
    case ORCA_VOLUME_PART: *out = Slic3r::ModelVolumeType::MODEL_PART; return true;
    case ORCA_VOLUME_NEGATIVE: *out = Slic3r::ModelVolumeType::NEGATIVE_VOLUME; return true;
    case ORCA_VOLUME_MODIFIER: *out = Slic3r::ModelVolumeType::PARAMETER_MODIFIER; return true;
    case ORCA_VOLUME_SUPPORT_BLOCKER: *out = Slic3r::ModelVolumeType::SUPPORT_BLOCKER; return true;
    case ORCA_VOLUME_SUPPORT_ENFORCER: *out = Slic3r::ModelVolumeType::SUPPORT_ENFORCER; return true;
    default: return false;
    }
}

static Slic3r::ModelVolume *plater_volume(Slic3r::ModelObject *object,
                                          orca_volume_id id,
                                          size_t *out_index = nullptr) {
    if (!object || id == 0 || id > std::numeric_limits<size_t>::max())
        return nullptr;
    for (size_t index = 0; index < object->volumes.size(); ++index) {
        Slic3r::ModelVolume *volume = object->volumes[index];
        if (volume->id().id == static_cast<size_t>(id)) {
            if (out_index) *out_index = index;
            return volume;
        }
    }
    return nullptr;
}

/// Keys an object / volume config may override (desktop
/// SettingsFactory::get_options): region keys for volumes, region + object
/// keys for objects.
static const std::set<std::string> &orcapad_settings_keys(bool for_volume) {
    static const std::set<std::string> region = [] {
        const Slic3r::PrintRegionConfig config;
        const auto keys = config.keys();
        return std::set<std::string>(keys.begin(), keys.end());
    }();
    static const std::set<std::string> object = [] {
        std::set<std::string> keys = region;
        const Slic3r::PrintObjectConfig config;
        for (const std::string &key : config.keys()) keys.insert(key);
        return keys;
    }();
    return for_volume ? region : object;
}

/// Overrides shown to users: the allowed keys a config sets ("extruder" is
/// the filament assignment, handled by plate.object-filament).
static size_t orcapad_override_count(const Slic3r::DynamicPrintConfig &config) {
    size_t count = 0;
    const std::set<std::string> &allowed = orcapad_settings_keys(false);
    for (const std::string &key : config.keys())
        if (allowed.count(key)) ++count;
    return count;
}

/// Marks an object's volume composition as changed (client caches key on
/// the object mesh revision).
static void orcapad_touch_object(orca_plater &plater, orca_object_id object_id) {
    plater.mesh_revisions[object_id] = plater.next_mesh_revision++;
}

/// Desktop GUI_ObjectList::create_mesh (shape -> mesh; SLAB uses the
/// instance bbox footprint).
static Slic3r::TriangleMesh orcapad_shape_mesh(int32_t shape, double size_mm,
                                               const Slic3r::BoundingBoxf3 &instance_bb) {
    using Slic3r::TriangleMesh;
    switch (shape) {
    case ORCA_SHAPE_CUBE: return TriangleMesh(Slic3r::its_make_cube(size_mm, size_mm, size_mm));
    case ORCA_SHAPE_CYLINDER: return TriangleMesh(Slic3r::its_make_cylinder(0.5 * size_mm, size_mm));
    case ORCA_SHAPE_SPHERE: return TriangleMesh(Slic3r::its_make_sphere(0.5 * size_mm, PI / 90.0));
    case ORCA_SHAPE_CONE: return TriangleMesh(Slic3r::its_make_cone(0.5 * size_mm, size_mm));
    case ORCA_SHAPE_DISC: return TriangleMesh(Slic3r::its_make_cylinder(0.5 * size_mm, 0.2));
    case ORCA_SHAPE_TORUS: return TriangleMesh(Slic3r::its_make_torus(0.5 * size_mm, 0.125 * size_mm, PI / 60.0));
    case ORCA_SHAPE_SLAB:
        return TriangleMesh(Slic3r::its_make_cube(
            instance_bb.size().x() * 1.5, instance_bb.size().y() * 1.5,
            instance_bb.size().z() * 0.5));
    default: return TriangleMesh();
    }
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
        orca_plater *plater = new orca_plater();
        // Desktop PartPlateList::init: every document starts with one plate.
        OrcapadPlate first;
        first.id = plater->next_plate_id++;
        first.name = "Plate 1";
        plater->plates.push_back(std::move(first));
        *out = plater;
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

        OrcapadMutation mutation(*plater, "Import");
        std::vector<Slic3r::ModelObject *> added;
        for (Slic3r::ModelObject *source : temporary.objects) {
            Slic3r::ModelObject *object = plater->model.add_object(*source);
            if (!object)
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine did not create a document object");
            added.push_back(object);
            if (!orcapad_register_object(*plater, *object))
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine returned an invalid or reused object ID");
        }
        const orca_object_id first = static_cast<orca_object_id>(added.front()->id().id);
        *out_revision = mutation.commit();
        *out_first_object_id = first;
        *out_object_count = static_cast<uint32_t>(added.size());
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
        OrcapadMutation mutation(*plater, "Delete");
        if (!plater->model.delete_object(
                Slic3r::ObjectID(static_cast<size_t>(object_id))))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine did not delete the object");
        plater->mesh_revisions.erase(object_id);
        *out_revision = mutation.commit();
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
        OrcapadMutation mutation(*plater, "Add instance");
        Slic3r::ModelInstance *instance = object->instances.empty()
            ? object->add_instance()
            : object->add_instance(*object->instances.back());
        if (!instance)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine did not create an instance");
        instance->set_offset(instance->get_offset() + Slic3r::Vec3d(10.0, 10.0, 0.0));
        object->invalidate_bounding_box();
        const orca_instance_id id =
            static_cast<orca_instance_id>(instance->id().id);
        if (id == 0)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine returned an invalid instance ID");
        *out_revision = mutation.commit();
        *out_instance_id = id;
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
        OrcapadMutation mutation(*plater, "Delete instance");
        object->delete_instance(instance_index);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_instances_delete(
    orca_plater *plater,
    const orca_object_id *object_ids,
    const orca_instance_id *instance_ids,
    int32_t count,
    orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_instances_delete";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (count < 1 || !object_ids || !instance_ids)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "count is below one or an array is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        // Resolve every (object, instance index) up front: a missing entry
        // must delete nothing. Duplicate pairs collapse.
        std::map<Slic3r::ModelObject *, std::set<size_t>> targets;
        for (int32_t index = 0; index < count; ++index) {
            Slic3r::ModelObject *object = plater_obj(plater, object_ids[index]);
            if (!object)
                return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                    "object was not found");
            size_t instance_index = 0;
            if (!plater_instance(object, instance_ids[index], &instance_index))
                return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                    "instance was not found");
            targets[object].insert(instance_index);
        }
        // An object whose EVERY instance is listed is removed whole
        // (desktop Selection::erase semantics).
        std::set<Slic3r::ModelObject *> whole;
        for (const auto &entry : targets)
            if (entry.second.size() == entry.first->instances.size())
                whole.insert(entry.first);
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater,
                                 count == 1 ? "Delete instance" : "Delete instances");
        for (Slic3r::ModelObject *object : whole) {
            const orca_object_id id = static_cast<orca_object_id>(object->id().id);
            if (!plater->model.delete_object(object->id()))
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine did not delete the object");
            plater->mesh_revisions.erase(id);
        }
        // Remaining instances: descending index order so earlier deletes
        // never shift a later target.
        for (const auto &entry : targets) {
            if (whole.count(entry.first)) continue;
            for (auto index = entry.second.rbegin(); index != entry.second.rend(); ++index)
                entry.first->delete_instance(*index);
        }
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_instance_set(orca_plater *plater,
                                     orca_object_id object_id,
                                     orca_instance_id instance_id,
                                     const orca_instance_transform *transform,
                                     const char *label,
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
        OrcapadMutation mutation(*plater, label && label[0] ? label : "Transform");
        Slic3r::Geometry::Transformation candidate = instance->get_transformation();
        candidate.set_offset(Slic3r::Vec3d(
            transform->offset_x, transform->offset_y, transform->offset_z));
        candidate.set_rotation(Slic3r::Vec3d(
            transform->rotation_x, transform->rotation_y, transform->rotation_z));
        candidate.set_scaling_factor(Slic3r::Vec3d(
            transform->scale_x, transform->scale_y, transform->scale_z));
        instance->set_transformation(candidate);
        orcapad_rest_on_bed(object, instance);
        *out_revision = mutation.commit();
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
        OrcapadMutation mutation(*plater, "Rotate");
        instance->rotate(Eigen::AngleAxisd(radians, world_axis).toRotationMatrix());
        orcapad_rest_on_bed(object, instance);
        *out_revision = mutation.commit();
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
        OrcapadMutation mutation(*plater, "Drop to bed");
        for (Slic3r::ModelObject *object : plater->model.objects)
            object->ensure_on_bed(false);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

/// Desktop Plater::undo / redo: moves one step between the stacks. The
/// restored document keeps its stable IDs; the revision still advances
/// (revisions order observations, they are never rewound).
static orca_result orcapad_step_history(orca_plater *plater, bool undo,
                                        orca_revision *out_revision,
                                        const char *operation) {
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        std::deque<OrcapadHistoryStep> &from = undo ? plater->undo : plater->redo;
        std::deque<OrcapadHistoryStep> &to = undo ? plater->redo : plater->undo;
        if (from.empty())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                undo ? "nothing to undo" : "nothing to redo");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadHistoryStep step = std::move(from.back());
        from.pop_back();
        to.push_back(OrcapadHistoryStep{step.label, std::move(plater->model),
                                        std::move(plater->mesh_revisions),
                                        std::move(plater->plates)});
        plater->model = std::move(step.model);
        plater->mesh_revisions = std::move(step.mesh_revisions);
        plater->plates = std::move(step.plates);
        // The selected plate is session state: only clamp it into range.
        orcapad_clamp_current_plate(*plater);
        *out_revision = ++plater->revision;
        return orcapad_ok();
    });
}

orca_result orca_plater_undo(orca_plater *plater, orca_revision *out_revision) {
    return orcapad_step_history(plater, true, out_revision, "orca_plater_undo");
}

orca_result orca_plater_redo(orca_plater *plater, orca_revision *out_revision) {
    return orcapad_step_history(plater, false, out_revision, "orca_plater_redo");
}

orca_result orca_plater_object_rename(orca_plater *plater, orca_object_id object_id,
                                      const char *name, orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_object_rename";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!name || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "name or output pointer is null");
    const std::string value(name);
    if (value.find_first_not_of(" \t\r\n") == std::string::npos)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "name is empty");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Rename");
        object->name = value;
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_clear(orca_plater *plater, orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_clear";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (plater->model.objects.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "document contains no model object");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Delete all");
        plater->model.clear_objects();
        plater->mesh_revisions.clear();
        // Plates survive "Delete all" (desktop parity); the pin sweep on
        // the next snapshot drops the dead pins.
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

// --- plates (ABI v27) -------------------------------------------------------

orca_result orca_plater_set_bed(orca_plater *plater,
                               double origin_x, double origin_y,
                               double width, double depth, double height,
                               orca_scene_snapshot *out_snapshot) {
    constexpr const char *operation = "orca_plater_set_bed";
    if (out_snapshot) *out_snapshot = orcapad_empty_snapshot();
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!std::isfinite(origin_x) || !std::isfinite(origin_y) ||
        !std::isfinite(width) || !std::isfinite(depth) || !std::isfinite(height) ||
        width <= 0.0 || depth <= 0.0 || height <= 0.0)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "bed geometry contains a non-finite or non-positive value");
    plater->bed_origin_x = origin_x;
    plater->bed_origin_y = origin_y;
    plater->bed_width = width;
    plater->bed_depth = depth;
    plater->bed_height = height;
    if (!out_snapshot) return orcapad_ok();
    return orca_plater_snapshot(plater, out_snapshot);
}

orca_result orca_plater_plate_add(orca_plater *plater,
                                  orca_plate_id *out_plate_id,
                                  orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_plate_add";
    if (out_plate_id) *out_plate_id = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_plate_id || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (plater->plates.empty())
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document has no plates");
        if (static_cast<int32_t>(plater->plates.size()) >= ORCA_PLATE_MAX_COUNT)
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "the plate limit (" "36" ") is reached");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Add plate");
        OrcapadPlate plate;
        plate.id = plater->next_plate_id++;
        plate.name = "Plate " + std::to_string(plater->plates.size() + 1);
        *out_plate_id = plate.id;
        plater->plates.push_back(std::move(plate));
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_plate_delete(orca_plater *plater, orca_plate_id plate_id,
                                    orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_plate_delete";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        size_t index = 0;
        if (!orcapad_plate_by_id(plater, plate_id, &index))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "plate was not found");
        if (plater->plates.size() == 1)
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "the last plate cannot be deleted");
        // Desktop refuses to delete a plate that still carries objects.
        for (const Slic3r::ModelObject *object : plater->model.objects)
            for (const Slic3r::ModelInstance *instance : object->instances)
                if (orcapad_instance_plate(
                        *plater,
                        static_cast<orca_object_id>(object->id().id),
                        static_cast<orca_instance_id>(instance->id().id),
                        orcapad_instance_box(*instance)) ==
                    static_cast<int>(index))
                    return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                        "the plate is not empty");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Delete plate");
        plater->plates.erase(plater->plates.begin() +
                             static_cast<ptrdiff_t>(index));
        orcapad_clamp_current_plate(*plater);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_plate_rename(orca_plater *plater, orca_plate_id plate_id,
                                     const char *name,
                                     orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_plate_rename";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!name || !name[0] || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "name or output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        OrcapadPlate *plate = orcapad_plate_by_id(plater, plate_id);
        if (!plate)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "plate was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Rename plate");
        plate->name = name;
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_plate_lock(orca_plater *plater, orca_plate_id plate_id,
                                   uint8_t lock, orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_plate_lock";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        size_t index = 0;
        OrcapadPlate *plate = orcapad_plate_by_id(plater, plate_id, &index);
        if (!plate)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "plate was not found");
        if (plate->locked == (lock != 0))
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                lock ? "the plate is already locked"
                                     : "the plate is not locked");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, lock ? "Lock plate" : "Unlock plate");
        if (lock) {
            // Pin every instance currently assigned to this plate.
            plate->locked = true;
            plate->pinned.clear();
            for (const Slic3r::ModelObject *object : plater->model.objects)
                for (const Slic3r::ModelInstance *instance : object->instances)
                    if (orcapad_instance_plate(
                            *plater,
                            static_cast<orca_object_id>(object->id().id),
                            static_cast<orca_instance_id>(instance->id().id),
                            orcapad_instance_box(*instance)) ==
                        static_cast<int>(index))
                        plate->pinned.emplace_back(
                            static_cast<orca_object_id>(object->id().id),
                            static_cast<orca_instance_id>(instance->id().id));
        } else {
            plate->locked = false;
            plate->pinned.clear();
        }
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_plate_move_to_front(orca_plater *plater,
                                            orca_plate_id plate_id,
                                            orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_plate_move_to_front";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        size_t index = 0;
        if (!orcapad_plate_by_id(plater, plate_id, &index))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "plate was not found");
        if (index == 0)
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "the plate is already first");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Move plate to front");
        // Keep the SELECTED plate selected across the reorder (desktop
        // tracks the plate, not the position).
        const orca_plate_id selected =
            plater->current_plate >= 0 &&
                    plater->current_plate <
                        static_cast<int32_t>(plater->plates.size())
                ? plater->plates[static_cast<size_t>(plater->current_plate)].id
                : 0;
        std::rotate(plater->plates.begin(), plater->plates.begin() +
                                              static_cast<ptrdiff_t>(index),
                    plater->plates.end());
        plater->current_plate = 0;
        if (selected != 0)
            for (size_t position = 0; position < plater->plates.size(); ++position)
                if (plater->plates[position].id == selected)
                    plater->current_plate = static_cast<int32_t>(position);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_plate_duplicate(orca_plater *plater,
                                         orca_plate_id plate_id,
                                         orca_plate_id *out_new_plate_id,
                                         orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_plate_duplicate";
    if (out_new_plate_id) *out_new_plate_id = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_new_plate_id || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        size_t index = 0;
        if (!orcapad_plate_by_id(plater, plate_id, &index))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "plate was not found");
        if (static_cast<int32_t>(plater->plates.size()) >= ORCA_PLATE_MAX_COUNT)
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "the plate limit (36) is reached");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        // The new plate lands at the END; its objects keep their placement
        // relative to the source plate (desktop duplicate semantics). The
        // shift pairs the PRE-ADD source origin (the objects' actual frame)
        // with the POST-ADD target origin (the final grid).
        const size_t new_index = plater->plates.size();
        const Slic3r::Vec3d source_origin =
            orcapad_plate_origin(*plater, static_cast<int>(index));
        OrcapadMutation mutation(*plater, "Duplicate plate");
        OrcapadPlate plate;
        plate.id = plater->next_plate_id++;
        plate.name = "Plate " + std::to_string(plater->plates.size() + 1);
        plater->plates.push_back(std::move(plate));
        *out_new_plate_id = plater->plates.back().id;
        const Slic3r::Vec3d shift =
            orcapad_plate_origin(*plater, static_cast<int>(new_index)) -
            source_origin;
        for (const Slic3r::ModelObject *object : plater->model.objects) {
            // Instances of this object on the source plate, if any.
            std::vector<const Slic3r::ModelInstance *> members;
            for (const Slic3r::ModelInstance *instance : object->instances)
                if (orcapad_instance_plate(
                        *plater,
                        static_cast<orca_object_id>(object->id().id),
                        static_cast<orca_instance_id>(instance->id().id),
                        orcapad_instance_box(*instance)) ==
                    static_cast<int>(index))
                    members.push_back(instance);
            if (members.empty()) continue;
            Slic3r::ModelObject *copy = plater->model.add_object(*object);
            if (!copy)
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine refused to copy the object");
            copy->clear_instances();
            for (const Slic3r::ModelInstance *instance : members) {
                Slic3r::ModelInstance *clone = copy->add_instance(*instance);
                clone->set_offset(clone->get_offset() + shift);
            }
            copy->ensure_on_bed(false);
            if (!orcapad_register_object(*plater, *copy))
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine returned an invalid or reused object ID");
        }
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_plate_select(orca_plater *plater, orca_plate_id plate_id,
                                     orca_scene_snapshot *out_snapshot) {
    constexpr const char *operation = "orca_plater_plate_select";
    if (out_snapshot) *out_snapshot = orcapad_empty_snapshot();
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        size_t index = 0;
        if (!orcapad_plate_by_id(plater, plate_id, &index))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "plate was not found");
        plater->current_plate = static_cast<int32_t>(index);
        if (!out_snapshot) return orcapad_ok();
        return orca_plater_snapshot(plater, out_snapshot);
    });
}

static const char *orcapad_shape_name(int32_t shape) {
    switch (shape) {
    case ORCA_SHAPE_CUBE: return "Cube";
    case ORCA_SHAPE_CYLINDER: return "Cylinder";
    case ORCA_SHAPE_SPHERE: return "Sphere";
    case ORCA_SHAPE_CONE: return "Cone";
    case ORCA_SHAPE_DISC: return "Disc";
    case ORCA_SHAPE_TORUS: return "Torus";
    case ORCA_SHAPE_SLAB: return "Slab";
    default: return nullptr;
    }
}

static bool orcapad_valid_shape(int32_t shape) {
    return shape >= ORCA_SHAPE_CUBE && shape <= ORCA_SHAPE_SLAB;
}

static const char *orcapad_volume_add_label(uint8_t role) {
    switch (role) {
    case ORCA_VOLUME_NEGATIVE: return "Add Negative Volume";
    case ORCA_VOLUME_MODIFIER: return "Add Modifier";
    case ORCA_VOLUME_SUPPORT_BLOCKER: return "Add Support Blocker";
    case ORCA_VOLUME_SUPPORT_ENFORCER: return "Add Support Enforcer";
    default: return "Add Part";
    }
}

/// Desktop volume extruder default: the object's extruder for model parts,
/// 0 (inherit) otherwise.
static int orcapad_volume_default_extruder(const Slic3r::ModelObject &object,
                                           uint8_t role) {
    if (role == ORCA_VOLUME_PART && object.config.has("extruder"))
        return object.config.opt_int("extruder");
    return 0;
}

orca_result orca_plater_add_shape_object(orca_plater *plater, int32_t shape,
                                         double size_mm, double bed_center_x,
                                         double bed_center_y,
                                         orca_object_id *out_object_id,
                                         orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_add_shape_object";
    if (out_object_id) *out_object_id = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_object_id || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    if (!orcapad_valid_shape(shape) || shape == ORCA_SHAPE_SLAB)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "shape must be cube, cylinder, sphere, cone, disc or torus");
    if (!std::isfinite(size_mm) || size_mm <= 0.0)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "size must be positive");
    if (!std::isfinite(bed_center_x) || !std::isfinite(bed_center_y))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "bed center contains a non-finite value");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Add Primitive");
        Slic3r::TriangleMesh mesh = orcapad_shape_mesh(shape, size_mm, {});
        if (mesh.empty())
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "shape generator returned an empty mesh");
        const char *name = orcapad_shape_name(shape);
        // desktop load_mesh_object: object + one volume, extruder 1,
        // mesh centered, instance at the bed center, resting on the bed.
        Slic3r::ModelObject *object = plater->model.add_object();
        object->name = name;
        Slic3r::ModelVolume *volume = object->add_volume(std::move(mesh));
        volume->name = name;
        object->config.set_key_value("extruder", new Slic3r::ConfigOptionInt(1));
        volume->config.set_key_value("extruder", new Slic3r::ConfigOptionInt(1));
        volume->source.is_from_builtin_objects = true;
        Slic3r::ModelInstance *instance = object->add_instance();
        if (!instance || !volume)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine did not create the shape object");
        object->center_around_origin();
        instance->set_offset(Slic3r::Vec3d(bed_center_x, bed_center_y, 0.0));
        object->ensure_on_bed(false);
        if (!orcapad_register_object(*plater, *object))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine returned an invalid or reused object ID");
        const orca_object_id id = static_cast<orca_object_id>(object->id().id);
        *out_revision = mutation.commit();
        *out_object_id = id;
        return orcapad_ok();
    });
}

orca_result orca_plater_volume_add_shape(orca_plater *plater, orca_object_id object_id,
                                         orca_instance_id instance_id, uint8_t type,
                                         int32_t shape, double size_mm,
                                         orca_volume_id *out_volume_id,
                                         orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_volume_add_shape";
    if (out_volume_id) *out_volume_id = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_volume_id || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    Slic3r::ModelVolumeType role;
    if (!orcapad_volume_type(type, &role))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "unknown volume type");
    if (!orcapad_valid_shape(shape))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "unknown shape");
    if (!std::isfinite(size_mm) || size_mm <= 0.0)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "size must be positive");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        Slic3r::ModelInstance *instance = plater_instance(object, instance_id);
        if (!instance)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "instance was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, orcapad_volume_add_label(type));
        object->invalidate_bounding_box();
        const Slic3r::BoundingBoxf3 instance_bb =
            object->instance_bounding_box(*instance);
        Slic3r::TriangleMesh mesh = orcapad_shape_mesh(shape, size_mm, instance_bb);
        if (mesh.empty())
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "shape generator returned an empty mesh");
        // desktop load_generic_subobject: aligned with the bed through the
        // inverse instance rotation/scale, placed at the instance bbox corner.
        Slic3r::ModelVolume *volume = object->add_volume(std::move(mesh), role);
        if (!volume)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine did not create the volume");
        volume->name = std::string("Generic-") + orcapad_shape_name(shape);
        volume->config.set_key_value(
            "extruder", new Slic3r::ConfigOptionInt(
                             orcapad_volume_default_extruder(*object, type)));
        volume->source.is_from_builtin_objects = true;
        const Slic3r::Transform3d instance_no_offset =
            instance->get_transformation().get_matrix_no_offset();
        const Slic3r::Transform3d to_object = instance_no_offset.inverse();
        volume->set_transformation(Slic3r::Geometry::Transformation(to_object));
        const Slic3r::BoundingBoxf3 mesh_bb = volume->mesh().bounding_box();
        const Slic3r::Vec3d world =
            shape == ORCA_SHAPE_SLAB
                ? Slic3r::Vec3d(0.0, 0.0,
                                0.5 * mesh_bb.size().z() + instance_bb.min.z())
                : Slic3r::Vec3d(instance_bb.max.x(), instance_bb.min.y(),
                                instance_bb.min.z()) +
                      0.5 * mesh_bb.size();
        volume->set_offset(to_object * (world - instance->get_offset()));
        object->invalidate_bounding_box();
        const orca_volume_id id = static_cast<orca_volume_id>(volume->id().id);
        if (id == 0)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine returned an invalid volume ID");
        orcapad_touch_object(*plater, object_id);
        *out_revision = mutation.commit();
        *out_volume_id = id;
        return orcapad_ok();
    });
}

orca_result orca_plater_volume_add_file(orca_plater *plater, orca_object_id object_id,
                                        uint8_t type, const char *path,
                                        orca_volume_id *out_volume_id,
                                        orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_volume_add_file";
    if (out_volume_id) *out_volume_id = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!path || !path[0] || !out_volume_id || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "path or output pointer is null");
    Slic3r::ModelVolumeType role;
    if (!orcapad_volume_type(type, &role))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "unknown volume type");
    struct stat path_status;
    if (stat(path, &path_status) != 0)
        return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation, "input file is not accessible");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        // desktop load_modifier: read geometry only (mesh() transforms
        // instances, so the default identity instances are required)
        Slic3r::Model loaded = Slic3r::Model::read_from_file(
            path, nullptr, nullptr, Slic3r::LoadStrategy::LoadModel);
        if (loaded.objects.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "input contains no model object");
        loaded.add_default_instances();
        OrcapadMutation mutation(*plater, orcapad_volume_add_label(type));
        for (Slic3r::ModelObject *source : loaded.objects) {
            if (object->origin_translation != Slic3r::Vec3d::Zero()) {
                source->center_around_origin();
                const Slic3r::Vec3d delta =
                    object->origin_translation - source->origin_translation;
                for (Slic3r::ModelVolume *volume : source->volumes)
                    volume->translate(delta);
            }
        }
        Slic3r::TriangleMesh mesh = loaded.mesh();
        if (mesh.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "input contains no mesh");
        Slic3r::ModelVolume *volume = object->add_volume(std::move(mesh), role);
        if (!volume)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine did not create the volume");
        volume->name =
            boost::filesystem::path(path).filename().string();
        volume->config.set_key_value(
            "extruder", new Slic3r::ConfigOptionInt(
                             orcapad_volume_default_extruder(*object, type)));
        volume->source.input_file = path;
        // prusaslicer-style placement: keep the source-coordinate relation to
        // the object's first volume (both carry their centering shift).
        const Slic3r::Vec3d offset =
            volume->source.mesh_offset - object->volumes.front()->source.mesh_offset;
        volume->set_offset(offset);
        const orca_volume_id id = static_cast<orca_volume_id>(volume->id().id);
        if (id == 0)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine returned an invalid volume ID");
        orcapad_touch_object(*plater, object_id);
        *out_revision = mutation.commit();
        *out_volume_id = id;
        return orcapad_ok();
    });
}

orca_result orca_plater_volume_set_type(orca_plater *plater, orca_object_id object_id,
                                        orca_volume_id volume_id, uint8_t type,
                                        orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_volume_set_type";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    Slic3r::ModelVolumeType role;
    if (!orcapad_volume_type(type, &role))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "unknown volume type");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        Slic3r::ModelVolume *volume = plater_volume(object, volume_id);
        if (!volume)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "volume was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        if (volume->is_model_part() && role != Slic3r::ModelVolumeType::MODEL_PART) {
            size_t parts = 0;
            for (const Slic3r::ModelVolume *other : object->volumes)
                if (other->is_model_part()) ++parts;
            if (parts == 1)
                return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                    "an object keeps at least one solid part");
        }
        OrcapadMutation mutation(*plater, "Change type");
        volume->set_type(role);
        orcapad_touch_object(*plater, object_id);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_volume_delete(orca_plater *plater, orca_object_id object_id,
                                      orca_volume_id volume_id,
                                      orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_volume_delete";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        size_t index = 0;
        Slic3r::ModelVolume *volume = plater_volume(object, volume_id, &index);
        if (!volume)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "volume was not found");
        if (volume->is_model_part()) {
            size_t parts = 0;
            for (const Slic3r::ModelVolume *other : object->volumes)
                if (other->is_model_part()) ++parts;
            if (parts == 1)
                return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                    "delete the object instead of its last solid part");
        }
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Delete part");
        object->delete_volume(index);
        orcapad_touch_object(*plater, object_id);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_volume_rename(orca_plater *plater, orca_object_id object_id,
                                      orca_volume_id volume_id, const char *name,
                                      orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_volume_rename";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!name || !name[0] || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "name or output pointer is null");
    const std::string value(name);
    if (value.find_first_not_of(" \t\r\n") == std::string::npos)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "name is empty");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        Slic3r::ModelVolume *volume = plater_volume(object, volume_id);
        if (!volume)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "volume was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Rename");
        volume->name = value;
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_split_objects(orca_plater *plater, orca_object_id object_id,
                                      orca_object_id *out_first_object_id,
                                      uint32_t *out_object_count,
                                      orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_split_objects";
    if (out_first_object_id) *out_first_object_id = 0;
    if (out_object_count) *out_object_count = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_first_object_id || !out_object_count || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        if (object->volumes.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "object has no volume to split");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Split to Objects");
        Slic3r::ModelObjectPtrs split;
        object->split(&split, false);
        if (split.size() <= 1)
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "the object could not be split (a single body)");
        // the split registered the new objects in the document already
        for (Slic3r::ModelObject *part : split) {
            if (!orcapad_register_object(*plater, *part))
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine returned an invalid or reused object ID");
            part->invalidate_bounding_box();
            part->ensure_on_bed(false);
        }
        const orca_object_id first =
            static_cast<orca_object_id>(split.front()->id().id);
        plater->mesh_revisions.erase(object_id);
        plater->model.delete_object(
            Slic3r::ObjectID(static_cast<size_t>(object_id)));
        const uint32_t count = static_cast<uint32_t>(split.size());
        *out_revision = mutation.commit();
        *out_first_object_id = first;
        *out_object_count = count;
        return orcapad_ok();
    });
}

orca_result orca_plater_split_parts(orca_plater *plater, orca_object_id object_id,
                                    orca_volume_id volume_id,
                                    uint32_t *out_part_count,
                                    orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_split_parts";
    if (out_part_count) *out_part_count = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_part_count || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        Slic3r::ModelVolume *volume = nullptr;
        if (volume_id == 0) {
            for (Slic3r::ModelVolume *candidate : object->volumes)
                if (candidate->is_model_part()) {
                    if (volume)
                        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                            "the object has several parts: name the part to split");
                    volume = candidate;
                }
            if (!volume)
                return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                    "object has no solid part");
        } else {
            volume = plater_volume(object, volume_id);
            if (!volume)
                return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "volume was not found");
            if (!volume->is_model_part())
                return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                    "only solid parts can be split");
        }
        if (!volume->is_splittable())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "the part contains only one body and cannot be split");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Split to Parts");
        const size_t parts = volume->split(1, false);
        if (parts <= 1)
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "the part could not be split (a single body)");
        orcapad_touch_object(*plater, object_id);
        *out_part_count = static_cast<uint32_t>(parts);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

/// Resolves N parallel (object, instance) pairs; every pair must exist.
static orca_result orcapad_resolve_group(
    orca_plater *plater, const orca_object_id *object_ids,
    const orca_instance_id *instance_ids, int32_t count,
    const char *operation, std::vector<Slic3r::ModelInstance *> *out) {
    if (count <= 0 || count > 1'000'000)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "group count is out of range");
    std::set<size_t> seen;
    for (int32_t index = 0; index < count; ++index) {
        Slic3r::ModelObject *object = plater_obj(plater, object_ids[index]);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "group object was not found");
        Slic3r::ModelInstance *instance =
            plater_instance(object, instance_ids[index]);
        if (!instance)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "group instance was not found");
        const size_t key = reinterpret_cast<size_t>(instance);
        if (!seen.insert(key).second)
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "group lists an instance twice");
        out->push_back(instance);
    }
    return orcapad_ok();
}

orca_result orca_plater_instances_set(
    orca_plater *plater,
    const orca_object_id *object_ids,
    const orca_instance_id *instance_ids,
    const orca_instance_transform *transforms,
    int32_t count, const char *label,
    orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_instances_set";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!object_ids || !instance_ids || !transforms || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "input or output pointer is null");
    for (int32_t index = 0; index < count; ++index)
        if (!orcapad_valid_transform(transforms[index]))
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "a group transform is invalid");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        std::vector<Slic3r::ModelInstance *> group;
        const orca_result found = orcapad_resolve_group(
            plater, object_ids, instance_ids, count, operation, &group);
        if (found.code != ORCA_STATUS_OK) return found;
        OrcapadMutation mutation(*plater, label && label[0] ? label : "Transform");
        for (int32_t index = 0; index < count; ++index) {
            Slic3r::ModelInstance *instance = group[static_cast<size_t>(index)];
            const orca_instance_transform &wanted = transforms[index];
            Slic3r::Geometry::Transformation candidate = instance->get_transformation();
            candidate.set_offset(Slic3r::Vec3d(
                wanted.offset_x, wanted.offset_y, wanted.offset_z));
            candidate.set_rotation(Slic3r::Vec3d(
                wanted.rotation_x, wanted.rotation_y, wanted.rotation_z));
            candidate.set_scaling_factor(Slic3r::Vec3d(
                wanted.scale_x, wanted.scale_y, wanted.scale_z));
            instance->set_transformation(candidate);
            orcapad_rest_on_bed(instance->get_object(), instance);
        }
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_instances_rotate(
    orca_plater *plater,
    const orca_object_id *object_ids,
    const orca_instance_id *instance_ids,
    int32_t count, int32_t axis, double radians,
    orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_instances_rotate";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!object_ids || !instance_ids || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "input or output pointer is null");
    if (axis < 0 || axis > 2)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "axis must be 0 (X), 1 (Y), or 2 (Z)");
    if (!std::isfinite(radians))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "rotation angle is not finite");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        std::vector<Slic3r::ModelInstance *> group;
        const orca_result found = orcapad_resolve_group(
            plater, object_ids, instance_ids, count, operation, &group);
        if (found.code != ORCA_STATUS_OK) return found;
        OrcapadMutation mutation(*plater, "Rotate");
        const Slic3r::Vec3d world_axis = axis == 0 ? Slic3r::Vec3d::UnitX()
            : axis == 1 ? Slic3r::Vec3d::UnitY() : Slic3r::Vec3d::UnitZ();
        const Slic3r::Matrix3d rotation =
            Eigen::AngleAxisd(radians, world_axis).toRotationMatrix();
        for (Slic3r::ModelInstance *instance : group) {
            instance->rotate(rotation);
            orcapad_rest_on_bed(instance->get_object(), instance);
        }
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_instance_mirror(orca_plater *plater,
                                        orca_object_id object_id,
                                        orca_instance_id instance_id,
                                        int32_t axis, orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_instance_mirror";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    if (axis < 0 || axis > 2)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "axis must be 0 (X), 1 (Y), or 2 (Z)");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        Slic3r::ModelInstance *instance = plater_instance(object, instance_id);
        if (!instance)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "instance was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Mirror");
        // ModelInstance has no mirror() toggle (ModelObject does):
        // flip the axis mirror flag like Selection::mirror does.
        instance->set_mirror(static_cast<Slic3r::Axis>(axis),
                             -instance->get_mirror(static_cast<Slic3r::Axis>(axis)));
        orcapad_rest_on_bed(object, instance);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

/// Resolves a settings target: the object config (volume_id 0) or one
/// volume's config.
static orca_result orcapad_settings_target(orca_plater *plater, orca_object_id object_id,
                                           orca_volume_id volume_id, const char *operation,
                                           Slic3r::ModelConfig **out_config,
                                           bool *out_is_volume) {
    Slic3r::ModelObject *object = plater_obj(plater, object_id);
    if (!object)
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
    if (volume_id == 0) {
        *out_config = &object->config;
        *out_is_volume = false;
        return orcapad_ok();
    }
    Slic3r::ModelVolume *volume = plater_volume(object, volume_id);
    if (!volume)
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "volume was not found");
    *out_config = &volume->config;
    *out_is_volume = true;
    return orcapad_ok();
}

orca_result orca_plater_settings_keys(uint8_t for_volume, orca_owned_string *out_json) {
    constexpr const char *operation = "orca_plater_settings_keys";
    if (out_json) *out_json = orcapad_empty_string();
    if (!out_json)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        nlohmann::json keys = nlohmann::json::array();
        for (const std::string &key : orcapad_settings_keys(for_volume != 0)) keys.push_back(key);
        if (!orcapad_copy_string(keys.dump().c_str(), out_json))
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate the key list");
        return orcapad_ok();
    });
}

orca_result orca_plater_settings_dump(orca_plater *plater, orca_object_id object_id,
                                      orca_volume_id volume_id,
                                      orca_owned_string *out_json) {
    constexpr const char *operation = "orca_plater_settings_dump";
    if (out_json) *out_json = orcapad_empty_string();
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_json)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelConfig *config = nullptr;
        bool is_volume = false;
        const orca_result found = orcapad_settings_target(
            plater, object_id, volume_id, operation, &config, &is_volume);
        if (found.code != ORCA_STATUS_OK) return found;
        const std::set<std::string> &allowed = orcapad_settings_keys(is_volume);
        nlohmann::json out = nlohmann::json::object();
        for (const std::string &key : config->keys())
            if (allowed.count(key)) out[key] = config->opt_serialize(key);
        if (!orcapad_copy_string(out.dump().c_str(), out_json))
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate the override dump");
        return orcapad_ok();
    });
}

orca_result orca_plater_settings_set(orca_plater *plater, orca_object_id object_id,
                                     orca_volume_id volume_id, const char *key,
                                     const char *serialized_value,
                                     orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_settings_set";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!key || !key[0] || !serialized_value || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "key, value or output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelConfig *config = nullptr;
        bool is_volume = false;
        const orca_result found = orcapad_settings_target(
            plater, object_id, volume_id, operation, &config, &is_volume);
        if (found.code != ORCA_STATUS_OK) return found;
        if (!orcapad_settings_keys(is_volume).count(key))
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                is_volume ? "this option cannot be overridden per part"
                                          : "this option cannot be overridden per object");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, is_volume ? "Part setting" : "Object setting");
        // re-resolve inside the mutation scope (pointers stay valid: the
        // scope copies the document, the live model is unchanged)
        Slic3r::ConfigSubstitutionContext substitutions(
            Slic3r::ForwardCompatibilitySubstitutionRule::Disable);
        try {
            config->set_deserialize(key, serialized_value, substitutions);
        } catch (const std::exception &error) {
            return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation, error.what());
        }
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_settings_erase(orca_plater *plater, orca_object_id object_id,
                                       orca_volume_id volume_id, const char *key,
                                       orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_settings_erase";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!key || !key[0] || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "key or output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelConfig *config = nullptr;
        bool is_volume = false;
        const orca_result found = orcapad_settings_target(
            plater, object_id, volume_id, operation, &config, &is_volume);
        if (found.code != ORCA_STATUS_OK) return found;
        if (!config->has(key))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "the option is not overridden here");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, is_volume ? "Part setting" : "Object setting");
        config->erase(key);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_settings_apply(orca_plater *plater, orca_object_id object_id,
                                       orca_volume_id volume_id,
                                       const char *const *keys,
                                       const char *const *serialized_values,
                                       int32_t count, orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_settings_apply";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (count < 0 || (count > 0 && (!keys || !serialized_values)))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "count is negative or the key/value arrays are null");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelConfig *config = nullptr;
        bool is_volume = false;
        const orca_result found = orcapad_settings_target(
            plater, object_id, volume_id, operation, &config, &is_volume);
        if (found.code != ORCA_STATUS_OK) return found;
        const std::set<std::string> &allowed = orcapad_settings_keys(is_volume);
        // Validate everything BEFORE the mutation scope: a rejected key or
        // an empty name must leave the document untouched.
        for (int32_t index = 0; index < count; ++index) {
            const char *key = keys[index];
            const char *value = serialized_values[index];
            if (!key || !key[0] || !value)
                return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                    "a key or value entry is null or empty");
            if (!allowed.count(key)) {
                const std::string detail =
                    std::string("this option cannot be overridden ") +
                    (is_volume ? "per part: " : "per object: ") + key;
                return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                    detail.c_str());
            }
        }
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater,
                                 is_volume ? "Paste part settings" : "Paste object settings");
        // Desktop ObjectList::paste_settings_into_list: the target's config
        // is reset, then the copied pairs are applied.
        config->reset();
        Slic3r::ConfigSubstitutionContext substitutions(
            Slic3r::ForwardCompatibilitySubstitutionRule::Disable);
        for (int32_t index = 0; index < count; ++index)
            try {
                config->set_deserialize(keys[index], serialized_values[index],
                                        substitutions);
            } catch (const std::exception &error) {
                return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                    error.what());
            }
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

// --- object operations (ABI v23) -------------------------------------------

static Slic3r::DynamicPrintConfig orcapad_arrange_config(orca_presets *presets);

#define ORCAPAD_BEGIN(op_name)                                                     \
    constexpr const char *operation = op_name;                                     \
    if (out_revision) *out_revision = 0;                                           \
    if (!plater)                                                                   \
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,                 \
                            "plater handle is null");                              \
    if (!out_revision)                                                             \
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,               \
                            "output pointer is null");

orca_result orca_plater_set_printable(orca_plater *plater, orca_object_id object_id,
                                      orca_instance_id instance_id, uint8_t printable,
                                      orca_revision *out_revision) {
    ORCAPAD_BEGIN("orca_plater_set_printable")
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        Slic3r::ModelInstance *instance = nullptr;
        if (instance_id != 0) {
            instance = plater_instance(object, instance_id);
            if (!instance)
                return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "instance was not found");
        }
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, printable ? "Set printable" : "Set unprintable");
        if (instance) {
            instance->printable = printable != 0;
        } else {
            object->printable = printable != 0;
            for (Slic3r::ModelInstance *each : object->instances) each->printable = printable != 0;
        }
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_set_instance_count(orca_plater *plater, orca_object_id object_id,
                                           int32_t count, orca_revision *out_revision) {
    ORCAPAD_BEGIN("orca_plater_set_instance_count")
    if (count < 1 || count > 1000)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "instance count must be 1..1000");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        if (object->instances.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation, "object has no instance");
        if (static_cast<size_t>(count) == object->instances.size())
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "the object already has that many instances");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Set number of instances");
        while (object->instances.size() > static_cast<size_t>(count))
            object->delete_instance(object->instances.size() - 1);
        while (object->instances.size() < static_cast<size_t>(count)) {
            Slic3r::ModelInstance *instance = object->add_instance(*object->instances.back());
            instance->set_offset(instance->get_offset() + Slic3r::Vec3d(10.0, 10.0, 0.0));
        }
        object->invalidate_bounding_box();
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_clone_object(orca_plater *plater, orca_object_id object_id,
                                     int32_t count, orca_object_id *out_first_object_id,
                                     orca_revision *out_revision) {
    if (out_first_object_id) *out_first_object_id = 0;
    ORCAPAD_BEGIN("orca_plater_clone_object")
    if (!out_first_object_id)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    if (count < 1 || count > 100)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "clone count must be 1..100");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *source = plater_obj(plater, object_id);
        if (!source)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Clone");
        orca_object_id first = 0;
        for (int32_t index = 1; index <= count; ++index) {
            Slic3r::ModelObject *clone = plater->model.add_object(*source);
            if (!clone)
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine did not create the clone");
            clone->translate_instances(Slic3r::Vec3d(10.0 * index, 10.0 * index, 0.0));
            clone->ensure_on_bed(false);
            if (!orcapad_register_object(*plater, *clone))
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine returned an invalid or reused object ID");
            if (first == 0) first = static_cast<orca_object_id>(clone->id().id);
        }
        *out_revision = mutation.commit();
        *out_first_object_id = first;
        return orcapad_ok();
    });
}

orca_result orca_plater_instance_to_object(orca_plater *plater, orca_object_id object_id,
                                           orca_instance_id instance_id,
                                           orca_object_id *out_object_id,
                                           orca_revision *out_revision) {
    if (out_object_id) *out_object_id = 0;
    ORCAPAD_BEGIN("orca_plater_instance_to_object")
    if (!out_object_id)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        size_t index = 0;
        if (!plater_instance(object, instance_id, &index))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "instance was not found");
        if (object->instances.size() < 2)
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "the object has a single instance");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Instance to object");
        // desktop instances_to_separated_object: a copy keeping only that instance
        Slic3r::ModelObject *separated = plater->model.add_object(*object);
        if (!separated)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine did not create the object");
        for (size_t i = separated->instances.size(); i-- > 0;)
            if (i != index) separated->delete_instance(i);
        object->delete_instance(index);
        object->invalidate_bounding_box();
        separated->invalidate_bounding_box();
        if (!orcapad_register_object(*plater, *separated))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine returned an invalid or reused object ID");
        const orca_object_id id = static_cast<orca_object_id>(separated->id().id);
        *out_revision = mutation.commit();
        *out_object_id = id;
        return orcapad_ok();
    });
}

orca_result orca_plater_merge_objects(orca_plater *plater, const orca_object_id *object_ids,
                                      int32_t count, orca_object_id *out_object_id,
                                      orca_revision *out_revision) {
    if (out_object_id) *out_object_id = 0;
    ORCAPAD_BEGIN("orca_plater_merge_objects")
    if (!object_ids || !out_object_id)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "input or output pointer is null");
    if (count < 2 || count > 1000)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "assembling needs at least two objects");
    return orcapad_guard(operation, [&]() -> orca_result {
        std::vector<Slic3r::ModelObject *> sources;
        std::set<orca_object_id> seen;
        for (int32_t i = 0; i < count; ++i) {
            Slic3r::ModelObject *object = plater_obj(plater, object_ids[i]);
            if (!object)
                return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
            if (!seen.insert(object_ids[i]).second)
                return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                    "an object is listed twice");
            if (object->instances.size() != 1)
                return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                    "assemble single-instance objects (split instances first)");
            sources.push_back(object);
        }
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Assemble");
        // desktop ObjectList::merge(true)
        Slic3r::ModelObject *assembly = plater->model.add_object();
        assembly->name = "Assembly";
        assembly->add_instance();
        for (Slic3r::ModelObject *object : sources) {
            const Slic3r::Transform3d matrix = object->instances[0]->get_transformation().get_matrix();
            for (const Slic3r::ModelVolume *volume : object->volumes) {
                Slic3r::ModelVolume *merged = assembly->add_volume(*volume);
                merged->set_transformation(matrix * merged->get_matrix());
                if (object->volumes.size() > 1) merged->config.assign_config(volume->config);
                if (!merged->config.has("extruder") && object->config.has("extruder"))
                    merged->config.set_key_value(
                        "extruder", new Slic3r::ConfigOptionInt(object->config.opt_int("extruder")));
            }
            for (const std::string &key : object->config.keys())
                if (!assembly->config.has(key))
                    assembly->config.set_key_value(key, object->config.option(key)->clone());
            if (!object->instances[0]->printable) {
                assembly->printable = false;
                assembly->instances[0]->printable = false;
            }
            for (const auto &range : object->layer_config_ranges)
                assembly->layer_config_ranges.emplace(range);
        }
        assembly->sort_volumes(true);
        assembly->ensure_on_bed();
        assembly->center_around_origin();
        assembly->translate_instances(-assembly->origin_translation);
        assembly->origin_translation = Slic3r::Vec3d::Zero();
        for (Slic3r::ModelObject *object : sources) {
            const orca_object_id id = static_cast<orca_object_id>(object->id().id);
            plater->mesh_revisions.erase(id);
            plater->model.delete_object(object);
        }
        if (!orcapad_register_object(*plater, *assembly))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine returned an invalid or reused object ID");
        const orca_object_id id = static_cast<orca_object_id>(assembly->id().id);
        *out_revision = mutation.commit();
        *out_object_id = id;
        return orcapad_ok();
    });
}

orca_result orca_plater_scale_to_fit(orca_plater *plater, orca_presets *presets,
                                     orca_object_id object_id, orca_instance_id instance_id,
                                     orca_revision *out_revision) {
    ORCAPAD_BEGIN("orca_plater_scale_to_fit")
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "presets handle is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        Slic3r::ModelInstance *instance = plater_instance(object, instance_id);
        if (!instance)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "instance was not found");
        const Slic3r::DynamicPrintConfig config = orcapad_arrange_config(presets);
        const auto *area = config.option<Slic3r::ConfigOptionPoints>("printable_area");
        if (!area || area->values.empty() || !config.has("printable_height"))
            return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                "the machine has no printable area / height");
        Slic3r::BoundingBoxf bed;
        for (const auto &point : area->values) bed.merge(Slic3r::Vec2d(point.x(), point.y()));
        const Slic3r::Vec3d volume_size(bed.size().x(), bed.size().y(),
                                        config.opt_float("printable_height"));
        object->invalidate_bounding_box();
        const Slic3r::Vec3d box =
            object->instance_bounding_box(*instance).size() + 0.01 * Slic3r::Vec3d::Ones();
        if (box.x() <= 0 || box.y() <= 0 || box.z() <= 0)
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation, "the instance has no extent");
        const double s = std::min({volume_size.x() / box.x(), volume_size.y() / box.y(),
                                   volume_size.z() / box.z()});
        if (std::abs(s - 1.0) < 1e-9)
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "the instance already fits the build volume exactly");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Scale To Fit");
        instance->set_scaling_factor(instance->get_scaling_factor() * s);
        object->invalidate_bounding_box();
        const Slic3r::BoundingBoxf3 scaled = object->instance_bounding_box(*instance);
        const Slic3r::Vec3d shift(bed.center().x() - scaled.center().x(),
                                  bed.center().y() - scaled.center().y(), 0.0);
        instance->set_offset(instance->get_offset() + shift);
        orcapad_rest_on_bed(object, instance);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_convert_units(orca_plater *plater, orca_object_id object_id,
                                      int32_t conversion, orca_object_id *out_object_id,
                                      orca_revision *out_revision) {
    if (out_object_id) *out_object_id = 0;
    ORCAPAD_BEGIN("orca_plater_convert_units")
    if (!out_object_id)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    Slic3r::ConversionType type;
    switch (conversion) {
    case ORCA_UNITS_FROM_INCH: type = Slic3r::ConversionType::CONV_FROM_INCH; break;
    case ORCA_UNITS_TO_INCH: type = Slic3r::ConversionType::CONV_TO_INCH; break;
    case ORCA_UNITS_FROM_METER: type = Slic3r::ConversionType::CONV_FROM_METER; break;
    case ORCA_UNITS_TO_METER: type = Slic3r::ConversionType::CONV_TO_METER; break;
    default:
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "unknown unit conversion");
    }
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Convert units");
        // convert_units returns detached clones (set_model(nullptr)) whose
        // destructor is private to Model: a scratch Model owns and frees
        // them; they enter the document as copies through add_object.
        Slic3r::Model scratch;
        object->convert_units(scratch.objects, type, {});
        if (scratch.objects.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "the conversion produced no object");
        orca_object_id first = 0;
        for (const Slic3r::ModelObject *clone : scratch.objects) {
            Slic3r::ModelObject *added = plater->model.add_object(*clone);
            if (!added)
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine did not add the converted object");
            added->ensure_on_bed(false);
            if (!orcapad_register_object(*plater, *added))
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine returned an invalid or reused object ID");
            if (first == 0) first = static_cast<orca_object_id>(added->id().id);
        }
        plater->mesh_revisions.erase(object_id);
        plater->model.delete_object(object);
        *out_revision = mutation.commit();
        *out_object_id = first;
        return orcapad_ok();
    });
}

#undef ORCAPAD_BEGIN

// --- per-layer custom G-code (ABI v24) --------------------------------------

static bool orcapad_custom_type(int32_t type, Slic3r::CustomGCode::Type *out) {
    switch (type) {
    case ORCA_CUSTOM_COLOR_CHANGE: *out = Slic3r::CustomGCode::Type::ColorChange; return true;
    case ORCA_CUSTOM_PAUSE_PRINT: *out = Slic3r::CustomGCode::Type::PausePrint; return true;
    case ORCA_CUSTOM_TOOL_CHANGE: *out = Slic3r::CustomGCode::Type::ToolChange; return true;
    case ORCA_CUSTOM_TEMPLATE: *out = Slic3r::CustomGCode::Type::Template; return true;
    case ORCA_CUSTOM_CUSTOM: *out = Slic3r::CustomGCode::Type::Custom; return true;
    default: return false;
    }
}

static const char *orcapad_custom_label(int32_t type) {
    switch (type) {
    case ORCA_CUSTOM_COLOR_CHANGE: return "Color change";
    case ORCA_CUSTOM_PAUSE_PRINT: return "Pause print";
    case ORCA_CUSTOM_TOOL_CHANGE: return "Tool change";
    case ORCA_CUSTOM_TEMPLATE: return "Custom template";
    default: return "Custom G-code";
    }
}

void orca_custom_gcode_item_dispose(orca_custom_gcode_item *item) {
    if (!item) return;
    orca_owned_string_dispose(&item->color);
    orca_owned_string_dispose(&item->extra);
    *item = orca_custom_gcode_item{};
}

static Slic3r::CustomGCode::Info &orcapad_plate_custom_gcodes(orca_plater *plater) {
    return plater->model.plates_custom_gcodes[plater->model.curr_plate_index];
}

orca_result orca_plater_custom_gcode_count(orca_plater *plater, int32_t *out_count) {
    constexpr const char *operation = "orca_plater_custom_gcode_count";
    if (out_count) *out_count = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_count)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        const size_t count = orcapad_plate_custom_gcodes(plater).gcodes.size();
        if (count > static_cast<size_t>(std::numeric_limits<int32_t>::max()))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "custom G-code count exceeds ABI range");
        *out_count = static_cast<int32_t>(count);
        return orcapad_ok();
    });
}

orca_result orca_plater_custom_gcode_item(orca_plater *plater, int32_t index,
                                          orca_custom_gcode_item *out_item) {
    constexpr const char *operation = "orca_plater_custom_gcode_item";
    if (out_item) *out_item = orca_custom_gcode_item{};
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_item)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        const auto &gcodes = orcapad_plate_custom_gcodes(plater).gcodes;
        if (index < 0 || static_cast<size_t>(index) >= gcodes.size())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "custom G-code item was not found");
        const Slic3r::CustomGCode::Item &item = gcodes[static_cast<size_t>(index)];
        int32_t type = -1;
        for (int candidate = ORCA_CUSTOM_COLOR_CHANGE;
             candidate <= ORCA_CUSTOM_CUSTOM; ++candidate) {
            Slic3r::CustomGCode::Type mapped{};
            if (orcapad_custom_type(candidate, &mapped) && mapped == item.type) {
                type = candidate;
                break;
            }
        }
        if (type < 0)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine stored an unknown custom G-code type");
        if (!orcapad_copy_string(item.color.c_str(), &out_item->color) ||
            !orcapad_copy_string(item.extra.c_str(), &out_item->extra)) {
            orca_custom_gcode_item_dispose(out_item);
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate the custom G-code item");
        }
        out_item->print_z = item.print_z;
        out_item->type = type;
        out_item->extruder = item.extruder;
        return orcapad_ok();
    });
}

orca_result orca_plater_custom_gcode_add(orca_plater *plater, double print_z,
                                         int32_t type, int32_t extruder,
                                         const char *color, const char *extra,
                                         orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_custom_gcode_add";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!color || !extra || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "color, extra or output pointer is null");
    if (!std::isfinite(print_z) || print_z <= 0.0)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "print height must be positive");
    Slic3r::CustomGCode::Type mapped{};
    if (!orcapad_custom_type(type, &mapped))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "unknown custom G-code type");
    if (type == ORCA_CUSTOM_TEMPLATE)
        return orcapad_fail(ORCA_STATUS_UNSUPPORTED_CAPABILITY, operation,
                            "custom templates need the preset template G-code and are not supported yet");
    if ((type == ORCA_CUSTOM_COLOR_CHANGE || type == ORCA_CUSTOM_TOOL_CHANGE) && extruder < 1)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "colour and tool changes need a 1-based extruder");
    if (type == ORCA_CUSTOM_CUSTOM &&
        std::string(extra).find_first_not_of(" \t\r\n") == std::string::npos)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "custom G-code text is empty");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, orcapad_custom_label(type));
        Slic3r::CustomGCode::Info &info = orcapad_plate_custom_gcodes(plater);
        auto &gcodes = info.gcodes;
        Slic3r::CustomGCode::Item item;
        item.print_z = print_z;
        item.type = mapped;
        item.extruder = extruder;
        item.color = color;
        item.extra = extra;
        // replace an item at the same height, else sorted insert
        auto at = std::lower_bound(gcodes.begin(), gcodes.end(), item);
        if (at != gcodes.end() && std::abs(at->print_z - print_z) < 1e-6)
            *at = item;
        else
            gcodes.insert(at, item);
        info.mode = Slic3r::CustomGCode::Undef; // re-derive on next use
        Slic3r::CustomGCode::check_mode_for_custom_gcode_per_print_z(info);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_custom_gcode_delete(orca_plater *plater, double print_z,
                                            orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_custom_gcode_delete";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    if (!std::isfinite(print_z))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "print height is not finite");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        Slic3r::CustomGCode::Info &info = orcapad_plate_custom_gcodes(plater);
        auto &gcodes = info.gcodes;
        Slic3r::CustomGCode::Item probe;
        probe.print_z = print_z;
        auto at = std::lower_bound(gcodes.begin(), gcodes.end(), probe);
        if (at == gcodes.end() || std::abs(at->print_z - print_z) >= 1e-6)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "no custom G-code at that print height");
        OrcapadMutation mutation(*plater, "Delete custom G-code");
        gcodes.erase(at);
        info.mode = Slic3r::CustomGCode::Undef;
        Slic3r::CustomGCode::check_mode_for_custom_gcode_per_print_z(info);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_object_copy(orca_plater *plater, orca_object_id object_id) {
    constexpr const char *operation = "orca_plater_object_copy";
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    return orca_plater_objects_copy(plater, &object_id, 1);
}

/// Shared paste core: adds `src` to the document centred so its first
/// instance lands at `place` (z kept; ensure_on_bed applies). Returns the new
/// object ID through `out_object_id`. Runs INSIDE a mutation scope owned by
/// the caller (a failure unwinds the whole paste).
static orca_result orcapad_paste_object(
    orca_plater &plater, const Slic3r::ModelObject &src,
    const Slic3r::Vec3d &place, const char *operation,
    orca_object_id *out_object_id) {
    Slic3r::ModelObject *object = plater.model.add_object(src);
    if (!object)
        return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                            "engine did not create the pasted object");
    object->center_around_origin();
    if (object->instances.empty())
        object->add_instance();
    object->instances.front()->set_offset(place);
    object->ensure_on_bed(false);
    if (!orcapad_register_object(plater, *object))
        return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                            "engine returned an invalid or reused object ID");
    *out_object_id = static_cast<orca_object_id>(object->id().id);
    return orcapad_ok();
}

orca_result orca_plater_object_paste(orca_plater *plater, double bed_center_x,
                                     double bed_center_y,
                                     orca_object_id *out_object_id,
                                     orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_object_paste";
    if (out_object_id) *out_object_id = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_object_id || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    if (!std::isfinite(bed_center_x) || !std::isfinite(bed_center_y))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "bed center contains a non-finite value");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (!plater->clipboard || plater->clipboard->objects.empty())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "the clipboard is empty");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, "Paste");
        const orca_result pasted = orcapad_paste_object(
            *plater, *plater->clipboard->objects.front(),
            Slic3r::Vec3d(bed_center_x, bed_center_y, 0.0), operation,
            out_object_id);
        if (pasted.code != ORCA_STATUS_OK) return pasted;
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_objects_delete(orca_plater *plater,
                                       const orca_object_id *object_ids,
                                       int32_t count,
                                       orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_objects_delete";
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (count < 1 || !object_ids)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "count is below one or the ID array is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        // Resolve every target up front (duplicates collapsed): a missing
        // ID must delete nothing.
        std::vector<orca_object_id> targets;
        targets.reserve(static_cast<size_t>(count));
        for (int32_t index = 0; index < count; ++index)
            if (std::find(targets.begin(), targets.end(), object_ids[index]) ==
                targets.end())
                targets.push_back(object_ids[index]);
        for (const orca_object_id id : targets)
            if (!plater_obj(plater, id))
                return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                    "object was not found");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater,
                                 targets.size() == 1 ? "Delete" : "Delete objects");
        for (const orca_object_id id : targets) {
            if (!plater->model.delete_object(
                    Slic3r::ObjectID(static_cast<size_t>(id))))
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine did not delete the object");
            plater->mesh_revisions.erase(id);
        }
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

orca_result orca_plater_objects_copy(orca_plater *plater,
                                     const orca_object_id *object_ids,
                                     int32_t count) {
    constexpr const char *operation = "orca_plater_objects_copy";
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (count < 1 || !object_ids)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "count is below one or the ID array is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        std::vector<const Slic3r::ModelObject *> targets;
        targets.reserve(static_cast<size_t>(count));
        for (int32_t index = 0; index < count; ++index) {
            const Slic3r::ModelObject *object = plater_obj(plater, object_ids[index]);
            if (!object)
                return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                    "object was not found");
            if (std::find(targets.begin(), targets.end(), object) == targets.end())
                targets.push_back(object);
        }
        Slic3r::Model clipboard;
        for (const Slic3r::ModelObject *object : targets)
            if (!clipboard.add_object(*object))
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "engine refused to copy the object");
        plater->clipboard = std::move(clipboard);
        return orcapad_ok();
    });
}

orca_result orca_plater_objects_paste(orca_plater *plater,
                                     double bed_center_x, double bed_center_y,
                                     orca_object_id *out_ids, int32_t capacity,
                                     int32_t *out_count,
                                     orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_objects_paste";
    if (out_count) *out_count = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_count || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    if (!std::isfinite(bed_center_x) || !std::isfinite(bed_center_y))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "bed center contains a non-finite value");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (!plater->clipboard || plater->clipboard->objects.empty())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "the clipboard is empty");
        const size_t paste_count = plater->clipboard->objects.size();
        if (paste_count > static_cast<size_t>(std::numeric_limits<int32_t>::max()))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "clipboard size exceeds ABI range");
        if (!out_ids || capacity < static_cast<int32_t>(paste_count))
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "the output array is null or smaller than the clipboard");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");
        OrcapadMutation mutation(*plater, paste_count == 1 ? "Paste" : "Paste objects");
        // Desktop Selection::paste_objects_from_clipboard keeps the relative
        // placement between objects: the first lands on `bed_center`, the
        // others keep their offset relative to it (the clipboard's own
        // offsets — imports are centred, so they are comparable).
        const Slic3r::Vec3d reference =
            plater->clipboard->objects.front()->instances.empty()
                ? Slic3r::Vec3d::Zero()
                : plater->clipboard->objects.front()->instances.front()->get_offset();
        for (size_t index = 0; index < paste_count; ++index) {
            const Slic3r::ModelObject &src = *plater->clipboard->objects[index];
            const Slic3r::Vec3d own =
                src.instances.empty() ? Slic3r::Vec3d::Zero()
                                      : src.instances.front()->get_offset();
            const Slic3r::Vec3d place(bed_center_x + (own.x() - reference.x()),
                                      bed_center_y + (own.y() - reference.y()), 0.0);
            orca_object_id pasted_id = 0;
            const orca_result pasted =
                orcapad_paste_object(*plater, src, place, operation, &pasted_id);
            if (pasted.code != ORCA_STATUS_OK) return pasted;
            out_ids[index] = pasted_id;
        }
        *out_count = static_cast<int32_t>(paste_count);
        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

static orca_scene_snapshot orcapad_empty_snapshot() noexcept {
    return orca_scene_snapshot{};
}

void orca_scene_snapshot_dispose(orca_scene_snapshot *snapshot) {
    if (!snapshot) return;
    if (snapshot->objects) {
        for (int32_t index = 0; index < snapshot->object_count; ++index) {
            orca_scene_object &object = snapshot->objects[index];
            orca_owned_string_dispose(&object.name);
            if (object.volumes) {
                for (int32_t v = 0; v < object.volume_count; ++v) {
                    orca_owned_string_dispose(&object.volumes[v].name);
                    std::free(object.volumes[v].positions);
                    std::free(object.volumes[v].indices);
                }
            }
            std::free(object.volumes);
            std::free(object.positions);
            std::free(object.indices);
            std::free(object.instances);
        }
    }
    std::free(snapshot->objects);
    if (snapshot->plates) {
        for (int32_t index = 0; index < snapshot->plate_count; ++index)
            orca_owned_string_dispose(&snapshot->plates[index].name);
    }
    std::free(snapshot->plates);
    orca_owned_string_dispose(&snapshot->undo_label);
    orca_owned_string_dispose(&snapshot->redo_label);
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
        if (plater->plates.empty())
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document has no plates");
        // Derived-state maintenance: pins never outlive their instances.
        orcapad_sweep_pins(*plater);

        // Per-plate object counts, filled while instances are assigned.
        std::vector<int32_t> plate_objects(plater->plates.size(), 0);

        orca_scene_snapshot snapshot = orcapad_empty_snapshot();
        std::unique_ptr<orca_scene_snapshot,
                        void (*)(orca_scene_snapshot *)> cleanup(
            &snapshot, &orca_scene_snapshot_dispose);
        snapshot.document_id =
            static_cast<orca_document_id>(plater->model.id().id);
        snapshot.revision = plater->revision;
        snapshot.object_count =
            static_cast<int32_t>(plater->model.objects.size());
        snapshot.undo_count = static_cast<uint32_t>(plater->undo.size());
        snapshot.redo_count = static_cast<uint32_t>(plater->redo.size());
        if (!orcapad_copy_string(plater->undo.empty() ? "" : plater->undo.back().label.c_str(),
                                 &snapshot.undo_label) ||
            !orcapad_copy_string(plater->redo.empty() ? "" : plater->redo.back().label.c_str(),
                                 &snapshot.redo_label))
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate history labels");
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

        // Plates (ABI v27): grid layout, names, locks. The per-plate object
        // counts are filled AFTER the object loop below ran — allocation
        // happens here, the counts in the final pass.
        snapshot.plate_count = static_cast<int32_t>(plater->plates.size());
        snapshot.plates = static_cast<orca_scene_plate *>(std::calloc(
            static_cast<size_t>(snapshot.plate_count), sizeof(orca_scene_plate)));
        if (!snapshot.plates)
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate snapshot plates");
        for (int32_t plate_index = 0; plate_index < snapshot.plate_count;
             ++plate_index) {
            const OrcapadPlate &source = plater->plates[static_cast<size_t>(plate_index)];
            orca_scene_plate &plate = snapshot.plates[plate_index];
            plate.id = source.id;
            plate.index = plate_index;
            plate.locked = source.locked ? 1 : 0;
            const Slic3r::BoundingBoxf3 box =
                orcapad_plate_box(*plater, plate_index);
            for (int axis = 0; axis < 3; ++axis) {
                plate.origin[axis] = static_cast<float>(box.min(axis));
                plate.size[axis] = static_cast<float>(box.size()(axis));
            }
            if (!orcapad_copy_string(source.name.c_str(), &plate.name))
                return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                    "could not allocate plate name");
        }
        snapshot.current_plate = plater->current_plate;

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
            object.override_count = static_cast<uint32_t>(
                orcapad_override_count(model_object->config.get()));
            const Slic3r::DynamicPrintConfig &object_config = model_object->config.get();
            if (const auto *extruder =
                    object_config.option<Slic3r::ConfigOptionInt>("extruder"))
                object.extruder = static_cast<int32_t>(extruder->value);
            else
                object.extruder = 0;
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
            // Plates this object touches via its instances (for the
            // per-plate object_count below).
            std::vector<char> object_landed(plater->plates.size(), 0);
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
                instance.mirrored = model_instance->is_left_handed() ? 1 : 0;
                instance.printable = model_instance->printable ? 1 : 0;
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
                instance.plate = orcapad_instance_plate(
                    *plater,
                    static_cast<orca_object_id>(model_object->id().id),
                    instance.id,
                    orcapad_instance_box(*model_instance));
                if (instance.plate >= 0 &&
                    instance.plate < static_cast<int32_t>(object_landed.size()))
                    object_landed[instance.plate] = 1;
            }
            for (size_t plate_index = 0; plate_index < object_landed.size();
                 ++plate_index)
                if (object_landed[plate_index]) ++plate_objects[plate_index];

            // Volumes (desktop object list), document order. Model parts
            // render through the merged object mesh above; every other
            // role carries its own object-space mesh. `merged_triangles`
            // tracks each part's range inside that merged mesh.
            uint32_t merged_triangles = 0;
            object.volume_count =
                static_cast<int32_t>(model_object->volumes.size());
            object.volumes = static_cast<orca_scene_volume *>(std::calloc(
                static_cast<size_t>(object.volume_count),
                sizeof(orca_scene_volume)));
            if (!object.volumes)
                return fail_snapshot(ORCA_STATUS_OUT_OF_MEMORY,
                                     "could not allocate snapshot volumes");
            for (int32_t volume_index = 0;
                 volume_index < object.volume_count; ++volume_index) {
                const Slic3r::ModelVolume *model_volume =
                    model_object->volumes[static_cast<size_t>(volume_index)];
                orca_scene_volume &volume = object.volumes[volume_index];
                volume.id = static_cast<orca_volume_id>(model_volume->id().id);
                const uint8_t role = orcapad_volume_role(model_volume->type());
                if (volume.id == 0 || role == 0xFF)
                    return fail_snapshot(ORCA_STATUS_INTERNAL_INVARIANT,
                                         "engine returned an invalid volume");
                volume.type = role;
                volume.extruder = model_volume->config.has("extruder")
                    ? model_volume->config.opt_int("extruder") : 0;
                volume.override_count = static_cast<uint32_t>(
                    orcapad_override_count(model_volume->config.get()));
                if (!orcapad_copy_string(model_volume->name.c_str(), &volume.name))
                    return fail_snapshot(ORCA_STATUS_OUT_OF_MEMORY,
                                         "could not allocate volume name");

                if (role == ORCA_VOLUME_PART) {
                    // Triangle range inside the merged mesh above: raw_mesh()
                    // concatenates part volumes in document order, so the
                    // running sum of per-part triangle counts is exact.
                    const size_t triangles =
                        model_volume->mesh().its.indices.size();
                    if (triangles > std::numeric_limits<uint32_t>::max() ||
                        merged_triangles >
                            std::numeric_limits<uint32_t>::max() - triangles)
                        return fail_snapshot(ORCA_STATUS_INTERNAL_INVARIANT,
                                             "part triangle range exceeds ABI range");
                    volume.merged_triangle_start = merged_triangles;
                    volume.merged_triangle_count =
                        static_cast<uint32_t>(triangles);
                    merged_triangles += triangles;
                    const Slic3r::BoundingBoxf3 box =
                        model_volume->mesh().transformed_bounding_box(
                            model_volume->get_matrix());
                    if (!box.defined)
                        return fail_snapshot(ORCA_STATUS_INVALID_MODEL,
                                             "volume mesh is empty");
                    for (int axis = 0; axis < 3; ++axis) {
                        volume.bbox_min[axis] = static_cast<float>(box.min(axis));
                        volume.bbox_max[axis] = static_cast<float>(box.max(axis));
                    }
                    continue;
                }

                Slic3r::TriangleMesh object_space(model_volume->mesh());
                object_space.transform(model_volume->get_matrix());
                const indexed_triangle_set &indexed = object_space.its;
                if (indexed.vertices.empty() || indexed.indices.empty())
                    return fail_snapshot(ORCA_STATUS_INVALID_MODEL,
                                         "volume mesh is empty");
                if (indexed.vertices.size() >
                        static_cast<size_t>(std::numeric_limits<int32_t>::max()) ||
                    indexed.indices.size() >
                        static_cast<size_t>(std::numeric_limits<int32_t>::max() / 3))
                    return fail_snapshot(ORCA_STATUS_INTERNAL_INVARIANT,
                                         "volume mesh exceeds ABI count range");
                volume.position_count =
                    static_cast<int32_t>(indexed.vertices.size());
                volume.index_count =
                    static_cast<int32_t>(indexed.indices.size() * 3);
                volume.positions = static_cast<float *>(std::malloc(
                    static_cast<size_t>(volume.position_count) * 3 * sizeof(float)));
                volume.indices = static_cast<uint32_t *>(std::malloc(
                    static_cast<size_t>(volume.index_count) * sizeof(uint32_t)));
                if (!volume.positions || !volume.indices)
                    return fail_snapshot(ORCA_STATUS_OUT_OF_MEMORY,
                                         "could not allocate volume mesh");
                for (int axis = 0; axis < 3; ++axis) {
                    volume.bbox_min[axis] = std::numeric_limits<float>::max();
                    volume.bbox_max[axis] = std::numeric_limits<float>::lowest();
                }
                for (int32_t vertex_index = 0;
                     vertex_index < volume.position_count; ++vertex_index) {
                    const auto &vertex =
                        indexed.vertices[static_cast<size_t>(vertex_index)];
                    for (int axis = 0; axis < 3; ++axis) {
                        const float coordinate = vertex(axis);
                        if (!std::isfinite(coordinate))
                            return fail_snapshot(ORCA_STATUS_INVALID_MODEL,
                                                 "volume mesh contains a non-finite vertex");
                        volume.positions[static_cast<size_t>(vertex_index) * 3 + axis] =
                            coordinate;
                        volume.bbox_min[axis] =
                            std::min(volume.bbox_min[axis], coordinate);
                        volume.bbox_max[axis] =
                            std::max(volume.bbox_max[axis], coordinate);
                    }
                }
                size_t flat_index = 0;
                for (const auto &triangle : indexed.indices)
                    for (int corner = 0; corner < 3; ++corner) {
                        if (triangle(corner) < 0 ||
                            triangle(corner) >= volume.position_count)
                            return fail_snapshot(ORCA_STATUS_INVALID_MODEL,
                                                 "volume mesh index is out of range");
                        volume.indices[flat_index++] =
                            static_cast<uint32_t>(triangle(corner));
                    }
            }
            // The merged mesh contains exactly the part triangles: if the
            // ranges disagree, part picking would silently mis-map — fail
            // the snapshot instead.
            if (merged_triangles !=
                static_cast<uint32_t>(object.index_count / 3))
                return fail_snapshot(ORCA_STATUS_INTERNAL_INVARIANT,
                                     "part triangle ranges do not cover the merged mesh");
        }

        // Per-plate object counts, now that every instance is assigned.
        for (int32_t plate_index = 0; plate_index < snapshot.plate_count;
             ++plate_index)
            snapshot.plates[plate_index].object_count =
                plate_objects[static_cast<size_t>(plate_index)];

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

/// Which moves become segments: extrusions/travels are LINES; engine
/// marker moves (Seam, Retract, Unretract, Tool/Color change, Pause,
/// Custom G-code, Wipe) are exported as POINT segments (start == end) for
/// the desktop visibility options.
static bool orcapad_keep_move(Slic3r::EMoveType type) {
    switch (type) {
    case Slic3r::EMoveType::Extrude:
    case Slic3r::EMoveType::Travel:
    case Slic3r::EMoveType::Seam:
    case Slic3r::EMoveType::Retract:
    case Slic3r::EMoveType::Unretract:
    case Slic3r::EMoveType::Tool_change:
    case Slic3r::EMoveType::Color_change:
    case Slic3r::EMoveType::Pause_Print:
    case Slic3r::EMoveType::Custom_GCode:
    case Slic3r::EMoveType::Wipe:
        return true;
    case Slic3r::EMoveType::Noop:
    case Slic3r::EMoveType::Count:
        return false;
    }
    return false;
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
            if (!orcapad_keep_move(moves[i].type))
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
            if (!orcapad_keep_move(move.type))
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
            segment.actual_feedrate = move.actual_feedrate;
            segment.volumetric_rate = move.volumetric_rate();
            segment.actual_volumetric_rate = move.actual_volumetric_rate();
            segment.pressure_advance = move.pressure_advance;
            segment.acceleration = move.acceleration;
            segment.jerk = move.jerk;
            segment.layer_duration = move.layer_duration;
            segment.time_stealth = move.time[static_cast<size_t>(
                Slic3r::PrintEstimatedStatistics::ETimeMode::Stealth)];
            // marker moves (Seam, Retract, …) are points: start == end
            if (move.type != Slic3r::EMoveType::Extrude &&
                move.type != Slic3r::EMoveType::Travel &&
                move.type != Slic3r::EMoveType::Wipe) {
                segment.start[0] = segment.end[0] = move.position.x();
                segment.start[1] = segment.end[1] = move.position.y();
                segment.start[2] = segment.end[2] = move.position.z();
            }
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
        const float stealth =
            gcode->result.print_statistics
                .modes[static_cast<size_t>(
                    Slic3r::PrintEstimatedStatistics::ETimeMode::
                        Stealth)]
                .time;
        toolpath.estimated_stealth_seconds =
            stealth > 0.0f && std::abs(stealth - toolpath.estimated_time_seconds) > 0.5f
                ? stealth : 0.0f;
        toolpath.printable_height = gcode->result.printable_height;

        const size_t extruders = gcode->result.filaments_count;
        if (extruders == 0 || extruders > ORCA_TP_MAX_EXTRUDERS)
            return [&]() {
                orca_toolpath_dispose(&toolpath);
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "extruder count is outside the ABI range");
            }();
        toolpath.extruder_count = static_cast<uint32_t>(extruders);
        for (size_t e = 0; e < extruders; ++e) {
            toolpath.filament_diameters[e] =
                e < gcode->result.filament_diameters.size()
                    ? gcode->result.filament_diameters[e] : 1.75f;
            toolpath.filament_densities[e] =
                e < gcode->result.filament_densities.size()
                    ? gcode->result.filament_densities[e] : 0.0f;
            toolpath.filament_costs[e] =
                e < gcode->result.filament_costs.size()
                    ? gcode->result.filament_costs[e] : 0.0f;
            const auto found = gcode->result.print_statistics
                .total_volumes_per_extruder.find(e);
            toolpath.total_volumes[e] =
                found != gcode->result.print_statistics.total_volumes_per_extruder.end()
                    ? found->second : 0.0;
        }
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
    uint32_t thumbnail_size = 0;
    std::vector<uint8_t> thumbnail_rgba; // top-down
};

/// Box-filters a square top-down RGBA image into a `width`×`height`
/// ThumbnailData (aspect-fit, transparent letterbox) with BOTTOM-UP rows —
/// the GL convention both upstream encoders flip back
/// (tdefl_write_image_to_png_file_in_memory_ex(..., flip = 1)).
static Slic3r::ThumbnailData orcapad_thumbnail(uint32_t source_size,
                                               const std::vector<uint8_t> &source,
                                               unsigned int width, unsigned int height) {
    Slic3r::ThumbnailData data;
    data.set(width, height);
    std::fill(data.pixels.begin(), data.pixels.end(), 0);
    const unsigned int edge = std::min(width, height);
    const unsigned int off_x = (width - edge) / 2, off_y = (height - edge) / 2;
    const double scale = double(source_size) / double(edge);
    for (unsigned int y = 0; y < edge; ++y) {
        const unsigned int sy0 = unsigned(y * scale);
        const unsigned int sy1 = std::max(sy0 + 1, std::min(source_size, unsigned((y + 1) * scale)));
        for (unsigned int x = 0; x < edge; ++x) {
            const unsigned int sx0 = unsigned(x * scale);
            const unsigned int sx1 = std::max(sx0 + 1, std::min(source_size, unsigned((x + 1) * scale)));
            unsigned int sum[4] = {0, 0, 0, 0}, n = 0;
            for (unsigned int sy = sy0; sy < sy1; ++sy)
                for (unsigned int sx = sx0; sx < sx1; ++sx, ++n)
                    for (int c = 0; c < 4; ++c)
                        sum[c] += source[(size_t(sy) * source_size + sx) * 4 + c];
            // destination row flipped: top-down source → bottom-up data
            const size_t row = size_t(height - 1 - (off_y + y));
            unsigned char *dst = &data.pixels[(row * width + off_x + x) * 4];
            for (int c = 0; c < 4; ++c) dst[c] = (unsigned char)(sum[c] / std::max(n, 1u));
        }
    }
    return data;
}

orca_result orca_slice_job_set_thumbnail(orca_slice_job *job, uint32_t size,
                                         const uint8_t *rgba) {
    constexpr const char *operation = "orca_slice_job_set_thumbnail";
    if (!job)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "slice job is null");
    if (!rgba || size < 16 || size > 2048)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "thumbnail must be 16..2048 px square RGBA");
    try {
        std::lock_guard<std::mutex> lock(job->mutex);
        job->thumbnail_rgba.assign(rgba, rgba + size_t(size) * size * 4);
        job->thumbnail_size = size;
        return orcapad_ok();
    } catch (const std::bad_alloc &) {
        return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation, "allocation failed");
    }
}

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

/// Aggregates a multi-plate slice-all run (desktop slices plate by plate
/// into per-plate files; OrcaPad concatenates with markers).
struct OrcapadSliceAccumulator {
    std::vector<OrcapadWarning> warnings;
    double time_estimate_s = 0.0;
    int64_t gcode_bytes = 0;
};

// --- config finalization (desktop PresetBundle::full_config semantics) -----

/// Per-filament vector options the desktop bundle pads to the filament
/// count (repeat-last-value); matrix-shaped options follow below. Everything
/// the engine indexes by filament count must be structurally valid BEFORE
/// print.apply: ToolOrdering (and friends) copy straight out of these
/// vectors — an empty/short one crashed slicing with a null memmove
/// (TestFlight 0.2.0). Repairs are reported, never silent.
static const char *const orcapad_per_filament_keys[] = {
    "filament_colour", "filament_diameter", "filament_flow_ratio",
    "filament_density", "filament_type", "filament_soluble",
    "filament_cost", "filament_settings_id", "filament_ids",
    "filament_max_volumetric_speed", "filament_minimal_purge_on_wipe_tower",
    "filament_load_time", "filament_unload_time", "filament_toolchange_delay",
    "filament_cooling_moves", "filament_cooling_initial_speed",
    "filament_cooling_final_speed", "filament_ramming_parameters",
    "filament_multitool_ramming", "filament_staging_times",
    "filament_retraction_length", "filament_retraction_speed",
    "filament_deretraction_speed", "filament_retract_restart_extra",
    "filament_retract_before_wipe", "filament_wipe", "filament_retraction_layer_change",
    "filament_travel_lift",
};

/// Applies desktop's normalization to one config: pads per-filament vectors
/// to the filament count (repeat last value, like full_config()), and sizes
/// the flush matrix (filaments^2 per nozzle; upstream default 280/0) and
/// flush vector. Returns one warning per repair.
static std::vector<OrcapadWarning> orcapad_finalize_config(
    Slic3r::DynamicPrintConfig &config) {
    std::vector<OrcapadWarning> repairs;
    auto filament_count = [&]() -> size_t {
        const auto *colours = config.option<Slic3r::ConfigOptionStrings>("filament_colour");
        return colours && !colours->values.empty() ? colours->values.size() : 1;
    };
    const size_t filaments = filament_count();
    for (const char *key : orcapad_per_filament_keys) {
        if (!config.has(key)) continue;
        const Slic3r::ConfigOption *option = config.option(key);
        size_t size = 0;
        if (const auto *strings = dynamic_cast<const Slic3r::ConfigOptionStrings *>(option))
            size = strings->values.size();
        else if (const auto *floats = dynamic_cast<const Slic3r::ConfigOptionFloats *>(option))
            size = floats->values.size();
        else if (const auto *ints = dynamic_cast<const Slic3r::ConfigOptionInts *>(option))
            size = ints->values.size();
        else if (const auto *bools = dynamic_cast<const Slic3r::ConfigOptionBools *>(option))
            size = bools->values.size();
        else continue;
        if (size == 0 || size >= filaments) continue;
        if (auto *strings = dynamic_cast<Slic3r::ConfigOptionStrings *>(config.option(key))) {
            while (strings->values.size() < filaments) strings->values.push_back(strings->values.back());
        } else if (auto *floats = dynamic_cast<Slic3r::ConfigOptionFloats *>(config.option(key))) {
            while (floats->values.size() < filaments) floats->values.push_back(floats->values.back());
        } else if (auto *ints = dynamic_cast<Slic3r::ConfigOptionInts *>(config.option(key))) {
            while (ints->values.size() < filaments) ints->values.push_back(ints->values.back());
        } else if (auto *bools = dynamic_cast<Slic3r::ConfigOptionBools *>(config.option(key))) {
            while (bools->values.size() < filaments) bools->values.push_back(bools->values.back());
        } else {
            continue;
        }
        repairs.push_back({ORCA_SLICE_WARNING_WARNING, ORCA_SLICE_SOURCE_VALIDATE,
                           key, "vector had " + std::to_string(size) +
                               " value(s) for " + std::to_string(filaments) +
                               " filament(s); padded with the last value", ""});
    }
    // flush matrix: filaments^2 per nozzle (280 between different
    // filaments, 0 on the diagonal — upstream PrintConfig defaults)
    if (auto *nozzles = config.option<Slic3r::ConfigOptionFloats>("nozzle_diameter")) {
        const size_t nozzle_count = nozzles->values.empty() ? 1 : nozzles->values.size();
        if (auto *matrix = config.option<Slic3r::ConfigOptionFloats>("flush_volumes_matrix")) {
            const size_t need = filaments * filaments * nozzle_count;
            if (matrix->values.size() < need) {
                std::vector<double> repaired(need, 280.0);
                for (size_t nozzle = 0; nozzle < nozzle_count; ++nozzle)
                    for (size_t row = 0; row < filaments; ++row)
                        repaired[nozzle * filaments * filaments + row * filaments + row] = 0.0;
                matrix->values = std::move(repaired);
                repairs.push_back({ORCA_SLICE_WARNING_WARNING, ORCA_SLICE_SOURCE_VALIDATE,
                                   "flush_volumes_matrix",
                                   "flush matrix had too few values; reset to the "
                                   "default 280 mm\u00b3 purge volumes", ""});
            }
        }
    }
    return repairs;
}

/// Appends finalized-config repairs to an already-filled ABI report.
static void orcapad_report_append_warnings(
    orca_slice_report *report, const std::vector<OrcapadWarning> &warnings) {
    if (!report || warnings.empty()) return;
    orca_slice_warning *grown = static_cast<orca_slice_warning *>(
        std::realloc(report->warnings,
                     (report->warning_count + warnings.size()) * sizeof(orca_slice_warning)));
    if (!grown) return;
    report->warnings = grown;
    for (const OrcapadWarning &warning : warnings) {
        orca_slice_warning &slot = report->warnings[report->warning_count];
        slot.level = warning.level;
        slot.source = warning.source;
        slot.code = orcapad_empty_string();
        slot.message = orcapad_empty_string();
        slot.detail = orcapad_empty_string();
        if (orcapad_copy_string(warning.code.c_str(), &slot.code) &&
            orcapad_copy_string(warning.message.c_str(), &slot.message) &&
            orcapad_copy_string(warning.detail.c_str(), &slot.detail)) {
            ++report->warning_count;
        }
    }
}

static orca_result orcapad_run_print(const char *operation,
                                     Slic3r::Print &print,
                                     const char *gcode_path,
                                     orca_progress_fn progress, void *ctx,
                                     orca_slice_job *job,
                                     orca_slice_report *out_report,
                                     OrcapadSliceAccumulator *accumulate = nullptr);

static orca_result orcapad_run_print(const char *operation,
                                     Slic3r::Print &print,
                                     const char *gcode_path,
                                     orca_progress_fn progress, void *ctx,
                                     orca_slice_job *job,
                                     orca_slice_report *out_report,
                                     OrcapadSliceAccumulator *accumulate) {
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
            Slic3r::ThumbnailsGeneratorCallback thumbnails = nullptr;
            if (job) {
                std::lock_guard<std::mutex> lock(job->mutex);
                if (job->thumbnail_size > 0) {
                    const uint32_t size = job->thumbnail_size;
                    const std::vector<uint8_t> source = job->thumbnail_rgba;
                    thumbnails = [size, source](const Slic3r::ThumbnailsParams &params) {
                        Slic3r::ThumbnailsList list;
                        for (const Slic3r::Vec2d &dim : params.sizes) {
                            const unsigned w = unsigned(dim.x()), h = unsigned(dim.y());
                            if (w == 0 || h == 0) continue;
                            list.push_back(orcapad_thumbnail(size, source, w, h));
                        }
                        return list;
                    };
                }
            }
            const std::string final_path =
                print.export_gcode(gcode_path, &processor_result, thumbnails);
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
                // The engine's G-code warnings use its own severity scale
                // (0 tip, 1 warning, 2 error, 3 blocking-error for Studio,
                // emitted ALONGSIDE a 2); the ABI owns its values, so map:
                // 2 and 3 are CRITICAL here. Desktop never fails a slice on
                // these (it matches them by message).
                const int32_t level = warning.level >= 2
                    ? ORCA_SLICE_WARNING_CRITICAL
                    : (warning.level <= 0 ? ORCA_SLICE_WARNING_TIP
                                          : ORCA_SLICE_WARNING_WARNING);
                warnings.push_back({level, ORCA_SLICE_SOURCE_GCODE,
                                    warning.msg, warning.error_code, detail});
            }
            if (const auto conflict = print.get_conflict_result()) {
                warnings.push_back({ORCA_SLICE_WARNING_CRITICAL, ORCA_SLICE_SOURCE_CONFLICT,
                                    "gcode_path_conflict", "",
                                    conflict->_objName1 + "\n" + conflict->_objName2 + "\n" +
                                        std::to_string(conflict->_height) + "\n" +
                                        std::to_string(conflict->layer)});
            }

            if (accumulate) {
                // slice-all: fold this plate into the aggregate; the final
                // report is built once, after every plate ran.
                accumulate->warnings.insert(
                    accumulate->warnings.end(),
                    std::make_move_iterator(warnings.begin()),
                    std::make_move_iterator(warnings.end()));
                accumulate->time_estimate_s +=
                    processor_result.print_statistics.modes.front().time;
                accumulate->gcode_bytes += static_cast<int64_t>(file_status.st_size);
            } else if (!orcapad_fill_report(
                    warnings, processor_result.print_statistics.modes.front().time,
                    static_cast<int64_t>(file_status.st_size), out_report)) {
                return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                    "could not allocate slice report");
            }
            if (progress && !accumulate) progress(100, "done", ctx);
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
        const std::vector<OrcapadWarning> repairs = orcapad_finalize_config(config);

        if (progress) progress(2, "applying config", ctx);
        Slic3r::Print print;
        print.apply(model, std::move(config));
        print.is_BBL_printer() = false;
        const orca_result sliced = orcapad_run_print(operation, print, gcode_path, progress, ctx,
                                                     job, out_report);
        if (sliced.code == ORCA_STATUS_OK)
            orcapad_report_append_warnings(out_report, repairs);
        return sliced;
    });
}

/// Slicing sees only ONE plate (desktop per-plate slicing): this builds a
/// filtered model copy keeping exactly that plate's instances (meshes are
/// shared; ids are preserved). Typed INVALID_MODEL when the plate is empty.
static orca_result orcapad_build_plate_model(orca_plater &plater,
                                             const char *operation,
                                             int32_t plate_index,
                                             Slic3r::Model &out) {
    if (plater.plates.empty())
        return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                            "document has no plates");
    if (plate_index < 0 ||
        plate_index >= static_cast<int32_t>(plater.plates.size()))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "plate index is out of range");
    out = plater.model;
    std::vector<Slic3r::ObjectID> empty;
    size_t kept_instances = 0;
    for (Slic3r::ModelObject *object : out.objects) {
        const orca_object_id object_id =
            static_cast<orca_object_id>(object->id().id);
        for (size_t index = object->instances.size(); index-- > 0;) {
            Slic3r::ModelInstance *instance = object->instances[index];
            const int plate = orcapad_instance_plate(
                plater, object_id,
                static_cast<orca_instance_id>(instance->id().id),
                orcapad_instance_box(*instance));
            if (plate != plate_index)
                object->delete_instance(index);
            else
                ++kept_instances;
        }
        if (object->instances.empty()) empty.push_back(object->id());
    }
    for (const Slic3r::ObjectID id : empty) out.delete_object(id);
    if (kept_instances == 0)
        return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                            "the selected plate is empty");
    return orcapad_ok();
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
        const std::vector<OrcapadWarning> repairs = orcapad_finalize_config(config);
        if (progress) progress(1, "applying plater", ctx);
        Slic3r::Model plate_model;
        const orca_result filtered =
            orcapad_build_plate_model(*plater, operation, plater->current_plate, plate_model);
        if (filtered.code != ORCA_STATUS_OK) return filtered;
        Slic3r::Print print;
        print.apply(plate_model, std::move(config));
        print.is_BBL_printer() = false;
        // Desktop PartPlate::set_print parity: plate origin + index.
        print.set_plate_origin(
            orcapad_plate_origin(*plater, plater->current_plate));
        print.set_plate_index(plater->current_plate);
        const orca_result sliced = orcapad_run_print(operation, print, gcode_path, progress, ctx,
                                                     job, out_report);
        if (sliced.code == ORCA_STATUS_OK)
            orcapad_report_append_warnings(out_report, repairs);
        return sliced;
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
        const std::vector<OrcapadWarning> repairs = orcapad_finalize_config(config);
        if (progress) progress(1, "applying presets", ctx);
        Slic3r::Model plate_model;
        const orca_result filtered =
            orcapad_build_plate_model(*plater, operation, plater->current_plate, plate_model);
        if (filtered.code != ORCA_STATUS_OK) return filtered;
        Slic3r::Print print;
        print.apply(plate_model, std::move(config));
        print.is_BBL_printer() = presets->bundle->is_bbl_vendor();
        // Desktop PartPlate::set_print parity: plate origin + index.
        print.set_plate_origin(
            orcapad_plate_origin(*plater, plater->current_plate));
        print.set_plate_index(plater->current_plate);
        const orca_result sliced = orcapad_run_print(operation, print, gcode_path, progress, ctx,
                                                     job, out_report);
        if (sliced.code == ORCA_STATUS_OK)
            orcapad_report_append_warnings(out_report, repairs);
        return sliced;
    });
}

// --- slice all plates (ABI v27) ---------------------------------------------

/// Scales one plate's 0..100 progress into the slice-all range.
struct OrcapadPlateProgressState {
    orca_progress_fn progress;
    void *ctx;
    int32_t plate_position;
    int32_t plate_count;
};

static void orcapad_plate_progress_trampoline(int32_t percent, const char *message,
                                               void *context) {
    auto *state = static_cast<OrcapadPlateProgressState *>(context);
    if (!state || !state->progress) return;
    const double span = 100.0 / static_cast<double>(state->plate_count);
    const double local = percent < 0 ? 0.0 : static_cast<double>(percent);
    const int32_t global = static_cast<int32_t>(
        std::lround(state->plate_position * span + local * span / 100.0));
    state->progress(std::clamp(global, 0, 99), message, state->ctx);
}

/// Shared slice-all core: presets null = the preset-free overlay config.
static orca_result orcapad_slice_all(orca_plater *plater,
                                     orca_presets *presets,
                                     const char *gcode_path,
                                     orca_progress_fn progress, void *ctx,
                                     orca_slice_job *job,
                                     orca_slice_report *out_report) {
    constexpr const char *operation = "orca_plater_slice_all_to_gcode";
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
        // 1) the plates that carry objects, in order
        std::vector<int32_t> targets;
        for (int32_t plate_index = 0;
             plate_index < static_cast<int32_t>(plater->plates.size());
             ++plate_index) {
            bool any = false;
            for (const Slic3r::ModelObject *object : plater->model.objects)
                for (const Slic3r::ModelInstance *instance : object->instances)
                    if (orcapad_instance_plate(
                            *plater,
                            static_cast<orca_object_id>(object->id().id),
                            static_cast<orca_instance_id>(instance->id().id),
                            orcapad_instance_box(*instance)) == plate_index)
                        any = true;
            if (any) targets.push_back(plate_index);
        }
        if (targets.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "every plate is empty");

        // 2) truncate the destination once; plates append in order
        FILE *output = fopen(gcode_path, "wb");
        if (!output)
            return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                                "could not create the output G-code");
        fclose(output);

        OrcapadSliceAccumulator aggregate;
        const std::string base(gcode_path);
        for (size_t position = 0; position < targets.size(); ++position) {
            const int32_t plate_index = targets[position];
            const OrcapadPlate &plate =
                plater->plates[static_cast<size_t>(plate_index)];
            if (progress) {
                char label[128];
                std::snprintf(label, sizeof label, "slicing plate %d/%d: %s",
                              static_cast<int>(position + 1),
                              static_cast<int>(targets.size()), plate.name.c_str());
                progress(static_cast<int32_t>(position * 100 / targets.size()),
                         label, ctx);
            }

            Slic3r::Model plate_model;
            const orca_result filtered = orcapad_build_plate_model(
                *plater, operation, plate_index, plate_model);
            if (filtered.code != ORCA_STATUS_OK) return filtered;

            Slic3r::DynamicPrintConfig config = presets
                ? presets->bundle->full_config()
                : Slic3r::DynamicPrintConfig::full_print_config();
            if (!presets) orcapad_config_overlays(config);
            const std::vector<OrcapadWarning> repairs =
                orcapad_finalize_config(config);
            if (!repairs.empty())
                aggregate.warnings.insert(
                    aggregate.warnings.end(), repairs.begin(), repairs.end());

            Slic3r::Print print;
            print.apply(plate_model, std::move(config));
            print.is_BBL_printer() = presets ? presets->bundle->is_bbl_vendor() : false;
            // Desktop PartPlate::set_print: every plate's Print carries the
            // plate's world origin (its m_origin is UNINITIALIZED otherwise)
            // and index; the G-code comes out plate-relative.
            print.set_plate_origin(orcapad_plate_origin(*plater, plate_index));
            print.set_plate_index(plate_index);
            // Desktop "Name of the plate sliced" (PrintBase::m_plate_name —
            // it flows into the {plate_name} G-code placeholder).
            print.set_plate_name(plate.name);

            const std::string temp =
                base + ".plate" + std::to_string(plate_index) + ".tmp";
            OrcapadPlateProgressState state{
                progress, ctx,
                static_cast<int32_t>(position),
                static_cast<int32_t>(targets.size())};
            const orca_result sliced = orcapad_run_print(
                operation, print, temp.c_str(),
                progress ? orcapad_plate_progress_trampoline : nullptr,
                progress ? &state : nullptr, job, out_report, &aggregate);
            if (sliced.code != ORCA_STATUS_OK) {
                std::remove(temp.c_str());
                return sliced;
            }

            // marker + plate G-code + marker
            std::string error;
            [&] {
                FILE *out = fopen(gcode_path, "ab");
                if (!out) {
                    error = "could not reopen the output G-code";
                    return;
                }
                fprintf(out, "; ORCA_PLATE index=%d total=%d name=\"%s\" begin\n",
                        plate_index + 1, static_cast<int>(targets.size()),
                        plate.name.c_str());
                FILE *in = fopen(temp.c_str(), "rb");
                if (!in) {
                    fclose(out);
                    error = "a plate's temporary G-code disappeared";
                    return;
                }
                std::vector<char> buffer(1 << 16);
                size_t read = 0;
                while ((read = fread(buffer.data(), 1, buffer.size(), in)) > 0)
                    if (fwrite(buffer.data(), 1, read, out) != read) {
                        error = "could not append a plate's G-code";
                        break;
                    }
                const bool read_failed = ferror(in) != 0;
                fclose(in);
                fprintf(out, "; ORCA_PLATE index=%d end\n", plate_index + 1);
                if (fclose(out) != 0 && error.empty())
                    error = "could not finalize the output G-code";
                if (error.empty() && read_failed)
                    error = "could not read a plate's temporary G-code";
            }();
            std::remove(temp.c_str());
            if (!error.empty())
                return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                                    error.c_str());
        }

        struct stat status;
        if (stat(gcode_path, &status) != 0)
            return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                                "combined G-code could not be inspected");
        if (!orcapad_fill_report(aggregate.warnings, aggregate.time_estimate_s,
                                 static_cast<int64_t>(status.st_size), out_report))
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate slice report");
        if (progress) progress(100, "done", ctx);
        return orcapad_ok();
    });
}

orca_result orca_plater_slice_all_to_gcode(orca_plater *plater,
                                           const char *gcode_path,
                                           orca_progress_fn progress, void *ctx,
                                           orca_slice_job *job,
                                           orca_slice_report *out_report) {
    if (out_report) *out_report = orca_slice_report{};
    return orcapad_slice_all(plater, nullptr, gcode_path, progress, ctx, job,
                             out_report);
}

orca_result orca_plater_slice_all_to_gcode_with_presets(
    orca_plater *plater, orca_presets *presets, const char *gcode_path,
    orca_progress_fn progress, void *ctx, orca_slice_job *job,
    orca_slice_report *out_report) {
    if (out_report) *out_report = orca_slice_report{};
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE,
                            "orca_plater_slice_all_to_gcode",
                            "presets handle is null");
    return orcapad_slice_all(plater, presets, gcode_path, progress, ctx, job,
                             out_report);
}

// --- physical printers -----------------------------------------------------

static bool orcapad_valid_host_type(const std::string &host_type) {
    const Slic3r::ConfigOptionDef *def =
        Slic3r::print_config_def.get("host_type");
    return def && std::find(def->enum_values.begin(), def->enum_values.end(),
                            host_type) != def->enum_values.end();
}

void orca_physical_printer_dispose(orca_physical_printer *printer) {
    if (!printer) return;
    orca_owned_string_dispose(&printer->name);
    orca_owned_string_dispose(&printer->host_type);
    orca_owned_string_dispose(&printer->url);
    orca_owned_string_dispose(&printer->webui);
    orca_owned_string_dispose(&printer->api_key);
    orca_owned_string_dispose(&printer->preset_names);
    *printer = orca_physical_printer{};
}

orca_result orca_physical_printer_count(orca_presets *presets, int32_t *out_count) {
    constexpr const char *operation = "orca_physical_printer_count";
    if (out_count) *out_count = 0;
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "presets handle is null");
    if (!out_count)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        const size_t count = presets->bundle->physical_printers().size();
        if (count > static_cast<size_t>(std::numeric_limits<int32_t>::max()))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "physical printer count exceeds ABI range");
        *out_count = static_cast<int32_t>(count);
        return orcapad_ok();
    });
}

orca_result orca_physical_printer_list(orca_presets *presets, int32_t index,
                                       orca_physical_printer *out_printer) {
    constexpr const char *operation = "orca_physical_printer_list";
    if (out_printer) *out_printer = orca_physical_printer{};
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "presets handle is null");
    if (!out_printer)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        const auto &printers = presets->bundle->physical_printers();
        if (index < 0 || static_cast<size_t>(index) >= printers.size())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "physical printer index was not found");
        const Slic3r::PhysicalPrinter &printer =
            printers[static_cast<size_t>(index)];
        // const opt_string() dereferences a missing option: check first so a
        // malformed persisted printer is a typed failure, not a crash.
        for (const char *key : {"host_type", "print_host", "print_host_webui", "printhost_apikey"})
            if (!printer.config.has(key))
                return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                    (std::string("physical printer lacks option ") + key).c_str());
        orca_physical_printer entry;
        std::string presets_list;
        for (const std::string &preset : printer.get_preset_names())
            presets_list += (presets_list.empty() ? "" : "\n") + preset;
        if (!orcapad_copy_string(printer.name.c_str(), &entry.name) ||
            !orcapad_copy_string(
                printer.config.opt_serialize("host_type").c_str(),
                &entry.host_type) ||
            !orcapad_copy_string(printer.config.opt_string("print_host").c_str(), &entry.url) ||
            !orcapad_copy_string(printer.config.opt_string("print_host_webui").c_str(), &entry.webui) ||
            !orcapad_copy_string(printer.config.opt_string("printhost_apikey").c_str(), &entry.api_key) ||
            !orcapad_copy_string(presets_list.c_str(), &entry.preset_names)) {
            orca_physical_printer_dispose(&entry);
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate physical printer entry");
        }
        *out_printer = entry;
        return orcapad_ok();
    });
}

orca_result orca_physical_printer_upsert(orca_presets *presets, const char *name,
                                         const char *host_type, const char *url,
                                         const char *webui_url,
                                         const char *api_key,
                                         const char *preset_name) {
    constexpr const char *operation = "orca_physical_printer_upsert";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "presets handle is null");
    if (!name || !name[0] || !host_type || !host_type[0] || !url || !url[0] ||
        !webui_url || !api_key || !preset_name || !preset_name[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "name, host type, url, web UI, api key or preset name is missing");
    const auto is_http = [](const std::string &value) {
        return value.rfind("http://", 0) == 0 || value.rfind("https://", 0) == 0;
    };
    if (!is_http(url))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "print host URL must start with http:// or https://");
    if (webui_url[0] && !is_http(webui_url))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "device UI URL must be empty or start with http:// or https://");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_valid_host_type(host_type))
            return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                                "unknown print host type");
        auto &collection = presets->bundle->physical_printers;
        const std::string preset(preset_name);
        if (!presets->bundle->printers.find_preset(preset, false, true))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "printer preset was not found");
        Slic3r::PhysicalPrinter *existing = collection.find_printer(name, true);
        Slic3r::PhysicalPrinter printer =
            existing ? *existing
                     : Slic3r::PhysicalPrinter(name, collection.default_config(),
                                               presets->bundle->printers.get_edited_preset());
        printer.name = name;
        if (auto *host = printer.config.option<Slic3r::ConfigOptionEnum<Slic3r::PrintHostType>>(
                "host_type", true)) {
            // map the enum string through the pinned def's keys_map
            const auto *def = Slic3r::print_config_def.get("host_type");
            const int value = def && def->enum_keys_map
                ? def->enum_keys_map->at(host_type) : 0;
            host->value = static_cast<Slic3r::PrintHostType>(value);
        } else {
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "host type option is missing from the printer config");
        }
        printer.config.opt_string("print_host") = url;
        printer.config.opt_string("print_host_webui") = webui_url;
        printer.config.opt_string("printhost_apikey") = api_key;
        printer.add_preset(preset);
        printer.update_preset_names_in_config();
        // ConfigBase::save_to_json does NOT create the parent directory and
        // fails silently when it is missing (desktop's GUI creates it first).
        boost::filesystem::create_directories(
            boost::filesystem::path(Slic3r::data_dir()) /
            "user/default/physical_machine");
        collection.save_printer(printer);
        return orcapad_ok();
    });
}

orca_result orca_physical_printer_delete(orca_presets *presets, const char *name) {
    constexpr const char *operation = "orca_physical_printer_delete";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "presets handle is null");
    if (!name || !name[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "name is empty");
    return orcapad_guard(operation, [&]() -> orca_result {
        if (!presets->bundle->physical_printers.find_printer(name, true))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "physical printer was not found");
        if (!presets->bundle->physical_printers.delete_printer(name))
            return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                                "engine refused to delete the physical printer");
        return orcapad_ok();
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
        if (scratch.plates.size() > static_cast<size_t>(ORCA_PLATE_MAX_COUNT))
            return orcapad_fail(ORCA_STATUS_UNSUPPORTED_CAPABILITY, operation,
                                "project has more plates than the ABI limit (36)");

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
        uint64_t next_mesh_revision = plater->next_mesh_revision;
        for (const Slic3r::ModelObject *object : loaded.objects) {
            const orca_object_id id = static_cast<orca_object_id>(object->id().id);
            if (id == 0 || !revisions.emplace(id, next_mesh_revision++).second)
                return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                    "project object has an invalid or duplicate ID");
        }
        const uint32_t object_count = static_cast<uint32_t>(loaded.objects.size());

        // 4) commit: new document + session swap atomically. A new
        //    document starts a new history (desktop clears its undo stack).
        //    Plates come from the project metadata: names + locks are read
        //    verbatim; membership of LOCKED plates is pinned from the file
        //    (unlocked membership derives from the absolute positions).
        plater->model = std::move(loaded);
        plater->mesh_revisions.swap(revisions);
        plater->next_mesh_revision = next_mesh_revision;
        plater->undo.clear();
        plater->redo.clear();
        ++plater->revision;
        presets->bundle.swap(candidate);
        {
            std::vector<OrcapadPlate> adopted;
            const size_t plate_count =
                std::max<size_t>(scratch.plates.size(), 1);
            for (size_t plate_index = 0; plate_index < plate_count; ++plate_index) {
                OrcapadPlate plate;
                plate.id = plater->next_plate_id++;
                plate.name = "Plate " + std::to_string(plate_index + 1);
                const Slic3r::PlateData *data =
                    plate_index < scratch.plates.size()
                        ? scratch.plates[plate_index] : nullptr;
                if (data) {
                    if (!data->plate_name.empty()) plate.name = data->plate_name;
                    plate.locked = data->locked;
                }
                adopted.push_back(std::move(plate));
            }
            // Pin locked-plate members (document-order indices from the file).
            for (size_t plate_index = 0; plate_index < scratch.plates.size();
                 ++plate_index) {
                const Slic3r::PlateData *data = scratch.plates[plate_index];
                if (!data || !data->locked) continue;
                OrcapadPlate &plate = adopted[plate_index];
                for (const auto &entry : data->objects_and_instances) {
                    if (entry.first < 0 ||
                        entry.first >= static_cast<int>(plater->model.objects.size()))
                        continue;
                    Slic3r::ModelObject *object =
                        plater->model.objects[static_cast<size_t>(entry.first)];
                    if (entry.second < 0 ||
                        entry.second >= static_cast<int>(object->instances.size()))
                        continue;
                    plate.pinned.emplace_back(
                        static_cast<orca_object_id>(object->id().id),
                        static_cast<orca_instance_id>(
                            object->instances[static_cast<size_t>(entry.second)]->id().id));
                }
            }
            plater->plates = std::move(adopted);
            plater->current_plate = 0;
        }

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
                              const char *path, uint32_t thumbnail_size,
                              const uint8_t *thumbnail_rgba) {
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
    if (thumbnail_rgba && (thumbnail_size < 16 || thumbnail_size > 2048))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "thumbnail must be 16..2048 px square RGBA");

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
        // One PlateData per document plate (names, locks, membership by
        // derived assignment) so desktop OrcaSlicer reads the same plates.
        for (size_t plate_index = 0; plate_index < plater->plates.size();
             ++plate_index) {
            const OrcapadPlate &source = plater->plates[plate_index];
            auto *data = new Slic3r::PlateData();
            plates.push_back(data);
            data->plate_index = static_cast<int>(plate_index);
            data->locked = source.locked;
            data->plate_name = source.name;
            for (size_t object = 0; object < plater->model.objects.size(); ++object) {
                const Slic3r::ModelObject *model_object =
                    plater->model.objects[object];
                const orca_object_id object_id =
                    static_cast<orca_object_id>(model_object->id().id);
                for (size_t instance = 0; instance < model_object->instances.size();
                     ++instance) {
                    const int plate = orcapad_instance_plate(
                        *plater, object_id,
                        static_cast<orca_instance_id>(
                            model_object->instances[instance]->id().id),
                        orcapad_instance_box(*model_object->instances[instance]));
                    if (plate == static_cast<int>(plate_index))
                        data->objects_and_instances.emplace_back(
                            int(object), int(instance));
                }
            }
            data->printer_model_id =
                bundle.printers.get_edited_preset().get_printer_type(&bundle);
            if (const auto *nozzles =
                    config.option<Slic3r::ConfigOptionFloats>("nozzle_diameter"))
                data->nozzle_diameters = nozzles->serialize();
        }
        Slic3r::PlateData *const plate = plates.front();

        Slic3r::StoreParams params;
        params.path = target.c_str();
        params.model = &plater->model;
        params.plate_data_list = plates;
        params.project_presets = embedded.list;
        params.config = &config;
        // desktop plate thumbnail (PartPlate::thumbnail_data, 512²)
        Slic3r::ThumbnailData plate_thumbnail;
        if (thumbnail_rgba) {
            const std::vector<uint8_t> source(
                thumbnail_rgba, thumbnail_rgba + size_t(thumbnail_size) * thumbnail_size * 4);
            plate_thumbnail = orcapad_thumbnail(thumbnail_size, source, 512, 512);
            params.thumbnail_data.push_back(&plate_thumbnail);
        }
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
    // preset-free fallback: raw defaults. (No overlay —
    // those fix slice/gcode interop, which orient/arrange never touch.)
    return Slic3r::DynamicPrintConfig::full_print_config();
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

        OrcapadMutation mutation(*plater, "Orient");
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

        *out_revision = mutation.commit();
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
        OrcapadMutation mutation(*plater, "Lay flat");
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

        *out_revision = mutation.commit();
        return orcapad_ok();
    });
}

// --- flatten planes (desktop GLGizmoFlatten::update_planes, ABI v29) ------

void orca_flatten_planes_dispose(orca_flatten_planes *planes) {
    if (!planes) return;
    for (uint32_t i = 0; i < planes->plane_count && planes->planes; ++i)
        std::free(planes->planes[i].vertices);
    std::free(planes->planes);
    *planes = orca_flatten_planes{};
}

orca_result orca_plater_flatten_planes(orca_plater *plater,
                                       orca_object_id object_id,
                                       orca_instance_id instance_id,
                                       orca_flatten_planes *out) {
    constexpr const char *operation = "orca_plater_flatten_planes";
    if (out) *out = orca_flatten_planes{};
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation, "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        Slic3r::ModelInstance *instance = plater_instance(object, instance_id);
        if (!instance)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "instance was not found");

        // 1) merged convex hull of the parts (desktop update_planes)
        Slic3r::TriangleMesh ch;
        for (const Slic3r::ModelVolume *volume : object->volumes) {
            if (volume->type() != Slic3r::ModelVolumeType::MODEL_PART) continue;
            Slic3r::TriangleMesh volume_hull = volume->get_convex_hull();
            volume_hull.transform(volume->get_matrix());
            ch.merge(volume_hull);
        }
        ch = ch.convex_hull_3d();

        // 2) BFS over hull facets, grouping by normal (desktop epsilons).
        const float minimal_area = 5.0f;    // mm^2
        const float minimal_side = 1.0f;    // mm
        const float minimal_angle = 1.0f;   // degrees
        const int facet_count = ch.facets_count();
        if (facet_count == 0)
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "object has no hull facets");
        const std::vector<Slic3r::Vec3f> face_normals = Slic3r::its_face_normals(ch.its);
        const std::vector<Slic3r::Vec3i32> face_neighbors = Slic3r::its_face_neighbors(ch.its);
        std::vector<int> facet_queue(facet_count, 0);
        std::vector<bool> facet_visited(facet_count, false);
        int queue_count = 0;
        int facet_index = 0;
        struct Plane {
            Slic3r::Vec3d normal;
            Slic3r::Pointf3s vertices;
        };
        std::vector<Plane> planes;
        while (true) {
            for (; facet_index < facet_count; ++facet_index)
                if (!facet_visited[facet_index]) {
                    facet_queue[queue_count++] = facet_index;
                    facet_visited[facet_index] = true;
                    planes.emplace_back();
                    break;
                }
            if (facet_index == facet_count) break;
            const Slic3r::Vec3f &seed_normal = face_normals[facet_index];
            while (queue_count > 0) {
                const int current = facet_queue[--queue_count];
                const Slic3r::Vec3f &this_normal = face_normals[current];
                if (std::abs(this_normal.x() - seed_normal.x()) < 0.001f &&
                    std::abs(this_normal.y() - seed_normal.y()) < 0.001f &&
                    std::abs(this_normal.z() - seed_normal.z()) < 0.001f) {
                    const Slic3r::Vec3i32 face = ch.its.indices[current];
                    for (int j = 0; j < 3; ++j)
                        planes.back().vertices.emplace_back(
                            ch.its.vertices[face[j]].cast<double>());
                    facet_visited[current] = true;
                    for (int j = 0; j < 3; ++j)
                        if (const int neighbor = face_neighbors[current][j];
                            neighbor >= 0 && !facet_visited[neighbor])
                            facet_queue[queue_count++] = neighbor;
                }
            }
            planes.back().normal = seed_normal.cast<double>();
            // whole-group vertices — drop tiny three-vertex slivers early
            if (planes.back().vertices.size() == 3) {
                const auto &v = planes.back().vertices;
                if ((v[0] - v[1]).norm() < minimal_side ||
                    (v[0] - v[2]).norm() < minimal_side ||
                    (v[1] - v[2]).norm() < minimal_side)
                    planes.pop_back();
            }
        }

        // 3) world transform, per-plane 2D hull + filters (desktop order).
        const Slic3r::Transform3d world = instance->get_matrix();
        const Slic3r::Matrix3d world_linear = world.matrix().block(0, 0, 3, 3);
        struct OutPlane {
            Slic3r::Pointf3s vertices;
            Slic3r::Vec3d normal;
            float area;
        };
        std::vector<OutPlane> kept;
        for (Plane &plane : planes) {
            Slic3r::Pointf3s polygon;
            polygon.reserve(plane.vertices.size());
            for (const Slic3r::Vec3d &vertex : plane.vertices)
                polygon.push_back(world * vertex);
            const Slic3r::Vec3d normal_world = (world_linear * plane.normal).normalized();

            // rotate the plane flat (normal → +Z) so the 2D hull applies
            Slic3r::Matrix3d flatten = Slic3r::Matrix3d::Identity();
            {
                Slic3r::Vec3d axis;
                double angle = 0.0;
                Slic3r::Geometry::rotation_from_two_vectors(
                    normal_world, Slic3r::Vec3d::UnitZ(), axis, angle, &flatten);
            }
            auto transform_polygon = [&](const Slic3r::Matrix3d &matrix) {
                for (Slic3r::Vec3d &vertex : polygon) vertex = matrix * vertex;
            };
            transform_polygon(flatten);

            // rescale to avoid fixed-point overflow, hull, rescale back
            Slic3r::Vec3d bb_size = Slic3r::BoundingBoxf3(polygon).size();
            const double scale_x = bb_size.x() > 0 ? 1.0 / bb_size.x() : 1.0;
            const double scale_y = bb_size.y() > 0 ? 1.0 / bb_size.y() : 1.0;
            const float sf = std::min(float(scale_x), float(scale_y));
            const Slic3r::Matrix3d shrink = Slic3r::Matrix3d::Identity() * sf;
            const Slic3r::Matrix3d grow = Slic3r::Matrix3d::Identity() / sf;
            transform_polygon(shrink);
            polygon = Slic3r::Geometry::convex_hull(polygon);
            transform_polygon(grow);

            // shoelace area
            float area = 0.0f;
            for (size_t i = 0; i < polygon.size(); ++i) {
                const Slic3r::Vec3d &a = polygon[i];
                const Slic3r::Vec3d &b = polygon[(i + 1 < polygon.size()) ? i + 1 : 0];
                area += float(a.x() * b.y() - b.x() * a.y());
            }
            area = 0.5f * std::abs(area);
            if (area < minimal_area) continue;

            // discard slivers: edges nearly collinear (>179 degrees)
            const double angle_threshold = std::cos(minimal_angle * M_PI / 180.0);
            bool discard = false;
            for (size_t i = 0; i < polygon.size() && !discard; ++i) {
                const Slic3r::Vec3d &prec = polygon[(i == 0) ? polygon.size() - 1 : i - 1];
                const Slic3r::Vec3d &curr = polygon[i];
                const Slic3r::Vec3d &next = polygon[(i == polygon.size() - 1) ? 0 : i + 1];
                if ((prec - curr).normalized().dot((next - curr).normalized()) > angle_threshold)
                    discard = true;
            }
            if (discard) continue;

            // back to world orientation, then shrink 10% toward the centroid
            // (desktop margin so the highlight does not touch the edges)
            transform_polygon(flatten.transpose());
            Slic3r::Vec3d centroid = Slic3r::Vec3d::Zero();
            for (const Slic3r::Vec3d &vertex : polygon) centroid += vertex;
            centroid /= double(polygon.size());
            for (Slic3r::Vec3d &vertex : polygon)
                vertex = 0.9 * vertex + 0.1 * centroid;
            kept.push_back(OutPlane{polygon, normal_world, area});
        }
        if (kept.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "no resting plane passed the filters");

        // 4) ABI copy
        orca_flatten_planes result{};
        result.plane_count = static_cast<uint32_t>(kept.size());
        result.planes = static_cast<orca_flatten_plane *>(
            std::calloc(kept.size(), sizeof(orca_flatten_plane)));
        if (!result.planes)
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate flatten planes");
        for (size_t i = 0; i < kept.size(); ++i) {
            orca_flatten_plane &slot = result.planes[i];
            slot.vertex_count = static_cast<int32_t>(kept[i].vertices.size());
            slot.vertices = static_cast<float(*)[3]>(
                std::calloc(kept[i].vertices.size(), sizeof(float[3])));
            if (!slot.vertices) {
                orca_flatten_planes_dispose(&result);
                return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                    "could not allocate a flatten polygon");
            }
            for (size_t v = 0; v < kept[i].vertices.size(); ++v) {
                slot.vertices[v][0] = static_cast<float>(kept[i].vertices[v].x());
                slot.vertices[v][1] = static_cast<float>(kept[i].vertices[v].y());
                slot.vertices[v][2] = static_cast<float>(kept[i].vertices[v].z());
            }
            slot.normal[0] = kept[i].normal.x();
            slot.normal[1] = kept[i].normal.y();
            slot.normal[2] = kept[i].normal.z();
            slot.area = kept[i].area;
        }
        *out = result;
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

        OrcapadMutation mutation(*plater, "Arrange");
        const Slic3r::DynamicPrintConfig config = orcapad_arrange_config(presets);
        // desktop ArrangeJob::prepare: every printable instance is selected
        Slic3r::ModelInstancePtrs instances;
        Slic3r::arrangement::ArrangePolygons input =
            Slic3r::get_arrange_polys(plater->model, instances);
        if (input.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "no arrangeable instance");

        // Locked plates pin their content (desktop preprocess_arrange_polygon):
        // pinned instances never move and act as fixed obstacles.
        Slic3r::arrangement::ArrangePolygons excluded;
        Slic3r::ModelInstancePtrs arrangeable;
        {
            Slic3r::arrangement::ArrangePolygons movable;
            Slic3r::ModelInstancePtrs movable_instances;
            for (size_t i = 0; i < input.size(); ++i) {
                const bool pinned = [&] {
                    const Slic3r::ModelInstance *instance = instances[i];
                    const orca_object_id object_id =
                        static_cast<orca_object_id>(instance->get_object()->id().id);
                    const orca_instance_id instance_id =
                        static_cast<orca_instance_id>(instance->id().id);
                    for (const OrcapadPlate &plate : plater->plates) {
                        if (!plate.locked) continue;
                        for (const auto &pin : plate.pinned)
                            if (pin.first == object_id && pin.second == instance_id)
                                return true;
                    }
                    return false;
                }();
                if (pinned) {
                    excluded.push_back(input[i]);
                } else {
                    movable.push_back(input[i]);
                    movable_instances.push_back(instances[i]);
                }
            }
            input = std::move(movable);
            instances = std::move(movable_instances);
        }
        if (input.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "every instance is on a locked plate");

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

        Slic3r::arrangement::arrange(input, excluded, bed, params);

        // Overflow becomes PLATES (desktop virtual beds): the engine's
        // bed_idx maps to our plate grid; missing plates are created up to
        // the cap, and anything beyond it keeps the legacy parking strip.
        int32_t max_bed = 0;
        for (const auto &polygon : input)
            if (polygon.bed_idx > max_bed) max_bed = polygon.bed_idx;
        const int32_t capped =
            orcapad_ensure_plates(*plater, std::min(max_bed, ORCA_PLATE_MAX_COUNT - 1));
        (void)capped; // inputs beyond the created plates keep the parking strip
        const Slic3r::Vec3d base_origin = orcapad_plate_origin(*plater, 0);
        uint32_t unprintable = 0;
        for (size_t i = 0; i < input.size(); ++i) {
            if (input[i].bed_idx < 0) continue; // not placed at all
            if (input[i].bed_idx < static_cast<int>(plater->plates.size())) {
                const Slic3r::Vec3d origin =
                    orcapad_plate_origin(*plater, input[i].bed_idx);
                input[i].translation.x() +=
                    Slic3r::scaled(origin.x() - base_origin.x());
                input[i].translation.y() +=
                    Slic3r::scaled(origin.y() - base_origin.y());
            } else {
                // beyond ORCA_PLATE_MAX_COUNT: park beside the plates
                ++unprintable;
                const double shift = plater->bed_width * 1.25 * input[i].bed_idx;
                input[i].translation.x() += Slic3r::scaled(shift);
            }
            instances[i]->apply_arrange_result(
                input[i].translation.cast<double>(), input[i].rotation);
        }
        for (Slic3r::ModelObject *object : plater->model.objects) {
            object->invalidate_bounding_box();
            object->ensure_on_bed();
        }

        *out_revision = mutation.commit();
        *out_unprintable = unprintable;
        return orcapad_ok();
    });
}

// --- fill bed (desktop FillBedJob, ABI v30) ---------------------------------

orca_result orca_plater_fill_bed(orca_plater *plater, orca_presets *presets,
                                 orca_object_id object_id,
                                 uint8_t allow_rotations,
                                 uint32_t *out_added,
                                 orca_revision *out_revision) {
    constexpr const char *operation = "orca_plater_fill_bed";
    if (out_added) *out_added = 0;
    if (out_revision) *out_revision = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation, "plater handle is null");
    if (!out_added || !out_revision)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelObject *object = plater_obj(plater, object_id);
        if (!object)
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation, "object was not found");
        if (object->instances.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "object has no instance");
        if (!orcapad_revision_available(*plater))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "document revision is exhausted");

        OrcapadMutation mutation(*plater, "Fill bed");
        const Slic3r::DynamicPrintConfig config = orcapad_arrange_config(presets);

        // Split the printable instances: the template object's instances on
        // the current plate arrange; other objects there are fixed obstacles
        // (desktop FillBedJob::prepare); everything else stays untouched.
        Slic3r::ModelInstancePtrs instances;
        Slic3r::arrangement::ArrangePolygons input =
            Slic3r::get_arrange_polys(plater->model, instances);
        Slic3r::arrangement::ArrangePolygons selected, fixed;
        Slic3r::ModelInstancePtrs selected_instances;
        for (size_t i = 0; i < input.size(); ++i) {
            const Slic3r::ModelInstance *instance = instances[i];
            const orca_object_id owner =
                static_cast<orca_object_id>(instance->get_object()->id().id);
            const int plate = orcapad_instance_plate(
                *plater, owner,
                static_cast<orca_instance_id>(instance->id().id),
                orcapad_instance_box(*instance));
            if (plate != plater->current_plate) continue;
            if (owner == object_id && instance->printable) {
                selected.push_back(input[i]);
                selected_instances.push_back(instances[i]);
            } else {
                fixed.push_back(input[i]);
            }
        }
        if (selected.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "the object has no printable instance on the selected plate");

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
        Slic3r::arrangement::update_arrange_params(params, &config, selected);
        Slic3r::arrangement::update_selected_items_inflation(selected, &config, params);
        Slic3r::arrangement::update_selected_items_axis_align(selected, &config, params);

        // The bed is the CURRENT PLATE box in scaled world coordinates
        // (desktop FillBedJob uses plate->get_bounding_box_crd()).
        const Slic3r::BoundingBoxf3 plate_box =
            orcapad_plate_box(*plater, plater->current_plate);
        const Slic3r::Points bed = {
            Slic3r::Point(Slic3r::scaled(plate_box.min.x()), Slic3r::scaled(plate_box.min.y())),
            Slic3r::Point(Slic3r::scaled(plate_box.max.x()), Slic3r::scaled(plate_box.min.y())),
            Slic3r::Point(Slic3r::scaled(plate_box.max.x()), Slic3r::scaled(plate_box.max.y())),
            Slic3r::Point(Slic3r::scaled(plate_box.min.x()), Slic3r::scaled(plate_box.max.y())),
        };

        // Desktop count: (bed_area - fixed_area - selected_count*template_area)
        // / template_area — the maximum, the real number is close but less.
        const double sc = Slic3r::scaled<double>(1.) * Slic3r::scaled(1.);
        auto template_polys = Slic3r::offset_ex(selected.front().poly, params.min_obj_distance / 2);
        const Slic3r::ExPolygon template_poly =
            template_polys.empty() ? selected.front().poly : template_polys.front();
        const double template_area = template_poly.area() / sc;
        if (template_area <= 0.0)
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "template instance has no footprint");
        double fixed_area = 0.0;
        for (const auto &polygon : fixed) fixed_area += polygon.poly.area() / sc;
        const double bed_area = Slic3r::Polygon(bed).area() / sc;
        const size_t existing_count = selected.size();
        const int needed_items = std::max(
            0, static_cast<int>((bed_area - fixed_area - double(existing_count) * template_area)
                                    / template_area));

        // Clones are arrange-only polygons (no instance yet); bed boxes map
        // to the single current plate, so overflow (bed_idx != 0) is dropped.
        const Slic3r::arrangement::ArrangePolygon template_ap = selected.front();
        for (int i = 0; i < needed_items; ++i) {
            Slic3r::arrangement::ArrangePolygon clone = template_ap;
            // desktop setter marker: MAX_PLATES_COUNT (a far-away bed) means
            // "unplaced, arrange me into bed 0" — UNARRANGED would skip it.
            clone.bed_idx = 256;
            clone.itemid = -1;
            selected.push_back(clone);
        }

        Slic3r::arrangement::arrange(selected, fixed, bed, params);

        uint32_t added = 0;
        for (size_t i = 0; i < selected.size(); ++i) {
            if (selected[i].bed_idx < 0) continue; // not placed at all
            if (i < existing_count) {
                selected_instances[i]->apply_arrange_result(
                    selected[i].translation.cast<double>(), selected[i].rotation);
            } else if (selected[i].bed_idx == 0) {
                // desktop setter: add_instance with the template transform,
                // then the arranged placement (fill_bed_with_instances)
                const Slic3r::ModelInstance *template_instance = selected_instances.front();
                Slic3r::ModelInstance *clone = object->add_instance(
                    template_instance->get_offset(),
                    template_instance->get_scaling_factor(),
                    template_instance->get_rotation(),
                    template_instance->get_mirror());
                if (!clone)
                    return orcapad_fail(ORCA_STATUS_ENGINE_FAILURE, operation,
                                        "engine refused to add an instance");
                clone->apply_arrange_result(
                    selected[i].translation.cast<double>(), selected[i].rotation);
                ++added;
            }
        }
        object->invalidate_bounding_box();
        object->ensure_on_bed();

        *out_revision = mutation.commit();
        *out_added = added;
        return orcapad_ok();
    });
}
