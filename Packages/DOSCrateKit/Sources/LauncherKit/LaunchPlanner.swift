import ConfigKit
import Foundation
import LibraryKit

public struct LaunchPlan: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]
    public var configURL: URL
    public var logsDirectory: URL
}

public enum LaunchPlanner {
    public static func plan(_ r: GameRecord, cDrive: URL, global: GlobalConfig, dosbox: URL, io: CrateIO) throws -> LaunchPlan {
        let text = try render(r, cDrive: cDrive, global: global)
        let fm = FileManager.default
        let logs = io.logsURL(r.crateURL)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let conf = io.cacheURL(r.crateURL).appending(path: "launch.conf", directoryHint: .notDirectory)
        try Data(text.utf8).write(to: conf, options: .atomic)

        var args = ["--noprimaryconf", "--nolocalconf", "--working-dir", r.crateURL.path, "--conf", conf.path]
        let override = io.overrideURL(r.crateURL)
        if let size = (try? fm.attributesOfItem(atPath: override.path))?[.size] as? NSNumber, size.intValue > 0 {
            args += ["--conf", override.path]
        }
        // Without a program the session is a DOS prompt (e.g. installing from D:), so never quit after autoexec.
        if r.game.launch.exitWhenDone, let exe = r.game.launch.executable, !exe.isEmpty { args.append("--exit") }
        return LaunchPlan(executable: dosbox, arguments: args, workingDirectory: r.crateURL,
                          environment: [:], configURL: conf, logsDirectory: logs)
    }

    public static func generatedConfigPreview(_ r: GameRecord, global: GlobalConfig, io: CrateIO) -> String {
        do {
            return try render(r, cDrive: io.cDriveURL(for: r), global: global)
        } catch {
            return "# error: \(error)"
        }
    }

    private static func render(_ r: GameRecord, cDrive: URL, global: GlobalConfig) throws -> String {
        let media = r.game.media.map { (Preflight.mediaURL($0, in: r.crateURL), $0.kind) }
        do {
            return try LaunchConfigBuilder.build(game: r.game, cDrive: cDrive, media: media, global: global).render()
        } catch DOSPathError.notDOSName(let component, let parent) {
            let root = parent.isEmpty ? component : parent + "/" + component
            throw LaunchError.nonDOSPath(component: component, suggestedCRoot: root)
        } catch DOSPathError.unquotablePath(let p) {
            throw LaunchError.unsupportedPath(p)
        }
    }
}
