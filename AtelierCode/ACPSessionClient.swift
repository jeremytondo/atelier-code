//
//  ACPSessionClient.swift
//  AtelierCode
//
//  Created by Codex on 3/14/26.
//

import Foundation

nonisolated struct ACPSessionClientTimeouts: Sendable {
    let initialize: TimeInterval
    let sessionLoad: TimeInterval
    let sessionNew: TimeInterval
    let sessionPrompt: TimeInterval

    static let atelierCodeDefault = ACPSessionClientTimeouts(
        initialize: 10,
        sessionLoad: 15,
        sessionNew: 15,
        sessionPrompt: 60
    )

    func timeout(for method: ACPMethod) -> TimeInterval? {
        switch method {
        case .initialize:
            return initialize
        case .sessionLoad:
            return sessionLoad
        case .sessionNew:
            return sessionNew
        case .sessionPrompt:
            return sessionPrompt
        default:
            return nil
        }
    }
}

nonisolated enum ACPSessionClientError: LocalizedError {
    case sessionNotCreated
    case promptNotInFlight
    case requestTimedOut(method: String, timeout: TimeInterval)
    case invalidResponse(method: String)
    case deadTransport(method: String, requestID: Int?)
    case missingResult(method: String)
    case serverError(method: String, error: ACPError)
    case authenticationRequired(method: String, error: ACPError)
    case modelUnavailable(method: String, error: ACPError)
    case unsupportedProtocolVersion(received: Int, supported: [Int])

    var errorDescription: String? {
        switch self {
        case .sessionNotCreated:
            return "The ACP session has not been created yet."
        case .promptNotInFlight:
            return "There is no in-flight ACP prompt to cancel."
        case .requestTimedOut(let method, let timeout):
            return "The ACP request \(method) timed out after \(Self.formattedTimeout(timeout))."
        case .invalidResponse(let method):
            return "The ACP response for \(method) could not be decoded."
        case .deadTransport(let method, let requestID):
            if let requestID {
                return "The ACP transport was already gone while sending \(method) (#\(requestID))."
            }
            return "The ACP transport was already gone while sending \(method)."
        case .missingResult(let method):
            return "The ACP response for \(method) did not include a result."
        case .serverError(let method, let error):
            return Self.structuredFailureDescription(
                prefix: "The ACP request \(method) failed",
                error: error
            )
        case .authenticationRequired(let method, let error):
            return Self.structuredFailureDescription(
                prefix: "The ACP request \(method) needs Gemini authentication",
                error: error,
                guidance: "Re-authenticate in a terminal and try again."
            )
        case .modelUnavailable(let method, let error):
            return Self.structuredFailureDescription(
                prefix: "The ACP request \(method) failed because the configured Gemini model is unavailable",
                error: error,
                guidance: "Check the explicit Gemini model and try again."
            )
        case .unsupportedProtocolVersion(let received, let supported):
            let supportedList = supported.map(String.init).joined(separator: ", ")
            return "The ACP initialize response negotiated unsupported protocol version \(received). AtelierCode supports: \(supportedList)."
        }
    }

    private static func formattedTimeout(_ timeout: TimeInterval) -> String {
        if timeout.rounded(.towardZero) == timeout {
            return "\(Int(timeout))s"
        }

        return String(format: "%.2fs", timeout)
    }

    private static func structuredFailureDescription(
        prefix: String,
        error: ACPError,
        guidance: String? = nil
    ) -> String {
        var segments = ["\(prefix) (code \(error.code))."]

        if let guidance {
            segments.append(guidance)
        }

        segments.append("Server message: \(error.message)")

        if let context = error.contextDescription {
            segments.append("Context: \(context)")
        }

        return segments.joined(separator: " ")
    }
}

nonisolated enum ACPPermissionCategory: String, Sendable {
    case agentTool
    case fileRead
    case fileWrite
    case terminal
}

nonisolated struct ACPPermissionContext: Sendable {
    let category: ACPPermissionCategory
    let sessionId: String
    let toolCallId: String?
}

nonisolated enum ACPPermissionLocalAction: Sendable {
    case fileRead(path: String)
    case terminalCreate(command: String, cwd: String)
    case terminalKill(terminalId: String)
    case terminalRelease(terminalId: String)

    var data: ACPJSONValue {
        switch self {
        case .fileRead(let path):
            return .object([
                "reason": .string("file_read"),
                "path": .string(path),
            ])
        case .terminalCreate(let command, let cwd):
            return .object([
                "reason": .string("terminal_create"),
                "command": .string(command),
                "cwd": .string(cwd),
            ])
        case .terminalKill(let terminalId):
            return .object([
                "reason": .string("terminal_kill"),
                "terminalId": .string(terminalId),
            ])
        case .terminalRelease(let terminalId):
            return .object([
                "reason": .string("terminal_release"),
                "terminalId": .string(terminalId),
            ])
        }
    }

    var defaultDeniedMessage: String {
        switch self {
        case .fileRead(let path):
            return "AtelierCode denied workspace read access to \(path)."
        case .terminalCreate(let command, let cwd):
            return "AtelierCode denied terminal creation for \(command) in \(cwd)."
        case .terminalKill(let terminalId):
            return "AtelierCode denied killing terminal \(terminalId)."
        case .terminalRelease(let terminalId):
            return "AtelierCode denied releasing terminal \(terminalId)."
        }
    }
}

nonisolated enum ACPPermissionAuthorization: Sendable {
    case allow
    case deny(message: String?)
}

nonisolated struct ACPPermissionPolicy: Sendable {
    private let resolveOutcome: @Sendable (ACPRequestPermissionRequest, ACPPermissionContext) async -> ACPRequestPermissionOutcome
    private let authorizeLocalAction: @Sendable (ACPPermissionLocalAction, ACPPermissionContext) async -> ACPPermissionAuthorization

    init(
        resolveOutcome: @escaping @Sendable (ACPRequestPermissionRequest, ACPPermissionContext) async -> ACPRequestPermissionOutcome,
        authorizeLocalAction: @escaping @Sendable (ACPPermissionLocalAction, ACPPermissionContext) async -> ACPPermissionAuthorization = { _, _ in .allow }
    ) {
        self.resolveOutcome = resolveOutcome
        self.authorizeLocalAction = authorizeLocalAction
    }

    func outcome(
        for request: ACPRequestPermissionRequest,
        context: ACPPermissionContext
    ) async -> ACPRequestPermissionOutcome {
        await resolveOutcome(request, context)
    }

    func authorization(
        for action: ACPPermissionLocalAction,
        context: ACPPermissionContext
    ) async -> ACPPermissionAuthorization {
        await authorizeLocalAction(action, context)
    }

    static let autoApproveCompatible = ACPPermissionPolicy { request, _ in
        let preferredOption =
            request.options.first(where: { $0.kind == "allow_once" }) ??
            request.options.first(where: { $0.kind == "allow_always" }) ??
            request.options.first

        return preferredOption.map { ACPRequestPermissionOutcome.selected(optionId: $0.optionId) }
            ?? .cancelled
    }
}

