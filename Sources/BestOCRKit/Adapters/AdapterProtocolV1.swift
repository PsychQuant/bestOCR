import Foundation

/// The parts of OCR protocol v1 (spec §5.4) shared by every adapter-backed
/// engine: locating python, materializing the embedded script, reading the one
/// JSON reply, and probing.
///
/// Extracted when document-assembly engines arrived. A second copy of the
/// protocol would be a second place for it to drift — and the host's whole
/// bargain with adapters is that the *protocol* is the host's, while the tool's
/// quirks stay in the script.
enum AdapterProtocolV1 {
    static let supportedProtocols: Set<Int> = [1]

    /// `BESTOCR_PYTHON` env override, else `python3` from PATH.
    static func locatePython() -> URL? {
        if let override = ProcessInfo.processInfo.environment["BESTOCR_PYTHON"] {
            return FileManager.default.isExecutableFile(atPath: override)
                ? URL(fileURLWithPath: override) : nil
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in pathDirs {
            let candidate = "\(dir)/python3"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Protocol reads exactly one JSON object: the LAST stdout line that
    /// parses as JSON (download noise above it is ignored).
    static func lastJSONLine(_ stdout: String) -> Data? {
        for line in stdout.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            let data = Data(trimmed.utf8)
            if (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
        }
        return nil
    }

    /// Materializes an embedded adapter script (single-binary distribution,
    /// M3): written to `BESTOCR_ADAPTER_DIR` or `~/.bestocr/adapters/`, and
    /// rewritten whenever the on-disk copy differs from the embedded source.
    static func materialize(_ content: String, tool: String) -> URL? {
        let dirPath = ProcessInfo.processInfo.environment["BESTOCR_ADAPTER_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".bestocr/adapters").path
        let dir = URL(fileURLWithPath: dirPath)
        let url = dir.appendingPathComponent("bestocr-\(tool)-adapter.py")
        if (try? String(contentsOf: url, encoding: .utf8)) != content {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
        }
        return url
    }

    struct ProbeReply: Decodable {
        let `protocol`: Int
        let ok: Bool
        let tool: String?
        let version: String?
        let reason: String?
        /// sys.executable of the interpreter that answered (#37); absent on
        /// older adapters — absence decodes as nil (= unrecorded).
        let interpreter: String?
    }

    /// Absence is a value, never an exception (spec §5.1/§8) — every failure
    /// mode returns `.unavailable` with an actionable hint.
    static func probe(python: URL, script: URL, tool: String,
                      installHint: String) -> EngineAvailability {
        let run: Subprocess.Result
        do {
            run = try Subprocess.run(python, arguments: [script.path, "probe"], timeout: 60)
        } catch {
            return .unavailable(reason: "probe failed: \(error.localizedDescription)",
                                installHint: installHint)
        }
        guard run.exitCode == 0,
              let data = lastJSONLine(run.stdout),
              let reply = try? JSONDecoder().decode(ProbeReply.self, from: data) else {
            let tail = run.stderr.suffix(200).trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(reason: "probe exited \(run.exitCode) without a protocol reply\(tail.isEmpty ? "" : ": \(tail)")",
                                installHint: installHint)
        }
        guard supportedProtocols.contains(reply.protocol) else {
            return .unavailable(reason: "unsupported adapter protocol v\(reply.protocol)",
                                installHint: nil)
        }
        guard reply.ok else {
            return .unavailable(reason: reply.reason ?? "tool import failed",
                                installHint: installHint)
        }
        return .available
    }

    /// The adapter's own tool version, from the same `probe` reply that
    /// `probe(python:script:tool:installHint:)` uses for availability.
    ///
    /// Always `.adapterReported`: the adapter states its version, and bestOCR
    /// has no way to confirm the value was read from the interpreter that will
    /// actually run — a machine can hold several installs of the same package
    /// under different interpreters. Labelling it is honest; treating it as
    /// verified would not be.
    static func probeVersion(python: URL, script: URL, tool: String) -> EngineVersion {
        guard let run = try? Subprocess.run(python, arguments: [script.path, "probe"],
                                            timeout: 60),
              run.exitCode == 0,
              let data = lastJSONLine(run.stdout),
              let reply = try? JSONDecoder().decode(ProbeReply.self, from: data),
              reply.ok,
              let version = reply.version, !version.isEmpty else {
            return .unavailable
        }
        return .single(reply.tool ?? tool, version, resolution: .adapterReported,
                       interpreter: reply.interpreter)
    }
}
