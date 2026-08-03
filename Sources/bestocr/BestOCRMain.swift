import ArgumentParser

@main
struct BestOCR: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bestocr",
        abstract: "Evidence-based multi-engine OCR — auto-routing by default (measured rows first, capability filter otherwise), explicit --engine to pin, cloud reference via compare, explicit evidence ingest. `pipeline` goes all the way to a deliverable file.",
        subcommands: [Run.self, Pipeline.self, ListEngines.self, Recommend.self,
                      Compare.self, Consensus.self, Evidence.self, Triage.self]
    )
}
