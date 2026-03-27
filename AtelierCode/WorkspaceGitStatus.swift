import Foundation

enum WorkspaceGitStatusUnavailableReason: Equatable, Sendable {
    case noRepository
    case gitUnavailable
    case lookupFailed
}

enum WorkspaceGitStatus: Equatable, Sendable {
    case branch(String)
    case detachedHead(String)
    case unavailable(WorkspaceGitStatusUnavailableReason)
}

protocol WorkspaceGitStatusProviding: Sendable {
    func gitStatus(for workspacePath: String) async -> WorkspaceGitStatus
}

struct WorkspaceGitStatusProvider: WorkspaceGitStatusProviding {
    private let commandRunner: any GitCommandRunning

    init(commandRunner: (any GitCommandRunning)? = nil) {
        self.commandRunner = commandRunner ?? ProcessGitCommandRunner()
    }

    func gitStatus(for workspacePath: String) async -> WorkspaceGitStatus {
        do {
            let repositoryCheck = try await commandRunner.run(
                arguments: ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]
            )
            guard repositoryCheck.exitCode == 0 else {
                return .unavailable(.noRepository)
            }

            let symbolicReference = try await commandRunner.run(
                arguments: ["-C", workspacePath, "symbolic-ref", "--quiet", "--short", "HEAD"]
            )
            if symbolicReference.exitCode == 0,
               let branchName = symbolicReference.stdout.trimmedGitOutput.nilIfEmpty {
                return .branch(branchName)
            }

            let commitReference = try await commandRunner.run(
                arguments: ["-C", workspacePath, "rev-parse", "--short", "HEAD"]
            )
            if commitReference.exitCode == 0,
               let commitSHA = commitReference.stdout.trimmedGitOutput.nilIfEmpty {
                return .detachedHead(commitSHA)
            }

            return .unavailable(.lookupFailed)
        } catch GitCommandRunnerError.executableUnavailable {
            return .unavailable(.gitUnavailable)
        } catch {
            return .unavailable(.lookupFailed)
        }
    }
}

struct GitCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum GitCommandRunnerError: Error, Equatable, Sendable {
    case executableUnavailable
}

protocol GitCommandRunning: Sendable {
    func run(arguments: [String]) async throws -> GitCommandResult
}

struct ProcessGitCommandRunner: GitCommandRunning {
    private let executableURL: URL

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/git", isDirectory: false)) {
        self.executableURL = executableURL
    }

    func run(arguments: [String]) async throws -> GitCommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
                    throw GitCommandRunnerError.executableUnavailable
                }

                if let cocoaError = error as? CocoaError,
                   cocoaError.code == .fileNoSuchFile {
                    throw GitCommandRunnerError.executableUnavailable
                }

                throw error
            }

            process.waitUntilExit()

            let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

            return GitCommandResult(
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: stderr
            )
        }.value
    }
}

private extension String {
    var trimmedGitOutput: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
