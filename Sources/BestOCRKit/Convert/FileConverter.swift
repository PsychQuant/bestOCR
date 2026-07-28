import Foundation

/// Markdown → target format, via an external converter. Probe-gated with an
/// install hint, exactly like every engine: absence is a value, not a crash.
///
/// Which converter runs is decided by **content**, not preference (#3): only
/// pandoc turns `$…$` into native Word OMath equations, so math-bearing markdown
/// prefers it; everything else goes to macdoc. The choice is reported, because a
/// fidelity complaint has to land on the right project.
public struct FileConverter: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case pandoc, macdoc
    }

    public struct Outcome: Sendable {
        public let kind: Kind
        public let attribution: String
    }

    /// Preference order. `forced` means the user overrode the heuristic on
    /// purpose, so it is the ONLY candidate — silently using the other tool would
    /// make the attribution in the report untrue.
    public static func order(hasMath: Bool, forced: Kind?,
                            pandocAvailable: Bool) -> [Kind] {
        if let forced { return [forced] }
        guard pandocAvailable else { return [.macdoc] }
        return hasMath ? [.pandoc, .macdoc] : [.macdoc, .pandoc]
    }

    public static func attribution(_ kind: Kind) -> String {
        switch kind {
        case .pandoc:
            return "pandoc — math pandoc recognized became native Word OMath equations"
        case .macdoc:
            return "macdoc — math stays as literal LaTeX text in the docx (install pandoc for native equations)"
        }
    }

    static func installHint(_ kind: Kind) -> String {
        switch kind {
        case .pandoc:
            return "brew install pandoc"
        case .macdoc:
            return "claude plugin marketplace add PsychQuant/macdoc && claude plugin install macdoc@macdoc"
        }
    }

    /// `BESTOCR_PANDOC` / `BESTOCR_MACDOC` override the PATH lookup.
    public static func locate(_ kind: Kind) -> URL? {
        let envKey = "BESTOCR_\(kind.rawValue.uppercased())"
        if let override = ProcessInfo.processInfo.environment[envKey] {
            return FileManager.default.isExecutableFile(atPath: override)
                ? URL(fileURLWithPath: override) : nil
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in pathDirs {
            let candidate = "\(dir)/\(kind.rawValue)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// `locate` is injectable so a test can exercise the present-but-broken
    /// converter path WITHOUT mutating the process environment — `setenv` races
    /// with the `getenv` that almost every code path here performs, and a
    /// parallel test suite wedges on it.
    public static func availability(_ kind: Kind,
                                   locate: (Kind) -> URL? = FileConverter.locate) -> EngineAvailability {
        locate(kind) != nil
            ? .available
            : .unavailable(reason: "\(kind.rawValue) not found on PATH",
                           installHint: installHint(kind))
    }

    public static func convert(_ kind: Kind, markdown: URL, target: URL,
                              timeout: TimeInterval = 300,
                              locate: (Kind) -> URL? = FileConverter.locate) throws -> Outcome {
        guard let tool = locate(kind) else {
            throw OCREngineError(engine: "convert",
                                 message: "\(kind.rawValue) not found on PATH — install: \(installHint(kind))")
        }
        let arguments: [String]
        switch kind {
        case .pandoc:
            arguments = [markdown.path, "-o", target.path]
        case .macdoc:
            // macdoc writes <stem>.docx beside the markdown; the host moves it.
            arguments = ["convert", "--to", target.pathExtension, markdown.path]
        }
        let run: Subprocess.Result
        do {
            run = try Subprocess.run(tool, arguments: arguments, timeout: timeout)
        } catch {
            throw OCREngineError(engine: "convert",
                                 message: "\(kind.rawValue): \(error.localizedDescription)")
        }
        guard run.exitCode == 0 else {
            let tail = run.stderr.suffix(400).trimmingCharacters(in: .whitespacesAndNewlines)
            throw OCREngineError(engine: "convert",
                                 message: "\(kind.rawValue) exit \(run.exitCode): \(tail)")
        }
        if kind == .macdoc {
            let produced = markdown.deletingPathExtension()
                .appendingPathExtension(target.pathExtension)
            if produced != target {
                guard FileManager.default.fileExists(atPath: produced.path) else {
                    throw OCREngineError(engine: "convert",
                                         message: "macdoc exited 0 but wrote nothing at \(produced.path)")
                }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: produced, to: target)
            }
        }
        return Outcome(kind: kind, attribution: attribution(kind))
    }
}
