import ArgumentParser
import BestOCRKit
import Foundation

struct Recommend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Evidence-labelled engine recommendation for a workload (honest evidence-pending when unmeasured).")

    @Option(name: .customLong("doc-type"),
            help: "Workload doc type matching evidence rows (e.g. math_pdf, scanned_book, screenshot).")
    var docType: String

    @Option(help: "Comma-separated required languages, e.g. \"zh-Hant,en\".")
    var lang: String = ""

    @Option(help: "quality | speed | balanced.")
    var priority: String = "balanced"

    @Flag(help: "Require math-aware output (math_markdown engines only).")
    var math: Bool = false

    mutating func run() async throws {
        guard let prio = WorkloadSpec.Priority(rawValue: priority) else {
            throw ValidationError("--priority must be one of: quality, speed, balanced")
        }
        let languages = lang.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let workload = WorkloadSpec(docType: docType, languages: languages,
                                    priority: prio, needsMath: math)
        let evidence: EvidenceStore
        do {
            evidence = try EvidenceStore.load(from: EvidenceStore.defaultURL())
        } catch let error as OCREngineError {
            throw ValidationError(error.errorDescription ?? "\(error)")
        }
        let answer = Recommender.recommend(workload: workload,
                                           registry: EngineRegistry.standard(),
                                           evidence: evidence)
        switch answer.mode {
        case .ranked(let tier):
            print("RANKED (\(tier) evidence, priority: \(prio.rawValue), doc-type: \(docType))")
        case .evidencePending:
            print("EVIDENCE-PENDING — no measured rows for this workload; this is a capability filter, not a ranking.")
        }
        for (index, entry) in answer.entries.enumerated() {
            print("  \(index + 1). \(entry.engineID) — \(entry.note)")
        }
        if !answer.citations.isEmpty {
            print("evidence rows used: \(answer.citations.joined(separator: "; "))")
        }
    }
}
