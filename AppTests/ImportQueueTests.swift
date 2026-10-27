import Foundation
import Testing
@testable import DOSCrate

@MainActor
struct ImportQueueTests {
    @Test func addsAdvancesAndEmpties() {
        let queue = ImportQueue()
        #expect(queue.current == nil)
        let a = URL(filePath: "/tmp/a.zip"), b = URL(filePath: "/tmp/b.zip")
        queue.add([a, b])
        #expect(queue.current?.url == a)
        queue.add([URL(filePath: "/tmp/c.zip")])
        #expect(queue.current?.url == a)
        queue.finishCurrent()
        #expect(queue.current?.url == b)
        queue.finishCurrent()
        queue.finishCurrent()
        #expect(queue.current == nil)
        queue.finishCurrent()
        #expect(queue.current == nil)
    }
}
