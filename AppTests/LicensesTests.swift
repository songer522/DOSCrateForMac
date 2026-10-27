import Foundation
import Testing
@testable import DOSCrate

@MainActor
struct LicensesTests {
    private var licensesURL: URL {
        Bundle(for: AppModel.self).resourceURL!.appending(path: "Licenses", directoryHint: .isDirectory)
    }

    @Test func licensesIncludeStagingGPL() throws {
        let files = LicenseFile.all(in: licensesURL)
        let texts = files.compactMap { try? String(contentsOf: $0.url, encoding: .utf8) }
        #expect(texts.contains { $0.contains("GNU GENERAL PUBLIC LICENSE") && $0.contains("Version 2") })
    }

    @Test func licensesIncludeOwnAndSparkle() {
        let names = LicenseFile.all(in: licensesURL).map(\.name)
        #expect(names.contains("DOSCrate-MIT.txt"))
        #expect(names.contains("Sparkle-LICENSE.txt"))
    }
}
