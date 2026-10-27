import Testing
@testable import LibraryKit

@Test func libraryKitVersion() {
    #expect(LibraryKitVersion.value == "1")
}
