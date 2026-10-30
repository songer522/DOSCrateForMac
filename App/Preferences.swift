import ConfigKit
import Foundation
import ImportKit
import LauncherKit
import LibraryKit
import Observation

enum ImportLocationPreference: String, CaseIterable, Sendable {
    case ask
    case copy
    case reference

    var displayName: String {
        switch self {
        case .ask: "Ask"
        case .copy: "Copy into library"
        case .reference: "Keep in place"
        }
    }

    var defaultMode: ImportMode {
        self == .reference ? .reference : .copy
    }
}

enum AppTheme: String, CaseIterable, Sendable {
    case dos
    case standard

    var displayName: String {
        switch self {
        case .dos: "DOS"
        case .standard: "Standard"
        }
    }
}

@MainActor @Observable
final class Preferences {
    enum Key {
        static let libraryPath = "libraryPath"
        static let appTheme = "appTheme"
        static let defaultPreset = "defaultPreset"
        static let importLocation = "importLocation"
        static let globalOverrides = "globalOverrides"
        static let rawGlobalOverrides = "rawGlobalOverrides"
        static let soundfontPath = "soundfontPath"
        static let mt32RomDir = "mt32RomDir"
        static let useControllers = "useControllers"
        static let fetchMetadataOnImport = "fetchMetadataOnImport"
    }

    static var defaultLibraryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/DOSCrate Library", directoryHint: .isDirectory)
    }

    @ObservationIgnored private let defaults: UserDefaults

    var libraryPath: String { didSet { defaults.set(libraryPath, forKey: Key.libraryPath) } }
    var appTheme: AppTheme { didSet { defaults.set(appTheme.rawValue, forKey: Key.appTheme) } }
    var defaultPreset: Preset { didSet { defaults.set(defaultPreset.rawValue, forKey: Key.defaultPreset) } }
    var importLocation: ImportLocationPreference {
        didSet { defaults.set(importLocation.rawValue, forKey: Key.importLocation) }
    }
    var globalOverrides: GameSettings {
        didSet { defaults.set(try? JSONEncoder().encode(globalOverrides), forKey: Key.globalOverrides) }
    }
    var rawGlobalOverrides: String { didSet { defaults.set(rawGlobalOverrides, forKey: Key.rawGlobalOverrides) } }
    var soundfontPath: String { didSet { defaults.set(soundfontPath, forKey: Key.soundfontPath) } }
    var mt32RomDir: String { didSet { defaults.set(mt32RomDir, forKey: Key.mt32RomDir) } }
    var useControllers: Bool { didSet { defaults.set(useControllers, forKey: Key.useControllers) } }
    var fetchMetadataOnImport: Bool { didSet { defaults.set(fetchMetadataOnImport, forKey: Key.fetchMetadataOnImport) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        libraryPath = defaults.string(forKey: Key.libraryPath) ?? Self.defaultLibraryURL.path
        appTheme = defaults.string(forKey: Key.appTheme).flatMap(AppTheme.init(rawValue:)) ?? .dos
        defaultPreset = defaults.string(forKey: Key.defaultPreset).flatMap(Preset.init(rawValue:)) ?? .auto
        importLocation = defaults.string(forKey: Key.importLocation).flatMap(ImportLocationPreference.init(rawValue:)) ?? .ask
        globalOverrides = defaults.data(forKey: Key.globalOverrides)
            .flatMap { try? JSONDecoder().decode(GameSettings.self, from: $0) } ?? GameSettings()
        rawGlobalOverrides = defaults.string(forKey: Key.rawGlobalOverrides) ?? ""
        soundfontPath = defaults.string(forKey: Key.soundfontPath) ?? ""
        mt32RomDir = defaults.string(forKey: Key.mt32RomDir) ?? ""
        useControllers = defaults.object(forKey: Key.useControllers) as? Bool ?? true
        fetchMetadataOnImport = defaults.object(forKey: Key.fetchMetadataOnImport) as? Bool ?? true
    }

    var libraryURL: URL { URL(filePath: libraryPath, directoryHint: .isDirectory) }

    var globalConfig: GlobalConfig {
        GlobalConfig(
            defaultPreset: defaultPreset, overrides: globalOverrides, rawOverrides: rawGlobalOverrides,
            env: ConfigEnvironment(soundfontPath: soundfontPath.isEmpty ? nil : soundfontPath,
                                   mt32RomDir: mt32RomDir.isEmpty ? nil : mt32RomDir))
    }

    func launchConfig(gamepads: [GamepadInfo]) -> GlobalConfig {
        var c = globalConfig
        let detected = LayoutSelector.select(gamepads)
        c.detectedControllerLayout = detected
        c.controllerLayout = useControllers ? detected : nil
        return c
    }
}
