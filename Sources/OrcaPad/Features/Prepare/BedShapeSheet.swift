// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import SwiftUI
import UniformTypeIdentifiers

/// Desktop BedShapeDialog subset (prepare bed-shape): edit the machine's
/// `printable_area` (Rectangular / Elliptical + size + origin — desktop's
/// most-used path) and pick custom bed texture / model files. Values are
/// written through the same per-key edited-preset commit path as the
/// settings pages (`PresetStore.setValue`, kind .machine).
///
/// Serialization is the engine's `ConfigOptionPoints` format: comma-
/// separated "XxY" points ("0x0,200x0,200x200,0x200"); the ellipse is a
/// 32-point polygon (desktop uses a many-point circular polygon).
struct BedShapeSheet: View {
    let presets: PresetStore

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    enum ShapeKind: String, CaseIterable, Identifiable {
        case rectangular = "Rectangular"
        case elliptical = "Elliptical"

        var id: String { rawValue }
    }

    @State private var shape: ShapeKind = .rectangular
    @State private var sizeX: Double = 200
    @State private var sizeY: Double = 200
    @State private var originX: Double = 0
    @State private var originY: Double = 0
    /// The current value is a polygon that is neither rect nor ellipse
    /// (desktop's "Custom" path — v1 replaces it when a shape is applied).
    @State private var isCustomShape = false
    @State private var texturePath: String = ""
    @State private var modelPath: String = ""
    @State private var texturePresented = false
    @State private var modelPresented = false
    @State private var failureText: String?

    private static let ellipsePoints = 32

    private static let textureTypes: [UTType] = [.image]
    /// Desktop bed custom model: an STL placed on the bed view.
    private static let modelTypes: [UTType] =
        [UTType(filenameExtension: "stl", conformingTo: .data) ?? .data]

