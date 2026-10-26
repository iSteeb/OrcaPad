// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation

/// Read-only value lookup for one preset kind: the engine's EDITED config
/// dump (authoritative — slices consume `full_config()` of edited presets)
/// with the selected system preset's dump as the fallback. Serialized
/// values only; parsing handles percent suffixes and single-element
/// vectors exactly like the desktop `ConfigOptionPercent`/`opt_int` reads
/// the rules below mirror.
struct SettingsValueLookup: Sendable {
    let edited: [String: String]
    let system: [String: String]

    func raw(_ key: String) -> String? {
        edited[key] ?? system[key]
    }

    /// First element of a (possibly vector) serialization, percent suffix
    /// stripped, quoted strings unquoted.
    func number(_ key: String) -> Double? {
        guard var token = raw(key) else { return nil }
        token = token.trimmingCharacters(in: .whitespaces)
        if token.hasPrefix("\"") && token.hasSuffix("\"") && token.count >= 2 {
            token = String(token.dropFirst().dropLast())
        }
        var element = token.split(separator: ",").first.map(String.init) ?? token
        if element.hasSuffix("%") { element = String(element.dropLast()) }
        return Double(element)
    }

    func int(_ key: String) -> Int? {
        number(key).map(Int.init)
    }

    /// Engine bool serialization ("1"/"0"; accept "true"/"false" too).
    func bool(_ key: String) -> Bool? {
        guard let value = raw(key)?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        return value == "1" || value.lowercased() == "true"
    }

    func string(_ key: String) -> String? {
        guard var token = raw(key) else { return nil }
        token = token.trimmingCharacters(in: .whitespaces)
        if token.hasPrefix("\"") && token.hasSuffix("\"") && token.count >= 2 {
            token = String(token.dropFirst().dropLast())
        }
        return token
    }
}

/// Hand-written option-dependency grey-outs for the Prepare settings pages
/// (board §wave-b/2).
///
/// Upstream has NO machine-readable dependency data — `ConfigOptionDef`
/// (src/libslic3r/Config.hpp) carries no enabled-expression; desktop
/// enforces dependencies in hardcoded C++ (`ConfigManipulation::`
/// `toggle_field`/`toggle_line` in src/slic3r/GUI/ConfigManipulation.cpp,
/// which hides or disables fields from raw boolean expressions over the
/// live config). This table ports the high-value subset of those exact
/// expressions; every rule cites its upstream line(s). Desktop HIDES
/// (`toggle_line`) or disables (`toggle_field`); OrcaPad always keeps the
/// row visible but greyed with the reason — better discoverability on a
/// touch screen, same semantics.
///
/// Desktop additionally AUTO-MUTATES some values when a dependency breaks
/// ("fix settings?" flows); that is out of scope here — grey + reason only.
enum SettingsRowGreyouts {
    /// The reason a row is disabled (what to change to enable it), or nil
    /// when the option is freely editable.
    static func reason(key: String, lookup: SettingsValueLookup) -> String? {
        rules.first { $0.keys.contains(key) }?.evaluate(lookup)
    }

    private struct Rule {
        let keys: Set<String>
        /// nil reason = enabled. @Sendable so the static table below is a
        /// concurrency-safe constant (Swift 6 strict concurrency).
        let evaluate: @Sendable (_ value: SettingsValueLookup) -> String?
    }

    // MARK: Desktop-parity rules (ConfigManipulation.cpp, pinned v2.4.2)

