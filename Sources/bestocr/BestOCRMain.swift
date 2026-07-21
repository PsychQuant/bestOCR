import ArgumentParser

@main
struct BestOCR: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bestocr",
        abstract: "Evidence-based multi-engine OCR (M1: explicit engine selection; auto-routing arrives with recommend in M2).",
        subcommands: [Run.self, ListEngines.self, Recommend.self, Compare.self, Evidence.self]
    )
}
