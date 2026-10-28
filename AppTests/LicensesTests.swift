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

    @Test func noticeUsesLockedStagingVersionAndContact() throws {
        let lock = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/staging.lock")
        let line = try #require(try String(contentsOf: lock, encoding: .utf8)
            .split(separator: "\n").first { $0.hasPrefix("STAGING_VERSION=") })
        #expect(StagingRelease.version == String(line.dropFirst("STAGING_VERSION=".count)))
        #expect(LicensesView.notice.contains("Staging \(StagingRelease.version)"))
        #expect(LicensesView.notice.contains(StagingRelease.tagURL))
        #expect(LicensesView.notice.contains(LicensesView.sourceOfferContact))
    }

    @Test func licensesIncludeOwnAndSparkle() {
        let names = LicenseFile.all(in: licensesURL).map(\.name)
        #expect(names.contains("DOSCrate-MIT.txt"))
        #expect(names.contains("Sparkle-LICENSE.txt"))
    }

    @Test func licensesIncludeTheFont() {
        let names = LicenseFile.all(in: licensesURL).map(\.name)
        #expect(names.contains { $0.contains("Fonts/PxPlus-IBM-VGA") })
        #expect(LicensesView.notice.contains("PxPlus IBM VGA"))
    }
}
