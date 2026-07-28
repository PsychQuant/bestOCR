import Foundation
import Testing
@testable import BestOCRKit

/// Phase 4 of the document-assembly spec: the document-class query axis and the
/// routing rule. Two properties matter equally — that an assembly-needing class
/// stops selecting engines that structurally cannot do the job, and that the
/// classes which existed before this change select **exactly** what they did
/// before.
struct DocumentClassRoutingTests {
    struct AssemblyStub: OCREngine {
        let id: String
        let assembly: AssemblyCapability
        let family = EngineFamily.documentPipeline
        var capabilities: EngineCapabilities {
            EngineCapabilities(outputLevel: .markdown, languages: ["en"],
                               needsNetwork: false, memoryClass: .heavy,
                               assembly: assembly)
        }
        func probe() async -> EngineAvailability { .available }
        func recognize(_ request: OCRRequest) async throws -> OCRResult {
            throw OCREngineError(engine: id, message: "stub")
        }
    }

    let registry = EngineRegistry(engines: [
        StubEngine(id: "vision", availability: .available, text: "x"),
        StubEngine(id: "vlm.glm-ocr", availability: .available, text: "x",
                   outputLevel: .mathMarkdown),
        AssemblyStub(id: "doc.paddleocr-pipeline", assembly: .fullStructure),
        AssemblyStub(id: "doc.marker", assembly: .readingOrder),
    ])

    func candidates(_ documentClass: DocumentClass) -> [String] {
        Recommender.recommend(
            workload: WorkloadSpec(docType: "scanned_doc", documentClass: documentClass),
            registry: registry, evidence: EvidenceStore(rows: [])).entries.map(\.engineID)
    }

    // MARK: - The rule (spec §7.3)

    @Test(arguments: [DocumentClass.multiColumn, .tabular, .mixed])
    func assemblyNeedingClassesExcludePerPageEngines(documentClass: DocumentClass) {
        #expect(candidates(documentClass) == ["doc.paddleocr-pipeline", "doc.marker"])
    }

    /// The pre-existing behaviour must be byte-identical, not merely similar —
    /// this axis is opt-in and defaulted for exactly that reason.
    @Test(arguments: [DocumentClass.unspecified, .singleColumn])
    func nonAssemblyClassesLeaveSelectionUnchanged(documentClass: DocumentClass) {
        let withAxis = candidates(documentClass)
        let withoutAxis = Recommender.recommend(
            workload: WorkloadSpec(docType: "scanned_doc"),
            registry: registry, evidence: EvidenceStore(rows: [])).entries.map(\.engineID)
        #expect(withAxis == withoutAxis)
        // Assembly engines are not *excluded* from the unconstrained classes —
        // they are simply not required.
        #expect(withAxis.contains("vision"))
        #expect(withAxis.contains("doc.marker"))
    }

    /// `tabular` requires assembly, not `.fullStructure`. marker does produce
    /// table blocks — less reliably — and a capability filter that dropped it
    /// would be making a *quality* judgement with no evidence behind it. The
    /// quality difference is carried by the tradeoff label instead.
    @Test func tabularDoesNotSilentlyDropTheWeakerAssemblyEngine() {
        #expect(candidates(.tabular).contains("doc.marker"))
    }

