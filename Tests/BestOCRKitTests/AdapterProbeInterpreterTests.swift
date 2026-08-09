import Foundation
import Testing
@testable import BestOCRKit

/// #37: adapter probes report the interpreter that answered the version query,
/// so an `adapterReported` version is traceable to its source. Traceable, not
/// verified — the adapter may still read a different interpreter than the one
/// that runs OCR; that boundary is deliberate (#36 design).
@Suite(.serialized)   // spawns python subprocesses
struct AdapterProbeInterpreterTests {

    // MARK: - ProbeReply decoding (additive optional field)

    @Test func probeReplyDecodesInterpreterField() throws {
        let json = #"{"protocol":1,"ok":true,"tool":"rapidocr","version":"3.6.0","interpreter":"/opt/venv/bin/python3"}"#
        let reply = try JSONDecoder().decode(AdapterProtocolV1.ProbeReply.self,
                                             from: Data(json.utf8))
        #expect(reply.interpreter == "/opt/venv/bin/python3")
    }

    @Test func probeReplyToleratesMissingInterpreter() throws {
        // Old adapters lack the field — absence decodes as nil (= unrecorded),
        // never an error (#28/#36 convention).
        let json = #"{"protocol":1,"ok":true,"tool":"rapidocr","version":"3.6.0"}"#
        let reply = try JSONDecoder().decode(AdapterProtocolV1.ProbeReply.self,
                                             from: Data(json.utf8))
        #expect(reply.interpreter == nil)
    }

    // MARK: - EngineVersion carries the interpreter without polluting versions

    @Test func engineVersionCarriesInterpreterSeparately() {
        let version = EngineVersion.single("rapidocr", "3.6.0",
                                           resolution: .adapterReported,
                                           interpreter: "/opt/venv/bin/python3")
        #expect(version.interpreter == "/opt/venv/bin/python3")
        // The interpreter is provenance, not a versioned component — it must
        // never leak into components or the legacy tool_version string
        // (evidence rows would grow a bogus component).
        #expect(version.components == ["rapidocr": "3.6.0"])
        #expect(version.legacyToolVersion == "rapidocr 3.6.0")
    }

    @Test func engineVersionDecodesLegacyJSONWithoutInterpreter() throws {
        let json = #"{"components":{"surya-ocr":"0.22.1"},"resolution":"adapter_reported"}"#
        let decoded = try JSONDecoder().decode(EngineVersion.self, from: Data(json.utf8))
        #expect(decoded.interpreter == nil)
        #expect(decoded.components == ["surya-ocr": "0.22.1"])
    }

    // MARK: - probeVersion end-to-end (fake adapter script)

