// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Compression
import Foundation

enum ZipImportError: Error, LocalizedError, Sendable {
    /// The archive bytes could not be read from the picked URL.
    case unreadable(String)
    /// No End-Of-Central-Directory record: not a ZIP, or truncated.
    case notAnArchive
    /// A well-formed but unsupported feature (ZIP64, encryption, exotic
    /// compression method) — extracted loudly instead of half-parsed.
    case unsupported(String)
    /// Structural corruption (bad signature, size mismatch, zip-slip path).
    case corrupt(String)
    /// Extraction would exceed the per-entry / total budget (zip bomb).
    case tooLarge(String)
    /// The archive parsed but contains no model files to import.
    case noModelFiles(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "import zip: could not read the archive — \(detail)"
        case .notAnArchive:
            return "import zip: no ZIP end-of-central-directory record " +
                "(not a ZIP file, or it is truncated)"
        case .unsupported(let detail):
            return "import zip: \(detail)"
        case .corrupt(let detail):
            return "import zip: archive is corrupt — \(detail)"
        case .tooLarge(let detail):
            return "import zip: entry exceeds the extraction budget — \(detail)"
        case .noModelFiles(let names):
            return "import zip: no model files (stl/obj/amf/3mf) inside" +
                (names.isEmpty ? "" : " — found: \(names)")
        }
    }
}

/// Minimal ZIP reader for the "Import zip…" Plate action (board §wave-b/3,
/// option (a)): hand-parsed container + Apple Compression raw-DEFLATE.
///
/// Scope is deliberately narrow — a user-picked zip of models is ~100%
/// stored/deflate entries:
/// - methods 0 (stored) and 8 (deflate) ONLY; anything else is a typed
///   `unsupported` failure (fail loudly, no partial extraction);
/// - no ZIP64 (0xFFFF/0xFFFFFFFF markers reject), no encryption;
/// - entry CRCs are NOT verified (no zlib on iOS; the model importer
///   rejects broken geometry loudly anyway).
///
/// Everything throws with context; there are no silent skips.
enum ZipImport {
    /// Engine `Model::read_from_file` geometry extensions (ImportTypes).
    static let modelExtensions: Set<String> = ["stl", "obj", "amf", "3mf"]

    /// Per-entry uncompressed cap and total archive cap (zip-bomb guard).
    private static let maxEntryBytes = 512 * 1024 * 1024
    private static let maxTotalBytes = 2 * 1024 * 1024 * 1024

    private static let endRecordSignature: UInt32 = 0x0605_4b50
    private static let centralEntrySignature: UInt32 = 0x0201_4b50
    private static let localHeaderSignature: UInt32 = 0x0403_4b50

    // MARK: Byte helpers (ZIP is little-endian)

    private static func u16(_ data: Data, at offset: Int) -> Int {
        Int(data[data.startIndex + offset])
            | Int(data[data.startIndex + offset + 1]) << 8
    }