nonisolated struct ACPWorkspaceAccessPolicy: Sendable {
    let workspaceRoot: String

    init(workspaceRoot: String) {
        self.workspaceRoot = Self.canonicalPath(for: workspaceRoot)
    }

    func readTextFile(request: ACPReadTextFileRequest) throws -> ACPReadTextFileResponse {
        let authorizedRead = try authorizeRead(request: request)
        return try readTextFile(authorizedRead)
    }

    func resolveAuthorizedRead(request: ACPReadTextFileRequest) throws -> AuthorizedWorkspaceRead {
        try authorizeRead(request: request)
    }

    func readTextFile(_ authorizedRead: AuthorizedWorkspaceRead) throws -> ACPReadTextFileResponse {
        let content = try Self.readTextContent(
            at: authorizedRead.resolvedPath,
            startLine: authorizedRead.startLine,
            lineLimit: authorizedRead.lineLimit
        )
        return ACPReadTextFileResponse(content: content)
    }

    func resolveDirectoryPath(_ path: String?) throws -> String {
        let resolvedPath = try resolvePath(path)
        var isDirectory = ObjCBool(false)

        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            throw ACPWorkspaceAccessError.directoryMissing(path: resolvedPath)
        }

        guard isDirectory.boolValue else {
            throw ACPWorkspaceAccessError.notADirectory(path: resolvedPath)
        }

        return resolvedPath
    }

    private func authorizeRead(request: ACPReadTextFileRequest) throws -> AuthorizedWorkspaceRead {
        guard request.limit == nil || request.limit.map({ $0 >= 0 }) == true else {
            throw ACPWorkspaceAccessError.invalidReadRange(
                line: request.line,
                limit: request.limit
            )
        }

        guard request.line == nil || request.line.map({ $0 >= 0 }) == true else {
            throw ACPWorkspaceAccessError.invalidReadRange(
                line: request.line,
                limit: request.limit
            )
        }

        let standardizedPath = try resolvePath(request.path)

        var isDirectory = ObjCBool(false)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: standardizedPath, isDirectory: &isDirectory) else {
            throw ACPWorkspaceAccessError.fileMissing(path: standardizedPath)
        }

        guard !isDirectory.boolValue else {
            throw ACPWorkspaceAccessError.notAFile(path: standardizedPath)
        }

        return AuthorizedWorkspaceRead(
            resolvedPath: standardizedPath,
            startLine: max(request.line ?? 1, 1),
            lineLimit: request.limit
        )
    }

    private static func readTextContent(
        at path: String,
        startLine: Int,
        lineLimit: Int?
    ) throws -> String {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let rawText = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return slice(text: rawText, startLine: startLine, lineLimit: lineLimit)
        } catch {
            throw ACPWorkspaceAccessError.readFailed(path: path)
        }
    }

    private static func slice(text: String, startLine: Int, lineLimit: Int?) -> String {
        guard !text.isEmpty else { return "" }
        guard lineLimit != .some(0) else { return "" }

        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let startIndex = max(startLine - 1, 0)

        guard startIndex < lines.count else { return "" }

        let endIndex = lineLimit.map { min(startIndex + $0, lines.count) } ?? lines.count
        return Array(lines[startIndex..<endIndex]).joined(separator: "\n")
    }

    private static func isWithinWorkspace(_ path: String, workspaceRoot: String) -> Bool {
        path == workspaceRoot || path.hasPrefix(workspaceRoot + "/")
    }

    private static func canonicalPath(for path: String) -> String {
        let fileManager = FileManager.default
        var existingURL = URL(fileURLWithPath: path).standardizedFileURL
        var missingPathComponents: [String] = []

        while existingURL.path != "/", !fileManager.fileExists(atPath: existingURL.path) {
            missingPathComponents.insert(existingURL.lastPathComponent, at: 0)
            existingURL.deleteLastPathComponent()
        }

        return missingPathComponents
            .reduce(existingURL.resolvingSymlinksInPath()) { partialURL, component in
                partialURL.appendingPathComponent(component)
            }
            .path
    }

    private func resolvePath(_ path: String?) throws -> String {
        let requestedPath = path ?? workspaceRoot
        let trimmedPath = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw ACPWorkspaceAccessError.invalidPath(requestedPath)
        }

        let baseURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        let candidateURL: URL
        if trimmedPath.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: trimmedPath)
        } else {
            candidateURL = baseURL.appendingPathComponent(trimmedPath)
        }

        let standardizedPath = Self.canonicalPath(for: candidateURL.path)
        guard Self.isWithinWorkspace(standardizedPath, workspaceRoot: workspaceRoot) else {
            throw ACPWorkspaceAccessError.pathOutsideWorkspace(
                requestedPath: requestedPath,
                resolvedPath: standardizedPath,
                workspaceRoot: workspaceRoot
            )
        }

        return standardizedPath
    }

    struct AuthorizedWorkspaceRead: Sendable {
        let resolvedPath: String
        let startLine: Int
        let lineLimit: Int?
    }
}

nonisolated enum ACPWorkspaceAccessError: LocalizedError, Sendable {
    case invalidPath(String)
    case invalidReadRange(line: Int?, limit: Int?)
    case pathOutsideWorkspace(requestedPath: String, resolvedPath: String, workspaceRoot: String)
    case fileMissing(path: String)
    case notAFile(path: String)
    case directoryMissing(path: String)
    case notADirectory(path: String)
    case readFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "AtelierCode could not resolve the requested file path \(path)."
        case .invalidReadRange(let line, let limit):
            return "AtelierCode received an invalid file read range (line: \(line.map(String.init) ?? "nil"), limit: \(limit.map(String.init) ?? "nil"))."
        case .pathOutsideWorkspace(_, let resolvedPath, let workspaceRoot):
            return "AtelierCode denied file access to \(resolvedPath) because it is outside the active workspace root \(workspaceRoot)."
        case .fileMissing(let path):
            return "AtelierCode could not read \(path) because the file does not exist."
        case .notAFile(let path):
            return "AtelierCode can only read text files, but \(path) is not a regular file."
        case .directoryMissing(let path):
            return "AtelierCode could not open terminal working directory \(path) because it does not exist."
        case .notADirectory(let path):
            return "AtelierCode can only launch terminals from directories, but \(path) is not a directory."
        case .readFailed(let path):
            return "AtelierCode could not read the requested file at \(path)."
        }
    }

    var clientError: ACPClientError {
        switch self {
        case .invalidPath(let path):
            return ACPClientError(
                code: ACPClientErrorCode.invalidParams,
                message: errorDescription ?? "Invalid file path.",
                data: .object([
                    "reason": .string("invalid_path"),
                    "path": .string(path),
                ])
            )
        case .invalidReadRange(let line, let limit):
            return ACPClientError(
                code: ACPClientErrorCode.invalidParams,
                message: errorDescription ?? "Invalid file read range.",
                data: .object([
                    "reason": .string("invalid_read_range"),
                    "line": line.map(ACPJSONValue.int) ?? .null,
                    "limit": limit.map(ACPJSONValue.int) ?? .null,
                ])
            )
        case .pathOutsideWorkspace(let requestedPath, let resolvedPath, let workspaceRoot):
            return ACPClientError(
                code: ACPClientErrorCode.permissionDenied,
                message: errorDescription ?? "Path is outside the active workspace.",
                data: .object([
                    "reason": .string("path_outside_workspace"),
                    "requestedPath": .string(requestedPath),
                    "resolvedPath": .string(resolvedPath),
                    "workspaceRoot": .string(workspaceRoot),
                ])
            )
        case .fileMissing(let path):
            return ACPClientError(
                code: ACPClientErrorCode.resourceNotFound,
                message: errorDescription ?? "File not found.",
                data: .object([
                    "reason": .string("not_found"),
                    "path": .string(path),
                ])
            )
        case .notAFile(let path):
            return ACPClientError(
                code: ACPClientErrorCode.invalidParams,
                message: errorDescription ?? "Requested path is not a regular file.",
                data: .object([
                    "reason": .string("not_a_file"),
                    "path": .string(path),
                ])
            )
        case .directoryMissing(let path):
            return ACPClientError(
                code: ACPClientErrorCode.resourceNotFound,
                message: errorDescription ?? "Directory not found.",
                data: .object([
                    "reason": .string("directory_not_found"),
                    "path": .string(path),
                ])
            )
        case .notADirectory(let path):
            return ACPClientError(
                code: ACPClientErrorCode.invalidParams,
                message: errorDescription ?? "Requested path is not a directory.",
                data: .object([
                    "reason": .string("not_a_directory"),
                    "path": .string(path),
                ])
            )
        case .readFailed(let path):
            return ACPClientError(
                code: ACPClientErrorCode.internalError,
                message: errorDescription ?? "The requested file could not be read.",
                data: .object([
                    "reason": .string("read_failed"),
                    "path": .string(path),
                ])
            )
        }
    }
}

