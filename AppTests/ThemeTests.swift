import Foundation
import Testing
@testable import DOSCrate

@MainActor
struct ThemeTests {
    @Test func themeDefaultsToStandard() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        #expect(Preferences(defaults: d).appTheme == .standard)
    }

    @Test func themeRoundTrips() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let prefs = Preferences(defaults: d)
        prefs.appTheme = .dos
        #expect(Preferences(defaults: d).appTheme == .dos)
    }

    @Test func unknownThemeReadsAsStandard() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        d.set("amiga", forKey: "appTheme")
        #expect(Preferences(defaults: d).appTheme == .standard)
    }
}
