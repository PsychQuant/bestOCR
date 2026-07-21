import ArgumentParser
import BestOCRKit

struct ListEngines: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-engines",
        abstract: "Probe every registered engine and show availability + install hints.")

    mutating func run() async throws {
        let registry = EngineRegistry.standard()
        let probed = await registry.probeAll()
        let idWidth = max(probed.map { $0.engine.id.count }.max() ?? 0, 6)
        print("\("ENGINE".padding(toLength: idWidth, withPad: " ", startingAt: 0))  FAMILY           OUTPUT         STATUS")
        for (engine, availability) in probed {
            let status: String
            switch availability {
            case .available:
                status = "✓ available"
            case .unavailable(let reason, let hint):
                status = "✗ \(reason)" + (hint.map { " — install: \($0)" } ?? "")
            }
            let id = engine.id.padding(toLength: idWidth, withPad: " ", startingAt: 0)
            let family = engine.family.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)
            let output = engine.capabilities.outputLevel.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
            print("\(id)  \(family)  \(output)  \(status)")
        }
    }
}
