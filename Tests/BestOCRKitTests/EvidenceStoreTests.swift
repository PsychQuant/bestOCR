import Foundation
import Testing
@testable import BestOCRKit

struct EvidenceStoreTests {
    static func rowJSON(model: String, tier: String, estimand: String, value: Double,
                        docType: String = "math_pdf") -> String {
        """
        {"estimand":"\(estimand)","value":\(value),"condition":{"model":"\(model)","quant":"q8_0","dpi":100,"doc_type":"\(docType)","platform":"ollama","hardware":"test","instrument":"test"},"tier":"\(tier)","source":"unit-test"}
        """
    }

    @Test func loadsJSONLAndFiltersByDocType() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rows-\(UUID().uuidString).jsonl")
        let content = [
            Self.rowJSON(model: "glm-ocr", tier: "T2", estimand: "quality.word_recall", value: 0.98),
            Self.rowJSON(model: "glm-ocr", tier: "T2", estimand: "speed.ms_per_page", value: 1981),
            Self.rowJSON(model: "vision", tier: "T2", estimand: "quality.word_recall", value: 0.91,
                         docType: "screenshot"),
        ].joined(separator: "\n")
        try content.write(to: file, atomically: true, encoding: .utf8)
        let store = try EvidenceStore.load(from: file)
        #expect(store.rows.count == 3)
        #expect(store.rows(docType: "math_pdf").count == 2)
        #expect(store.rows(docType: "screenshot").first?.condition.model == "vision")
    }

    @Test func absentFileYieldsEmptyStore() throws {
        let store = try EvidenceStore.load(
            from: URL(fileURLWithPath: "/nonexistent/rows.jsonl"))
        #expect(store.rows.isEmpty)
    }

    @Test func malformedLineThrowsWithLineNumber() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rows-\(UUID().uuidString).jsonl")
        try "not json\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: OCREngineError.self) {
            _ = try EvidenceStore.load(from: file)
        }
    }

    @Test func defaultURLHonoursEnv() {
        setenv("BESTOCR_EVIDENCE", "/tmp/custom-rows.jsonl", 1)
        defer { unsetenv("BESTOCR_EVIDENCE") }
        #expect(EvidenceStore.defaultURL().path == "/tmp/custom-rows.jsonl")
    }
}

struct EvidenceStoreResolutionTests {
    // #9: 安裝版使用者的 CWD 不在 source checkout — resolution 鏈must是
    // env override → CWD repo 檔(存在才用)→ ~/.bestocr/evidence.jsonl。
    @Test func envOverrideWins() {
        let url = EvidenceStore.resolvedURL(
            environment: ["BESTOCR_EVIDENCE": "/tmp/custom.jsonl"],
            cwd: URL(fileURLWithPath: "/nonexistent"),
            home: URL(fileURLWithPath: "/nonexistent-home"))
        #expect(url.path == "/tmp/custom.jsonl")
    }

    @Test func cwdRowsPreferredWhenPresent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("evres-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("evidence"), withIntermediateDirectories: true)
        let rows = dir.appendingPathComponent("evidence/rows.jsonl")
        try "".write(to: rows, atomically: true, encoding: .utf8)
        let url = EvidenceStore.resolvedURL(environment: [:], cwd: dir,
                                            home: URL(fileURLWithPath: "/nonexistent-home"))
        #expect(url.path == rows.path)
    }

    @Test func homeFallbackWhenCwdRowsAbsent() {
        let home = URL(fileURLWithPath: "/Users/fake-home")
        let url = EvidenceStore.resolvedURL(
            environment: [:],
            cwd: FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)"),
            home: home)
        #expect(url.path == "/Users/fake-home/.bestocr/evidence.jsonl")
    }
}