nonisolated enum ACPTerminalManagerError: LocalizedError, Sendable {
    case invalidCommand
    case invalidOutputByteLimit(Int)
    case executableNotFound(command: String, cwd: String)
    case terminalNotFound(String)
    case terminalReleased(String)
    case launchFailed(command: String, cwd: String)

    var errorDescription: String? {
        switch self {
        case .invalidCommand:
            return "AtelierCode received an empty terminal command."
        case .invalidOutputByteLimit(let limit):
            return "AtelierCode received an invalid terminal output byte limit \(limit)."
        case .executableNotFound(let command, let cwd):
            return "AtelierCode could not resolve terminal command \(command) from \(cwd)."
        case .terminalNotFound(let terminalId):
            return "AtelierCode could not find terminal \(terminalId)."
        case .terminalReleased(let terminalId):
            return "AtelierCode terminal \(terminalId) has already been released."
        case .launchFailed(let command, let cwd):
            return "AtelierCode failed to launch terminal command \(command) in \(cwd)."
        }
    }

    var clientError: ACPClientError {
        switch self {
        case .invalidCommand:
            return ACPClientError(
                code: ACPClientErrorCode.invalidParams,
                message: errorDescription ?? "Invalid terminal command.",
                data: .object([
                    "reason": .string("invalid_terminal_command"),
                ])
            )
        case .invalidOutputByteLimit(let limit):
            return ACPClientError(
                code: ACPClientErrorCode.invalidParams,
                message: errorDescription ?? "Invalid terminal output byte limit.",
                data: .object([
                    "reason": .string("invalid_output_byte_limit"),
                    "outputByteLimit": .int(limit),
                ])
            )
        case .executableNotFound(let command, let cwd):
            return ACPClientError(
                code: ACPClientErrorCode.resourceNotFound,
                message: errorDescription ?? "Terminal command not found.",
                data: .object([
                    "reason": .string("terminal_executable_not_found"),
                    "command": .string(command),
                    "cwd": .string(cwd),
                ])
            )
        case .terminalNotFound(let terminalId):
            return ACPClientError(
                code: ACPClientErrorCode.resourceNotFound,
                message: errorDescription ?? "Terminal not found.",
                data: .object([
                    "reason": .string("terminal_not_found"),
                    "terminalId": .string(terminalId),
                ])
            )
        case .terminalReleased(let terminalId):
            return ACPClientError(
                code: ACPClientErrorCode.resourceNotFound,
                message: errorDescription ?? "Terminal has already been released.",
                data: .object([
                    "reason": .string("terminal_released"),
                    "terminalId": .string(terminalId),
                ])
            )
        case .launchFailed(let command, let cwd):
            return ACPClientError(
                code: ACPClientErrorCode.internalError,
                message: errorDescription ?? "Terminal launch failed.",
                data: .object([
                    "reason": .string("terminal_launch_failed"),
                    "command": .string(command),
                    "cwd": .string(cwd),
                ])
            )
        }
    }
}

@MainActor
final class ACPTerminalSessionManager {
    var onStateChange: ((ACPTerminalState) -> Void)?
    var onReset: (() -> Void)?

    private let processFactory: () -> Process
    private let pipeFactory: () -> Pipe
    private let currentEnvironment: [String: String]

    private struct TerminalRecord {
        var state: ACPTerminalState
        let outputByteLimit: Int?
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        var exitWaiters: [CheckedContinuation<ACPTerminalExitStatus, Never>]
    }

    private var terminals: [String: TerminalRecord] = [:]

    init(
        processFactory: @escaping () -> Process = { Process() },
        pipeFactory: @escaping () -> Pipe = { Pipe() },
        currentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.processFactory = processFactory
        self.pipeFactory = pipeFactory
        self.currentEnvironment = currentEnvironment
    }

    func createTerminal(
        request: ACPCreateTerminalRequest,
        workspaceAccessPolicy: ACPWorkspaceAccessPolicy
    ) throws -> ACPCreateTerminalResponse {
        let command = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw ACPTerminalManagerError.invalidCommand
        }

        if let outputByteLimit = request.outputByteLimit, outputByteLimit < 0 {
            throw ACPTerminalManagerError.invalidOutputByteLimit(outputByteLimit)
        }

        let resolvedCwd = try workspaceAccessPolicy.resolveDirectoryPath(request.cwd)
        let environmentOverrides = Dictionary(uniqueKeysWithValues: (request.env ?? []).map { ($0.name, $0.value) })
        let resolvedExecutable = try resolveExecutable(command: command, cwd: resolvedCwd, environmentOverrides: environmentOverrides)
        let executableURL = URL(fileURLWithPath: resolvedExecutable)

        var environment = GeminiProcessEnvironment.make(
            currentEnvironment: currentEnvironment,
            executableDirectory: executableURL.deletingLastPathComponent().path
        )
        for (name, value) in environmentOverrides {
            environment[name] = value
        }
        environment["PWD"] = resolvedCwd

        let process = processFactory()
        let stdinPipe = pipeFactory()
        let stdoutPipe = pipeFactory()
        let stderrPipe = pipeFactory()
        let terminalId = "terminal_\(UUID().uuidString)"