    /// Production's resolution first (BESTOCR_PYTHON → PATH via
    /// `locatePython()`), hardcoded paths only as fallback — the test must
    /// exercise the interpreter production will actually use (R1 verify
    /// D2/R3: the hardcoded /usr/bin/python3 resolved to a DIFFERENT
    /// interpreter than production's, inverting branch coverage).
    private func systemPython() -> URL? {
        if let production = AdapterProtocolV1.locatePython() { return production }
        for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// The expected value must be SELF-REPORTED by the same python — path
    /// comparison against the invoked path is wrong (/usr/bin/python3's
    /// sys.executable resolves to the Xcode CLT shim path).
    private func expectedExecutable(of python: URL) throws -> String {
        let run = try Subprocess.run(python, arguments: ["-c", "import sys;print(sys.executable)"],
                                     timeout: 30)
        return run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func probeVersionCarriesInterpreterFromReply() throws {
        guard let python = systemPython() else { print("SKIP: no python3"); return }
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-interp-\(UUID().uuidString).py")
        defer { try? FileManager.default.removeItem(at: script) }
        try #"""
        import json, sys
        print(json.dumps({"protocol": 1, "ok": True, "tool": "faketool",
                          "version": "9.9.9", "interpreter": sys.executable}))
        """#.write(to: script, atomically: true, encoding: .utf8)

        let version = AdapterProtocolV1.probeVersion(python: python, script: script,
                                                     tool: "faketool")
        #expect(version.components == ["faketool": "9.9.9"])
        #expect(version.resolution == .adapterReported)
        // Exact match against the python's self-reported sys.executable —
        // "non-empty" let three wiring mutations survive the whole suite
        // (R1 verify D1: reply.tool 接錯、硬編碼、常數全過).
        let interpreter = try #require(version.interpreter)
        #expect(interpreter == (try expectedExecutable(of: python)))
    }

    @Test func probeVersionRejectsUnsupportedProtocol() throws {
        // R1 verify D4: probe() and recognize() both guard the protocol
        // version; probeVersion did not — a protocol-2 adapter was judged
        // unavailable for availability yet its version AND interpreter were
        // still trusted.
        guard let python = systemPython() else { print("SKIP: no python3"); return }
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-proto2-\(UUID().uuidString).py")
        defer { try? FileManager.default.removeItem(at: script) }
        try #"""
        import json, sys
        print(json.dumps({"protocol": 2, "ok": True, "tool": "faketool",
                          "version": "9.9.9", "interpreter": sys.executable}))
        """#.write(to: script, atomically: true, encoding: .utf8)
        let version = AdapterProtocolV1.probeVersion(python: python, script: script,
                                                     tool: "faketool")
        #expect(version.resolution == .unavailable)
        #expect(version.interpreter == nil)
    }

    @Test func probeVersionNormalizesEmptyInterpreterToNil() throws {
        // CPython documents sys.executable may be "" (frozen/embedded).
        // nil = unrecorded is the documented state; an empty string would
        // read as "recorded, says nothing" (R1 verify security F3b).
        guard let python = systemPython() else { print("SKIP: no python3"); return }
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-empty-\(UUID().uuidString).py")
        defer { try? FileManager.default.removeItem(at: script) }
        try #"""
        import json
        print(json.dumps({"protocol": 1, "ok": True, "tool": "faketool",
                          "version": "9.9.9", "interpreter": ""}))
        """#.write(to: script, atomically: true, encoding: .utf8)
        let version = AdapterProtocolV1.probeVersion(python: python, script: script,
                                                     tool: "faketool")
        #expect(version.resolution == .adapterReported)
        #expect(version.interpreter == nil)
    }

    @Test func engineVersionOmitsNilInterpreterKeyOnEncode() throws {
        // Pin the synthesized encodeIfPresent behavior: nil must OMIT the
        // key (byte-identical to pre-#37 JSON), never write null. Guarded
        // by compiler synthesis today; a future hand-written encode(to:)
        // would break this silently (R1 verify R6/F6).
        let version = EngineVersion.single("rapidocr", "3.6.0", resolution: .adapterReported)
        let json = String(decoding: try JSONEncoder().encode(version), as: UTF8.self)
        #expect(!json.contains("interpreter"))
        let with = EngineVersion.single("rapidocr", "3.6.0", resolution: .adapterReported,
                                        interpreter: "/opt/venv/bin/python3")
        let decoded = try JSONDecoder().decode(EngineVersion.self,
                                               from: try JSONEncoder().encode(with))
        #expect(decoded == with)
    }

    // MARK: - Every embedded adapter probe reports the interpreter

    /// The field must appear in EVERY reply the probe emits — including
    /// unavailable ones, where knowing which interpreter answered matters
    /// most (wrong-interpreter is the #37 motivating failure). Boundary,
    /// honestly stated: only `Exception` is caught — a BaseException /
    /// native abort during import produces NO reply at all, and the caller
    /// then has no interpreter (R1 verify D3); the exitCode assertion below
    /// is what would surface such a hard failure here.
    ///
    /// NOTE: this list is hand-written — a sixth adapter script will NOT
    /// turn anything red by itself; add it here when adding the script.
    @Test func allEmbeddedAdapterProbesReportInterpreter() throws {
        guard let python = systemPython() else { print("SKIP: no python3"); return }
        let expected = try expectedExecutable(of: python)
        let scripts: [(name: String, source: String)] = [
            ("rapidocr", AdapterScripts.rapidocr),
            ("cnocr", AdapterScripts.cnocr),
            ("surya", AdapterScripts.surya),
            ("marker", DocumentAdapterScripts.marker),
            ("paddleocr-pipeline", DocumentAdapterScripts.paddleOCRPipeline),
        ]
        for (name, source) in scripts {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("probe-\(name)-\(UUID().uuidString).py")
            defer { try? FileManager.default.removeItem(at: file) }
            try source.write(to: file, atomically: true, encoding: .utf8)

            // py_compile first — a syntax error would masquerade as probe failure.
            let compile = try Subprocess.run(python, arguments: ["-m", "py_compile", file.path],
                                             timeout: 60)
            #expect(compile.exitCode == 0, "\(name): py_compile failed: \(compile.stderr)")

            // Timeout matches production's probe timeout (60s) — heavy
            // imports (torch/paddle) can exceed 30s cold on machines that
            // HAVE the packages (R1 verify F8).
            let run = try Subprocess.run(python, arguments: [file.path, "probe"], timeout: 60)
            #expect(run.exitCode == 0,
                    "\(name): probe exited \(run.exitCode) — a BaseException/native abort produces no reply and loses the interpreter (D3)")
            let lastLine = run.stdout.split(separator: "\n").last.map(String.init) ?? ""
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any],
                "\(name): probe emitted no JSON (stdout tail: \(run.stdout.suffix(120)))")
            let interpreter = try #require(object["interpreter"] as? String,
                                           "\(name): probe reply lacks interpreter field")
            // Exact match against the python's self-reported sys.executable
            // — non-empty let a hardcoded literal survive (R1 verify D1).
            #expect(interpreter == expected,
                    "\(name): interpreter \(interpreter) != expected \(expected)")
        }
    }
}
