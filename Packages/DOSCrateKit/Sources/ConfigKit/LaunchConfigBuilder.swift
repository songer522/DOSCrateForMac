import Foundation
import LibraryKit

public struct GlobalConfig: Sendable {
    public var defaultPreset: Preset
    public var overrides: GameSettings
    public var rawOverrides: String
    public var env: ConfigEnvironment
    public init(defaultPreset: Preset = .auto, overrides: GameSettings = GameSettings(),
                rawOverrides: String = "", env: ConfigEnvironment = ConfigEnvironment()) {
        self.defaultPreset = defaultPreset; self.overrides = overrides
        self.rawOverrides = rawOverrides; self.env = env
    }
}

public enum LaunchConfigBuilder {
    /// Layers, lowest to highest: global curated, global raw, preset, game settings, autoexec.
    public static func build(game: Game, cDrive: URL, media: [(URL, MediaKind)], global: GlobalConfig) throws(DOSPathError) -> ConfigDocument {
        var doc = SettingsMapper.document(global.overrides, env: global.env)
        doc.merge(ConfigDocument.parse(global.rawOverrides))
        doc.merge(Presets.document(game.settings.preset ?? global.defaultPreset))
        doc.merge(SettingsMapper.document(game.settings, env: global.env))
        var tail = ConfigDocument()
        tail.autoexec = try AutoexecBuilder.lines(cDrive: cDrive, media: media, launch: game.launch)
        doc.merge(tail)
        return doc
    }
}
