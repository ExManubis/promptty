import Foundation

/// Runs a program without holding a thread while it runs.
public enum ProcessRunner {
    /// The program's standard output, or nil when it cannot start, exits with a failure, or runs
    /// longer than `timeout` seconds (it is terminated then). Output is read as it arrives, so a
    /// large one never stalls the program on a full pipe.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            let run = Run(continuation)
            run.start(executable, arguments, timeout: timeout)
        }
    }

    /// One run's state: finished when the program has exited and its output has ended, or at the
    /// timeout, whichever comes first.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        private let process = Process()
        private let out = Pipe()
        private var output = Data()
        private var exited = false
        private var ended = false
        private var status: Int32 = 0

        init(_ continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
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
                lock.unlock()
                if data.isEmpty { handle.readabilityHandler = nil }
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
                complete(nil)
                return
            }
            // The parent's copy of the write end would keep the read end from ever ending.
            try? out.fileHandleForWriting.close()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
                if complete(nil) { process.terminate() }
            }
        }

        private func finishIfDone() {
            lock.lock()
            let done = exited && ended
            let result = status == 0 ? String(decoding: output, as: UTF8.self) : nil
            lock.unlock()
            if done { complete(result) }
        }

        /// Resumes the caller once; false when it already was. The pipe is not closed here: after a
        /// timeout the read handler may be running and drains to the end of the output (the
        /// terminated program's), then the handles close when the run is released.
        @discardableResult
        private func complete(_ result: String?) -> Bool {
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
}
