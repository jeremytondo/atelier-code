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

struct WorkspaceGitSnapshot: Equatable, Sendable {
    let status: WorkspaceGitStatus
    let localBranches: [String]
}

enum WorkspaceGitBranchManagerError: Error, Equatable, Sendable {
    case gitUnavailable
    case gitRejected(String)

    var message: String {
        switch self {
        case .gitUnavailable:
            return "Git is not available."
        case .gitRejected(let message):
            return message
        }
    }
}

protocol WorkspaceGitServing: Sendable {
    func snapshot(for workspacePath: String) async -> WorkspaceGitSnapshot
    func switchToBranch(named branchName: String, for workspacePath: String) async throws -> WorkspaceGitSnapshot
    func createAndSwitchToBranch(named branchName: String, for workspacePath: String) async throws -> WorkspaceGitSnapshot
}

struct WorkspaceGitService: WorkspaceGitServing {
    private let commandRunner: any GitCommandRunning

    init(commandRunner: (any GitCommandRunning)? = nil) {
        self.commandRunner = commandRunner ?? ProcessGitCommandRunner()
    }

    func snapshot(for workspacePath: String) async -> WorkspaceGitSnapshot {
        await loadSnapshot(for: workspacePath)
    }

    func switchToBranch(named branchName: String, for workspacePath: String) async throws -> WorkspaceGitSnapshot {
        _ = try await run(arguments: ["-C", workspacePath, "switch", branchName])
        let snapshot = await loadSnapshot(for: workspacePath)

        return snapshot.withFallbackBranchName(branchName)
    }

    func createAndSwitchToBranch(named branchName: String, for workspacePath: String) async throws -> WorkspaceGitSnapshot {
        _ = try await run(arguments: ["-C", workspacePath, "switch", "-c", branchName])
        let snapshot = await loadSnapshot(for: workspacePath)

        return snapshot.withFallbackBranchName(branchName)
    }

    private func loadSnapshot(for workspacePath: String) async -> WorkspaceGitSnapshot {
        do {
            let repositoryCheck = try await commandRunner.run(
                arguments: ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]
            )
            guard repositoryCheck.exitCode == 0 else {
                return WorkspaceGitSnapshot(status: .unavailable(.noRepository), localBranches: [])
            }

            let status = try await resolveStatus(for: workspacePath)
            let localBranches = try await resolveLocalBranches(
                for: workspacePath,
                currentBranchName: status.currentBranchName
            )

            return WorkspaceGitSnapshot(
                status: status,
                localBranches: localBranches
            )
        } catch GitCommandRunnerError.executableUnavailable {
            return WorkspaceGitSnapshot(status: .unavailable(.gitUnavailable), localBranches: [])
        } catch {
            return WorkspaceGitSnapshot(status: .unavailable(.lookupFailed), localBranches: [])
        }
    }

    private func resolveStatus(for workspacePath: String) async throws -> WorkspaceGitStatus {
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
    }

    private func resolveLocalBranches(for workspacePath: String, currentBranchName: String?) async throws -> [String] {
        let result = try await commandRunner.run(
            arguments: ["-C", workspacePath, "for-each-ref", "--format=%(refname:short)", "refs/heads"]
        )

        guard result.exitCode == 0 else {
            return Self.normalizeLocalBranches([], currentBranchName: currentBranchName)
        }

        let localBranches = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        return Self.normalizeLocalBranches(localBranches, currentBranchName: currentBranchName)
    }

    private func run(arguments: [String]) async throws -> GitCommandResult {
        do {
            let result = try await commandRunner.run(arguments: arguments)
            guard result.exitCode == 0 else {
                throw WorkspaceGitBranchManagerError.gitRejected(result.failureMessage)
            }

            return result
        } catch GitCommandRunnerError.executableUnavailable {
            throw WorkspaceGitBranchManagerError.gitUnavailable
        } catch let error as WorkspaceGitBranchManagerError {
            throw error
        } catch {
            throw WorkspaceGitBranchManagerError.gitRejected(error.localizedDescription)
        }
    }

    fileprivate static func normalizeLocalBranches(_ branchNames: [String], currentBranchName: String?) -> [String] {
        var seenBranches = Set<String>()
        var normalizedBranches = branchNames
            .map(\.trimmedGitOutput)
            .filter { $0.isEmpty == false }
            .filter { seenBranches.insert($0).inserted }

        if let currentBranchName = currentBranchName?.trimmedGitOutput,
           currentBranchName.isEmpty == false,
           seenBranches.insert(currentBranchName).inserted {
            normalizedBranches.append(currentBranchName)
        }

        normalizedBranches.sort { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        return normalizedBranches
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

    init(executableURL: URL? = nil, fileManager: FileManager = .default) {
        self.executableURL = executableURL ?? Self.defaultExecutableURL(fileManager: fileManager)
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

    private static func defaultExecutableURL(fileManager: FileManager) -> URL {
        for path in candidateExecutablePaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: false)
        }

        return URL(fileURLWithPath: "/usr/bin/git", isDirectory: false)
    }

    private static let candidateExecutablePaths: [String] = [
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/usr/bin/git"
    ]
}

private extension WorkspaceGitSnapshot {
    func withFallbackBranchName(_ branchName: String) -> WorkspaceGitSnapshot {
        guard status.currentBranchName == nil else {
            return self
        }

        return WorkspaceGitSnapshot(
            status: .branch(branchName),
            localBranches: WorkspaceGitService.normalizeLocalBranches(localBranches, currentBranchName: branchName)
        )
    }
}

private extension WorkspaceGitStatus {
    var currentBranchName: String? {
        guard case .branch(let branchName) = self else {
            return nil
        }

        return branchName
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

private extension GitCommandResult {
    var failureMessage: String {
        stderr.trimmedGitOutput.nilIfEmpty
            ?? stdout.trimmedGitOutput.nilIfEmpty
            ?? "Git command failed."
    }
}
