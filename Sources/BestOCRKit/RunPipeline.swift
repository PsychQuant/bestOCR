import Foundation

/// Result of one CLI/MCP run: where the outputs landed + the full OCRResult.
public struct RunSummary: Sendable {
    public let runID: String
    public let outputMarkdown: URL
    public let outputMeta: URL
    public let result: OCRResult
}

/// The shared run flow (spec §6, §7): probe → normalize → recognize → write
/// outputs → append run log. CLI and (M3) MCP are thin shells over this.
public enum RunPipeline {
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
                          outputMeta: metaURL, result: result)
    }
}
