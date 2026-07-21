import Testing
@testable import BestOCRMCPCore

struct SingleFlightTests {
    @Test func serializesConcurrentWork() async throws {
        let gate = SingleFlight()
        let recorder = Recorder()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    _ = try? await gate.run {
                        await recorder.enter(i)
                        try await Task.sleep(for: .milliseconds(20))
                        await recorder.exit(i)
                        return i
                    }
                }
            }
        }
        #expect(await recorder.maxConcurrent == 1)
    }

    @Test func failedOperationDoesNotWedgeQueue() async throws {
        let gate = SingleFlight()
        struct Boom: Error {}
        _ = try? await gate.run { () -> Int in throw Boom() }
        let value = try await gate.run { 42 }
        #expect(value == 42)
    }
}

actor Recorder {
    var active = 0
    var maxConcurrent = 0
    func enter(_ i: Int) { active += 1; maxConcurrent = max(maxConcurrent, active) }
    func exit(_ i: Int) { active -= 1 }
}
