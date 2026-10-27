// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import OrcaBridge
import os
import SwiftUI

/// Byte-offset index of a G-code file's `;LAYER_CHANGE` markers (desktop
/// "Show G-code Window" backing data). Built ONCE by streaming the file
/// with FileHandle in bounded chunks — slice outputs can exceed 50 MB, so
/// the text is never held in memory; only marker offsets survive:
///
/// ```text
/// ;LAYER_CHANGE      <- marker line (byte offset + line number kept)
/// ;Z:0.32            <- the layer's print z (BBL: "; Z_HEIGHT: 0.32")
/// ;HEIGHT:0.2
/// ```
///
/// Slice-all results additionally carry `; ORCA_PLATE index=… begin/end`
/// sections; a marker belongs to the section it appears in.
struct GcodeLineIndex: Sendable, Equatable {
    struct Marker: Sendable, Equatable {
        /// 0-based line number of the `;LAYER_CHANGE` line.
        let line: Int
        /// Byte offset of that line's start.
        let offset: UInt64
        /// Print z from the following `;Z:` comment (nil when absent).
        var z: Double?
    }

    /// One `; ORCA_PLATE` section: the (0-based) plate index and the
    /// markers that fall inside it.
    struct Section: Sendable, Equatable {
        let plateIndex: Int
        let markerRange: Range<Int>
    }

    let markers: [Marker]
    let sections: [Section]
    let lineCount: Int
    let byteSize: UInt64

    /// Byte window of one layer's lines (marker line through the next
    /// marker or EOF).
    struct Window: Sendable, Equatable {
        let firstLine: Int
        let start: UInt64
        let end: UInt64
    }

    /// Locates the file lines of the preview layer `layerIndex` (print z
    /// `z`, from the engine's own layer record). Slice-all files: the
    /// layer is found inside its plate's `; ORCA_PLATE` section, so equal
    /// z values on different plates cannot cross-match. The engine writes
    /// z via `%g` (6 significant digits), so the match is CLOSEST-z with a
    /// first-wins tie-break (a start-gcode layer 0 sitting above the first
    /// layer's z still maps to the earliest plausible marker).
    func window(
        forLayer layerIndex: Int,
        z: Double?,
        previewSections: [EngineGcode.PlateSection]
    ) -> Window? {
        guard !markers.isEmpty else { return nil }
        var range = markers.indices
        if let section = previewSections.first(where: {
            layerIndex >= $0.layerRange.lowerBound
                && layerIndex < $0.layerRange.upperBound
        }) ?? previewSections.last,
           let fileSection = sections.first(where: {
               $0.plateIndex == section.plateIndex
           }) {
            let clamped = fileSection.markerRange.clamped(to: markers.indices)
            if !clamped.isEmpty { range = clamped }
        }
        var chosen = range.upperBound - 1
        if let z {
            var bestDelta = Double.infinity
            for candidate in range {
                guard let markerZ = markers[candidate].z else { continue }
                let delta = abs(markerZ - z)
                if delta < bestDelta {
                    bestDelta = delta
                    chosen = candidate
                }
            }
        }
        let marker = markers[chosen]
        let end = chosen + 1 < markers.endIndex
            ? markers[chosen + 1].offset : byteSize
        return Window(
            firstLine: marker.line,
            start: marker.offset,
            end: max(end, marker.offset + 1)
        )
    }
}

enum GcodeLineIndexer {
    private static let chunkSize = 1 << 20

