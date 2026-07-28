/// Auto-routing (spec §7 Flow B "auto 路由(查 evidence)"): the candidate
/// order IS the Recommender's answer — ranked engines first (tier-disciplined),
/// then capability-filtered unverified ones. Cloud engines never appear
/// (Recommender excludes `.cloudReference`). The fallback chain (spec §8)
/// walks this list in RunPipeline.executeAuto.
public enum AutoRouter {
    public struct Selection: Sendable {
        public let candidateIDs: [String]
        public let mode: Recommendation.Mode
        /// Set when the document class narrowed the roster (document-assembly
        /// spec §7.3 requirement 1). Routing to an assembly engine buys reading
        /// order and pays for it in wall-clock; printing the win without the
        /// cost would be the dishonest half of the truth.
        public let notice: String?
    }

    public static func candidates(docType: String, languages: [String],
                                  priority: WorkloadSpec.Priority, needsMath: Bool,
                                  documentClass: DocumentClass = .unspecified,
                                  registry: EngineRegistry,
                                  evidence: EvidenceStore) -> Selection {
        let workload = WorkloadSpec(docType: docType, languages: languages,
                                    priority: priority, needsMath: needsMath,
                                    documentClass: documentClass)
        let answer = Recommender.recommend(workload: workload, registry: registry,
                                           evidence: evidence)
        let notice: String? = documentClass.requiresAssembly
            ? "document-class \(documentClass.rawValue) requires document assembly — "
                + "only assembly engines are candidates, and they are substantially "
                + "slower than per-page transcription (see each engine's tradeoff)"
            : nil
        return Selection(candidateIDs: answer.entries.map(\.engineID), mode: answer.mode,
                         notice: notice)
    }
}
