import ConfigKit
import Foundation
import LibraryKit

public enum Preflight {
    /// Validates everything needed to launch `r`; returns the C: URL.
    public static func check(_ r: GameRecord, io: CrateIO, dosbox: URL) throws(LaunchError) -> URL {
        let fm = FileManager.default
        switch r.status {
        case .ok: break
        case .needsRepair: throw .needsRepair
        case .missingSource:
            if case .referenced(let path, _) = r.game.source { throw .sourceUnreachable(path: path) }
            throw .needsRepair
        }
        guard fm.isExecutableFile(atPath: dosbox.path) else { throw .dosboxMissing }

        let cDrive: URL
        do {
            cDrive = try io.cDriveURL(for: r)
        } catch LibraryError.sourceUnreachable(let path) {
            throw .sourceUnreachable(path: path)
        } catch {
            throw .needsRepair
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cDrive.path, isDirectory: &isDir), isDir.boolValue else {
            // A referenced folder that resolved but is no longer a folder is still the source going missing;
            // everything else is a missing `files/` or a `driveCRoot` that no longer exists.
            if case .referenced(let path, _) = r.game.source, r.game.launch.driveCRoot.isEmpty {
                throw .sourceUnreachable(path: path)
            }
            throw .cRootMissing(path: cDrive.path)
        }
        if cDrive.path.contains("\"") { throw .unsupportedPath(cDrive.path) }

        if let exe = r.game.launch.executable, !exe.isEmpty {
            do {
                _ = try DOSPath.dosPath(relative: exe)
            } catch {
                switch error {
                case .notDOSName(let component, let parent):
                    let root = parent.isEmpty ? component : parent + "/" + component
                    throw .nonDOSPath(component: component, suggestedCRoot: root)
                case .unquotablePath(let p):
                    throw .unsupportedPath(p)
                }
            }
            let exeURL = cDrive.appending(path: exe, directoryHint: .notDirectory)
            guard fm.fileExists(atPath: exeURL.path) else { throw .executableMissing(path: exe) }
        } else if r.game.media.isEmpty {
            throw .executableNotSet
        }

        for image in r.game.media {
            let url = mediaURL(image, in: r.crateURL)
            guard fm.fileExists(atPath: url.path) else { throw .mediaMissing(path: url.path) }
            if url.path.contains("\"") { throw .unsupportedPath(url.path) }
        }
        return cDrive
    }

    static func mediaURL(_ image: MediaImage, in crate: URL) -> URL {
        crate.appending(path: image.relativePath, directoryHint: .notDirectory)
    }
}