    enum IndexError: LocalizedError {
        case unreadable(String)
        case missingSize

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail):
                "Could not read the G-code file: \(detail)"
            case .missingSize:
                "Could not determine the G-code file size."
            }
        }
    }

    /// Streams the whole file once and records every layer marker and
    /// plate-section boundary. Blocking and I/O-heavy: run off the main
    /// actor (BackgroundWork).
    static func index(url: URL) throws -> GcodeLineIndex {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw IndexError.unreadable(error.localizedDescription)
        }
        var failure: Error?
        var markers: [GcodeLineIndex.Marker] = []
        var sections: [GcodeLineIndex.Section] = []
        var openPlate: Int?
        var openPlateFirstMarker = 0
        var zAwaitingMarker: Int?
        var lineNumber = 0
        var pending = Data()
        var pendingStart: UInt64 = 0
        var consumed: UInt64 = 0
        do {
            while let chunk = try handle.read(upToCount: chunkSize),
                  !chunk.isEmpty {
                let chunkBase = consumed
                consumed += UInt64(chunk.count)
                var scan = chunk.startIndex
                while let newline = chunk[scan...].firstIndex(of: 0x0A) {
                    let text = String(
                        decoding: pending + chunk[scan..<newline], as: UTF8.self)
                    consumeLine(
                        text, at: pendingStart, lineNumber: lineNumber,
                        markers: &markers, sections: &sections,
                        openPlate: &openPlate, openPlateFirstMarker: &openPlateFirstMarker,
                        zAwaitingMarker: &zAwaitingMarker)
                    lineNumber += 1
                    pending.removeAll(keepingCapacity: true)
                    pendingStart = chunkBase
                        + UInt64(chunk.distance(from: chunk.startIndex, to: newline))
                        + 1
                    scan = chunk.index(after: newline)
                }
                pending.append(contentsOf: chunk[scan...])
            }
            if !pending.isEmpty {
                consumeLine(
                    String(decoding: pending, as: UTF8.self), at: pendingStart,
                    lineNumber: lineNumber, markers: &markers,
                    sections: &sections, openPlate: &openPlate,
                    openPlateFirstMarker: &openPlateFirstMarker,
                    zAwaitingMarker: &zAwaitingMarker)
                lineNumber += 1
            }
        } catch {
            failure = error
        }
        do {
            try handle.close()
        } catch {
            if failure == nil { failure = error }
        }
        if let failure { throw failure }
        let size: UInt64
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path)
            guard let value = attributes[.size] as? NSNumber else {
                throw IndexError.missingSize
            }
            size = value.uint64Value
        } catch {
            throw IndexError.unreadable(error.localizedDescription)
        }
        return GcodeLineIndex(
            markers: markers, sections: sections,
            lineCount: lineNumber, byteSize: max(size, consumed))
    }

    /// One finished line: layer markers, their `;Z:` value, and plate
    /// section boundaries (all engine-emitted comment forms).
    private static func consumeLine(
        _ raw: String,
        at offset: UInt64,
        lineNumber: Int,
        markers: inout [GcodeLineIndex.Marker],
        sections: inout [GcodeLineIndex.Section],
        openPlate: inout Int?,
        openPlateFirstMarker: inout Int,
        zAwaitingMarker: inout Int?
    ) {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == ";LAYER_CHANGE" {
            markers.append(GcodeLineIndex.Marker(line: lineNumber, offset: offset, z: nil))
            zAwaitingMarker = markers.count - 1
            return
        }
        if let awaiting = zAwaitingMarker {
            zAwaitingMarker = nil
            // The z comment sits directly after the marker: ";Z:0.32"
            // (Orca) or "; Z_HEIGHT: 0.32" (BBL machines).
            if lineNumber == markers[awaiting].line + 1,
               trimmed.hasPrefix(";Z:") || trimmed.hasPrefix("; Z_HEIGHT:"),
               let colon = trimmed.firstIndex(of: ":") {
                markers[awaiting].z = Double(
                    trimmed[trimmed.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces))
            }
            return
        }
        if trimmed.hasPrefix("; ORCA_PLATE") {
            if trimmed.hasSuffix(" begin"),
               let plate = parsePlateIndex(trimmed) {
                openPlate = plate
                openPlateFirstMarker = markers.count
            } else if trimmed.hasSuffix(" end"), let plate = openPlate {
                sections.append(GcodeLineIndex.Section(
                    plateIndex: plate,
                    markerRange: openPlateFirstMarker..<markers.count))
                openPlate = nil
            }
        }
    }

    /// `; ORCA_PLATE index=1 … begin` → 0 (the marker writes 1-based).
    private static func parsePlateIndex(_ line: String) -> Int? {
        for token in line.split(separator: " ") where token.hasPrefix("index=") {
            guard let oneBased = Int(token.dropFirst("index=".count)) else {
                return nil
            }
            return oneBased - 1
        }
        return nil
    }
}

// MARK: - Line reading (pass two: byte ranges only)

struct GcodeLineRow: Identifiable, Equatable, Sendable {
    /// 0-based file line number.
    let line: Int
    let text: String
    var id: Int { line }
}

