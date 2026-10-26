// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import Foundation

enum EnginePathError: Error, LocalizedError, Sendable {
    case presetDataDirectory(String)
    case bundledProfilesMissing(String)
    case importCopy(String)
    case gcodeDirectory(String)
    case projectName(String)
    case projectDirectory(String)

    var errorDescription: String? {
        switch self {
        case .presetDataDirectory(let diagnostic):
            return "preset data directory: \(diagnostic)"
        case .bundledProfilesMissing(let path):
            return "system profiles are missing at \(path)"
        case .importCopy(let diagnostic):
            return "import copy: \(diagnostic)"
        case .gcodeDirectory(let diagnostic):
            return "G-code directory: \(diagnostic)"
        case .projectName(let name):
            return "invalid project name \"\(name)\""
        case .projectDirectory(let diagnostic):
            return "project directory: \(diagnostic)"
        }
    }
}

enum EnginePaths {
    /// Creates the writable data-dir shape required by PresetBundle and links
    /// its read-only system tree to the current app bundle. The symlink must be
    /// recreated every launch because each install changes the bundle UUID.
    ///
    /// The data directory lives in Application Support, NOT Documents:
    /// Documents is Files-app visible (UIFileSharingEnabled for G-code), and
    /// the writable tree carries print-host API keys
    /// (user/default/physical_machine) that must not be user-browsable.
    static func preparePresetDataDirectory() throws -> URL {
        let fileManager = FileManager.default
        try migrateLegacyDocumentsDataDirectory(fileManager)
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let dataDirectory = support.appendingPathComponent(
            "orcapad-data",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: dataDirectory.appendingPathComponent(
                    "user/default",
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
            let systemLink = dataDirectory.appendingPathComponent("system")
            var linkExists = false
            do {
                _ = try fileManager.destinationOfSymbolicLink(
                    atPath: systemLink.path
                )
                linkExists = true
            } catch let error as CocoaError
                where error.code == .fileNoSuchFile ||
                    error.code == .fileReadNoSuchFile {
                linkExists = false
            }
            if linkExists {
                try fileManager.removeItem(at: systemLink)
            }

            let bundledSystem = Bundle.module.bundleURL
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("system", isDirectory: true)
            guard fileManager.fileExists(atPath: bundledSystem.path) else {
                throw EnginePathError.bundledProfilesMissing(
                    bundledSystem.path
                )
            }
            try fileManager.createSymbolicLink(
                at: systemLink,
                withDestinationURL: bundledSystem
            )
            return dataDirectory
        } catch let error as EnginePathError {
            throw error
        } catch {
            throw EnginePathError.presetDataDirectory(
                String(reflecting: error)
            )
        }
    }

    /// One-time move of the pre-v0.8 `Documents/orcapad-data` (Files-visible,
    /// carried API keys and user presets) into Application Support. Only a
    /// legacy tree with no modern counterpart is moved; a failed move throws
    /// — presets must not silently load an empty fresh tree while the user's
    /// printers/presets sit in the old location.
    private static func migrateLegacyDocumentsDataDirectory(
        _ fileManager: FileManager
    ) throws {
        let documents = fileManager.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        let legacy = documents.appendingPathComponent("orcapad-data", isDirectory: true)
        let modern = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("orcapad-data", isDirectory: true)
        var legacyIsDirectory: ObjCBool = false
        let legacyExists = fileManager.fileExists(
            atPath: legacy.path, isDirectory: &legacyIsDirectory
        )
        guard legacyExists, legacyIsDirectory.boolValue,
              !fileManager.fileExists(atPath: modern.path)
        else { return }
        do {
            try fileManager.createDirectory(
                at: modern.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacy, to: modern)
        } catch {
            throw EnginePathError.presetDataDirectory(
                "could not move the legacy Documents/orcapad-data into " +
                    "Application Support: \(String(reflecting: error)) — the " +
                    "old tree was left in place"
            )
        }
    }

    /// Copies a user-picked file into `tmp/imports/<kind>/<original name>`
    /// (the engine needs a plain readable path; the original name keeps
    /// object / G-code names meaningful). Each kind keeps only its latest
    /// copy; kinds are serialized by their owning store.
    static func copyImportIntoSandbox(_ source: URL, kind: String) throws -> URL {
        let hasSecurityScope = source.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("imports", isDirectory: true)
            .appendingPathComponent(kind, isDirectory: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        do {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            return destination
        } catch {
            throw EnginePathError.importCopy(String(reflecting: error))
        }
    }

    /// `Documents/Projects/<name>.3mf` (visible in Files ▸ On My iPad).
    static func projectURL(name: String) throws -> URL {
        let trimmed = (name as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw EnginePathError.projectName(name)
        }
        let fileManager = FileManager.default
        let directory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projects", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw EnginePathError.projectDirectory(String(reflecting: error))
        }
        return directory.appendingPathComponent(trimmed).appendingPathExtension("3mf")
    }

    /// Filesystem-safe base name for outputs derived from an object/scene
    /// name: 3MF object names are arbitrary strings and may contain "/",
    /// ":" or control characters (an unsanitized name nests a path and the
    /// slice fails at export with a confusing IO error).
    static func sanitizedBaseName(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isLetter || character.isNumber ||
                " -_.()[]+".contains(character) {
                result.append(character)
            } else {
                result.append("-")
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        let capped = String(trimmed.prefix(80))
        return capped.isEmpty ? "plater" : capped
    }

    static func gcodeOutputURL(sceneName: String) throws -> URL {
        let fileManager = FileManager.default
        let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let directory = documents.appendingPathComponent(
            "G-code",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw EnginePathError.gcodeDirectory(String(reflecting: error))
        }
        let baseName = sanitizedBaseName((sceneName as NSString).deletingPathExtension)
        // Never silently overwrite a previous slice: every result gets its
        // own file (name, name-2, name-3 …). The G-code folder is visible in
        // Files, so previous results stay available until the user deletes
        // them — no last-slice-wins data loss.
        var candidate = directory
            .appendingPathComponent(baseName)
            .appendingPathExtension("gcode")
        var ordinal = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName)-\(ordinal)")
                .appendingPathExtension("gcode")
            ordinal += 1
        }
        return candidate
    }

    /// `Application Support/Autosave/autosave.3mf` — the lightweight
    /// background-session snapshot (desktop project auto-backup subset).
    /// Not in Documents: it is engine state, not a user deliverable.
    static func autosaveURL() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        .appendingPathComponent("Autosave", isDirectory: true)
        .appendingPathComponent("autosave")
        .appendingPathExtension("3mf")
    }
}
