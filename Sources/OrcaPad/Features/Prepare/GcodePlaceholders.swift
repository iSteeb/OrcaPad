// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation

/// Curated G-code placeholder catalog (board cycle-0.15): the tokens
/// desktop machine/process custom G-code most commonly uses, grouped for
/// the multiline editor's placeholder browser. Any engine setting key is
/// also a valid placeholder (e.g. {travel_speed}) — the browser only
/// lists the frequent ones.
enum GcodePlaceholders {
    struct Item: Identifiable, Sendable {
        /// The token as it appears in G-code, braces included.
        let token: String
        let summary: String
        var id: String { token }
    }

    struct Group: Identifiable, Sendable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Time & job", items: [
            Item(token: "{print_time}", summary: "total estimated print time"),
            Item(token: "{total_toolchanges}", summary: "tool changes in the file"),
            Item(token: "{curr_bed_type}", summary: "selected plate type"),
            Item(token: "{printable_height}", summary: "height of the print (mm)"),
        ]),
        Group(title: "Layers", items: [
            Item(token: "{layer_num}", summary: "current layer number (1-based)"),
            Item(token: "{layer_z}", summary: "current layer Z (mm)"),
            Item(token: "{total_layer_count}", summary: "total layer count"),
            Item(token: "{object_layer_num}", summary: "layer number within the object"),
            Item(token: "{object_layer_z}", summary: "Z within the object (mm)"),
        ]),
        Group(title: "Temperatures", items: [
            Item(token: "{temperature}", summary: "active nozzle temperature"),
            Item(token: "{nozzle_temperature}", summary: "nozzle temperature"),
            Item(token: "{nozzle_temperature_initial_layer}", summary: "first-layer nozzle temp"),
            Item(token: "{nozzle_temperature_range_low}", summary: "minimum nozzle temp"),
            Item(token: "{nozzle_temperature_range_high}", summary: "maximum nozzle temp"),
            Item(token: "{bed_temperature}", summary: "bed temperature"),
            Item(token: "{bed_temperature_initial_layer}", summary: "first-layer bed temp"),
            Item(token: "{chamber_temperature}", summary: "chamber temperature"),
        ]),
        Group(title: "Filament", items: [
            Item(token: "{filament_type}", summary: "filament type (e.g. PLA)"),
            Item(token: "{filament_diameter}", summary: "filament diameter (mm)"),
            Item(token: "{filament_flow_ratio}", summary: "flow ratio"),
            Item(token: "{filament_colour}", summary: "filament colour"),
            Item(token: "{filament_ids}", summary: "filament slot IDs"),
            Item(token: "{filament_wipe_volume}", summary: "tool-change wipe volume (mm³)"),
        ]),
        Group(title: "Machine", items: [
            Item(token: "{nozzle_diameter}", summary: "nozzle diameter (mm)"),
            Item(token: "{extruder}", summary: "active extruder number"),
            Item(token: "{max_print_height}", summary: "max print height (mm)"),
        ]),
    ]
}
