import Foundation

/// Where one input's artifacts will be written.
public struct OutputPlan: Sendable, Equatable {
    public let input: URL
    public let markdown: URL
    public let target: URL
}

/// The output rules that used to be prose in the `ocr-to` skill (#1, #7). They
/// are here as code because prose is not enforcement: an agent that skipped the
/// "never write into the input directory" step destroyed a hand-made file, and
/// nothing failed.
public enum OutputPlanner {
    /// A sibling directory, never the input's own directory — the input's folder
    /// is exactly where a user's own `<stem>.docx` tends to sit.
    public static func defaultOutDir(for input: URL) -> URL {
        input.deletingLastPathComponent()
            .appendingPathComponent("bestocr-out", isDirectory: true)
    }

    /// Distinct output names for a batch. Colliding stems from different source
    /// folders are suffixed **symmetrically** — with only one of them renamed you
    /// cannot tell from the output which file came from where.
    public static func plan(inputs: [URL], outDir: URL,
                           targetExtension: String) -> [OutputPlan] {
        var stemCounts: [String: Int] = [:]
        for input in inputs {
            stemCounts[stem(input), default: 0] += 1
        }
        var used = Set<String>()
        var plans: [OutputPlan] = []
        for input in inputs {
            let base = stem(input)
            var name = base
            if (stemCounts[base] ?? 0) > 1 {
                let folder = input.deletingLastPathComponent().lastPathComponent
                if !folder.isEmpty, folder != "/" { name = "\(base)-\(folder)" }
            }
            // Terminating fallback: same stem AND same folder name.
            var unique = name
            var bump = 2
            while used.contains(unique) {
                unique = "\(name)-\(bump)"
                bump += 1
            }
            used.insert(unique)
            plans.append(OutputPlan(
                input: input,
                markdown: outDir.appendingPathComponent("\(unique).md"),
                target: outDir.appendingPathComponent("\(unique).\(targetExtension)")))
        }
        return plans
    }

    /// Everything a run would write that already exists. Checked for the WHOLE
    /// batch before any OCR starts, so a refusal costs seconds rather than the
    /// minutes a document pipeline takes.
    public static func existingOutputs(_ plans: [OutputPlan]) -> [URL] {
        plans.flatMap { [$0.markdown, $0.target] }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func stem(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
