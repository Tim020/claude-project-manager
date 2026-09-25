import Foundation

/// A running agent conversation that accepts stream-json lines on stdin and
/// emits parsed events. Abstracted so the app model can be tested with fakes.
public protocol AgentProcess: AnyObject {
    /// Called on the process's callback queue for each parsed stdout record.
    var onEvent: ((StreamEvent) -> Void)? { get set }
    /// Called once when the process exits, with its exit code and the tail of stderr.
    var onExit: ((Int32, String) -> Void)? { get set }
    var isRunning: Bool { get }
    func start() throws
    func send(_ line: String) throws
    func terminate()
}

public enum AgentProcessError: Error, Equatable, LocalizedError {
    case notRunning
    case executableNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "The Claude Code process is not running."
        case .executableNotFound(let path): return "Claude Code was not found at \(path)."
        }
    }
}

/// `claude -p --input-format stream-json --output-format stream-json` as a child process.
public final class ClaudeProcess: AgentProcess {
    public var onEvent: ((StreamEvent) -> Void)?
    public var onExit: ((Int32, String) -> Void)?

    public let configuration: ClaudeLaunchConfiguration
    private let callbackQueue: DispatchQueue
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var stdoutBuffer = LineBuffer()
    private var stderrTail = Data()
    private var started = false
    private var stdoutClosed = false
    private var exitStatus: Int32?
    private var reported = false

    static let maxStderrBytes = 4096

    public init(configuration: ClaudeLaunchConfiguration, callbackQueue: DispatchQueue = .main) {
        self.configuration = configuration
        self.callbackQueue = callbackQueue
    }

    public var isRunning: Bool { process.isRunning }

    public func start() throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.executable) else {
            throw AgentProcessError.executableNotFound(configuration.executable)
        }
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = configuration.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory)
        process.environment = ClaudeExecutableLocator.childEnvironment(executable: configuration.executable)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleStdout(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleStderr(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.handleTermination(process.terminationStatus)
        }

        try process.run()
        // Close the child's ends in this process so stdout reaches EOF when it exits.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
        lock.lock(); started = true; lock.unlock()
    }

    public func send(_ line: String) throws {
        lock.lock()
        let canSend = started && exitStatus == nil
        lock.unlock()
        guard canSend else { throw AgentProcessError.notRunning }
        try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    public func terminate() {
        guard process.isRunning else { return }
        try? stdin.fileHandleForWriting.close()
        process.terminate()
    }

    // MARK: - Output handling

    private func handleStdout(_ data: Data) {
        if data.isEmpty {
            stdout.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            let trailing = stdoutBuffer.flush()
            stdoutClosed = true
            lock.unlock()
            if let trailing { deliver(trailing) }
            finishIfDone()
            return
        }
        lock.lock()
        let lines = stdoutBuffer.append(data)
        lock.unlock()
        lines.forEach(deliver)
    }

    private func deliver(_ line: String) {
        guard let event = StreamEventParser.parse(line), event != .partial else { return }
        callbackQueue.async { [weak self] in self?.onEvent?(event) }
    }

    private func handleStderr(_ data: Data) {
        if data.isEmpty {
            stderr.fileHandleForReading.readabilityHandler = nil
            return
        }
        lock.lock()
        stderrTail.append(data)
        if stderrTail.count > ClaudeProcess.maxStderrBytes {
            stderrTail = stderrTail.suffix(ClaudeProcess.maxStderrBytes)
        }
        lock.unlock()
    }

    private func handleTermination(_ status: Int32) {
        lock.lock(); exitStatus = status; lock.unlock()
        finishIfDone()
        // If a grandchild keeps stdout open, don't wait for EOF forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.stdoutClosed = true; self.lock.unlock()
            self.finishIfDone()
        }
    }

    /// Reports exit only after stdout has been drained, so no events are lost
    /// and `onExit` always comes after the last `onEvent`.
    private func finishIfDone() {
        lock.lock()
        guard stdoutClosed, !reported, let status = exitStatus else { lock.unlock(); return }
        reported = true
        let tail = String(decoding: stderrTail, as: UTF8.self)
        lock.unlock()
        callbackQueue.async { [weak self] in self?.onExit?(status, tail) }
    }
}
