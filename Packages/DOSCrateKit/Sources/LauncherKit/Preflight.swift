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
        case .readOnly(let reason): throw .readOnly(reason: reason)
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
        } else if r.game.media.isEmpty && r.game.launch.folderMounts.isEmpty {
            throw .executableNotSet
        }

        for image in r.game.media {
            let url = mediaURL(image, in: r.crateURL)
            guard fm.fileExists(atPath: url.path) else { throw .mediaMissing(path: url.path) }
            if url.path.contains("\"") { throw .unsupportedPath(url.path) }
        }
        let hasCDROM = r.game.media.contains { $0.kind == .cdrom }
        var effectiveMounts = r.game.launch.folderMounts
        guard FolderMount.reassignConflictsWithCDROM(&effectiveMounts, hasCDROM: hasCDROM) else {
            throw .launchFailed("All DOS drive letters (D:–Y:) are already used by folder mounts. Remove a folder mount to free D: for the CD-ROM.")
        }
        for mount in r.game.launch.folderMounts {
            let url = try resolveFolderMount(mount)
            if url.path.contains("\"") { throw .unsupportedPath(url.path) }
        }
        return cDrive
    }

    static func mediaURL(_ image: MediaImage, in crate: URL) -> URL {
        crate.appending(path: image.relativePath, directoryHint: .notDirectory)
    }

    static func resolveFolderMount(_ mount: FolderMount) throws(LaunchError) -> URL {
        let fm = FileManager.default
        if !mount.bookmark.isEmpty {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: mount.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
                    return resolved
                }
            }
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: mount.path, isDirectory: &isDir), isDir.boolValue else {
            throw .folderMountMissing(driveLetter: mount.driveLetter, path: mount.path)
        }
        return URL(fileURLWithPath: mount.path, isDirectory: true)
    }
}
