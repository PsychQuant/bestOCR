import Foundation

/// Estimand naming (`evidence/schema.md` §2). Versioned `name@vN` is the
/// canonical form; the unversioned names that pre-date the convention denote
/// `@v1`, so no committed row has to be rewritten.
///
/// This exists as code and not just documentation because matching is done by
/// string equality: without canonicalization, a legacy `speed.ms_per_page` row
/// and a freshly ingested `speed.ms_per_page@v1` row would look like two
/// different estimands and split one ranking into two — the precise failure the
/// compat line promises does not happen.
public enum Estimand {
    /// Reading-order fidelity — Kendall tau-b over matched block sequences.
    /// **Defined, deliberately unmeasured**: no annotated reference subset
    /// exists (document-assembly spec §6.3).
    public static let readingOrderTau = "quality.reading_order_tau@v1"
    /// Table-structure fidelity — cell-level F1 over `(row, col, text)`.
    /// Same status: defined, unmeasured.
    public static let tableStructureF1 = "quality.table_structure_f1@v1"

    /// `speed.ms_per_page` → `speed.ms_per_page@v1`; already-versioned names
    /// are returned unchanged. A different version is a different formula and
    /// must never collapse into this one.
    public static func canonical(_ name: String) -> String {
        name.contains("@") ? name : "\(name)@v1"
    }

    // MARK: - Consensus estimands (#17)

    /// A consensus quantity is **defined by the adjudicator that computed it** —
    /// "low consensus" under Dawid-Skene-lite means its tie / fewer-than-two-
    /// corroborators rule, and a different model computes a different quantity.
    /// Putting the adjudicator in the *name* makes them mechanically un-mixable
    /// under `evidence/schema.md` hard rule 2, with no schema-shape change and
    /// no row migration.
    ///
    /// Ids are hyphenated for the CLI (`--adjudicator ds-lite`); estimand
    /// segments are underscored, so the mapping happens here once rather than
    /// at every call site.
    public static func consensus(_ adjudicator: String, _ quantity: String) -> String {
        let segment = adjudicator.replacingOccurrences(of: "-", with: "_")
        return "consensus.\(segment).\(quantity)@v1"
    }

    /// The unqualified name rows carried before adjudicators were pluggable.
    public static let legacyConsensusLowShare = "consensus.low_consensus_share@v1"

    /// Reads a legacy unqualified consensus estimand as `ds-lite`.
    ///
    /// This is **history, not an assumption**: Dawid-Skene-lite was the only
    /// adjudicator that ever existed when those rows were written. It is code
    /// rather than a doc note for the same reason `canonical` is — matching is
    /// string equality, so an unmapped legacy row would split one ranking into
    /// two the moment a second adjudicator appears.
    public static func canonicalConsensus(_ name: String) -> String {
        name == legacyConsensusLowShare
            ? consensus(DawidSkeneLiteAdjudicator.id, "low_consensus_share")
            : canonical(name)
    }
}