    var body: some View {
        NavigationStack {
            Form {
                if let failureText {
                    Section {
                        Label(failureText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Picker("Shape", selection: $shape) {
                        ForEach(ShapeKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    if isCustomShape {
                        Text("The current shape is a custom polygon. Applying Rectangular or Elliptical replaces it.")
                    }
                }
                Section("Size") {
                    numericRow("Size X", value: $sizeX, range: 50...2000)
                    numericRow("Size Y", value: $sizeY, range: 50...2000)
                }
                Section {
                    numericRow("Origin X", value: $originX, range: -500...500, step: 5)
                    numericRow("Origin Y", value: $originY, range: -500...500, step: 5)
                } header: {
                    Text("Origin")
                } footer: {
                    Text("Bed corner in machine coordinates (printers whose origin is not at the bed corner).")
                }
                Section {
                    artRow(
                        title: "Custom texture",
                        path: texturePath,
                        onPick: { texturePresented = true },
                        onRemove: { texturePath = "" }
                    )
                    artRow(
                        title: "Custom model",
                        path: modelPath,
                        onPick: { modelPresented = true },
                        onRemove: { modelPath = "" }
                    )
                } header: {
                    Text("Custom bed art")
                } footer: {
                    Text("Optional bed image / STL shown by the engine's bed rendering. Picked files are copied into Application Support/BedArt.")
                }
                Section {
                    LabeledContent("printable_area") {
                        Text(serializedShape)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                } footer: {
                    Text("Slicing uses the new area immediately. The plate grid follows the selected printer preset — save the printer preset (Preset \u{25b8} Save as preset\u{2026}) to apply the new bed to the plate.")
                }
            }
            .navigationTitle("Bed Shape")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .disabled(!(sizeX > 0) || !(sizeY > 0))
                }
            }
            .fileImporter(
                isPresented: $texturePresented,
                allowedContentTypes: Self.textureTypes,
                onCompletion: { pickTexture($0) }
            )
            .fileImporter(
                isPresented: $modelPresented,
                allowedContentTypes: Self.modelTypes,
                onCompletion: { pickModel($0) }
            )
            .onAppear { load() }
        }
        .presentationDetents([.large])
    }

    // MARK: rows

    /// Numeric entry: an exact text field plus a coarse stepper.
    private func numericRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 10
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(
                "mm",
                value: value,
                format: .number
            )
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .font(.callout.monospaced())
            .frame(width: 110)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    private func artRow(
        title: String,
        path: String,
        onPick: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack {
            LabeledContent(title) {
                Text(path.isEmpty
                     ? "None"
                     : URL(fileURLWithPath: path).lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Choose\u{2026}", action: onPick)
                .buttonStyle(.borderless)
            if !path.isEmpty {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(title)")
            }
        }
    }

    // MARK: value plumbing

    /// Loads the current edited machine values: printable area → shape /
    /// size / origin (bounding box), custom art paths.
    private func load() {
        let machine = presets.editedConfigs[.machine] ?? [:]
        if let points = Self.parsePoints(machine["printable_area"]), !points.isEmpty {
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            originX = xs.min() ?? 0
            originY = ys.min() ?? 0
            sizeX = (xs.max() ?? 200) - originX
            sizeY = (ys.max() ?? 200) - originY
            if points.count == 4, Self.isAxisAlignedRectangle(points) {
                shape = .rectangular
                isCustomShape = false
            } else if points.count > 4 {
                shape = .elliptical
                isCustomShape = false
            } else {
                shape = .rectangular
                isCustomShape = true
            }
        }
        texturePath = machine["bed_custom_texture"] ?? ""
        modelPath = machine["bed_custom_model"] ?? ""
    }

    private var serializedShape: String {
        switch shape {
        case .rectangular:
            let farX = originX + sizeX
            let farY = originY + sizeY
            return [
                Self.point(originX, originY),
                Self.point(farX, originY),
                Self.point(farX, farY),
                Self.point(originX, farY),
            ].joined(separator: ",")
        case .elliptical:
            let centerX = originX + sizeX / 2
            let centerY = originY + sizeY / 2
            let radiusX = sizeX / 2
            let radiusY = sizeY / 2
            return (0..<Self.ellipsePoints).map { index in
                let angle = Double(index) / Double(Self.ellipsePoints) * 2 * .pi
                return Self.point(
                    centerX + radiusX * cos(angle),
                    centerY + radiusY * sin(angle)
                )
            }.joined(separator: ",")
        }
    }

    private static func point(_ x: Double, _ y: Double) -> String {
        String(format: "%gx%g", x, y)
    }

    /// Parses "XxY,XxY,…" (`ConfigOptionPoints::serialize`); nil when
    /// malformed.
    private static func parsePoints(_ serialized: String?) -> [(x: Double, y: Double)]? {
        guard let serialized, !serialized.isEmpty else { return nil }
        var points: [(x: Double, y: Double)] = []
        for pair in serialized.split(separator: ",") {
            let parts = pair.split(separator: "x", maxSplits: 1)
            guard parts.count == 2,
                  let x = Double(parts[0]),
                  let y = Double(parts[1])
            else { return nil }
            points.append((x, y))
        }
        return points
    }

    private static func isAxisAlignedRectangle(
        _ points: [(x: Double, y: Double)]
    ) -> Bool {
        guard points.count == 4 else { return false }
        let xs = Set(points.map { String(format: "%g", $0.x) })
        let ys = Set(points.map { String(format: "%g", $0.y) })
        return xs.count == 2 && ys.count == 2
    }

    // MARK: actions

    private func pickTexture(_ result: Result<URL, any Error>) {
        pickBedArt(result) { texturePath = $0 }
    }

    private func pickModel(_ result: Result<URL, any Error>) {
        pickBedArt(result) { modelPath = $0 }
    }

    /// Copies the picked file and hands the container path to `assign`
    /// (@State assignment through the closure — the state storage is
    /// shared across struct copies in SwiftUI).
    private func pickBedArt(
        _ result: Result<URL, any Error>,
        assign: (String) -> Void
    ) {
        switch result {
        case .success(let url):
            do {
                assign(try Self.copyBedArt(url).path)
            } catch {
                reportBedArtFailure(error, operation: "copy bed art")
            }
        case .failure(let error):
            reportBedArtFailure(error, operation: "pick bed art")
        }
    }

    private func reportBedArtFailure(_ error: any Error, operation: String) {
        let failure = AppFailure.wrap(error, operation: operation)
        failureText = failure.localizedDescription
        environment.status.report(.presets, failure: failure)
    }

    /// Copies a picked bed-art file into `Application Support/BedArt/` and
    /// returns its path (desktop semantics: the option stores the file
    /// path; OrcaPad stores container paths). A same-named file is replaced
    /// — the option holds exactly one active file per kind.
    private static func copyBedArt(_ source: URL) throws -> URL {
        let secured = source.startAccessingSecurityScopedResource()
        defer {
            if secured { source.stopAccessingSecurityScopedResource() }
        }
        let manager = FileManager.default
        let directory = manager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("BedArt", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
        return destination
    }

    private func apply() {
        failureText = nil
        guard sizeX > 0, sizeY > 0 else {
            failureText = "Bed size must be positive."
            return
        }
        let shapeValue = serializedShape
        let textureValue = texturePath
        let modelValue = modelPath
        Task {
            let before = presets.editedConfigs[.machine] ?? [:]
            if before["printable_area"] != shapeValue {
                await presets.setValue(
                    kind: .machine, key: "printable_area", serializedValue: shapeValue)
            }
            if before["bed_custom_texture"] != textureValue {
                await presets.setValue(
                    kind: .machine, key: "bed_custom_texture", serializedValue: textureValue)
            }
            if before["bed_custom_model"] != modelValue {
                await presets.setValue(
                    kind: .machine, key: "bed_custom_model", serializedValue: modelValue)
            }
            // Postcondition: every requested write landed in the edited
            // dump (setValue reports its own failures — this catches them
            // instead of dismissing over a silently failed apply).
            let after = presets.editedConfigs[.machine] ?? [:]
            if after["printable_area"] != shapeValue ||
                after["bed_custom_texture"] != textureValue ||
                after["bed_custom_model"] != modelValue {
                failureText = "The engine rejected one or more bed values — see the status banner."
                return
            }
            await presets.refreshMachineGeometry()
            environment.status.update(.presets, "presets: bed shape modified")
            dismiss()
        }
    }
}
