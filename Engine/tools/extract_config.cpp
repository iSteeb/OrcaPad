// OrcaPad config-schema extractor (HOST tool, x86 Linux).
// Dumps Slic3r::print_config_def (all ConfigOptionDefs) to JSON so the iOS
// settings UI can be GENERATED from the defs — never hand-written.
//
// Build (host): see Engine/tools/build-extract-config.sh
// Output: JSON array — one object per option:
//   { key, type (int, Slic3r::ConfigOptionType), nullable, label, full_label,
//     category, tooltip, gui_flags, default (serialized), min?, max?,
//     enum_values[], enum_labels[] }

#include "libslic3r/Config.hpp"
#include "libslic3r/I18N.hpp"
#include "libslic3r/PrintConfig.hpp"

#include "nlohmann/json.hpp"

#include <iostream>
#include <string>

// Upstream defines this in utils.cpp (needs macOS libproc.h). Host tool uses
// the same identity adapter as orca_core.cpp.
namespace Slic3r { namespace I18N {
static std::string identity_translate(const char *s) { return s; }
translate_fn_type translate_fn = &identity_translate;
}}

int main() {
    nlohmann::json out = nlohmann::json::array();
    for (const auto &kvp : Slic3r::print_config_def.options) {
        const Slic3r::ConfigOptionDef &def = kvp.second;
        nlohmann::json j;
        j["key"]         = def.opt_key;
        j["type"]        = int(def.type);
        j["nullable"]    = def.nullable;
        j["label"]       = def.label;
        j["full_label"]  = def.full_label;
        j["category"]    = def.category;
        j["tooltip"]     = def.tooltip;
        j["gui_flags"]   = def.gui_flags;
        j["default"]     = def.default_value ? def.default_value->serialize() : nullptr;
        j["min"]         = def.min;
        j["max"]         = def.max;
        j["enum_values"] = def.enum_values;
        j["enum_labels"] = def.enum_labels;
        out.push_back(std::move(j));
    }
    std::cout << out.dump() << std::endl;
    std::cerr << "extracted " << out.size() << " options" << std::endl;
    return 0;
}
