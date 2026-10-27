import Foundation
import Security

public enum LaunchError: Error, Equatable {
    case dosboxMissing
    case executableNotSet
    case executableMissing(path: String)
    case sourceUnreachable(path: String)
    case nonDOSPath(component: String, suggestedCRoot: String)
    case unsupportedPath(String)
    case needsRepair
    case alreadyRunning
}

public enum StagingLocator {
    /// The embedded DOSBox Staging executable inside the app bundle's Resources.
    public static func dosboxURL(appBundle: Bundle = .main) -> URL {
        (appBundle.resourceURL ?? appBundle.bundleURL)
            .appending(path: "DOSBox Staging.app/Contents/MacOS/dosbox", directoryHint: .notDirectory)
    }

    /// Checks that the executable exists, is executable and has a valid code signature.
    public static func verify(_ url: URL) throws(LaunchError) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: url.path) else {
            throw .dosboxMissing
        }
        // Validate the enclosing .app when the executable sits at <App>/Contents/MacOS/<name>.
        var target = url
        if url.deletingLastPathComponent().lastPathComponent == "MacOS",
           url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" {
            target = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(target as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
            throw .dosboxMissing
        }
    }
}
