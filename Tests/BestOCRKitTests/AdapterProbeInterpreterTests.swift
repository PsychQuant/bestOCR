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

    private func systemPython() -> URL? {
        for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
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
        let interpreter = try #require(version.interpreter)
        #expect(!interpreter.isEmpty)
    }

    // MARK: - Every embedded adapter probe reports the interpreter

    /// The field must appear whether or not the tool imports — an UNAVAILABLE
    /// probe is exactly the case where knowing which interpreter answered
    /// matters most (wrong-interpreter is the #37 motivating failure).
    @Test func allEmbeddedAdapterProbesReportInterpreter() throws {
        guard let python = systemPython() else { print("SKIP: no python3"); return }
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
                                             timeout: 30)
            #expect(compile.exitCode == 0, "\(name): py_compile failed: \(compile.stderr)")

            let run = try Subprocess.run(python, arguments: [file.path, "probe"], timeout: 30)
            let lastLine = run.stdout.split(separator: "\n").last.map(String.init) ?? ""
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any],
                "\(name): probe emitted no JSON (stdout tail: \(run.stdout.suffix(120)))")
            let interpreter = try #require(object["interpreter"] as? String,
                                           "\(name): probe reply lacks interpreter field")
            #expect(!interpreter.isEmpty, "\(name): interpreter is empty")
        }
    }
}