    @Test func documentClassCombinesWithTheExistingMathFilter() {
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "scanned_doc", needsMath: true,
                                   documentClass: .multiColumn),
            registry: registry, evidence: EvidenceStore(rows: []))
        // Only an engine that is BOTH math-aware and assembling survives; the
        // markdown-only paddle stub is not, so nothing does here.
        #expect(answer.entries.isEmpty)
    }

    /// No assembly engine at all → an honest empty answer, never a per-page
    /// engine quietly substituted for one that can do reading order.
    @Test func withoutAnyAssemblyEngineTheAnswerIsEmptyNotSubstituted() {
        let perPageOnly = EngineRegistry(engines: [
            StubEngine(id: "vision", availability: .available, text: "x"),
        ])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "scanned_doc", documentClass: .multiColumn),
            registry: perPageOnly, evidence: EvidenceStore(rows: []))
        #expect(answer.entries.isEmpty)
        #expect(answer.mode == .evidencePending)
    }

    // MARK: - Cost surfacing (spec §7.3 requirement 1)

    @Test func routingNoticeStatesTheSpeedCostWhenTheClassForcesAssembly() {
        let selection = AutoRouter.candidates(
            docType: "scanned_doc", languages: [], priority: .balanced, needsMath: false,
            documentClass: .multiColumn, registry: registry, evidence: EvidenceStore(rows: []))
        let notice = try! #require(selection.notice)
        #expect(notice.contains("multi_column"))
        // A correctness win must not be printed without its cost.
        #expect(notice.lowercased().contains("slower"))
    }

    @Test func noNoticeWhenNothingWasConstrained() {
        for documentClass in [DocumentClass.unspecified, .singleColumn] {
            let selection = AutoRouter.candidates(
                docType: "scanned_doc", languages: [], priority: .balanced,
                needsMath: false, documentClass: documentClass,
                registry: registry, evidence: EvidenceStore(rows: []))
            #expect(selection.notice == nil)
        }
    }

    // MARK: - Tradeoff labels (phase 5)

    /// `tradeoffNote` is a protocol REQUIREMENT with a default, not an
    /// extension-only member. As the latter it would statically dispatch to
    /// `nil` through `any OCREngine` and silently hide every label — the label
    /// would exist in the type and never reach a user.
    @Test func tradeoffReachesThroughTheExistential() {
        let engines: [any OCREngine] = [
            DocumentPipelineEngine.marker(),
            StubEngine(id: "vision", availability: .available, text: "x"),
        ]
        #expect(engines[0].tradeoffNote?.isEmpty == false)
        #expect(engines[1].tradeoffNote == nil)
    }

    /// Every place an engine is offered carries its cost — including the
    /// evidence-pending listing, which is where a brand-new engine will spend
    /// most of its life.
    @Test func recommendNotesCarryTheTradeoffForAssemblyEnginesOnly() {
        let mixedRegistry = EngineRegistry(engines: [
            StubEngine(id: "vision", availability: .available, text: "x"),
            DocumentPipelineEngine.paddleOCRPipeline(),
        ])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "scanned_doc"),
            registry: mixedRegistry, evidence: EvidenceStore(rows: []))
        let vision = try! #require(answer.entries.first { $0.engineID == "vision" })
        let paddle = try! #require(answer.entries.first { $0.engineID == "doc.paddleocr-pipeline" })
        #expect(!vision.note.contains("tradeoff:"))
        #expect(paddle.note.contains("tradeoff:"))
        #expect(paddle.note.contains("CPU-only"))
        // The evidence statement itself is untouched by the label.
        #expect(paddle.note.hasPrefix("unverified — no measured rows"))
    }

    @Test func rawValuesAreTheEvidenceFriendlySnakeCaseNames() {
        #expect(DocumentClass.multiColumn.rawValue == "multi_column")
        #expect(DocumentClass.singleColumn.rawValue == "single_column")
        #expect(DocumentClass.allCases.count == 5)
    }

    /// CLI and MCP share one parser, so the two surfaces cannot drift into
    /// accepting different spellings of the same class.
    @Test func parseAcceptsWhatAPersonActuallyTypes() {
        #expect(DocumentClass.parse("multi-column") == .multiColumn)
        #expect(DocumentClass.parse("multi_column") == .multiColumn)
        #expect(DocumentClass.parse(" Multi-Column ") == .multiColumn)
        #expect(DocumentClass.parse("tabular") == .tabular)
        #expect(DocumentClass.parse("two-column") == nil)   // unknown fails loudly
    }
}
