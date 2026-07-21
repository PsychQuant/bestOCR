import Foundation
import Testing
@testable import BestOCRMCPCore

struct JobRegistryTests {
    @Test func lifecycleRunningToDone() async throws {
        let registry = JobRegistry()
        let id = await registry.start { "RESULT" }
        let outcome = await registry.awaitResult(id, cap: .seconds(5))
        #expect(outcome == .result("RESULT"))
        #expect(await registry.status(id) == .done)
    }

    @Test func failureCarriesTypedMessage() async {
        let registry = JobRegistry()
        let id = await registry.start { throw JobError("engine exploded") }
        let outcome = await registry.awaitResult(id, cap: .seconds(5))
        #expect(outcome == .failed("engine exploded"))
    }

    @Test func unknownJobIsUnknown() async {
        let registry = JobRegistry()
        #expect(await registry.awaitResult("nope", cap: .milliseconds(50)) == .unknown)
        #expect(await registry.status("nope") == nil)
    }

    @Test func evictionBoundsRegistry() async throws {
        let clock = TestClock()
        let registry = JobRegistry(retention: 300, now: { clock.now() })
        let id = await registry.start { "x" }
        _ = await registry.awaitResult(id, cap: .seconds(5))
        clock.advance(by: 301)
        _ = await registry.start { "y" }     // sweep runs on start
        #expect(await registry.count == 1)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var base = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return base }
    func advance(by seconds: TimeInterval) { lock.lock(); base += seconds; lock.unlock() }
}
