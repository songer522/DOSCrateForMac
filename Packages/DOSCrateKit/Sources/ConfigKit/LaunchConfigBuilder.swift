import Foundation
import LibraryKit

public struct GlobalConfig: Sendable {
    public var defaultPreset: Preset
    public var overrides: GameSettings
    public var rawOverrides: String
    public var env: ConfigEnvironment
    public var controllerLayout: ControllerLayout?
    public var detectedControllerLayout: ControllerLayout?
    public init(defaultPreset: Preset = .auto, overrides: GameSettings = GameSettings(),
                rawOverrides: String = "", env: ConfigEnvironment = ConfigEnvironment(),
                controllerLayout: ControllerLayout? = nil,
                detectedControllerLayout: ControllerLayout? = nil) {
        self.defaultPreset = defaultPreset; self.overrides = overrides
        self.rawOverrides = rawOverrides; self.env = env
        self.controllerLayout = controllerLayout
        self.detectedControllerLayout = detectedControllerLayout ?? controllerLayout
    }
}

public enum LaunchConfigBuilder {
    /// Layers, lowest to highest: capture dir / controller map, global curated, global raw, preset, game settings, autoexec.
    public static func build(game: Game, cDrive: URL, media: [(URL, MediaKind)],
                             folderMounts: [(String, URL)] = [], global: GlobalConfig,
                             controllerMap: URL? = nil, captureDir: URL? = nil) throws(DOSPathError) -> ConfigDocument {
        var doc = ConfigDocument()
        if let captureDir {
            doc.set("dosbox", "capture_dir", captureDir.path)
        }
        if let controllerMap {
            doc.set("sdl", "mapperfile", controllerMap.path)
            doc.set("joystick", "joysticktype", "hidden")
        }
        doc.merge(SettingsMapper.document(global.overrides, env: global.env))
        doc.merge(ConfigDocument.parse(global.rawOverrides))
        doc.merge(Presets.document(game.settings.preset ?? global.defaultPreset))
        doc.merge(SettingsMapper.document(game.settings, env: global.env))
        var tail = ConfigDocument()
        tail.autoexec = try AutoexecBuilder.lines(cDrive: cDrive, media: media, folderMounts: folderMounts, launch: game.launch)
        doc.merge(tail)
        return doc
    }
}
