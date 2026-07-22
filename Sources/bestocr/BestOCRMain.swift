import ArgumentParser

@main
struct BestOCR: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bestocr",
        abstract: "Evidence-based multi-engine OCR — auto-routing by default (measured rows first, capability filter otherwise), explicit --engine to pin, cloud reference via compare, explicit evidence ingest.",
        subcommands: [Run.self, ListEngines.self, Recommend.self, Compare.self, Evidence.self]
    )
}
