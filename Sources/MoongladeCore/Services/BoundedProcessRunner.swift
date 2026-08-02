import Foundation
import Darwin

package struct BoundedProcessResult: Sendable {
    package let status: Int32
    package let output: Data

    package init(status: Int32, output: Data) {
        self.status = status
        self.output = output
    }
}

package enum BoundedProcessRunner {
    package static let defaultMaximumOutputBytes = 2 * 1_048_576

    package static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int = defaultMaximumOutputBytes
    ) throws -> BoundedProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        let outputFinished = DispatchSemaphore(value: 0)
        let outputState = OutputState(maximumBytes: maximumOutputBytes)
        DispatchQueue.global(qos: .utility).async {
            defer { outputFinished.signal() }
            do {
                while let chunk = try outputPipe.fileHandleForReading.read(upToCount: 64 * 1_024),
                      !chunk.isEmpty {
                    outputState.append(chunk)
                }
            } catch {
                outputState.record(error: error)
            }
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.closeFile()
            throw error
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 0.25) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.25)
            }
            _ = outputFinished.wait(timeout: .now() + 1)
            throw POSIXError(.ETIMEDOUT)
        }
        guard outputFinished.wait(timeout: .now() + 1) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = outputState.error {
            throw error
        }
        if outputState.didExceedLimit {
            throw POSIXError(.EFBIG)
        }
        return BoundedProcessResult(status: process.terminationStatus, output: outputState.data)
    }
}

private final class OutputState: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private(set) var data = Data()
    private(set) var didExceedLimit = false
    private(set) var error: Error?

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !didExceedLimit else { return }
        guard data.count + chunk.count <= maximumBytes else {
            didExceedLimit = true
            return
        }
        data.append(chunk)
    }

    func record(error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }
}
