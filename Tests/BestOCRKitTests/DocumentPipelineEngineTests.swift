import Foundation
import Testing
@testable import BestOCRKit

/// Phase 3 of the document-assembly spec: the two assembly engines.
///
/// The embedded Python is tested as Python — compiled, and its block mapping
/// driven against a fixture marker JSON — so the adapter logic is covered on a
/// machine where neither marker nor paddleocr is installed. The live end-to-end
/// runs stay opt-in, as the surya integration test already does.
struct DocumentPipelineEngineTests {
    // MARK: - Wiring

    @Test func wiringIdentitiesAndHonestCapabilities() {
        let paddle = DocumentPipelineEngine.paddleOCRPipeline()
        let marker = DocumentPipelineEngine.marker()
        #expect(paddle.id == "doc.paddleocr-pipeline")
        #expect(marker.id == "doc.marker")
        #expect(paddle.family == .documentPipeline)
        #expect(marker.family == .documentPipeline)
        // Spec §8: paddle gets fullStructure, marker only readingOrder.
        #expect(paddle.capabilities.assembly == .fullStructure)
        #expect(marker.capabilities.assembly == .readingOrder)
        // marker earns its place on math; paddle does not claim LaTeX.
        #expect(marker.capabilities.outputLevel == .mathMarkdown)
        #expect(paddle.capabilities.outputLevel == .markdown)
        // The cost travels with the engine, never only in a changelog.
        #expect(paddle.tradeoff.contains("CPU-only"))
        #expect(marker.tradeoff.contains("balanced"))
    }

    /// Whether the adapter may report warm per-page seconds is a property of the
    /// tool, not a preference — see `AssembleInvocation`.
    @Test func invocationModeMatchesWhatEachToolCanHonestlyMeasure() {
        #expect(DocumentPipelineEngine.paddleOCRPipeline().invocation == .wholeDocument)
        #expect(DocumentPipelineEngine.marker().invocation == .perPage)
    }

    @Test func standardRosterIncludesBothAssemblyEnginesAfterThePerPageOnes() {
        let ids = EngineRegistry.standard().engines.map(\.id)
        let paddle = try! #require(ids.firstIndex(of: "doc.paddleocr-pipeline"))
        let marker = try! #require(ids.firstIndex(of: "doc.marker"))
        let lastVLM = try! #require(ids.lastIndex { $0.hasPrefix("vlm.") })
        let firstCloud = try! #require(ids.firstIndex { $0.hasPrefix("cloud.") })
        #expect(lastVLM < paddle && paddle < marker && marker < firstCloud)
    }

    // MARK: - Result assembly (host side)

    static func request(pageNumbers: [Int]) -> OCRRequest {
        OCRRequest(pages: pageNumbers.map {
            PageImage(pageNumber: $0, url: URL(fileURLWithPath: "/tmp/p\($0).png"))
        }, languages: [], dpi: 200, docType: "multicolumn_scan")
    }

    static func reply(_ json: String) throws -> DocumentPipelineEngine.AssembleReply {
        try JSONDecoder().decode(DocumentPipelineEngine.AssembleReply.self,
                                from: Data(json.utf8))
    }

    /// A `--pages 3-4` run hands the adapter two images; the adapter calls them
    /// 1 and 2, and the host must put the real page numbers back.
    @Test func adapterPageIndicesAreRemappedToRealPageNumbers() throws {
        let engine = DocumentPipelineEngine.paddleOCRPipeline()
        let reply = try Self.reply("""
        {"protocol":1,"load_seconds":9.5,
         "pages":[{"page":1,"text":"alpha","seconds":2.0},
                  {"page":2,"text":"beta","seconds":3.0}],
         "blocks":[{"page":1,"kind":"paragraph","text":"alpha"},
                   {"page":2,"kind":"paragraph","text":"beta"}]}
        """)
        let result = try engine.wholeDocumentResult(reply: reply,
                                                    request: Self.request(pageNumbers: [3, 4]))
        #expect(result.pages.map(\.page) == [3, 4])
        #expect(result.document?.blocks.map(\.page) == [3, 4])
        #expect(result.document?.loadSeconds == 9.5)
        // Load time must NOT be smuggled into page timing: schema.md defines
        // speed.ms_per_page@v1 as warm.
        #expect(result.pages.map(\.seconds) == [2.0, 3.0])
    }

