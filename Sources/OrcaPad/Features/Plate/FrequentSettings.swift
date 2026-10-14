// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge

/// Desktop SettingsFactory::OBJECT_CATEGORY_SETTINGS / PART_CATEGORY_SETTINGS
/// (GUI_Factories.cpp): the "frequent settings" quick menu of the object
/// list. Keys are verbatim from the pinned upstream v2.4.2 tables; keys the
/// schema does not know (or the engine's overridable-keys list rejects) are
/// filtered out at presentation time by the caller's validation path.
enum FrequentSettings {
    struct Category {
        let name: String
        let keys: [String]
    }

    static let objectCategories: [Category] = [
        Category(name: "Quality", keys: [
            "layer_height", "seam_position", "slice_closing_radius", "resolution",
            "xy_hole_compensation", "xy_contour_compensation", "elefant_foot_compensation",
            "make_overhang_printable_angle", "make_overhang_printable_hole_size",
            "wall_sequence", "precise_z_height",
        ]),
        Category(name: "Support", keys: [
            "brim_type", "brim_width", "brim_object_gap", "brim_flow_ratio",
            "enable_support", "support_type", "support_threshold_angle",
            "support_threshold_overlap", "support_on_build_plate_only",
            "support_filament", "support_interface_filament", "support_expansion",
            "support_style", "tree_support_brim_width", "tree_support_branch_angle",
            "tree_support_branch_angle_organic", "tree_support_wall_count",
            "support_bottom_z_distance", "support_top_z_distance",
            "support_base_pattern", "support_base_pattern_spacing",
            "support_interface_top_layers", "support_interface_bottom_layers",
            "support_interface_spacing", "support_object_xy_distance",
            "bridge_no_support", "max_bridge_length",
        ]),
        Category(name: "Speed", keys: [
            "support_speed", "support_interface_speed",
        ]),
    ]

    static let partCategories: [Category] = [
        Category(name: "Quality", keys: [
            "ironing_type", "ironing_flow", "ironing_spacing", "ironing_inset",
            "bridge_flow", "make_overhang_printable", "ironing_expansion",
        ]),
        Category(name: "Strength", keys: [
            "wall_loops", "top_shell_layers", "top_shell_thickness",
            "bottom_shell_layers", "bottom_shell_thickness",
            "sparse_infill_density", "sparse_infill_pattern",
            "top_surface_pattern", "bottom_surface_pattern",
            "infill_combination", "infill_direction",
        ]),
    ]

    static func categories(forVolume: Bool) -> [Category] {
        forVolume ? partCategories : objectCategories
    }

    /// Schema label when available, key otherwise.
    static func label(for key: String) -> String {
        if case .success(let index) = ConfigSchema.index,
           let schema = index[key],
           let label = schema.label, !label.isEmpty {
            return label
        }
        return key
    }
}
