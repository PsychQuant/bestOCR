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
}
