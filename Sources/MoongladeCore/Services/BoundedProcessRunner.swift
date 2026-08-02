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
        // Raw read(2), not FileHandle.read(upToCount:): the FileHandle call
        // loops internally until it fills the requested length or hits EOF,
        // so a short burst of output would sit unappended for as long as any
        // inherited copy of the write end stays open. read(2) hands over
        // whatever is in the pipe as soon as it arrives.
        let readDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        DispatchQueue.global(qos: .utility).async {
            defer { outputFinished.signal() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(readDescriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    outputState.append(Data(buffer[0..<count]))
                    continue
                }
                if count == 0 { break }
                if errno == EINTR { continue }
                outputState.record(error: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                break
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
        // The process has exited, so everything it could write is already in
        // the pipe. EOF may still never come: a grandchild that inherited the
        // write end (a shell backgrounding a helper) holds it open past the
        // parent's death. After the drain grace the gathered output is the
        // command's complete output — return it rather than miscasting a
        // successful run as a timeout. The abandoned reader parks until the
        // orphan lets go; its handle is never closed from here, because a
        // concurrent close would let the descriptor number be recycled under
        // the still-blocked read.
        _ = outputFinished.wait(timeout: .now() + 1)
        let output = outputState.snapshot()
        if let error = output.error {
            throw error
        }
        if output.didExceedLimit {
            throw POSIXError(.EFBIG)
        }
        return BoundedProcessResult(status: process.terminationStatus, output: output.data)
    }
}

private final class OutputState: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()
    private var didExceedLimit = false
    private var error: Error?

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    /// The reader may still be appending when the drain grace expires, so
    /// every read of the gathered state goes through the lock as one unit.
    func snapshot() -> (data: Data, didExceedLimit: Bool, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (data, didExceedLimit, error)
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
