import ConfigKit
import Foundation
import LibraryKit
import Observation

@MainActor @Observable
final class Preferences {
    enum Key {
        static let libraryPath = "libraryPath"
        static let defaultPreset = "defaultPreset"
        static let globalOverrides = "globalOverrides"
        static let rawGlobalOverrides = "rawGlobalOverrides"
        static let soundfontPath = "soundfontPath"
        static let mt32RomDir = "mt32RomDir"
    }

    static var defaultLibraryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/DOSCrate Library", directoryHint: .isDirectory)
    }

    @ObservationIgnored private let defaults: UserDefaults

    var libraryPath: String { didSet { defaults.set(libraryPath, forKey: Key.libraryPath) } }
    var defaultPreset: Preset { didSet { defaults.set(defaultPreset.rawValue, forKey: Key.defaultPreset) } }
    var globalOverrides: GameSettings {
        didSet { defaults.set(try? JSONEncoder().encode(globalOverrides), forKey: Key.globalOverrides) }
    }
    var rawGlobalOverrides: String { didSet { defaults.set(rawGlobalOverrides, forKey: Key.rawGlobalOverrides) } }
    var soundfontPath: String { didSet { defaults.set(soundfontPath, forKey: Key.soundfontPath) } }
    var mt32RomDir: String { didSet { defaults.set(mt32RomDir, forKey: Key.mt32RomDir) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        libraryPath = defaults.string(forKey: Key.libraryPath) ?? Self.defaultLibraryURL.path
        defaultPreset = defaults.string(forKey: Key.defaultPreset).flatMap(Preset.init(rawValue:)) ?? .auto
        globalOverrides = defaults.data(forKey: Key.globalOverrides)
            .flatMap { try? JSONDecoder().decode(GameSettings.self, from: $0) } ?? GameSettings()
        rawGlobalOverrides = defaults.string(forKey: Key.rawGlobalOverrides) ?? ""
        soundfontPath = defaults.string(forKey: Key.soundfontPath) ?? ""
        mt32RomDir = defaults.string(forKey: Key.mt32RomDir) ?? ""
    }

    var libraryURL: URL { URL(filePath: libraryPath, directoryHint: .isDirectory) }

    var globalConfig: GlobalConfig {
        GlobalConfig(
            defaultPreset: defaultPreset, overrides: globalOverrides, rawOverrides: rawGlobalOverrides,
            env: ConfigEnvironment(soundfontPath: soundfontPath.isEmpty ? nil : soundfontPath,
                                   mt32RomDir: mt32RomDir.isEmpty ? nil : mt32RomDir))
    }
}
