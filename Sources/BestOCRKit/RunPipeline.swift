import Foundation

/// Result of one CLI/MCP run: where the outputs landed + the full OCRResult.
public struct RunSummary: Sendable {
    /// One entry per engine tried in auto mode; `failure == nil` on the
    /// engine that succeeded. Explicit-engine runs carry a single entry.
    public struct Attempt: Sendable {
        public let engineID: String
        public let failure: String?
    }

    public let runID: String
    public let outputMarkdown: URL
    public let outputMeta: URL
    public let result: OCRResult
    public let attempts: [Attempt]
}

/// The shared run flow (spec §6, §7): probe → normalize → recognize → write
/// outputs → append run log. CLI and MCP are thin shells over this.
public enum RunPipeline {
    /// Explicit-engine run — no fallback (the user chose; spec §8 scopes the
    /// fallback chain to auto mode).
    public static func execute(inputPath: String, engineID: String, dpi: Double,
                               pageSpec: String, languages: [String], docType: String,
                               outDir: URL, registry: EngineRegistry,
                               runLog: RunLog) async throws -> RunSummary {
        guard let engine = registry.engine(id: engineID) else {
            let valid = registry.engines.map(\.id).joined(separator: ", ")
            throw OCREngineError(engine: engineID,
                                 message: "unknown engine — valid ids: \(valid)")
        }
        if case .unavailable(let reason, let hint) = await engine.probe() {
            var message = "unavailable: \(reason)"
            if let hint { message += " — install: \(hint)" }
            throw OCREngineError(engine: engineID, message: message)
        }

        let normalized = try InputNormalizer.normalize(
            inputPath: inputPath, dpi: dpi, pageSpec: pageSpec, workDir: nil)
        defer { normalized.cleanup() }

        let request = OCRRequest(pages: normalized.pages, languages: languages,
                                 dpi: normalized.dpi, docType: docType)
        let result = try await engine.recognize(request)
        return try writeOutputs(result: result, inputPath: inputPath, outDir: outDir,
                                runLog: runLog,
                                attempts: [RunSummary.Attempt(engineID: engineID, failure: nil)])
    }

    /// Auto mode (spec §7/§8): candidates in Recommender order, fallback past
    /// unavailable or failing engines, every hop recorded. All-fail is loud.
    public static func executeAuto(inputPath: String, dpi: Double, pageSpec: String,
                                   languages: [String], docType: String,
                                   priority: WorkloadSpec.Priority, needsMath: Bool,
                                   outDir: URL, registry: EngineRegistry,
                                   evidence: EvidenceStore,
                                   runLog: RunLog) async throws -> RunSummary {
        let selection = AutoRouter.candidates(docType: docType, languages: languages,
                                              priority: priority, needsMath: needsMath,
                                              registry: registry, evidence: evidence)
        guard !selection.candidateIDs.isEmpty else {
            throw OCREngineError(engine: "auto",
                                 message: "no engine matches this workload (doc-type \(docType), math=\(needsMath), languages \(languages))")
        }

        let normalized = try InputNormalizer.normalize(
            inputPath: inputPath, dpi: dpi, pageSpec: pageSpec, workDir: nil)
        defer { normalized.cleanup() }
        let request = OCRRequest(pages: normalized.pages, languages: languages,
                                 dpi: normalized.dpi, docType: docType)

        var attempts: [RunSummary.Attempt] = []
        for candidateID in selection.candidateIDs {
            guard let engine = registry.engine(id: candidateID) else { continue }
            if case .unavailable(let reason, _) = await engine.probe() {
                attempts.append(.init(engineID: candidateID, failure: "unavailable: \(reason)"))
                continue
            }
            do {
                let result = try await engine.recognize(request)
                attempts.append(.init(engineID: candidateID, failure: nil))
                return try writeOutputs(result: result, inputPath: inputPath,
                                        outDir: outDir, runLog: runLog, attempts: attempts)
            } catch let error as OCREngineError {
                attempts.append(.init(engineID: candidateID,
                                      failure: error.errorDescription ?? error.message))
            } catch {
                attempts.append(.init(engineID: candidateID,
                                      failure: String(describing: error)))
            }
        }
        let trail = attempts.map { "\($0.engineID): \($0.failure ?? "?")" }
            .joined(separator: "; ")
        throw OCREngineError(engine: "auto",
                             message: "every candidate failed — \(trail)")
    }

    /// Shared output path so explicit and auto runs can never diverge.
    private static func writeOutputs(result: OCRResult, inputPath: String, outDir: URL,
                                     runLog: RunLog,
                                     attempts: [RunSummary.Attempt]) throws -> RunSummary {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let stem = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent
        let mdURL = outDir.appendingPathComponent("\(stem).md")
        let combined = result.pages.map(\.text).joined(separator: "\n\n---\n\n")
        try combined.write(to: mdURL, atomically: true, encoding: .utf8)

        let metaURL = outDir.appendingPathComponent("\(stem).meta.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: metaURL)

        let entry = RunLogEntry(from: result, input: inputPath, output: mdURL.path)
        try runLog.append(entry)
        return RunSummary(runID: entry.id, outputMarkdown: mdURL,
                          outputMeta: metaURL, result: result, attempts: attempts)
    }
}