enum GcodeLineReader {
    private enum ReadError: LocalizedError {
        case outOfBounds

        var errorDescription: String? {
            "The layer's byte range lies outside the G-code file."
        }
    }

    /// Reads at most `limit` lines from `[start, end)` WITHOUT loading the
    /// file: one seek plus bounded chunks. `firstLine` is the 0-based file
    /// line number of the byte at `start` (known from the index).
    static func readLines(
        url: URL,
        firstLine: Int,
        from start: UInt64,
        to end: UInt64,
        limit: Int
    ) throws -> [GcodeLineRow] {
        guard start < end else { throw ReadError.outOfBounds }
        let handle = try FileHandle(forReadingFrom: url)
        var failure: Error?
        var rows: [GcodeLineRow] = []
        do {
            try handle.seek(toOffset: start)
            var offset = start
            var number = firstLine
            var pending = Data()
            outer: while offset < end, rows.count < limit {
                let length = Int(min(UInt64(1 << 16), end - offset))
                guard length > 0,
                      let chunk = try handle.read(upToCount: length),
                      !chunk.isEmpty else { break }
                offset += UInt64(chunk.count)
                var scan = chunk.startIndex
                while let newline = chunk[scan...].firstIndex(of: 0x0A) {
                    rows.append(GcodeLineRow(
                        line: number,
                        text: String(
                            decoding: pending + chunk[scan..<newline],
                            as: UTF8.self).stripCarriageReturn()))
                    number += 1
                    pending.removeAll(keepingCapacity: true)
                    if rows.count >= limit { break outer }
                    scan = chunk.index(after: newline)
                }
                pending.append(contentsOf: chunk[scan...])
            }
            // EOF without a trailing newline: the layer's last line.
            if rows.count < limit, !pending.isEmpty {
                rows.append(GcodeLineRow(
                    line: number,
                    text: String(decoding: pending, as: UTF8.self)
                        .stripCarriageReturn()))
            }
        } catch {
            failure = error
        }
        do {
            try handle.close()
        } catch {
            if failure == nil { failure = error }
        }
        if let failure { throw failure }
        return rows
    }
}

private extension String {
    func stripCarriageReturn() -> String {
        hasSuffix("\r") ? String(dropLast()) : self
    }
}

// MARK: - Sheet

/// Desktop "Show G-code Window" (preview.gcode-window): the G-code TEXT of
/// the currently viewed layer — the first ~200 lines from the layer's
/// `;LAYER_CHANGE` marker, monospaced with a leading line-number column.
/// The index is built once per file (streamed, bounded memory); switching
/// layers then reads only that layer's byte range.
///
/// The sheet shares the preview's layer state: the layer picker writes the
/// SAME store the slider writes, and moving the preview's layer (slider,
/// jump field, keyboard) scrolls the window to the layer's first line.
struct GcodeLineWindowSheet: View {
    let store: GcodePreviewStore
    let url: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var index: GcodeLineIndex?
    @State private var failure: String?
    @State private var rows: [GcodeLineRow] = []
    @State private var windowInfo = ""
    @State private var displayLayer = 0
    @State private var readGeneration = 0

