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
        let lines = try String(contentsOf: lock, encoding: .utf8).split(separator: "\n")
        let line = try #require(lines.first { $0.hasPrefix("STAGING_VERSION=") })
        #expect(StagingRelease.version == String(line.dropFirst("STAGING_VERSION=".count)))
        #expect(LicensesView.sourceOfferContact == "https://github.com/songer522/DOSCrateForMac")
        #expect(LicensesView.notice.contains("Staging \(StagingRelease.version)"))
        #expect(LicensesView.notice.contains(StagingRelease.tagURL))
        #expect(LicensesView.notice.contains(LicensesView.sourceOfferContact))

        for key in ["GLIB_VERSION=", "GLIB_SOURCE_SHA256=", "GETTEXT_VERSION=", "GETTEXT_SOURCE_SHA256="] {
            let entry = try #require(lines.first { $0.hasPrefix(key) })
            #expect(!entry.dropFirst(key.count).isEmpty)
        }
    }

    @Test func sparkleRequiresBothFeedURLAndPublicKey() {
        #expect(!DOSCrateApp.isSparkleConfigured(info: nil))
        #expect(!DOSCrateApp.isSparkleConfigured(info: [:]))
        #expect(!DOSCrateApp.isSparkleConfigured(info: ["SUFeedURL": "https://example.com/appcast.xml"]))
        #expect(!DOSCrateApp.isSparkleConfigured(info: ["SUPublicEDKey": "abc123"]))
        #expect(!DOSCrateApp.isSparkleConfigured(info: ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "   "]))
        #expect(DOSCrateApp.isSparkleConfigured(info: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "ed25519-public-key",
        ]))
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

    @Test func licensesIncludeLaunchBoxCredit() {
        #expect(LicensesView.notice.contains("Game information and images from the LaunchBox Games Database"))
    }
}
