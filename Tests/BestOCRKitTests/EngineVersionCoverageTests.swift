import Foundation
import Testing
@testable import BestOCRKit

/// Every execution point must answer "which version produced this" — including
/// when the answer is "unknown". These tests are the guard against a future
/// engine quietly reporting nothing (engine-version-provenance spec).
struct EngineVersionCoverageTests {

    // MARK: - Per-engine

    @Test("Vision reports the OS version as declared")
    func visionDeclaresOSVersion() async {
        let version = await VisionEngine().resolveVersion()
        #expect(version.resolution == .declared)
        #expect(!version.components.isEmpty)
    }

    /// Absence of the binary is a value, not a failure: the version is
    /// unavailable and nothing throws.
    @Test("Tesseract reports unavailable when the binary is missing")
    func tesseractMissingBinaryIsUnavailable() async {
        let engine = TesseractEngine(binaryPath: "/nonexistent/tesseract")
        let version = await engine.resolveVersion()
        #expect(version.resolution == .unavailable)
        #expect(version.components.isEmpty)
    }

    @Test("VLM reports its model tag and runtime")
    func vlmReportsModelAndRuntime() async throws {
        let profile = try #require(ModelProfile.all.first)
        let version = await VLMEngine(profile: profile).resolveVersion()
        #expect(version.components.count >= 1)
        #expect(!version.components.keys.contains(""))
        #expect(!version.components.values.contains(""))
    }

    /// A cloud provider does not disclose which model version served the
    /// request, so nothing is inferred from the provider name or the requested
    /// model id.
    @Test("Cloud reports unavailable rather than inferring a version")
    func cloudReportsUnavailable() async {
        for provider in CloudProvider.allCases {
            let version = await CloudReferenceEngine(provider: provider).resolveVersion()
            #expect(version.resolution == .unavailable)
            #expect(version.components.isEmpty)
        }
    }

    @Test("An adapter-backed engine labels its version as adapter-reported")
    func adapterVersionIsLabelled() throws {
        let reply = """
        {"protocol": 1, "ok": true, "tool": "surya", "version": "0.22.1"}
        """
        let data = try #require(reply.data(using: .utf8))
        let decoded = try JSONDecoder().decode(AdapterProtocolV1.ProbeReply.self, from: data)
        let version = EngineVersion.single(try #require(decoded.tool),
                                           try #require(decoded.version),
                                           resolution: .adapterReported)
        #expect(version.resolution == .adapterReported)
        #expect(version.components["surya"] == "0.22.1")
    }

    /// An adapter that cannot be reached yields the absence case rather than a
    /// fabricated version.
    @Test("An unreachable adapter reports unavailable")
    func unreachableAdapterIsUnavailable() async {
        let engine = ExternalToolEngine(
            tool: "definitely-not-installed",
            capabilities: EngineCapabilities(outputLevel: .plainText, languages: ["en"],
                                             needsNetwork: false, memoryClass: .light),
            installHint: "n/a",
            script: URL(fileURLWithPath: "/nonexistent/adapter.py"),
            timeout: 5)
        let version = await engine.resolveVersion()
        #expect(version.resolution == .unavailable)
    }

    // MARK: - Corpus-wide

    /// The check that makes "a new engine forgot to report a version" a test
    /// failure rather than a silent gap: every registered engine answers, and a
    /// non-absent answer must actually carry components.
    @Test("Every registered engine reports a well-formed version")
    func everyEngineReportsWellFormedVersion() async {
        let legal: Set<VersionResolution> = [.declared, .probed, .adapterReported, .unavailable]
        for engine in EngineRegistry.standard().engines {
            let version = await engine.resolveVersion()
            #expect(legal.contains(version.resolution),
                    "engine \(engine.id) returned an unexpected resolution")
            if version.resolution != .unavailable {
                #expect(!version.components.isEmpty,
                        "engine \(engine.id) claims \(version.resolution) but carries no components")
            } else {
                #expect(version.components.isEmpty,
                        "engine \(engine.id) reports unavailable but carries components")
            }
        }
    }
}