        process.executableURL = executableURL
        process.arguments = request.args ?? []
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: resolvedCwd, isDirectory: true)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }

            Task { @MainActor [weak self] in
                self?.appendOutput(data, to: terminalId)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }

            Task { @MainActor [weak self] in
                self?.appendOutput(data, to: terminalId)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.handleTermination(
                    terminalId: terminalId,
                    status: process.terminationStatus,
                    reason: process.terminationReason
                )
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw ACPTerminalManagerError.launchFailed(command: command, cwd: resolvedCwd)
        }

        try? stdinPipe.fileHandleForWriting.close()

        let state = ACPTerminalState(
            id: terminalId,
            command: command,
            cwd: resolvedCwd,
            output: "",
            truncated: false,
            exitStatus: nil,
            isReleased: false
        )
        terminals[terminalId] = TerminalRecord(
            state: state,
            outputByteLimit: request.outputByteLimit,
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            exitWaiters: []
        )
        onStateChange?(state)

        return ACPCreateTerminalResponse(terminalId: terminalId)
    }

    func output(for terminalId: String) throws -> ACPTerminalOutputResponse {
        let record = try terminalRecord(for: terminalId)
        return ACPTerminalOutputResponse(
            output: record.state.output,
            truncated: record.state.truncated,
            exitStatus: record.state.exitStatus
        )
    }

    func waitForExit(of terminalId: String) async throws -> ACPWaitForTerminalExitResponse {
        let currentRecord = try terminalRecord(for: terminalId)
        if let exitStatus = currentRecord.state.exitStatus {
            return ACPWaitForTerminalExitResponse(exitCode: exitStatus.exitCode, signal: exitStatus.signal)
        }

        let exitStatus = await withCheckedContinuation { continuation in
            guard var record = terminals[terminalId] else {
                continuation.resume(returning: ACPTerminalExitStatus(exitCode: nil, signal: "SIGTERM"))
                return
            }

            record.exitWaiters.append(continuation)
            terminals[terminalId] = record
        }

        return ACPWaitForTerminalExitResponse(exitCode: exitStatus.exitCode, signal: exitStatus.signal)
    }

    func kill(terminalId: String) throws -> ACPKillTerminalResponse {
        let record = try terminalRecord(for: terminalId)
        if record.state.exitStatus == nil, record.process.isRunning {
            record.process.terminate()
        }
        return ACPKillTerminalResponse()
    }

    func release(terminalId: String) throws -> ACPReleaseTerminalResponse {
        var record = try terminalRecord(for: terminalId)
        record.state.isReleased = true
        terminals[terminalId] = record
        onStateChange?(record.state)

        if record.state.exitStatus == nil, record.process.isRunning {
            record.process.terminate()
        } else {
            cleanupTerminal(terminalId: terminalId)
        }

        return ACPReleaseTerminalResponse()
    }

    func reset() {
        for terminalId in Array(terminals.keys) {
            guard var record = terminals[terminalId] else { continue }
            if record.state.exitStatus == nil {
                let fallbackExit = ACPTerminalExitStatus(exitCode: nil, signal: "SIGTERM")
                record.state.exitStatus = fallbackExit
                let waiters = record.exitWaiters
                record.exitWaiters.removeAll()
                terminals[terminalId] = record

                if record.process.isRunning {
                    record.process.terminate()
                }

                for waiter in waiters {
                    waiter.resume(returning: fallbackExit)
                }
            }

            cleanupResources(for: record)
        }

        terminals.removeAll()
        onReset?()
    }

    private func terminalRecord(for terminalId: String) throws -> TerminalRecord {
        guard let record = terminals[terminalId] else {
            throw ACPTerminalManagerError.terminalNotFound(terminalId)
        }

        guard !record.state.isReleased else {
            throw ACPTerminalManagerError.terminalReleased(terminalId)
        }

        return record
    }

    private func appendOutput(_ data: Data, to terminalId: String) {
        guard var record = terminals[terminalId] else { return }

        let chunk = String(decoding: data, as: UTF8.self)
        applyOutputChunk(chunk, to: &record.state, outputByteLimit: record.outputByteLimit)
        terminals[terminalId] = record
        onStateChange?(record.state)
    }

    private func handleTermination(
        terminalId: String,
        status: Int32,
        reason: Process.TerminationReason
    ) {
        guard var record = terminals[terminalId] else { return }

        let exitStatus = Self.exitStatus(for: status, reason: reason)
        record.state.exitStatus = exitStatus
        let waiters = record.exitWaiters
        record.exitWaiters.removeAll()
        terminals[terminalId] = record
        onStateChange?(record.state)

        for waiter in waiters {
            waiter.resume(returning: exitStatus)
        }

        if record.state.isReleased {
            cleanupTerminal(terminalId: terminalId)
        }
    }

    private func cleanupTerminal(terminalId: String) {
        guard let record = terminals.removeValue(forKey: terminalId) else { return }
        cleanupResources(for: record)
    }

    private func cleanupResources(for record: TerminalRecord) {
        record.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        record.stderrPipe.fileHandleForReading.readabilityHandler = nil
        record.process.terminationHandler = nil
        try? record.stdinPipe.fileHandleForWriting.close()
    }

    private func resolveExecutable(
        command: String,
        cwd: String,
        environmentOverrides: [String: String]
    ) throws -> String {
        let candidatePath: String?
        if command.hasPrefix("/") {
            candidatePath = command
        } else if command.contains("/") {
            candidatePath = URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent(command)
                .path
        } else {
            var environment = currentEnvironment
            for (name, value) in environmentOverrides {
                environment[name] = value
            }
            let pathDirectories = (environment["PATH"] ?? "")
                .split(separator: ":")
                .map(String.init)
            candidatePath = pathDirectories
                .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(command).path }
                .first(where: FileManager.default.isExecutableFile(atPath:))
        }

        guard let candidatePath else {
            throw ACPTerminalManagerError.executableNotFound(command: command, cwd: cwd)
        }

        let standardizedPath = URL(fileURLWithPath: candidatePath).standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: standardizedPath) else {
            throw ACPTerminalManagerError.executableNotFound(command: command, cwd: cwd)
        }

        return standardizedPath
    }

    private func applyOutputChunk(
        _ chunk: String,
        to state: inout ACPTerminalState,
        outputByteLimit: Int?
    ) {
        state.output += chunk

        guard let outputByteLimit else { return }
        guard state.output.lengthOfBytes(using: .utf8) > outputByteLimit else { return }

        state.truncated = true
        while state.output.lengthOfBytes(using: .utf8) > outputByteLimit, !state.output.isEmpty {
            state.output.removeFirst()
        }
    }

    private static func exitStatus(
        for status: Int32,
        reason: Process.TerminationReason
    ) -> ACPTerminalExitStatus {
        if reason == .exit {
            return ACPTerminalExitStatus(exitCode: Int(status), signal: nil)
        }

        return ACPTerminalExitStatus(
            exitCode: nil,
            signal: signalName(for: status)
        )
    }

    private static func signalName(for status: Int32) -> String {
        switch status {
        case SIGINT:
            return "SIGINT"
        case SIGTERM:
            return "SIGTERM"
        case SIGKILL:
            return "SIGKILL"
        case SIGHUP:
            return "SIGHUP"
        case SIGQUIT:
            return "SIGQUIT"
        case SIGABRT:
            return "SIGABRT"
        case SIGPIPE:
            return "SIGPIPE"
        case SIGALRM:
            return "SIGALRM"
        default:
            return "SIG\(status)"
        }
    }
}

@MainActor
final class ACPSessionClient {
    var onAgentMessageChunk: ((String) -> Void)?
    var onSessionUpdate: ((ACPSessionUpdateNotificationParams) -> Void)?
    var onPermissionDecision: ((ACPPermissionDecision) -> Void)?
    var onTerminalStateChange: ((ACPTerminalState) -> Void)?
    var onTerminalStatesReset: (() -> Void)?
    var onTransportError: ((any Error) -> Void)?

    private let transport: AgentTransport
    private let requestTimeouts: ACPSessionClientTimeouts
    var permissionPolicy: ACPPermissionPolicy
    private let terminalSessionManager: ACPTerminalSessionManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxDiagnosticLines = 20
    private let maxLifecycleEvents = 20

    private struct PendingResponse {
        let method: ACPMethod
        let timeoutTask: Task<Void, Never>?
        let complete: (Result<Data, any Error>) -> Void
    }

    private var nextRequestID = 1
    private var isTransportStarted = false
    private var pendingResponses: [Int: PendingResponse] = [:]
    private var workspaceAccessPolicy: ACPWorkspaceAccessPolicy?
    private var promptSessionIDInFlight: String?
    private var latestDiagnostics: [String] = []
    private var lifecycleEvents: [ACPTransportLifecycleEvent] = []
    private var lastRequestMethod: String?
    private var lastRequestID: Int?
    private var lastProcessExitStatus: Int?
    private var lastTerminationReason: String?
    private var hasObservedFirstResponse = false

    private(set) var negotiatedProtocolVersion: Int?
    private(set) var sessionID: String?
    private(set) var agentCapabilities: ACPAgentCapabilities?
    private(set) var authMethods: [ACPAuthMethod] = []
    private(set) var lastFailureContext: ACPTransportFailureContext?
    private(set) var lastRecoverableLoadFailure: ACPSessionClientError?
    private(set) var lastRecoverableFailureContext: ACPTransportFailureContext?

    init(
        transport: AgentTransport,
        requestTimeouts: ACPSessionClientTimeouts = .atelierCodeDefault,
        permissionPolicy: ACPPermissionPolicy = .autoApproveCompatible,
        terminalSessionManager: ACPTerminalSessionManager = ACPTerminalSessionManager()
    ) {
        self.transport = transport
        self.requestTimeouts = requestTimeouts
        self.permissionPolicy = permissionPolicy
        self.terminalSessionManager = terminalSessionManager
        transport.onReceive = { [weak self] result in
            self?.handleTransportMessage(result)
        }
        if let localTransport = transport as? LocalACPTransport {
            localTransport.onDiagnostic = { [weak self] diagnostic in
                self?.appendDiagnostic(diagnostic)
            }
        }
        terminalSessionManager.onStateChange = { [weak self] state in
            self?.onTerminalStateChange?(state)
        }
        terminalSessionManager.onReset = { [weak self] in
            self?.onTerminalStatesReset?()
        }
    }