    private static func u32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[data.startIndex + offset])
            | UInt32(data[data.startIndex + offset + 1]) << 8
            | UInt32(data[data.startIndex + offset + 2]) << 16
            | UInt32(data[data.startIndex + offset + 3]) << 24
    }

    // MARK: Public entry

    /// Extracts every MODEL file of a picked ZIP into
    /// `tmp/imports/zip/<uuid>/…` and returns the file URLs in archive
    /// order. The caller feeds each URL through the normal multi-import
    /// path (`DocumentStore.importModel`), which copies into its own
    /// sandbox — so this directory is scratch, not the final home.
    static func extractModelFiles(from source: URL) throws -> [URL] {
        let hasSecurityScope = source.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw ZipImportError.unreadable(String(describing: error))
        }
        guard !data.isEmpty else {
            throw ZipImportError.unreadable("the file is empty")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imports", isDirectory: true)
            .appendingPathComponent("zip", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw ZipImportError.unreadable(
                "could not create \(directory.path): \(String(describing: error))")
        }

        let entries = try parseCentralDirectory(data)
        var models: [URL] = []
        var totalBytes = 0
        for entry in entries {
            guard !entry.name.hasSuffix("/") else { continue }  // directory
            guard modelExtensions.contains(
                (entry.name as NSString).pathExtension.lowercased()
            ) else { continue }
            guard entry.uncompressedSize <= maxEntryBytes else {
                throw ZipImportError.tooLarge(
                    "\(entry.name) is \(entry.uncompressedSize) bytes")
            }
            totalBytes += entry.uncompressedSize
            guard totalBytes <= maxTotalBytes else {
                throw ZipImportError.tooLarge(
                    "\(entry.name): archive total exceeds \(maxTotalBytes) bytes")
            }
            let content = try entryContent(entry, in: data)
            let destination = directory.appendingPathComponent(entry.name)
            try validatePath(entry.name, relativeTo: directory)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try content.write(to: destination, options: .atomic)
            } catch {
                throw ZipImportError.unreadable(
                    "could not write \(entry.name): \(String(describing: error))")
            }
            models.append(destination)
        }

        guard !models.isEmpty else {
            let names = entries
                .filter { !$0.name.hasSuffix("/") }
                .map { ($0.name as NSString).lastPathComponent }
            throw ZipImportError.noModelFiles(names.prefix(8).joined(separator: ", "))
        }
        return models
    }

    // MARK: Container parsing

    private struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Scans backwards for the EOCD and parses every central-directory
    /// entry. Rejects ZIP64 markers, spanning disks and encryption.
    private static func parseCentralDirectory(_ data: Data) throws -> [Entry] {
        // The EOCD record itself is 22 bytes — anything shorter cannot be
        // a zip (guard FIRST: the backward scan would index negatively).
        guard data.count >= 22 else {
            throw ZipImportError.notAnArchive
        }
        // EOCD sits in the last 22 + 65535 bytes (max comment length).
        let scanStart = max(0, data.count - 22 - 65_535)
        var endRecordOffset: Int?
        var offset = data.count - 22
        while offset >= scanStart {
            if u32(data, at: offset) == endRecordSignature {
                endRecordOffset = offset
                break
            }
            offset -= 1
        }
        guard let eocd = endRecordOffset else {
            throw ZipImportError.notAnArchive
        }
        let diskNumber = u16(data, at: eocd + 4)
        let centralDisk = u16(data, at: eocd + 6)
        guard diskNumber == 0, centralDisk == 0 else {
            throw ZipImportError.unsupported(
                "multi-disk archives are not supported")
        }
        let entryCount = u16(data, at: eocd + 10)
        let centralSize = u32(data, at: eocd + 12)
        let centralOffset = u32(data, at: eocd + 16)
        if entryCount == 0xFFFF || centralSize == 0xFFFF_FFFF ||
            centralOffset == 0xFFFF_FFFF {
            throw ZipImportError.unsupported("ZIP64 archives are not supported")
        }

        var entries: [Entry] = []
        var cursor = Int(centralOffset)
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count,
                u32(data, at: cursor) == centralEntrySignature
            else {
                throw ZipImportError.corrupt(
                    "central directory entry \(entries.count) at byte \(cursor)")
            }
            // Local-header offset is the 4-byte field at +42; the name
            // starts after the fixed 46-byte part.
            let flags = u16(data, at: cursor + 8)
            guard flags & 0x1 == 0 else {
                throw ZipImportError.unsupported("encrypted entries are not supported")
            }
            let method = UInt16(u16(data, at: cursor + 10))
            guard method == 0 || method == 8 else {
                throw ZipImportError.unsupported(
                    "compression method \(method) in \"\(entryName(data, cursor))\" " +
                        "(only stored/deflate are supported)")
            }
            let compressedSize = Int(u32(data, at: cursor + 20))
            let uncompressedSize = Int(u32(data, at: cursor + 24))
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF {
                throw ZipImportError.unsupported("ZIP64 archives are not supported")
            }
            let nameLength = u16(data, at: cursor + 28)
            let extraLength = u16(data, at: cursor + 30)
            let commentLength = u16(data, at: cursor + 32)
            let localOffset = Int(u32(data, at: cursor + 42))
            if localOffset == 0xFFFF_FFFF {
                throw ZipImportError.unsupported("ZIP64 archives are not supported")
            }
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                throw ZipImportError.corrupt("truncated entry name")
            }
            // Names are ASCII or (flag 0x800) UTF-8; UTF-8 decoding of
            // plain ASCII is identity, so decode UTF-8 unconditionally.
            let name = String(
                decoding: data.subdata(in: nameStart..<(nameStart + nameLength)),
                as: UTF8.self)
            entries.append(Entry(
                name: name,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        guard cursor <= data.count else {
            throw ZipImportError.corrupt("central directory overruns the file")
        }
        return entries
    }

    private static func entryName(_ data: Data, _ cursor: Int) -> String {
        let length = u16(data, at: cursor + 28)
        guard cursor + 46 + length <= data.count else { return "?" }
        return String(
            decoding: data.subdata(in: (cursor + 46)..<(cursor + 46 + length)),
            as: UTF8.self)
    }

    /// Inflates (or copies) one entry's payload, validating every size.
    private static func entryContent(_ entry: Entry, in data: Data) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count,
            u32(data, at: header) == localHeaderSignature
        else {
            throw ZipImportError.corrupt(
                "local header of \"\(entry.name)\" at byte \(header)")
        }
        let localMethod = u16(data, at: header + 8)
        guard localMethod == Int(entry.method) else {
            throw ZipImportError.corrupt(
                "\"\(entry.name)\": central and local methods disagree")
        }
        // The LOCAL extra-field length can differ from the central one —
        // only the local header says where the payload starts.
        let payloadStart = header + 30
            + u16(data, at: header + 26)
            + u16(data, at: header + 28)
        guard payloadStart + entry.compressedSize <= data.count else {
            throw ZipImportError.corrupt(
                "\"\(entry.name)\": payload overruns the file")
        }
        let payload = data.subdata(
            in: payloadStart..<(payloadStart + entry.compressedSize))

        switch entry.method {
        case 0:
            guard payload.count == entry.uncompressedSize else {
                throw ZipImportError.corrupt(
                    "\"\(entry.name)\": stored size \(payload.count) != " +
                        "declared \(entry.uncompressedSize)")
            }
            return payload
        default:
            // Apple's COMPRESSION_ZLIB is RAW DEFLATE (RFC 1951) — exactly
            // what a zip entry stores. The zlib wrapper (RFC 1950) never
            // appears inside zip members.
            let inflated = try inflate(payload, expected: entry.uncompressedSize)
            guard inflated.count == entry.uncompressedSize else {
                throw ZipImportError.corrupt(
                    "\"\(entry.name)\": inflated \(inflated.count) bytes, " +
                        "declared \(entry.uncompressedSize)")
            }
            return inflated
        }
    }

    /// One-shot raw-DEFLATE decode via the Compression framework.
    private static func inflate(_ source: Data, expected: Int) throws -> Data {
        let destination = UnsafeMutablePointer<UInt8>.allocate(
            capacity: max(expected, 1))
        defer { destination.deallocate() }
        let decoded = try source.withUnsafeBytes { rawSource -> Int in
            guard let base = rawSource.baseAddress?.assumingMemoryBound(
                to: UInt8.self) else {
                throw ZipImportError.corrupt("empty deflate stream")
            }
            let count = compression_decode_buffer(
                destination, max(expected, 1),
                base, source.count, nil, COMPRESSION_ZLIB
            )
            return count
        }
        return Data(bytes: destination, count: decoded)
    }

    /// Zip-slip guard: every entry must stay inside the extraction
    /// directory (absolute paths and `..` traversal reject loudly).
    private static func validatePath(_ name: String, relativeTo root: URL) throws {
        guard !name.hasPrefix("/"), !name.contains("\\"),
            !name.components(separatedBy: "/").contains("..")
        else {
            throw ZipImportError.corrupt("unsafe entry path \"\(name)\"")
        }
        _ = root  // documented above: the check is purely lexical
    }
}