    private static let lineLimit = 200
    private static let logger = Logger(
        subsystem: "ie.duz.OrcaPad", category: "gcode-window")

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    failureView(failure)
                } else if index == nil {
                    ProgressView("Indexing G-code…")
                } else {
                    lineList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("G-code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.layerCount > 0 { layerMenu }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { displayLayer = store.upperLayer }
        .task { await buildIndex() }
        .onChange(of: indexed) { _, ready in
            if ready { Task { await readLayerWindow() } }
        }
        // Auto-follow: the preview's layer slider (or keyboard) drives the
        // window; the picker below drives it back through the same store.
        .onChange(of: store.upperLayer) { _, layer in
            displayLayer = layer
        }
        .onChange(of: displayLayer) { _, _ in
            Task { await readLayerWindow() }
        }
    }

    private var indexed: Bool { index != nil }

    private var lineList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: "\(row.line + 1)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                            Text(verbatim: row.text.isEmpty ? " " : row.text)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(
                                    row.text.hasPrefix(";")
                                        ? Color.secondary : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 1)
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: rows) { _, _ in
                if let first = rows.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text(windowInfo)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(.ultraThinMaterial)
        }
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("G-code window unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
    }

    // MARK: Indexing / reading

    private func buildIndex() async {
        guard let url else {
            failure = "No G-code file is loaded."
            return
        }
        let result = await BackgroundWork.run(operation: "index gcode layers") {
            try GcodeLineIndexer.index(url: url)
        }
        switch result {
        case .success(let built):
            index = built
            Self.logger.notice(
                "gcode window index: \(built.markers.count) layer markers, \(built.sections.count) plate sections, \(built.lineCount) lines"
            )
        case .failure(let appFailure):
            failure = appFailure.localizedDescription
        }
    }

    private func readLayerWindow() async {
        guard let index, let url else { return }
        if index.markers.isEmpty {
            // No ;LAYER_CHANGE markers (foreign G-code dialect): show the
            // file head instead of nothing, and say so.
            await read(
                url: url,
                window: GcodeLineIndex.Window(
                    firstLine: 0, start: 0, end: index.byteSize),
                layerCount: store.layerCount)
            windowInfo = "No layer markers found — showing the file start"
            return
        }
        let layer = displayLayer
        let z = store.layer(at: layer).map { Double($0.z) }
        let previewSections = store.sections
        if let window = index.window(
            forLayer: layer, z: z, previewSections: previewSections) {
            await read(url: url, window: window, layerCount: store.layerCount)
        } else {
            failure = "The G-code file contains no layer markers."
        }
    }

    private func read(
        url: URL, window: GcodeLineIndex.Window, layerCount: Int
    ) async {
        readGeneration += 1
        let generation = readGeneration
        let lineLimit = Self.lineLimit
        let result = await BackgroundWork.run(operation: "read gcode lines") {
            try GcodeLineReader.readLines(
                url: url, firstLine: window.firstLine,
                from: window.start, to: window.end, limit: lineLimit)
        }
        guard generation == readGeneration else { return }
        switch result {
        case .success(let loaded):
            rows = loaded
            let truncated = loaded.count >= Self.lineLimit ? "…" : ""
            windowInfo = "Layer \(displayLayer + 1) of \(layerCount)"
                + " · lines \(window.firstLine + 1)–\(window.firstLine + loaded.count)\(truncated)"
        case .failure(let appFailure):
            failure = appFailure.localizedDescription
        }
    }

    // MARK: Layer picker

    private var layerMenu: some View {
        Menu {
            if store.sections.isEmpty {
                layerEntries(range: 0..<store.layerCount)
            } else {
                ForEach(store.sections, id: \.plateIndex) { section in
                    Menu(section.name.isEmpty
                         ? "Plate \(section.plateIndex + 1)" : section.name) {
                        layerEntries(range: section.layerRange)
                    }
                }
            }
        } label: {
            Label(
                "Layer \(displayLayer + 1)",
                systemImage: "square.3.layers.3d.down.filled"
            )
        }
    }

    /// Layer buttons, chunked into ≤100-entry submenus so thousand-layer
    /// files do not build one giant menu at once.
    @ViewBuilder
    private func layerEntries(range: Range<Int>) -> some View {
        if range.count <= 100 {
            ForEach(range, id: \.self) { layer in
                layerButton(layer)
            }
        } else {
            let chunks = stride(from: range.lowerBound, to: range.upperBound, by: 100)
                .map { start in start..<min(start + 100, range.upperBound) }
            ForEach(chunks, id: \.lowerBound) { chunk in
                Menu("\(chunk.lowerBound + 1)–\(chunk.upperBound)") {
                    ForEach(chunk, id: \.self) { layer in
                        layerButton(layer)
                    }
                }
            }
        }
    }

    private func layerButton(_ layer: Int) -> some View {
        Button {
            selectLayer(layer)
        } label: {
            if let record = store.layer(at: layer), record.z > 0 {
                Text(verbatim: "Layer \(layer + 1) · \(String(format: "%.2f", record.z)) mm")
            } else {
                Text(verbatim: "Layer \(layer + 1)")
            }
        }
    }

    /// Same path as the tab's "Jump to layer": the range jumps onto the
    /// picked layer (the lower handle never crosses it).
    private func selectLayer(_ layer: Int) {
        store.setLayerRange(lower: min(store.lowerLayer, layer), upper: layer)
    }
}