    func connect(
        cwd: String = FileManager.default.currentDirectoryPath,
        clientInfo: ACPImplementationInfo = .atelierCode,
        clientCapabilities: ACPClientCapabilities = .atelierCodeDefaults,
        resumeSessionID: String? = nil,
        mcpServers: [ACPMCPServer] = []
    ) async throws {
        guard sessionID == nil else { return }

        try startTransportIfNeeded()

        let initializeResponse: ACPInitializeResponse = try await sendRequest(
            method: .initialize,
            params: ACPInitializeRequestParams(
                protocolVersion: ACPProtocolVersion.current,
                clientCapabilities: clientCapabilities,
                clientInfo: clientInfo
            )
        )

        guard ACPProtocolVersion.isSupported(initializeResponse.protocolVersion) else {
            throw ACPSessionClientError.unsupportedProtocolVersion(
                received: initializeResponse.protocolVersion,
                supported: ACPProtocolVersion.supported.sorted()
            )
        }

        negotiatedProtocolVersion = initializeResponse.protocolVersion
        agentCapabilities = initializeResponse.agentCapabilities
        authMethods = initializeResponse.authMethods ?? []

        sessionID = try await establishSession(
            cwd: cwd,
            resumeSessionID: resumeSessionID,
            mcpServers: mcpServers
        )
        workspaceAccessPolicy = ACPWorkspaceAccessPolicy(workspaceRoot: cwd)
    }

    func sendPrompt(_ text: String) async throws -> ACPPromptResponse {
        guard let sessionID else {
            throw ACPSessionClientError.sessionNotCreated
        }

        promptSessionIDInFlight = sessionID
        defer { promptSessionIDInFlight = nil }

        return try await sendRequest(
            method: .sessionPrompt,
            params: ACPPromptRequestParams(
                sessionId: sessionID,
                prompt: [.text(text)]
            )
        )
    }

    func cancelPrompt() throws {
        guard let sessionID = promptSessionIDInFlight else {
            throw ACPSessionClientError.promptNotInFlight
        }

        try sendNotification(
            method: .sessionCancel,
            params: ACPCancelPromptRequestParams(sessionId: sessionID)
        )
    }

    func reset() {
        sessionID = nil
        workspaceAccessPolicy = nil
        promptSessionIDInFlight = nil
        terminalSessionManager.reset()
        transport.stop()
        cancelPendingResponses()
        nextRequestID = 1
        isTransportStarted = false
        negotiatedProtocolVersion = nil
        agentCapabilities = nil
        authMethods = []
        latestDiagnostics.removeAll()
        lifecycleEvents.removeAll()
        lastRequestMethod = nil
        lastRequestID = nil
        lastProcessExitStatus = nil
        lastTerminationReason = nil
        hasObservedFirstResponse = false
    }

    private func startTransportIfNeeded() throws {
        guard !isTransportStarted else { return }
        latestDiagnostics.removeAll()
        lifecycleEvents.removeAll()
        lastProcessExitStatus = nil
        lastTerminationReason = nil
        hasObservedFirstResponse = false
        try transport.start()
        isTransportStarted = true
        recordLifecycleEvent(.processStarted)
    }

    func takeRecoverableFailureContext() -> ACPTransportFailureContext? {
        defer { lastRecoverableFailureContext = nil }
        return lastRecoverableFailureContext
    }

    func takeRecoverableLoadFailure() -> ACPSessionClientError? {
        defer { lastRecoverableLoadFailure = nil }
        return lastRecoverableLoadFailure
    }

    private func makeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func establishSession(
        cwd: String,
        resumeSessionID: String?,
        mcpServers: [ACPMCPServer]
    ) async throws -> String {
        lastRecoverableLoadFailure = nil
        lastRecoverableFailureContext = nil

        if let resumeSessionID, agentCapabilities?.loadSession == true {
            do {
                _ = try await sendRequest(
                    method: .sessionLoad,
                    params: ACPLoadSessionRequestParams(
                        sessionId: resumeSessionID,
                        cwd: cwd,
                        mcpServers: mcpServers
                    )
                ) as ACPLoadSessionResponse
                return resumeSessionID
            } catch let error as ACPSessionClientError {
                guard shouldFallbackToNewSession(afterLoadFailure: error) else {
                    throw error
                }

                lastRecoverableLoadFailure = error
                recordLifecycleEvent(.recoverableSessionLoadFailure, detail: error.localizedDescription)
                lastRecoverableFailureContext = captureFailureContext(
                    classificationHint: .sessionResumeFailure
                )
            }
        }

        let newSessionResponse: ACPNewSessionResponse = try await sendRequest(
            method: .sessionNew,
            params: ACPNewSessionRequestParams(
                cwd: cwd,
                mcpServers: mcpServers
            )
        )
        return newSessionResponse.sessionId
    }

    private func shouldFallbackToNewSession(afterLoadFailure error: ACPSessionClientError) -> Bool {
        switch error {
        case .serverError(let method, _):
            return method == ACPMethod.sessionLoad.rawValue
        default:
            return false
        }
    }