    /// Whole-document mode is the only mode where the adapter can time pages
    /// warm; if it does not, the host refuses rather than dividing a total.
    @Test func missingWarmSecondsIsRefusedNotImputed() throws {
        let engine = DocumentPipelineEngine.paddleOCRPipeline()
        let reply = try Self.reply("""
        {"protocol":1,"pages":[{"page":1,"text":"x"}],
         "blocks":[{"page":1,"kind":"paragraph","text":"x"}]}
        """)
        #expect(throws: OCREngineError.self) {
            try engine.wholeDocumentResult(reply: reply,
                                           request: Self.request(pageNumbers: [1]))
        }
    }

    /// A dropped page would read as a shorter document, not as a failure.
    @Test func aMissingPageRecordIsAnError() throws {
        let engine = DocumentPipelineEngine.paddleOCRPipeline()
        let reply = try Self.reply("""
        {"protocol":1,"pages":[{"page":1,"text":"x","seconds":1.0}],
         "blocks":[{"page":1,"kind":"paragraph","text":"x"}]}
        """)
        #expect(throws: OCREngineError.self) {
            try engine.wholeDocumentResult(reply: reply,
                                           request: Self.request(pageNumbers: [1, 2]))
        }
    }

    @Test func outOfRangePageIndexIsAnError() throws {
        let engine = DocumentPipelineEngine.paddleOCRPipeline()
        let reply = try Self.reply("""
        {"protocol":1,"pages":[{"page":7,"text":"x","seconds":1.0}],
         "blocks":[]}
        """)
        #expect(throws: OCREngineError.self) {
            try engine.wholeDocumentResult(reply: reply,
                                           request: Self.request(pageNumbers: [1]))
        }
    }

    /// Spec §4.3 enforcement: an adapter whose blocks lost a line must not ship
    /// a plausible-looking transcript with a hole in it.
    @Test func invariantViolationFailsLoudly() throws {
        let engine = DocumentPipelineEngine.paddleOCRPipeline()
        let reply = try Self.reply("""
        {"protocol":1,"pages":[{"page":1,"text":"kept\\nlost","seconds":1.0}],
         "blocks":[{"page":1,"kind":"paragraph","text":"kept"}]}
        """)
        #expect(throws: OCREngineError.self) {
            try engine.wholeDocumentResult(reply: reply,
                                           request: Self.request(pageNumbers: [1]))
        }
    }

    @Test func bboxSurvivesIntoTheStructure() throws {
        let engine = DocumentPipelineEngine.paddleOCRPipeline()
        let reply = try Self.reply("""
        {"protocol":1,"pages":[{"page":1,"text":"x","seconds":1.0}],
         "blocks":[{"page":1,"kind":"table","text":"x",
                    "bbox":{"x":0.1,"y":0.2,"width":0.3,"height":0.4}}]}
        """)
        let result = try engine.wholeDocumentResult(reply: reply,
                                                    request: Self.request(pageNumbers: [1]))
        let block = try #require(result.document?.blocks.first)
        #expect(block.kind == .table)
        #expect(block.bbox == BoundingBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
    }

    // MARK: - The embedded Python, tested as Python

    static func materialize(_ tool: String) throws -> URL {
        let content = try #require(DocumentAdapterScripts.script(for: tool))
        let url = try Fixtures.tempDir().appendingPathComponent("\(tool)-adapter.py")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test(arguments: ["marker", "paddleocr-pipeline"])
    func embeddedAdapterIsValidPython(tool: String) throws {
        guard let python = AdapterProtocolV1.locatePython() else {
            print("SKIP: no python3 to compile the adapter with")
            return
        }
        let script = try Self.materialize(tool)
        let run = try Subprocess.run(python, arguments: ["-m", "py_compile", script.path],
                                    timeout: 60)
        #expect(run.exitCode == 0, "\(tool) adapter failed to compile: \(run.stderr)")
    }

    @Test(arguments: ["marker", "paddleocr-pipeline"])
    func embeddedAdapterProbeSpeaksTheProtocol(tool: String) throws {
        guard let python = AdapterProtocolV1.locatePython() else {
            print("SKIP: no python3")
            return
        }
        let script = try Self.materialize(tool)
        let run = try Subprocess.run(python, arguments: [script.path, "probe"], timeout: 60)
        // A probe never fails: absence is reported as a value (spec §5.1).
        #expect(run.exitCode == 0)
        let data = try #require(AdapterProtocolV1.lastJSONLine(run.stdout))
        let reply = try JSONDecoder().decode(AdapterProtocolV1.ProbeReply.self, from: data)
        #expect(reply.protocol == 1)
        if !reply.ok { #expect(reply.reason?.isEmpty == false) }
    }

    /// Drives the marker adapter's own block mapping against a fixture shaped
    /// like marker 2.0's JSON renderer output — so KIND_MAP, the math handling
    /// that justifies admitting marker at all, table-HTML passthrough, and bbox
    /// normalization are all covered without marker installed.
    @Test func markerAdapterMapsBlocksMathAndGeometry() throws {
        guard let python = AdapterProtocolV1.locatePython() else {
            print("SKIP: no python3")
            return
        }
        let script = try Self.materialize("marker")
        let driver = script.deletingLastPathComponent().appendingPathComponent("drive.py")
        try #"""
        import importlib.util, json, sys
        spec = importlib.util.spec_from_file_location("adapter", sys.argv[1])
        adapter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(adapter)
        page = {
            "block_type": "Page", "bbox": [0, 0, 100, 200], "children": [
                {"block_type": "PageHeader", "bbox": [0, 0, 100, 20],
                 "html": "<p>EXAM 2025</p>", "children": None},
                {"block_type": "TextInlineMath", "bbox": [0, 30, 100, 60],
                 "html": "<p>Let <math>x^2</math> be</p>", "children": None},
                {"block_type": "Table", "bbox": [0, 70, 100, 120],
                 "html": "<table><tr><td>a</td></tr></table>", "children": None},
                {"block_type": "Equation", "bbox": [0, 130, 100, 160],
                 "html": "<p><math display=\"block\">E=mc^2</math></p>", "children": None},
                {"block_type": "Marginalia", "bbox": [0, 170, 100, 190],
                 "html": "<p>note</p>", "children": None},
            ],
        }
        out = []
        adapter.leaf_blocks(page, page["bbox"], out)
        print(json.dumps(out))
        """#.write(to: driver, atomically: true, encoding: .utf8)

        let run = try Subprocess.run(python, arguments: [driver.path, script.path], timeout: 60)
        #expect(run.exitCode == 0, "\(run.stderr)")
        struct Block: Decodable {
            let kind: String
            let text: String
            let bbox: BoundingBox?
        }
        let data = try #require(run.stdout.split(separator: "\n").last.map { Data($0.utf8) })
        let blocks = try JSONDecoder().decode([Block].self, from: data)

        #expect(blocks.map(\.kind) == ["header", "paragraph", "table", "formula", "other"])
        // Inline math becomes $…$ and display math $$…$$ — marker's LaTeX is the
        // reason this engine is admitted, so it must not be stripped with the tags.
        #expect(blocks[1].text == "Let $x^2$ be")
        #expect(blocks[3].text == "$$E=mc^2$$")
        // Tables keep native HTML rather than a lossy markdown conversion.
        #expect(blocks[2].text == "<table><tr><td>a</td></tr></table>")
        // Geometry is normalized against the page box: y 0…20 of 200 → height 0.1.
        let header = try #require(blocks[0].bbox)
        #expect(header.width == 1.0)
        #expect(abs(header.height - 0.1) < 1e-9)
        // An unmapped upstream label degrades to `other`, never crashes.
        #expect(blocks[4].kind == "other")
    }

    // MARK: - Live integration (opt-in: models are GBs and runs are minutes)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BESTOCR_TEST_DOCPIPELINE"] != nil),
          arguments: [DocumentPipelineEngine.marker(),
                      DocumentPipelineEngine.paddleOCRPipeline()])
    func assemblyEngineRunsEndToEnd(engine: DocumentPipelineEngine) async throws {
        guard case .available = await engine.probe() else {
            print("SKIP: \(engine.id) unavailable on this machine")
            return
        }
        let img = try Fixtures.textImage("HELLO 42")
        let result = try await engine.recognize(OCRRequest(
            pages: [PageImage(pageNumber: 1, url: img)], languages: ["en"],
            docType: "scanned_doc"))
        #expect(result.document != nil)
        #expect(result.documentContentMatchesPages)
        #expect(result.pages[0].text.uppercased().contains("HELLO"))
    }
}
