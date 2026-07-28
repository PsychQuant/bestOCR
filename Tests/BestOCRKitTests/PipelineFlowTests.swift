import Foundation
import Testing
@testable import BestOCRKit

/// #24 — the end-to-end flow. Vision is always available and both converters are
/// probe-gated, so the happy path here is a real run producing a real `.docx`
/// rather than a mock of one.
///
/// `.serialized` on purpose: every test here renders a PDF fixture through
/// AppKit/CoreGraphics, runs Vision, and spawns a converter. Fanning that out
/// across the whole suite wedged the parallel run — the end-to-end suite is the
/// wrong place to buy concurrency.
@Suite(.serialized) struct PipelineFlowTests {
    static func harness() throws -> (registry: EngineRegistry, runLog: RunLog, out: URL) {
        let dir = try Fixtures.tempDir()
        return (EngineRegistry(engines: [VisionEngine()]),
                RunLog(fileURL: dir.appendingPathComponent("runlog.jsonl")),
                dir.appendingPathComponent("out", isDirectory: true))
    }

    static func run(_ inputs: [String], to format: String = "docx",
                   out: URL, registry: EngineRegistry, runLog: RunLog,
                   converter: FileConverter.Kind? = nil,
                   overwrite: Bool = false,
                   locate: (@Sendable (FileConverter.Kind) -> URL?)? = nil)
    async throws -> PipelineReport {
        try await PipelineFlow.run(
            inputs: inputs, to: format, outDir: out, engineID: "vision",
            dpi: 100, docType: "screenshot", converter: converter,
            overwrite: overwrite, locateConverter: locate ?? FileConverter.locate,
            registry: registry, evidence: EvidenceStore(rows: []), runLog: runLog)
    }

    // MARK: - Pre-flight: refuse cheaply, before minutes of OCR

