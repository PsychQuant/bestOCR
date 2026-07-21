/// Auto-routing (spec §7 Flow B "auto 路由(查 evidence)"): the candidate
/// order IS the Recommender's answer — ranked engines first (tier-disciplined),
/// then capability-filtered unverified ones. Cloud engines never appear
/// (Recommender excludes `.cloudReference`). The fallback chain (spec §8)
/// walks this list in RunPipeline.executeAuto.
public enum AutoRouter {
    public struct Selection: Sendable {
        public let candidateIDs: [String]
        public let mode: Recommendation.Mode
    }

    public static func candidates(docType: String, languages: [String],
                                  priority: WorkloadSpec.Priority, needsMath: Bool,
                                  registry: EngineRegistry,
                                  evidence: EvidenceStore) -> Selection {
        let workload = WorkloadSpec(docType: docType, languages: languages,
                                    priority: priority, needsMath: needsMath)
        let answer = Recommender.recommend(workload: workload, registry: registry,
                                           evidence: evidence)
        return Selection(candidateIDs: answer.entries.map(\.engineID), mode: answer.mode)
    }
}
