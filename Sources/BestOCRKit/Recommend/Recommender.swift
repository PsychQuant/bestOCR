/// Evidence-disciplined recommendation (spec §6.1; schema.md hard rules):
/// ranking and capability-filtering are different speech acts — the answer
/// always states which one it is.
public struct Recommendation: Sendable {
    public enum Mode: Sendable, Equatable {
        case ranked(tier: String)
        case evidencePending
    }

    public struct Entry: Sendable {
        public let engineID: String
        public let note: String
    }

    public let mode: Mode
    public let entries: [Entry]
    public let citations: [String]
}

public enum Recommender {
    /// "glm-ocr-anova:q8_0" → "glm-ocr": evidence rows name base models; live
    /// engines carry build/quant-suffixed tags.
    static func baseModel(_ model: String) -> String {
        var base = model
        if let colon = base.firstIndex(of: ":") { base = String(base[..<colon]) }
        if base.hasSuffix("-anova") { base = String(base.dropLast("-anova".count)) }
        return base
    }

    /// The model name an engine's rows would carry (mirrors each engine's
    /// ConditionTuple.model), base-normalized.
    static func engineModelKey(_ engine: any OCREngine) -> String {
        if let vlm = engine as? VLMEngine { return baseModel(vlm.resolvedModelTag) }
        if let ext = engine as? ExternalToolEngine { return ext.tool }
        // Bare ids (vision, tesseract) map directly; namespaced ids from
        // other engine types fall back to their suffix ("vlm.glm-ocr" →
        // "glm-ocr") so row matching never depends on the concrete type.
        let id = engine.id
        if id.hasPrefix("vlm.") || id.hasPrefix("ext."),
           let dot = id.firstIndex(of: ".") {
            return baseModel(String(id[id.index(after: dot)...]))
        }
        return id
    }

    /// Estimand preference per priority. Exactly ONE estimand carries any
    /// ranking (schema.md hard rule 2) — the list is a fallback order, not a
    /// blend: word_recall (ground-truth referent) outranks the cloud-compare
    /// metric, which is used only when no word_recall rows exist. Speed never
    /// borrows quality numbers.
    static func estimands(for priority: WorkloadSpec.Priority) -> [(name: String, higherIsBetter: Bool)] {
        switch priority {
        case .quality, .balanced:
            return [("quality.word_recall", true), (Comparator.formulaID, true)]
        case .speed:
            return [("speed.ms_per_page", false)]
        }
    }

    public static func recommend(workload: WorkloadSpec, registry: EngineRegistry,
                                 evidence: EvidenceStore) -> Recommendation {
        // 1. Capability filter (never rank what can't do the job).
        let candidates = registry.engines.filter { engine in
            if engine.family == .cloudReference { return false }   // spec §6.1.3
            if workload.needsMath && engine.capabilities.outputLevel != .mathMarkdown { return false }
            if !workload.languages.isEmpty {
                let supported = Set(engine.capabilities.languages)
                if !workload.languages.allSatisfy(supported.contains) { return false }
            }
            return true
        }

        // 2. Rankable rows: matching doc type + the first estimand in the
        //    priority's preference order that has usable rows, T3 excluded
        //    (schema.md: never ranked, never blended across estimands).
        let candidateKeys = Set(candidates.map(engineModelKey))
        let docRows = evidence.rows(docType: workload.docType)
        var wanted = estimands(for: workload.priority)[0]
        var usable: [EvidenceRow] = []
        for preference in estimands(for: workload.priority) {
            let matching = docRows.filter { $0.estimand == preference.name && $0.tier != "T3" }
                .filter { candidateKeys.contains(baseModel($0.condition.model)) }
            if !matching.isEmpty {
                wanted = preference
                usable = matching
                break
            }
        }

        guard !usable.isEmpty else {
            // 3a. Honest evidence-pending: capability filtering only.
            let entries = candidates.map {
                Recommendation.Entry(engineID: $0.id,
                                     note: "unverified — no measured rows for this workload")
            }
            return Recommendation(mode: .evidencePending, entries: entries, citations: [])
        }

        // 3b. Rank strictly within the highest tier present (T1 > T2).
        let tier = usable.contains { $0.tier == "T1" } ? "T1" : "T2"
        let tierRows = usable.filter { $0.tier == tier }
        var bestByKey: [String: EvidenceRow] = [:]
        for row in tierRows {
            let key = baseModel(row.condition.model)
            if let existing = bestByKey[key] {
                let better = wanted.higherIsBetter ? row.value > existing.value
                                                   : row.value < existing.value
                if better { bestByKey[key] = row }
            } else {
                bestByKey[key] = row
            }
        }

        var ranked: [(engine: any OCREngine, row: EvidenceRow)] = []
        var unranked: [any OCREngine] = []
        for engine in candidates {
            if let row = bestByKey[engineModelKey(engine)] {
                ranked.append((engine, row))
            } else {
                unranked.append(engine)
            }
        }
        ranked.sort {
            wanted.higherIsBetter ? $0.row.value > $1.row.value
                                  : $0.row.value < $1.row.value
        }

        var entries = ranked.map { pair in
            Recommendation.Entry(
                engineID: pair.engine.id,
                note: "\(wanted.name) = \(pair.row.value) (\(tier), \(pair.row.source))"
                    + (pair.row.caveat.map { " — caveat: \($0)" } ?? ""))
        }
        // Other-tier evidence is surfaced but never mixed into the ranking.
        let otherTiers = Dictionary(grouping: usable.filter { $0.tier != tier },
                                    by: { baseModel($0.condition.model) })
        entries += unranked.map { engine in
            let key = engineModelKey(engine)
            if let rows = otherTiers[key], let first = rows.first {
                return Recommendation.Entry(
                    engineID: engine.id,
                    note: "has \(first.tier) evidence — not rankable against \(tier) rows")
            }
            return Recommendation.Entry(engineID: engine.id,
                                        note: "unverified — no measured rows for this workload")
        }
        return Recommendation(mode: .ranked(tier: tier), entries: entries,
                              citations: ranked.map(\.row.source))
    }
}
