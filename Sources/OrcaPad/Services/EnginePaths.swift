import Foundation

enum EnginePathError: Error, LocalizedError, Sendable {
    case presetDataDirectory(String)
    case bundledProfilesMissing(String)
    case importCopy(String)
    case gcodeDirectory(String)

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
        }
    }
}

enum EnginePaths {
    /// Creates the writable data-dir shape required by PresetBundle and links
    /// its read-only system tree to the current app bundle. The symlink must be
    /// recreated every launch because each install changes the bundle UUID.
    static func preparePresetDataDirectory() throws -> URL {
        let fileManager = FileManager.default
        let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let dataDirectory = documents.appendingPathComponent(
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
        let baseName = (sceneName as NSString).deletingPathExtension
        let outputName = baseName.isEmpty ? "plater" : baseName
        return directory
            .appendingPathComponent(outputName)
            .appendingPathExtension("gcode")
    }
}
