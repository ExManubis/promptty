import Foundation

/// Runs a program without holding a thread while it runs.
public enum ProcessRunner {
    /// How a run ended.
    public enum Outcome: Equatable, Sendable {
        /// The program exited with `status`, having written `output`.
        case exited(status: Int32, output: String)
        /// `until` was satisfied by `output` so far, and the program was terminated.
        case stopped(output: String)
        /// It ran longer than its timeout, and was terminated.
        case timedOut
        /// It could not start.
        case failedToStart

        /// The output of a successful run (or one stopped early); nil otherwise.
        public var output: String? {
            switch self {
            case .exited(0, let output), .stopped(let output): output
            default: nil
            }
        }
    }

    // Running a program is Mac only (iOS has no `Process`); `Outcome` is shared.
    #if os(macOS)
    /// The program's standard output, or nil when it cannot start, exits with a failure, or runs
    /// longer than `timeout` seconds (it is terminated then). Output is read as it arrives, so a
    /// large one never stalls the program on a full pipe.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> String? {
        await outcome(executable, arguments, timeout: timeout).output
    }

    /// How the program ended, so a caller can tell a slow program from a failing one. With `until`,
    /// the run ends (and the program is terminated) as soon as the output so far satisfies it.
    public static func outcome(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                               until: (@Sendable (Data) -> Bool)? = nil) async -> Outcome {
        await withCheckedContinuation { continuation in
            let run = Run(continuation, until: until)
            run.start(executable, arguments, timeout: timeout)
        }
    }

    /// One run's state: finished when the program has exited and its output has ended, at the
    /// timeout, or when `until` is satisfied, whichever comes first.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?
        private let until: (@Sendable (Data) -> Bool)?
        private let process = Process()
        private let out = Pipe()
        private var output = Data()
        private var exited = false
        private var ended = false
        private var status: Int32 = 0

        init(_ continuation: CheckedContinuation<Outcome, Never>, until: (@Sendable (Data) -> Bool)?) {
            self.continuation = continuation
            self.until = until
        }

        func start(_ executable: String, _ arguments: [String], timeout: TimeInterval) {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            out.fileHandleForReading.readabilityHandler = { [self] handle in
                let data = handle.availableData
                lock.lock()
                if data.isEmpty { ended = true } else { output.append(data) }
                let enough = !data.isEmpty && until?(output) == true
                let soFar = enough ? String(decoding: output, as: UTF8.self) : ""
                lock.unlock()
                if data.isEmpty { handle.readabilityHandler = nil }
                if enough {
                    if complete(.stopped(output: soFar)) { process.terminate() }
                    return
                }
                finishIfDone()
            }
            process.terminationHandler = { [self] process in
                lock.lock()
                exited = true
                status = process.terminationStatus
                lock.unlock()
                finishIfDone()
            }
            do { try process.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil
                complete(.failedToStart)
                return
            }
            // The parent's copy of the write end would keep the read end from ever ending.
            try? out.fileHandleForWriting.close()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
                if complete(.timedOut) { process.terminate() }
            }
        }

        private func finishIfDone() {
            lock.lock()
            let done = exited && ended
            let result = Outcome.exited(status: status, output: done ? String(decoding: output, as: UTF8.self) : "")
            lock.unlock()
            if done { complete(result) }
        }

        /// Resumes the caller once; false when it already was. The pipe is not closed here: after a
        /// timeout the read handler may be running and drains to the end of the output (the
        /// terminated program's), then the handles close when the run is released.
        @discardableResult
        private func complete(_ result: Outcome) -> Bool {
            lock.lock()
            guard let continuation else {
                lock.unlock()
                return false
            }
            self.continuation = nil
            lock.unlock()
            // Breaks the cycle through the handler's capture of this run.
            process.terminationHandler = nil
            continuation.resume(returning: result)
            return true
        }
    }
    #endif
}
