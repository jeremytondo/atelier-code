//
//  LocalACPTransport.swift
//  AtelierCode
//
//  Created by Codex on 3/14/26.
//

import Foundation

nonisolated struct GeminiProcessEnvironment: Sendable {
    static func make(
        currentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        userHomeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        executableDirectory: String? = nil
    ) -> [String: String] {
        var environment = currentEnvironment
        let mergedPathDirectories = uniquePaths(
            (executableDirectory.map { [$0] } ?? []) +
            pathDirectories(from: currentEnvironment["PATH"]) +
            fallbackPATHDirectories(userHomeDirectory: userHomeDirectory)
        )

        environment["PATH"] = mergedPathDirectories.joined(separator: ":")
        environment["NO_BROWSER"] = "1"

        if environment["HOME"]?.isEmpty != false {
            environment["HOME"] = userHomeDirectory
        }

        return environment
    }

    static func fallbackPATHDirectories(userHomeDirectory: String) -> [String] {
        uniquePaths(
            [
                "\(userHomeDirectory)/.local/share/mise/shims",
                "\(userHomeDirectory)/.local/bin",
                "\(userHomeDirectory)/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin"
            ]
        )
    }

    private static func pathDirectories(from path: String?) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        return path.split(separator: ":").map(String.init)
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seenPaths = Set<String>()
        return paths.filter { !($0.isEmpty) && seenPaths.insert($0).inserted }
    }
}

nonisolated struct JSONLMessageFramer: Sendable {
    private var buffer = Data()

    mutating func ingest(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }

        buffer.append(data)

        var messages: [Data] = []

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var message = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)

            if message.last == 0x0D {
                message.removeLast()
            }

            guard !message.isEmpty else { continue }
            messages.append(message)
        }

        return messages
    }

    mutating func finish() -> [Data] {
        guard !buffer.isEmpty else { return [] }

        defer { buffer.removeAll(keepingCapacity: true) }
        return [buffer]
    }

    static func frame(_ message: Data) -> Data {
        guard message.last != 0x0A else { return message }

        var framedMessage = message
        framedMessage.append(0x0A)
        return framedMessage
    }
}

nonisolated enum LocalACPTransportError: LocalizedError, Sendable {
    case processAlreadyRunning
    case processNotRunning
    case processTerminated(status: Int32, reason: String)

    var errorDescription: String? {
        switch self {
        case .processAlreadyRunning:
            return "The local Gemini ACP transport is already running."
        case .processNotRunning:
            return "The local Gemini ACP transport is not running."
        case .processTerminated(let status, let reason):
            return "The local Gemini ACP transport terminated with status \(status) (\(reason))."
        }
    }
}

@MainActor
final class LocalACPTransport: AgentTransport {
    var onReceive: ((Result<Data, any Error>) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var onTermination: ((Int32) -> Void)?

    private let executableLocator: GeminiExecutableLocator
    private let arguments: [String]
    private let processFactory: () -> Process
    private let pipeFactory: () -> Pipe

    private var process: Process?
    private var standardInputPipe: Pipe?
    private var standardOutputPipe: Pipe?
    private var standardErrorPipe: Pipe?
    private var stdoutFramer = JSONLMessageFramer()
    private var stderrFramer = JSONLMessageFramer()

    init(
        executableLocator: GeminiExecutableLocator = GeminiExecutableLocator(),
        arguments: [String] = ["--acp", "--model", "gemini-2.5-pro"],
        processFactory: @escaping () -> Process = { Process() },
        pipeFactory: @escaping () -> Pipe = { Pipe() }
    ) {
        self.executableLocator = executableLocator
        self.arguments = arguments
        self.processFactory = processFactory
        self.pipeFactory = pipeFactory
    }

    func start() throws {
        guard process?.isRunning != true else {
            throw LocalACPTransportError.processAlreadyRunning
        }

        let executableURL = try executableLocator.locate()
        let process = processFactory()
        let standardInputPipe = pipeFactory()
        let standardOutputPipe = pipeFactory()
        let standardErrorPipe = pipeFactory()

        stdoutFramer = JSONLMessageFramer()
        stderrFramer = JSONLMessageFramer()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = GeminiProcessEnvironment.make(
            executableDirectory: executableURL.deletingLastPathComponent().path
        )
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData

            Task { @MainActor [weak self] in
                self?.consumeStandardOutput(data)
            }
        }

        standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData

            Task { @MainActor [weak self] in
                self?.consumeStandardError(data)
            }
        }

        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let reason = process.terminationReason == .exit ? "exit" : "uncaught signal"

            Task { @MainActor [weak self] in
                self?.handleTermination(status: status, reason: reason)
            }
        }

        self.process = process
        self.standardInputPipe = standardInputPipe
        self.standardOutputPipe = standardOutputPipe
        self.standardErrorPipe = standardErrorPipe

        do {
            try process.run()
        } catch {
            standardOutputPipe.fileHandleForReading.readabilityHandler = nil
            standardErrorPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            self.process = nil
            self.standardInputPipe = nil
            self.standardOutputPipe = nil
            self.standardErrorPipe = nil
            throw error
        }
    }

    func send(message: Data) throws {
        guard let process, process.isRunning, let standardInputPipe else {
            throw LocalACPTransportError.processNotRunning
        }

        try standardInputPipe.fileHandleForWriting.write(contentsOf: JSONLMessageFramer.frame(message))
    }

    func stop() {
        standardOutputPipe?.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil

        if process?.isRunning == true {
            process?.terminate()
        }

        cleanupProcessState()
    }

    private func consumeStandardOutput(_ data: Data) {
        guard !data.isEmpty else {
            standardOutputPipe?.fileHandleForReading.readabilityHandler = nil
            return
        }

        for message in stdoutFramer.ingest(data) {
            onReceive?(.success(message))
        }
    }

    private func consumeStandardError(_ data: Data) {
        guard !data.isEmpty else {
            standardErrorPipe?.fileHandleForReading.readabilityHandler = nil
            return
        }

        emitDiagnostics(from: stderrFramer.ingest(data))
    }

    private func emitDiagnostics(from chunks: [Data]) {
        for chunk in chunks {
            let text = String(decoding: chunk, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { continue }
            onDiagnostic?(text)
        }
    }

    private func handleTermination(status: Int32, reason: String) {
        emitBufferedStandardOutput()
        emitDiagnostics(from: stderrFramer.finish())

        cleanupProcessState()

        onTermination?(status)
        onReceive?(.failure(LocalACPTransportError.processTerminated(status: status, reason: reason)))
    }

    private func emitBufferedStandardOutput() {
        for message in stdoutFramer.finish() {
            onReceive?(.success(message))
        }
    }

    private func cleanupProcessState() {
        standardOutputPipe?.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil

        process = nil
        standardInputPipe = nil
        standardOutputPipe = nil
        standardErrorPipe = nil
        stdoutFramer = JSONLMessageFramer()
        stderrFramer = JSONLMessageFramer()
    }
}