    @Test func unsupportedFormatRefuses() async throws {
        let harness = try Self.harness()
        let pdf = try Fixtures.textPDF("HELLO", pages: 1)
        await #expect(throws: OCREngineError.self) {
            try await Self.run([pdf.path], to: "pptx", out: harness.out,
                              registry: harness.registry, runLog: harness.runLog)
        }
        // Nothing was written for a request that was never going to work.
        #expect(!FileManager.default.fileExists(atPath: harness.out.path))
    }

    @Test func missingInputRefuses() async throws {
        let harness = try Self.harness()
        await #expect(throws: OCREngineError.self) {
            try await Self.run(["/nonexistent/nope.pdf"], out: harness.out,
                              registry: harness.registry, runLog: harness.runLog)
        }
    }

    /// The rule that used to be prose: an existing output is never silently
    /// replaced, and the refusal happens BEFORE any OCR is spent.
    @Test func existingOutputRefusesUntilOverwriteIsGiven() async throws {
        let harness = try Self.harness()
        let pdf = try Fixtures.textPDF("HELLO", pages: 1)
        try FileManager.default.createDirectory(at: harness.out, withIntermediateDirectories: true)
        let target = harness.out.appendingPathComponent("fixture.docx")
        try "a file the user made by hand".write(to: target, atomically: true, encoding: .utf8)

        await #expect(throws: OCREngineError.self) {
            try await Self.run([pdf.path], out: harness.out,
                              registry: harness.registry, runLog: harness.runLog)
        }
        // Untouched — and no markdown was produced either, so no OCR ran.
        #expect(try String(contentsOf: target, encoding: .utf8) == "a file the user made by hand")
        #expect(!FileManager.default.fileExists(
            atPath: harness.out.appendingPathComponent("fixture.md").path))
    }

    // MARK: - Happy path (real docx)

    @Test func endToEndProducesAValidDeliverable() async throws {
        guard FileConverter.locate(.pandoc) != nil || FileConverter.locate(.macdoc) != nil else {
            print("SKIP: neither pandoc nor macdoc installed")
            return
        }
        let harness = try Self.harness()
        let pdf = try Fixtures.textPDF("HELLO", pages: 1)
        let report = try await Self.run([pdf.path], out: harness.out,
                                       registry: harness.registry, runLog: harness.runLog)
        #expect(report.failed.isEmpty)
        let item = try #require(report.succeeded.first)
        let target = try #require(item.target)
        try DocxValidator.validate(target)
        #expect(item.engineID == "vision")
        // The attribution must name the converter that actually ran, so a
        // fidelity complaint lands on the right project.
        #expect(item.converter?.isEmpty == false)
        // The run is ingestable: the pipeline did not bypass the runlog.
        #expect(item.runID?.isEmpty == false)
        let markdown = try #require(item.markdown)
        #expect(FileManager.default.fileExists(atPath: markdown.path))
    }

    @Test func overwriteReplacesAnExistingDeliverable() async throws {
        guard FileConverter.locate(.pandoc) != nil || FileConverter.locate(.macdoc) != nil else {
            print("SKIP: no converter installed")
            return
        }
        let harness = try Self.harness()
        let pdf = try Fixtures.textPDF("HELLO", pages: 1)
        try FileManager.default.createDirectory(at: harness.out, withIntermediateDirectories: true)
        let target = harness.out.appendingPathComponent("fixture.docx")
        try "stale".write(to: target, atomically: true, encoding: .utf8)

        let report = try await Self.run([pdf.path], out: harness.out,
                                       registry: harness.registry, runLog: harness.runLog,
                                       overwrite: true)
        #expect(report.failed.isEmpty)
        try DocxValidator.validate(target)   // no longer the stale text file
    }

    // MARK: - Batch behaviour

    /// Colliding stems from different folders must both survive — the second
    /// quietly overwriting the first is the bug this exists to prevent.
    @Test func batchWithCollidingStemsProducesTwoDeliverables() async throws {
        guard FileConverter.locate(.pandoc) != nil || FileConverter.locate(.macdoc) != nil else {
            print("SKIP: no converter installed")
            return
        }
        let harness = try Self.harness()
        let first = try Fixtures.textPDF("ALPHA", pages: 1)     // both named fixture.pdf,
        let second = try Fixtures.textPDF("BETA", pages: 1)     // in different temp dirs
        #expect(first.lastPathComponent == second.lastPathComponent)

        let report = try await Self.run([first.path, second.path], out: harness.out,
                                       registry: harness.registry, runLog: harness.runLog)
        #expect(report.succeeded.count == 2)
        let targets = report.succeeded.compactMap(\.target)
        #expect(Set(targets.map(\.lastPathComponent)).count == 2)
        for target in targets { try DocxValidator.validate(target) }
    }

    /// One bad input records a failure and the batch keeps going — the good file
    /// still gets delivered.
    @Test func oneFailureDoesNotAbortTheBatch() async throws {
        guard FileConverter.locate(.pandoc) != nil || FileConverter.locate(.macdoc) != nil else {
            print("SKIP: no converter installed")
            return
        }
        let harness = try Self.harness()
        let good = try Fixtures.textPDF("HELLO", pages: 1)
        // Exists, so pre-flight passes, but it is not a PDF — normalization fails.
        let broken = try Fixtures.tempDir().appendingPathComponent("broken.pdf")
        try "this is not a pdf".write(to: broken, atomically: true, encoding: .utf8)

        let report = try await Self.run([good.path, broken.path], out: harness.out,
                                       registry: harness.registry, runLog: harness.runLog)
        #expect(report.succeeded.count == 1)
        #expect(report.failed.count == 1)
        #expect(report.failed[0].failure?.isEmpty == false)
        // The good one is a real deliverable, not collateral damage.
        try DocxValidator.validate(try #require(report.succeeded[0].target))
    }

    /// Conversion failing must not throw away the OCR: the markdown is the
    /// expensive artifact and it stays on disk with the failure recorded.
    @Test func aConverterFailureKeepsTheMarkdownAndReportsHonestly() async throws {
        let harness = try Self.harness()
        let pdf = try Fixtures.textPDF("HELLO", pages: 1)
        // A converter that is "found" but cannot run — injected rather than
        // installed via setenv, which would race with every other test's getenv.
        let report = try await Self.run([pdf.path], out: harness.out,
                                       registry: harness.registry, runLog: harness.runLog,
                                       converter: .macdoc,
                                       locate: { _ in URL(fileURLWithPath: "/nonexistent/macdoc") })
        #expect(report.failed.count == 1)
        let item = report.failed[0]
        #expect(item.target == nil)
        let markdown = try #require(item.markdown)
        #expect(FileManager.default.fileExists(atPath: markdown.path))
        #expect(!item.converterHops.isEmpty)
    }
}
