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
        let fm = FileManager.default
        let logs = io.logsURL(r.crateURL)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let captures = io.screenshotsURL(r.crateURL)
        try fm.createDirectory(at: captures, withIntermediateDirectories: true)
        var controllerMap: URL?
        if let controller = resolvedControllerPlan(for: r, global: global) {
            let map = io.cacheURL(r.crateURL).appending(path: "controller.map", directoryHint: .notDirectory)
            let rendered = ControllerMap.render(controller.layout, mode: controller.mode, bindings: controller.bindings)
            if (try? Data(rendered.utf8).write(to: map, options: .atomic)) != nil {
                controllerMap = map
            }
        }
        let text = try render(r, cDrive: cDrive, global: global, controllerMap: controllerMap, captureDir: captures)
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
        let controllerMap = resolvedControllerPlan(for: r, global: global) == nil ? nil
            : io.cacheURL(r.crateURL).appending(path: "controller.map", directoryHint: .notDirectory)
        do {
            return try render(r, cDrive: io.cDriveURL(for: r), global: global, controllerMap: controllerMap,
                              captureDir: io.screenshotsURL(r.crateURL))
        } catch {
            return "# error: \(error)"
        }
    }

    private static func resolvedControllerPlan(
        for r: GameRecord,
        global: GlobalConfig
    ) -> (layout: ControllerLayout, mode: ControllerMode, bindings: ControllerBindings)? {
        let effectiveMode = r.game.settings.controllerMode ?? global.overrides.controllerMode ?? .keyboard
        guard effectiveMode != .disabled else { return nil }
        let layout: ControllerLayout? = if r.game.settings.controllerMode != nil {
            global.detectedControllerLayout ?? global.controllerLayout
        } else {
            global.controllerLayout
        }
        guard let layout else { return nil }
        let bindings = ControllerBindings.merged(
            base: global.overrides.controllerBindings,
            override: r.game.settings.controllerBindings
        )
        return (layout, effectiveMode, bindings)
    }

    private static func render(
        _ r: GameRecord,
        cDrive: URL,
        global: GlobalConfig,
        controllerMap: URL?,
        captureDir: URL
    ) throws -> String {
        let media = r.game.media.map { (Preflight.mediaURL($0, in: r.crateURL), $0.kind) }
        let folderMounts = r.game.launch.folderMounts.map { mount in
            let url = (try? Preflight.resolveFolderMount(mount)) ?? URL(fileURLWithPath: mount.path, isDirectory: true)
            return (mount.driveLetter, url)
        }
        do {
            return try LaunchConfigBuilder.build(game: r.game, cDrive: cDrive, media: media,
                                                 folderMounts: folderMounts, global: global,
                                                 controllerMap: controllerMap, captureDir: captureDir).render()
        } catch DOSPathError.notDOSName(let component, let parent) {
            let root = parent.isEmpty ? component : parent + "/" + component
            throw LaunchError.nonDOSPath(component: component, suggestedCRoot: root)
        } catch DOSPathError.unquotablePath(let p) {
            throw LaunchError.unsupportedPath(p)
        }
    }
}