    private func sendRequest<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        method: ACPMethod,
        params: Params
    ) async throws -> Result {
        let requestID = makeRequestID()
        let request = ACPRequest(id: requestID, method: method.rawValue, params: params)
        let payload = try encoder.encode(request)
        let timeout = requestTimeouts.timeout(for: method)
        lastRequestMethod = method.rawValue
        lastRequestID = requestID

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = PendingResponse(
                method: method,
                timeoutTask: timeout.map { makeTimeoutTask(for: requestID, method: method, timeout: $0) }
            ) { [weak self, decoder] result in
                switch result {
                case .success(let data):
                    do {
                        let response = try decoder.decode(ACPResponse<Result>.self, from: data)

                        if let error = response.error {
                            let classifiedError = Self.classify(error: error, for: method)
                            self?.lastFailureContext = self?.captureFailureContext(
                                classificationHint: method == .sessionLoad ? .sessionResumeFailure : nil
                            )
                            continuation.resume(throwing: classifiedError)
                            return
                        }

                        guard let result = response.result else {
                            self?.lastFailureContext = self?.captureFailureContext(
                                classificationHint: .invalidResponse
                            )
                            continuation.resume(
                                throwing: ACPSessionClientError.missingResult(method: method.rawValue)
                            )
                            return
                        }

                        continuation.resume(returning: result)
                    } catch {
                        self?.lastFailureContext = self?.captureFailureContext(
                            classificationHint: .invalidResponse
                        )
                        continuation.resume(
                            throwing: ACPSessionClientError.invalidResponse(method: method.rawValue)
                        )
                    }

                case .failure(let error):
                    self?.lastFailureContext = self?.captureFailureContext(
                        classificationHint: self?.recoveryKind(for: error, method: method)
                    )
                    continuation.resume(throwing: error)
                }
            }

            do {
                try transport.send(message: payload)
            } catch {
                recordLifecycleEvent(.sendFailure, detail: "\(method.rawValue) (#\(requestID))")
                let resolvedError = classifyTransportSendError(
                    error,
                    method: method,
                    requestID: requestID
                )
                lastFailureContext = captureFailureContext(
                    classificationHint: recoveryKind(for: resolvedError, method: method)
                )
                resolvePendingResponse(requestID: requestID, with: .failure(resolvedError))
            }
        }
    }

    private func sendNotification<Params: Encodable & Sendable>(
        method: ACPMethod,
        params: Params
    ) throws {
        let notification = ACPNotificationRequest(method: method.rawValue, params: params)
        do {
            try transport.send(message: encoder.encode(notification))
        } catch {
            recordLifecycleEvent(.sendFailure, detail: method.rawValue)
            let resolvedError = classifyTransportSendError(error, method: method, requestID: nil)
            lastFailureContext = captureFailureContext(
                classificationHint: recoveryKind(for: resolvedError, method: method)
            )
            throw resolvedError
        }
    }

    private func handleTransportMessage(_ result: Result<Data, any Error>) {
        switch result {
        case .success(let data):
            handleIncomingData(data)
        case .failure(let error):
            let pendingMethod = pendingResponses.first?.value.method
            if let transportError = error as? LocalACPTransportError,
               case .processTerminated(let status, let reason) = transportError {
                lastProcessExitStatus = Int(status)
                lastTerminationReason = reason
            }

            recordLifecycleEvent(.terminationObserved, detail: error.localizedDescription)
            failPendingResponses(with: error)
            recordLifecycleEvent(.cleanupCompleted)
            lastFailureContext = captureFailureContext(
                classificationHint: recoveryKind(for: error, method: pendingMethod)
            )
            reset()
            onTransportError?(error)
        }
    }

    private func handleIncomingData(_ data: Data) {
        if !hasObservedFirstResponse {
            hasObservedFirstResponse = true
            recordLifecycleEvent(.firstResponseReceived)
        }

        guard let envelope = try? decoder.decode(ACPIncomingEnvelope.self, from: data) else {
            let error = ACPSessionClientError.invalidResponse(method: lastRequestMethod ?? "unknown")
            failPendingResponses(with: error)
            recordLifecycleEvent(.cleanupCompleted)
            lastFailureContext = captureFailureContext(classificationHint: .invalidResponse)
            reset()
            onTransportError?(error)
            return
        }

        if let method = envelope.method {
            if envelope.id != nil {
                handleRequest(method: method, id: envelope.id, data: data)
            } else {
                handleNotification(method: method, data: data)
            }
            return
        }

        if let id = envelope.id?.intValue {
            resolvePendingResponse(requestID: id, with: .success(data))
            return
        }

        let error = ACPSessionClientError.invalidResponse(method: lastRequestMethod ?? "unknown")
        failPendingResponses(with: error)
        recordLifecycleEvent(.cleanupCompleted)
        lastFailureContext = captureFailureContext(classificationHint: .invalidResponse)
        reset()
        onTransportError?(error)
    }

    private func handleRequest(method: String, id: ACPRequestID?, data: Data) {
        switch method {
        case ACPMethod.sessionRequestPermission.rawValue:
            handlePermissionRequest(id: id, data: data)
        case ACPMethod.fsReadTextFile.rawValue:
            handleReadTextFileRequest(id: id, data: data)
        case ACPMethod.terminalCreate.rawValue:
            handleCreateTerminalRequest(id: id, data: data)
        case ACPMethod.terminalOutput.rawValue:
            handleTerminalOutputRequest(id: id, data: data)
        case ACPMethod.terminalWaitForExit.rawValue:
            handleTerminalWaitForExitRequest(id: id, data: data)
        case ACPMethod.terminalKill.rawValue:
            handleTerminalKillRequest(id: id, data: data)
        case ACPMethod.terminalRelease.rawValue:
            handleTerminalReleaseRequest(id: id, data: data)
        default:
            let errorMessage =
                ACPInterimCapabilityStrategy.atelierCodeCurrent.fallbackErrorMessage(for: method)
                ?? "AtelierCode does not support client ACP method \(method)."
            sendClientErrorResponse(
                id: id,
                code: ACPClientErrorCode.methodNotFound,
                message: errorMessage
            )
        }
    }

    private func handleNotification(method: String, data: Data) {
        guard method == ACPMethod.sessionUpdate.rawValue else {
            return
        }

        guard
            let notification = try? decoder.decode(
                ACPNotification<ACPSessionUpdateNotificationParams>.self,
                from: data
            )
        else {
            return
        }

        if let sessionID, notification.params.sessionId != sessionID {
            return
        }

        onSessionUpdate?(notification.params)

        if let text = notification.params.agentMessageChunkText {
            onAgentMessageChunk?(text)
        }
    }

    private func handlePermissionRequest(id: ACPRequestID?, data: Data) {
        guard
            let request = try? decoder.decode(
                ACPInboundRequest<ACPRequestPermissionRequest>.self,
                from: data
            )
        else {
            sendClientErrorResponse(
                id: id,
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode could not decode the permission request."
            )
            return
        }

        let context = ACPPermissionContext(
            category: .agentTool,
            sessionId: request.params.sessionId,
            toolCallId: request.params.toolCall?.toolCallId
        )

        Task { @MainActor [weak self] in
            guard let self else { return }

            let outcome = await self.permissionPolicy.outcome(for: request.params, context: context)
            self.onPermissionDecision?(
                ACPPermissionDecision(
                    sessionId: request.params.sessionId,
                    toolCallId: request.params.toolCall?.toolCallId,
                    options: request.params.options,
                    outcome: outcome
                )
            )

            if let currentSessionID = self.sessionID, currentSessionID != request.params.sessionId {
                return
            }

            self.sendClientResponse(
                ACPClientResponse(
                    id: request.id,
                    result: ACPRequestPermissionResponse(outcome: outcome)
                )
            )
        }
    }

    private func handleReadTextFileRequest(id: ACPRequestID?, data: Data) {
        guard
            let request = try? decoder.decode(
                ACPInboundRequest<ACPReadTextFileRequest>.self,
                from: data
            )
        else {
            sendClientErrorResponse(
                id: id,
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode could not decode the file read request."
            )
            return
        }

        guard let sessionID else {
            sendClientErrorResponse(
                id: request.id,
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode cannot read files before a session is created."
            )
            return
        }

        guard request.params.sessionId == sessionID else {
            sendClientErrorResponse(
                id: request.id,
                error: ACPClientError(
                    code: ACPClientErrorCode.invalidParams,
                    message: "AtelierCode received a file read request for an unknown ACP session.",
                    data: .object([
                        "reason": .string("unknown_session"),
                        "sessionId": .string(request.params.sessionId),
                        "expectedSessionId": .string(sessionID),
                    ])
                )
            )
            return
        }

        guard let workspaceAccessPolicy else {
            sendClientErrorResponse(
                id: request.id,
                code: ACPClientErrorCode.internalError,
                message: "AtelierCode does not have an active workspace policy for this session."
            )
            return
        }

        let authorizedRead: ACPWorkspaceAccessPolicy.AuthorizedWorkspaceRead
        do {
            authorizedRead = try workspaceAccessPolicy.resolveAuthorizedRead(request: request.params)
        } catch let error as ACPWorkspaceAccessError {
            sendClientErrorResponse(id: request.id, error: error.clientError)
            return
        } catch {
            sendClientErrorResponse(
                id: request.id,
                error: ACPClientError(
                    code: ACPClientErrorCode.internalError,
                    message: "AtelierCode hit an unexpected error while validating a workspace file read.",
                    data: .object([
                        "reason": .string("unexpected_read_validation_failure"),
                        "path": .string(request.params.path),
                    ])
                )
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.assertAuthorized(
                    action: .fileRead(path: authorizedRead.resolvedPath),
                    context: ACPPermissionContext(
                        category: .fileRead,
                        sessionId: sessionID,
                        toolCallId: nil
                    )
                )

                guard self.sessionID == sessionID else { return }

                let response = try workspaceAccessPolicy.readTextFile(authorizedRead)
                self.sendClientResponse(
                    ACPClientResponse(
                        id: request.id,
                        result: response
                    )
                )
            } catch let error as ACPWorkspaceAccessError {
                self.sendClientErrorResponse(id: request.id, error: error.clientError)
            } catch let error as ACPClientError {
                self.sendClientErrorResponse(id: request.id, error: error)
            } catch {
                self.sendClientErrorResponse(
                    id: request.id,
                    error: ACPClientError(
                        code: ACPClientErrorCode.internalError,
                        message: "AtelierCode hit an unexpected error while reading a workspace file.",
                        data: .object([
                            "reason": .string("unexpected_read_failure"),
                            "path": .string(request.params.path),
                        ])
                    )
                )
            }
        }
    }

    private func handleCreateTerminalRequest(id: ACPRequestID?, data: Data) {
        guard
            let request = try? decoder.decode(
                ACPInboundRequest<ACPCreateTerminalRequest>.self,
                from: data
            )
        else {
            sendClientErrorResponse(
                id: id,
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode could not decode the terminal creation request."
            )
            return
        }

        let sessionID: String
        let workspaceAccessPolicy: ACPWorkspaceAccessPolicy
        do {
            sessionID = try requireKnownSession(requestSessionId: request.params.sessionId)
            workspaceAccessPolicy = try requireWorkspaceAccessPolicy()
        } catch let error as ACPClientError {
            sendClientErrorResponse(id: request.id, error: error)
            return
        } catch {
            sendClientErrorResponse(
                id: request.id,
                code: ACPClientErrorCode.internalError,
                message: "AtelierCode could not validate the terminal creation request."
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.assertAuthorized(
                    action: .terminalCreate(
                        command: request.params.command,
                        cwd: request.params.cwd ?? workspaceAccessPolicy.workspaceRoot
                    ),
                    context: ACPPermissionContext(
                        category: .terminal,
                        sessionId: sessionID,
                        toolCallId: nil
                    )
                )

                guard self.sessionID == sessionID else { return }

                let response = try self.terminalSessionManager.createTerminal(
                    request: request.params,
                    workspaceAccessPolicy: workspaceAccessPolicy
                )
                self.sendClientResponse(ACPClientResponse(id: request.id, result: response))
            } catch let error as ACPWorkspaceAccessError {
                self.sendClientErrorResponse(id: request.id, error: error.clientError)
            } catch let error as ACPTerminalManagerError {
                self.sendClientErrorResponse(id: request.id, error: error.clientError)
            } catch let error as ACPClientError {
                self.sendClientErrorResponse(id: request.id, error: error)
            } catch {
                self.sendClientErrorResponse(
                    id: request.id,
                    error: ACPClientError(
                        code: ACPClientErrorCode.internalError,
                        message: "AtelierCode hit an unexpected error while creating a terminal.",
                        data: .object([
                            "reason": .string("unexpected_terminal_create_failure"),
                            "command": .string(request.params.command),
                        ])
                    )
                )
            }
        }
    }

    private func handleTerminalOutputRequest(id: ACPRequestID?, data: Data) {
        guard
            let request = try? decoder.decode(
                ACPInboundRequest<ACPTerminalOutputRequest>.self,
                from: data
            )
        else {
            sendClientErrorResponse(
                id: id,
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode could not decode the terminal output request."
            )
            return
        }

        do {
            _ = try requireKnownSession(requestSessionId: request.params.sessionId)
            let response = try terminalSessionManager.output(for: request.params.terminalId)
            sendClientResponse(ACPClientResponse(id: request.id, result: response))
        } catch let error as ACPTerminalManagerError {
            sendClientErrorResponse(id: request.id, error: error.clientError)
        } catch let error as ACPClientError {
            sendClientErrorResponse(id: request.id, error: error)
        } catch {
            sendClientErrorResponse(
                id: request.id,
                error: ACPClientError(
                    code: ACPClientErrorCode.internalError,
                    message: "AtelierCode hit an unexpected error while reading terminal output.",
                    data: .object([
                        "reason": .string("unexpected_terminal_output_failure"),
                        "terminalId": .string(request.params.terminalId),
                    ])
                )
            )
        }
    }

    private func handleTerminalWaitForExitRequest(id: ACPRequestID?, data: Data) {
        guard
            let request = try? decoder.decode(
                ACPInboundRequest<ACPWaitForTerminalExitRequest>.self,
                from: data
            )
        else {
            sendClientErrorResponse(
                id: id,
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode could not decode the terminal wait request."
            )
            return
        }

        let expectedSessionId: String
        do {
            expectedSessionId = try requireKnownSession(requestSessionId: request.params.sessionId)
        } catch let error as ACPClientError {
            sendClientErrorResponse(id: request.id, error: error)
            return
        } catch {
            sendClientErrorResponse(
                id: request.id,
                code: ACPClientErrorCode.internalError,
                message: "AtelierCode could not validate the terminal wait request."
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let response = try await self.terminalSessionManager.waitForExit(of: request.params.terminalId)
                guard self.sessionID == expectedSessionId else { return }
                self.sendClientResponse(ACPClientResponse(id: request.id, result: response))
            } catch let error as ACPTerminalManagerError {
                self.sendClientErrorResponse(id: request.id, error: error.clientError)
            } catch {
                self.sendClientErrorResponse(
                    id: request.id,
                    error: ACPClientError(
                        code: ACPClientErrorCode.internalError,
                        message: "AtelierCode hit an unexpected error while waiting for terminal exit.",
                        data: .object([
                            "reason": .string("unexpected_terminal_wait_failure"),
                            "terminalId": .string(request.params.terminalId),
                        ])
                    )
                )
            }
        }
    }

    private func handleTerminalKillRequest(id: ACPRequestID?, data: Data) {
        guard
            let request = try? decoder.decode(
                ACPInboundRequest<ACPKillTerminalRequest>.self,
                from: data
            )
        else {
            sendClientErrorResponse(
                id: id,
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode could not decode the terminal kill request."
            )
            return
        }

        let sessionID: String
        do {
            sessionID = try requireKnownSession(requestSessionId: request.params.sessionId)
        } catch let error as ACPClientError {
            sendClientErrorResponse(id: request.id, error: error)
            return
        } catch {
            sendClientErrorResponse(
                id: request.id,
                code: ACPClientErrorCode.internalError,
                message: "AtelierCode could not validate the terminal kill request."
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.assertAuthorized(
                    action: .terminalKill(terminalId: request.params.terminalId),
                    context: ACPPermissionContext(
                        category: .terminal,
                        sessionId: sessionID,
                        toolCallId: nil
                    )
                )

                guard self.sessionID == sessionID else { return }

                let response = try self.terminalSessionManager.kill(terminalId: request.params.terminalId)
                self.sendClientResponse(ACPClientResponse(id: request.id, result: response))
            } catch let error as ACPTerminalManagerError {
                self.sendClientErrorResponse(id: request.id, error: error.clientError)
            } catch let error as ACPClientError {
                self.sendClientErrorResponse(id: request.id, error: error)
            } catch {
                self.sendClientErrorResponse(
                    id: request.id,
                    error: ACPClientError(
                        code: ACPClientErrorCode.internalError,
                        message: "AtelierCode hit an unexpected error while killing the terminal.",
                        data: .object([
                            "reason": .string("unexpected_terminal_kill_failure"),
                            "terminalId": .string(request.params.terminalId),
                        ])
                    )
                )
            }
        }
    }

    private func handleTerminalReleaseRequest(id: ACPRequestID?, data: Data) {
        guard
            let request = try? decoder.decode(
                ACPInboundRequest<ACPReleaseTerminalRequest>.self,
                from: data
            )
        else {
            sendClientErrorResponse(
                id: id,
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode could not decode the terminal release request."
            )
            return
        }

        let sessionID: String
        do {
            sessionID = try requireKnownSession(requestSessionId: request.params.sessionId)
        } catch let error as ACPClientError {
            sendClientErrorResponse(id: request.id, error: error)
            return
        } catch {
            sendClientErrorResponse(
                id: request.id,
                code: ACPClientErrorCode.internalError,
                message: "AtelierCode could not validate the terminal release request."
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.assertAuthorized(
                    action: .terminalRelease(terminalId: request.params.terminalId),
                    context: ACPPermissionContext(
                        category: .terminal,
                        sessionId: sessionID,
                        toolCallId: nil
                    )
                )

                guard self.sessionID == sessionID else { return }

                let response = try self.terminalSessionManager.release(terminalId: request.params.terminalId)
                self.sendClientResponse(ACPClientResponse(id: request.id, result: response))
            } catch let error as ACPTerminalManagerError {
                self.sendClientErrorResponse(id: request.id, error: error.clientError)
            } catch let error as ACPClientError {
                self.sendClientErrorResponse(id: request.id, error: error)
            } catch {
                self.sendClientErrorResponse(
                    id: request.id,
                    error: ACPClientError(
                        code: ACPClientErrorCode.internalError,
                        message: "AtelierCode hit an unexpected error while releasing the terminal.",
                        data: .object([
                            "reason": .string("unexpected_terminal_release_failure"),
                            "terminalId": .string(request.params.terminalId),
                        ])
                    )
                )
            }
        }
    }

    private func requireKnownSession(requestSessionId: String) throws -> String {
        guard let sessionID else {
            throw ACPClientError(
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode cannot handle ACP client requests before a session is created."
            )
        }

        guard requestSessionId == sessionID else {
            throw ACPClientError(
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode received an ACP client request for an unknown session.",
                data: .object([
                    "reason": .string("unknown_session"),
                    "sessionId": .string(requestSessionId),
                    "expectedSessionId": .string(sessionID),
                ])
            )
        }

        return sessionID
    }

    private func requireWorkspaceAccessPolicy() throws -> ACPWorkspaceAccessPolicy {
        guard let workspaceAccessPolicy else {
            throw ACPClientError(
                code: ACPClientErrorCode.internalError,
                message: "AtelierCode does not have an active workspace policy for this session."
            )
        }

        return workspaceAccessPolicy
    }

    private func assertAuthorized(
        action: ACPPermissionLocalAction,
        context: ACPPermissionContext
    ) async throws {
        let authorization = await permissionPolicy.authorization(for: action, context: context)
        guard case .allow = authorization else {
            let deniedMessage: String
            if case .deny(let message) = authorization {
                deniedMessage = message ?? action.defaultDeniedMessage
            } else {
                deniedMessage = action.defaultDeniedMessage
            }

            throw ACPClientError(
                code: ACPClientErrorCode.permissionDenied,
                message: deniedMessage,
                data: action.data
            )
        }
    }

    private func sendClientResponse<Result: Encodable & Sendable>(_ response: ACPClientResponse<Result>) {
        do {
            try transport.send(message: encoder.encode(response))
        } catch {
            recordLifecycleEvent(.sendFailure, detail: "client response")
            failPendingResponses(with: error)
            recordLifecycleEvent(.cleanupCompleted)
            lastFailureContext = captureFailureContext(
                classificationHint: recoveryKind(for: error, method: nil)
            )
            reset()
            onTransportError?(error)
        }
    }

    private func sendClientErrorResponse(id: ACPRequestID?, code: Int, message: String) {
        sendClientErrorResponse(
            id: id,
            error: ACPClientError(code: code, message: message)
        )
    }

    private func sendClientErrorResponse(id: ACPRequestID?, error: ACPClientError) {
        do {
            try transport.send(
                message: encoder.encode(
                    ACPClientErrorResponse(
                        id: id,
                        error: error
                    )
                )
            )
        } catch {
            recordLifecycleEvent(.sendFailure, detail: "client error response")
            failPendingResponses(with: error)
            recordLifecycleEvent(.cleanupCompleted)
            lastFailureContext = captureFailureContext(
                classificationHint: recoveryKind(for: error, method: nil)
            )
            reset()
            onTransportError?(error)
        }
    }

    private func failPendingResponses(with error: any Error) {
        let responses = Array(pendingResponses.values)
        pendingResponses.removeAll()

        for response in responses {
            response.timeoutTask?.cancel()
            response.complete(.failure(error))
        }
    }

    private func resolvePendingResponse(requestID: Int, with result: Result<Data, any Error>) {
        guard let pendingResponse = pendingResponses.removeValue(forKey: requestID) else {
            return
        }

        pendingResponse.timeoutTask?.cancel()
        pendingResponse.complete(result)
    }

    private func cancelPendingResponses() {
        let responses = Array(pendingResponses.values)
        pendingResponses.removeAll()

        for response in responses {
            response.timeoutTask?.cancel()
        }
    }

    private func appendDiagnostic(_ diagnostic: String) {
        let trimmedDiagnostic = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDiagnostic.isEmpty else { return }

        latestDiagnostics.append(trimmedDiagnostic)
        if latestDiagnostics.count > maxDiagnosticLines {
            latestDiagnostics.removeFirst(latestDiagnostics.count - maxDiagnosticLines)
        }
    }

    private func recordLifecycleEvent(
        _ kind: ACPTransportLifecycleEventKind,
        detail: String? = nil,
        occurredAt: Date = Date()
    ) {
        lifecycleEvents.append(
            ACPTransportLifecycleEvent(
                occurredAt: occurredAt,
                kind: kind,
                detail: detail
            )
        )

        if lifecycleEvents.count > maxLifecycleEvents {
            lifecycleEvents.removeFirst(lifecycleEvents.count - maxLifecycleEvents)
        }
    }

    private func captureFailureContext(
        classificationHint: ACPRecoveryIssueKind? = nil,
        occurredAt: Date = Date()
    ) -> ACPTransportFailureContext {
        ACPTransportFailureContext(
            occurredAt: occurredAt,
            classificationHint: classificationHint,
            processExitStatus: lastProcessExitStatus,
            terminationReason: lastTerminationReason,
            lastRequestMethod: lastRequestMethod,
            lastRequestID: lastRequestID,
            wasPromptInFlight: promptSessionIDInFlight != nil,
            diagnostics: latestDiagnostics,
            lifecycleEvents: lifecycleEvents
        )
    }

    private func classifyTransportSendError(
        _ error: any Error,
        method: ACPMethod,
        requestID: Int?
    ) -> any Error {
        if let transportError = error as? LocalACPTransportError,
           case .processNotRunning = transportError {
            return ACPSessionClientError.deadTransport(
                method: method.rawValue,
                requestID: requestID
            )
        }

        return error
    }

    private func recoveryKind(
        for error: any Error,
        method: ACPMethod?
    ) -> ACPRecoveryIssueKind? {
        if let sessionError = error as? ACPSessionClientError {
            switch sessionError {
            case .requestTimedOut:
                return .requestTimeout
            case .invalidResponse:
                return .invalidResponse
            case .deadTransport:
                return .deadTransportWhileSending
            case .serverError(let method, _) where method == ACPMethod.sessionLoad.rawValue:
                return .sessionResumeFailure
            default:
                break
            }
        }

        if let transportError = error as? LocalACPTransportError {
            return transportError.recoveryKind
        }

        if let method, method == .sessionLoad {
            return .sessionResumeFailure
        }

        return nil
    }

    private func makeTimeoutTask(for requestID: Int, method: ACPMethod, timeout: TimeInterval) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(for: timeout))
            } catch {
                return
            }

            await MainActor.run {
                let timeoutError = ACPSessionClientError.requestTimedOut(
                    method: method.rawValue,
                    timeout: timeout
                )
                self?.lastFailureContext = self?.captureFailureContext(
                    classificationHint: .requestTimeout
                )
                self?.resolvePendingResponse(
                    requestID: requestID,
                    with: .failure(timeoutError)
                )
            }
        }
    }

    private static func classify(error: ACPError, for method: ACPMethod) -> ACPSessionClientError {
        if error.isAuthenticationRelated {
            return .authenticationRequired(method: method.rawValue, error: error)
        }

        if error.isModelRelated {
            return .modelUnavailable(method: method.rawValue, error: error)
        }

        return .serverError(method: method.rawValue, error: error)
    }

    private static func nanoseconds(for timeout: TimeInterval) -> UInt64 {
        let seconds = max(timeout, 0)
        return UInt64(seconds * 1_000_000_000)
    }
}
