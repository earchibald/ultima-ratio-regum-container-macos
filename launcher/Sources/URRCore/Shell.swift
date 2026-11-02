import Foundation

/// One line in the launcher's log ("looking glass"). Every command the
/// launcher runs is logged verbatim before its output.
public struct LogEntry: Sendable, Identifiable {
    public enum Kind: String, Sendable { case step, command, output, info, warning, error }
    public let id = UUID()
    public let date = Date()
    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    public var plain: String {
        switch kind {
        case .step: return "==> \(text)"
        case .command: return "$ \(text)"
        case .output: return "  \(text)"
        case .info: return text
        case .warning: return "warning: \(text)"
        case .error: return "error: \(text)"
        }
    }
}

public typealias LogSink = @Sendable (LogEntry) -> Void

public struct CommandError: LocalizedError {
    public let command: String
    public let status: Int32
    public let tail: [String]
    public var errorDescription: String? {
        "\(command) failed (exit \(status))" + (tail.isEmpty ? "" : ": " + tail.joined(separator: " / "))
    }
}

/// A launched process whose merged stdout/stderr is streamed line by line.
public final class RunningCommand: @unchecked Sendable {
    public let display: String
    private let process: Process
    private let done = DispatchGroup()
    private let lock = NSLock()
    private var buffer = Data()
    private var recent: [String] = []
    private let onLine: @Sendable (String) -> Void

    init(executable: URL, arguments: [String], environment: [String: String]?, onLine: @escaping @Sendable (String) -> Void) throws {
        self.onLine = onLine
        display = ([executable.path] + arguments).map(Self.quote).joined(separator: " ")
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        done.enter()  // output EOF
        done.enter()  // process exit
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.flush(final: true)
                self.done.leave()
            } else {
                self.append(data)
            }
        }
        process.terminationHandler = { [done] _ in done.leave() }
        try process.run()
        try? pipe.fileHandleForWriting.close()
    }

    private func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
        flush(final: false)
    }

    private func flush(final: Bool) {
        lock.lock()
        var lines: [String] = []
        while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...i)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        if final, !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        recent.append(contentsOf: lines)
        if recent.count > 40 { recent.removeFirst(recent.count - 40) }
        lock.unlock()
        lines.forEach(onLine)
    }

    public var isRunning: Bool { process.isRunning }
    public var lastLines: [String] { lock.lock(); defer { lock.unlock() }; return recent }

    public func terminate() { if process.isRunning { process.terminate() } }

    /// Waits for the process to exit and its output to drain; returns the exit status.
    public func wait() async -> Int32 {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            done.notify(queue: .global()) { c.resume() }
        }
        return process.terminationStatus
    }

    static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=,@%+"))
        if s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum Shell {
    /// Starts a command, logging its command line and each output line.
    public static func start(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                             log: @escaping LogSink, quiet: Bool = false) throws -> RunningCommand {
        let cmd = try RunningCommand(executable: executable, arguments: arguments, environment: environment) { line in
            if !quiet { log(LogEntry(.output, line)) }
        }
        log(LogEntry(.command, cmd.display))
        return cmd
    }

    /// Runs a command to completion; returns its exit status and output lines.
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                           log: @escaping LogSink, quiet: Bool = false) async throws -> (status: Int32, output: [String]) {
        let collected = LineCollector()
        let cmd = try RunningCommand(executable: executable, arguments: arguments, environment: environment) { line in
            collected.add(line)
            if !quiet { log(LogEntry(.output, line)) }
        }
        log(LogEntry(.command, cmd.display))
        let status = await cmd.wait()
        return (status, collected.lines)
    }

    /// Runs a command and throws if it fails.
    @discardableResult
    public static func check(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                             log: @escaping LogSink, quiet: Bool = false) async throws -> [String] {
        let (status, output) = try await run(executable, arguments, environment: environment, log: log, quiet: quiet)
        guard status == 0 else {
            throw CommandError(command: ([executable.lastPathComponent] + arguments.prefix(2)).joined(separator: " "),
                               status: status, tail: Array(output.suffix(3)))
        }
        return output
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