    private static let rules: [Rule] = [
        // Walls: have_perimeters = wall_loops > 0 gates the wall options
        // (ConfigManipulation.cpp:616-618).
        Rule(
            keys: [
                "extra_perimeters_on_overhangs", "ensure_vertical_shell_thickness",
                "detect_thin_wall", "detect_overhang_wall", "seam_position",
                "staggered_inner_seams", "wall_sequence", "outer_wall_line_width",
                "inner_wall_speed", "outer_wall_speed", "small_perimeter_speed",
                "small_perimeter_threshold",
            ],
            evaluate: { value in
                guard (value.int("wall_loops") ?? 0) > 0 else {
                    return "Only used with walls — Wall loops is 0"
                }
                // detect_thin_wall additionally requires the classic wall
                // generator (ConfigManipulation.cpp:949 arachne disables it).
                return nil
            }
        ),
        // Infill: have_infill = sparse_infill_density > 0 (percent-aware)
        // gates the sparse-infill options (ConfigManipulation.cpp:622-625).
        Rule(
            keys: [
                "sparse_infill_pattern", "infill_combination", "fill_multiline",
                "infill_direction", "minimum_sparse_infill_area",
                "sparse_infill_filament_id",
            ],
            evaluate: { value in
                guard (value.number("sparse_infill_density") ?? 0) > 0 else {
                    return "Only used with infill — Sparse density is 0%"
                }
                return nil
            }
        ),
        // infill_combination_max_layer_height needs infill AND the
        // combination toggle (ConfigManipulation.cpp:629).
        Rule(
            keys: ["infill_combination_max_layer_height"],
            evaluate: { value in
                guard (value.number("sparse_infill_density") ?? 0) > 0,
                    value.bool("infill_combination") == true
                else {
                    return "Only used when Infill combination is on with infill"
                }
                return nil
            }
        ),
        // Spiral vase options (ConfigManipulation.cpp:672-676).
        Rule(
            keys: ["spiral_mode_smooth", "spiral_starting_flow_ratio",
                   "spiral_finishing_flow_ratio"],
            evaluate: { value in
                guard value.bool("spiral_mode") == true else {
                    return "Only used in Spiral vase mode"
                }
                return nil
            }
        ),
        Rule(
            keys: ["spiral_mode_max_xy_smoothing"],
            evaluate: { value in
                guard value.bool("spiral_mode") == true,
                    value.bool("spiral_mode_smooth") == true
                else {
                    return "Only used when Smooth Spiral vase is on"
                }
                return nil
            }
        ),
        // Top surface: has_top_shell = top_shell_layers > 0 || (spiral &&
        // bottom_shell_layers > 1) (ConfigManipulation.cpp:677-682, 698).
        Rule(
            keys: ["top_surface_pattern", "top_surface_density",
                   "top_surface_line_width", "top_surface_speed"],
            evaluate: { value in
                let hasTopShell = (value.int("top_shell_layers") ?? 0) > 0
                    || (value.bool("spiral_mode") == true
                        && (value.int("bottom_shell_layers") ?? 0) > 1)
                guard hasTopShell else {
                    return "Only used with top surfaces — Top shell layers is 0"
                }
                return nil
            }
        ),
        // Skirt: have_skirt = skirt_loops > 0; skirt_height also requires
        // the draft shield to be off (ConfigManipulation.cpp:733-738).
        Rule(
            keys: ["skirt_height"],
            evaluate: { value in
                guard (value.int("skirt_loops") ?? 0) > 0 else {
                    return "Only used with a skirt — Skirt loops is 0"
                }
                guard value.string("draft_shield") != "enabled" else {
                    return "Unused while the draft shield is enabled"
                }
                return nil
            }
        ),
        Rule(
            keys: ["skirt_type", "min_skirt_length", "skirt_distance",
                   "skirt_start_angle", "skirt_speed", "draft_shield",
                   "single_loop_draft_shield"],
            evaluate: { value in
                guard (value.int("skirt_loops") ?? 0) > 0 else {
                    return "Only used with a skirt — Skirt loops is 0"
                }
                return nil
            }
        ),
        // Brim: have_brim = brim_type != no_brim; brim_width additionally
        // excludes auto/painted brims; ear options need brim_width > 0
        // (ConfigManipulation.cpp:739-755).
        Rule(
            keys: ["brim_object_gap", "brim_use_efc_outline",
                   "combine_brims", "brim_flow_ratio"],
            evaluate: { value in
                guard value.string("brim_type") != "no_brim" else {
                    return "Only used with a brim — Brim type is No brim"
                }
                return nil
            }
        ),
        Rule(
            keys: ["brim_width"],
            evaluate: { value in
                let brimType = value.string("brim_type")
                guard brimType != "no_brim", brimType != "auto_brim",
                    brimType != "painted"
                else {
                    return "Only used with a manual brim — Brim type is " +
                        "no/auto/painted brim"
                }
                return nil
            }
        ),
        Rule(
            keys: ["brim_ears_max_angle", "brim_ears_detection_length"],
            evaluate: { value in
                guard (value.number("brim_width") ?? 0) > 0 else {
                    return "Only used with brim ears — Brim width is 0"
                }
                return nil
            }
        ),
        // Supports: have_support_material = enable_support || raft_layers
        // > 0 gates the support block (ConfigManipulation.cpp:763-786).
        Rule(
            keys: [
                "support_style", "support_base_pattern",
                "support_base_pattern_spacing", "support_expansion",
                "support_angle", "support_interface_pattern",
                "support_interface_top_layers", "support_interface_bottom_layers",
                "bridge_no_support", "max_bridge_length", "support_top_z_distance",
                "support_bottom_z_distance", "support_type",
                "support_on_build_plate_only", "support_object_xy_distance",
                "support_object_first_layer_gap", "independent_support_layer_height",
            ],
            evaluate: { value in
                guard value.bool("enable_support") == true
                    || (value.int("raft_layers") ?? 0) > 0
                else {
                    return "Only used with supports — Enable support is off " +
                        "and Raft layers is 0"
                }
                return nil
            }
        ),
        // Ironing: has_ironing = ironing_type != "no ironing"; ironing_speed
        // also stays alive for support ironing (raft or supports with a
        // top interface) (ConfigManipulation.cpp:836-843).
        Rule(
            keys: ["ironing_pattern", "ironing_flow", "ironing_spacing",
                   "ironing_angle", "ironing_angle_fixed"],
            evaluate: { value in
                guard value.string("ironing_type") != "no ironing" else {
                    return "Only used with ironing — Ironing type is No ironing"
                }
                return nil
            }
        ),
        Rule(
            keys: ["ironing_speed"],
            evaluate: { value in
                let hasIroning = value.string("ironing_type") != "no ironing"
                let hasSupportIroning = (value.int("raft_layers") ?? 0) > 0
                    || (value.bool("enable_support") == true
                        && (value.int("support_interface_top_layers") ?? 0) > 0)
                guard hasIroning || hasSupportIroning else {
                    return "Only used with (support) ironing — Ironing type is " +
                        "No ironing and no support interface is ironed"
                }
                return nil
            }
        ),
        // Prime tower options (ConfigManipulation.cpp:866-868).
        Rule(
            keys: ["prime_tower_width", "prime_tower_brim_width",
                   "prime_tower_skip_points", "wipe_tower_wall_type",
                   "prime_tower_infill_gap"],
            evaluate: { value in
                guard value.bool("enable_prime_tower") == true else {
                    return "Only used with a prime tower — Prime tower is off"
                }
                return nil
            }
        ),
        // Overhang speed ladder (ConfigManipulation.cpp:903-905).
        Rule(
            keys: ["overhang_1_4_speed", "overhang_2_4_speed",
                   "overhang_3_4_speed", "overhang_4_4_speed"],
            evaluate: { value in
                guard value.bool("enable_overhang_speed") == true else {
                    return "Only used when Overhang speed is enabled"
                }
                return nil
            }
        ),
        // Fuzzy skin options: fuzzy_skin != disabled_fuzzy
        // (ConfigManipulation.cpp:913-918; "none" is a fuzzy variant
        // upstream — only "disabled_fuzzy" turns fuzzy off).
        Rule(
            keys: ["fuzzy_skin_mode", "fuzzy_skin_noise_type",
                   "fuzzy_skin_point_distance", "fuzzy_skin_thickness",
                   "fuzzy_skin_first_layer"],
            evaluate: { value in
                guard value.string("fuzzy_skin") != "disabled_fuzzy" else {
                    return "Only used with fuzzy skin — Fuzzy skin is Disabled"
                }
                return nil
            }
        ),
        // Travel detour (ConfigManipulation.cpp:896-897).
        Rule(
            keys: ["max_travel_detour_distance"],
            evaluate: { value in
                guard value.bool("reduce_crossing_wall") == true else {
                    return "Only used when Reduce crossing walls is on"
                }
                return nil
            }
        ),
        // min_width_top_surface (ConfigManipulation.cpp:949).
        Rule(
            keys: ["min_width_top_surface"],
            evaluate: { value in
                let arachne = value.string("wall_generator") == "arachne"
                guard value.bool("only_one_wall_top") == true
                    || (arachne && (value.number("min_length_factor") ?? 0.5) > 0.5)
                else {
                    return "Only used when Only one wall on top surfaces is on, " +
                        "or Arachne runs with Min length factor > 0.5"
                }
                return nil
            }
        ),
    ]
}
