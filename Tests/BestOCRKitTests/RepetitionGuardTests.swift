import Testing
@testable import BestOCRKit

struct RepetitionGuardTests {
    let fuse = RepetitionGuard()

    @Test func normalTextDoesNotFlag() {
        #expect(!fuse.flags("A normal page of prose with $x^2$ math and 標題 headings."))
    }

    @Test func longIdenticalCharRunFlags() {
        #expect(fuse.flags("prefix " + String(repeating: "!", count: 200) + " suffix"))
    }

    @Test func charRunBelowThresholdDoesNotFlag() {
        #expect(!fuse.flags(String(repeating: "!", count: 199)))
    }

    @Test func repeatedTokenLoopFlags() {
        // PaddleOCR-VL-style degenerate loop: same token repeated endlessly.
        let loop = Array(repeating: "the", count: 50).joined(separator: " ")
        #expect(fuse.flags(loop))
    }

    @Test func repeatedTokenBelowThresholdDoesNotFlag() {
        let ok = Array(repeating: "the", count: 49).joined(separator: " ")
        #expect(!fuse.flags(ok))
    }
}
