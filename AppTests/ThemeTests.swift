import Foundation
import Testing
@testable import DOSCrate

@MainActor
struct ThemeTests {
    @Test func themeDefaultsToDOS() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        #expect(Preferences(defaults: d).appTheme == .dos)
    }

    @Test func themeRoundTrips() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let prefs = Preferences(defaults: d)
        prefs.appTheme = .standard
        #expect(Preferences(defaults: d).appTheme == .standard)
        prefs.appTheme = .dos
        #expect(Preferences(defaults: d).appTheme == .dos)
    }

    @Test func unknownThemeReadsAsDOS() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        d.set("amiga", forKey: "appTheme")
        #expect(Preferences(defaults: d).appTheme == .dos)
    }

    @Test func layoutFollowsTheme() {
        #expect(LibraryLayout(theme: .standard) == .standard)
        #expect(LibraryLayout(theme: .dos) == .retro)
    }
}
