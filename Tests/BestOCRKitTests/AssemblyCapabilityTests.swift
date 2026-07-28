import Foundation
import Testing
@testable import BestOCRKit

/// Phase 1 of the document-assembly spec: a new engine family and a new
/// capability axis, both added so that **no existing construction site
/// changes**. The gate for this phase is that omission keeps meaning exactly
/// what it meant before.
struct AssemblyCapabilityTests {
    /// The 14 pre-existing `EngineCapabilities(...)` sites pass no `assembly:`
    /// argument. They must keep compiling AND keep reporting "no assembly".
    @Test func assemblyDefaultsToNoneSoExistingSitesAreUnchanged() {
        let caps = EngineCapabilities(outputLevel: .plainText, languages: ["en"],
                                      needsNetwork: false, memoryClass: .light)
        #expect(caps.assembly == .none)
    }

    @Test func everyShippedPerPageEngineReportsNoAssembly() async {
        let perPage = EngineRegistry.standard().engines.filter {
            $0.family != .documentPipeline
        }
        #expect(!perPage.isEmpty)
        #expect(perPage.allSatisfy { $0.capabilities.assembly == .none })
    }

    /// Spec §7.1: adding an enum case is decode-safe because every already
    /// written row contains only pre-existing raw values.
    @Test func familyRawValuesAreStableAndTheNewOneIsAdditive() throws {
        #expect(EngineFamily.documentPipeline.rawValue == "document_pipeline")
        for raw in ["local_vlm", "classical", "cloud_reference", "document_pipeline"] {
            let decoded = try JSONDecoder().decode(EngineFamily.self,
                                                   from: Data("\"\(raw)\"".utf8))
            #expect(decoded.rawValue == raw)
        }
    }

    /// `OutputLevel` describes *text* fidelity and `assembly` describes
    /// *structure*; spec §7.1 refuses to conflate them because marker is the
    /// living counter-example — best inline-math LaTeX, worst reading order.
    @Test func assemblyIsIndependentOfOutputLevel() {
        let mathWithoutAssembly = EngineCapabilities(
            outputLevel: .mathMarkdown, languages: ["en"],
            needsNetwork: false, memoryClass: .medium)
        let plainWithFullStructure = EngineCapabilities(
            outputLevel: .plainText, languages: ["en"],
            needsNetwork: false, memoryClass: .heavy, assembly: .fullStructure)
        #expect(mathWithoutAssembly.assembly == .none)
        #expect(plainWithFullStructure.outputLevel == .plainText)
        #expect(plainWithFullStructure.assembly == .fullStructure)
    }
}
