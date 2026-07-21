import Foundation

/// Minimal subprocess runner with timeout — the shared mechanism for CLI-tool
/// engines (tesseract now; external protocol-v1 adapters in M2).
public enum Subprocess {
    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
    }

    public struct TimeoutError: Error, LocalizedError {
        public let seconds: TimeInterval
        public var errorDescription: String? { "process timed out after \(Int(seconds))s" }
    }

    /// NSLock-guarded byte box so pipe reads satisfy strict concurrency.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    public static func run(_ executable: URL, arguments: [String],
                           timeout: TimeInterval = 120) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBox = DataBox(), errBox = DataBox()
        let readGroup = DispatchGroup()
        // Drain both pipes concurrently so a chatty child never deadlocks on
        // a full pipe buffer before we observe termination.
        readGroup.enter()
        DispatchQueue.global().async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global().async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw TimeoutError(seconds: timeout)
        }
        readGroup.wait()
        return Result(stdout: String(data: outBox.get(), encoding: .utf8) ?? "",
                      stderr: String(data: errBox.get(), encoding: .utf8) ?? "",
                      exitCode: process.terminationStatus)
    }
}
