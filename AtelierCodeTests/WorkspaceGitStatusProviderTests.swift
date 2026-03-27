import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct WorkspaceGitServiceTests {
    @Test func resolvesNamedBranchSnapshot() async throws {
        let workspacePath = "/tmp/branch-workspace"
        let service = WorkspaceGitService(
            commandRunner: StubGitCommandRunner(results: [
                ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "true\n", stderr: "")
                ),
                ["-C", workspacePath, "symbolic-ref", "--quiet", "--short", "HEAD"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "main\n", stderr: "")
                ),
                ["-C", workspacePath, "for-each-ref", "--format=%(refname:short)", "refs/heads"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "feature/status-bar\nmain\n", stderr: "")
                )
            ])
        )

        let snapshot = await service.snapshot(for: workspacePath)

        #expect(snapshot.status == .branch("main"))
        #expect(snapshot.localBranches == ["feature/status-bar", "main"])
    }

    @Test func resolvesDetachedHeadWhenSymbolicRefFails() async throws {
        let workspacePath = "/tmp/detached-workspace"
        let service = WorkspaceGitService(
            commandRunner: StubGitCommandRunner(results: [
                ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "true\n", stderr: "")
                ),
                ["-C", workspacePath, "symbolic-ref", "--quiet", "--short", "HEAD"]: .success(
                    GitCommandResult(exitCode: 1, stdout: "", stderr: "fatal: ref HEAD is not a symbolic ref\n")
                ),
                ["-C", workspacePath, "rev-parse", "--short", "HEAD"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "abc1234\n", stderr: "")
                ),
                ["-C", workspacePath, "for-each-ref", "--format=%(refname:short)", "refs/heads"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "main\nrelease\n", stderr: "")
                )
            ])
        )

        let snapshot = await service.snapshot(for: workspacePath)

        #expect(snapshot.status == .detachedHead("abc1234"))
        #expect(snapshot.localBranches == ["main", "release"])
    }

    @Test func reportsNonRepositoryWhenRepositoryCheckFails() async throws {
        let workspacePath = "/tmp/non-repo-workspace"
        let service = WorkspaceGitService(
            commandRunner: StubGitCommandRunner(results: [
                ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]: .success(
                    GitCommandResult(exitCode: 128, stdout: "", stderr: "fatal: not a git repository\n")
                )
            ])
        )

        let snapshot = await service.snapshot(for: workspacePath)

        #expect(snapshot == WorkspaceGitSnapshot(status: .unavailable(.noRepository), localBranches: []))
    }

    @Test func reportsMissingGitExecutable() async throws {
        let workspacePath = "/tmp/missing-git-workspace"
        let service = WorkspaceGitService(
            commandRunner: StubGitCommandRunner(results: [
                ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]: .failure(
                    GitCommandRunnerError.executableUnavailable
                )
            ])
        )

        let snapshot = await service.snapshot(for: workspacePath)

        #expect(snapshot == WorkspaceGitSnapshot(status: .unavailable(.gitUnavailable), localBranches: []))
    }

    @Test func includesCurrentBranchWhenBranchListingOmitsIt() async throws {
        let workspacePath = "/tmp/current-branch-fallback"
        let service = WorkspaceGitService(
            commandRunner: StubGitCommandRunner(results: [
                ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "true\n", stderr: "")
                ),
                ["-C", workspacePath, "symbolic-ref", "--quiet", "--short", "HEAD"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "git-branches\n", stderr: "")
                ),
                ["-C", workspacePath, "for-each-ref", "--format=%(refname:short)", "refs/heads"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "main\n", stderr: "")
                )
            ])
        )

        let snapshot = await service.snapshot(for: workspacePath)

        #expect(snapshot.status == .branch("git-branches"))
        #expect(snapshot.localBranches == ["git-branches", "main"])
    }

    @Test func switchesToExistingLocalBranch() async throws {
        let workspacePath = "/tmp/switch-branch-workspace"
        let service = WorkspaceGitService(
            commandRunner: StubGitCommandRunner(results: [
                ["-C", workspacePath, "switch", "release"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "", stderr: "")
                ),
                ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "true\n", stderr: "")
                ),
                ["-C", workspacePath, "symbolic-ref", "--quiet", "--short", "HEAD"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "release\n", stderr: "")
                ),
                ["-C", workspacePath, "for-each-ref", "--format=%(refname:short)", "refs/heads"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "main\nrelease\n", stderr: "")
                )
            ])
        )

        let snapshot = try await service.switchToBranch(named: "release", for: workspacePath)

        #expect(snapshot.status == .branch("release"))
        #expect(snapshot.localBranches == ["main", "release"])
    }

    @Test func createsAndSwitchesToNewLocalBranch() async throws {
        let workspacePath = "/tmp/create-branch-workspace"
        let service = WorkspaceGitService(
            commandRunner: StubGitCommandRunner(results: [
                ["-C", workspacePath, "switch", "-c", "feature/new-branch"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "", stderr: "")
                ),
                ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "true\n", stderr: "")
                ),
                ["-C", workspacePath, "symbolic-ref", "--quiet", "--short", "HEAD"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "feature/new-branch\n", stderr: "")
                ),
                ["-C", workspacePath, "for-each-ref", "--format=%(refname:short)", "refs/heads"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "feature/new-branch\nmain\n", stderr: "")
                )
            ])
        )

        let snapshot = try await service.createAndSwitchToBranch(named: "feature/new-branch", for: workspacePath)

        #expect(snapshot.status == .branch("feature/new-branch"))
        #expect(snapshot.localBranches == ["feature/new-branch", "main"])
    }

    @Test func propagatesGitCheckoutFailures() async throws {
        let workspacePath = "/tmp/error-branch-workspace"
        let service = WorkspaceGitService(
            commandRunner: StubGitCommandRunner(results: [
                ["-C", workspacePath, "switch", "release"]: .success(
                    GitCommandResult(
                        exitCode: 1,
                        stdout: "",
                        stderr: "error: Your local changes to the following files would be overwritten by switch.\n"
                    )
                )
            ])
        )

        await #expect(throws: WorkspaceGitBranchManagerError.gitRejected(
            "error: Your local changes to the following files would be overwritten by switch."
        )) {
            try await service.switchToBranch(named: "release", for: workspacePath)
        }
    }

    @Test func realRepositorySnapshotIncludesCurrentAndMainBranches() async throws {
        let repositoryURL = try makeGitRepository(named: "workspace-git-snapshot")
        try writeFile(named: "README.md", contents: "hello\n", in: repositoryURL)
        try runGit(arguments: ["add", "README.md"], in: repositoryURL)
        try runGit(arguments: ["commit", "-m", "Initial commit"], in: repositoryURL)
        try runGit(arguments: ["switch", "-c", "git-branches"], in: repositoryURL)

        let snapshot = await WorkspaceGitService().snapshot(for: repositoryURL.path)

        #expect(snapshot.status == .branch("git-branches"))
        #expect(snapshot.localBranches == ["git-branches", "main"])
    }
}

private struct StubGitCommandRunner: GitCommandRunning {
    let results: [[String]: Result<GitCommandResult, Error>]

    func run(arguments: [String]) async throws -> GitCommandResult {
        guard let result = results[arguments] else {
            Issue.record("Unexpected git command: \(arguments)")
            throw StubError.unexpectedCommand
        }

        switch result {
        case .success(let commandResult):
            return commandResult
        case .failure(let error):
            throw error
        }
    }
}

private enum StubError: Error {
    case unexpectedCommand
}

private func makeGitRepository(named name: String) throws -> URL {
    let repositoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
    try runGit(arguments: ["init", "-b", "main"], in: repositoryURL)
    try runGit(arguments: ["config", "user.name", "AtelierCode Tests"], in: repositoryURL)
    try runGit(arguments: ["config", "user.email", "tests@example.com"], in: repositoryURL)
    return repositoryURL
}

private func writeFile(named name: String, contents: String, in directoryURL: URL) throws {
    let fileURL = directoryURL.appendingPathComponent(name, isDirectory: false)
    guard let data = contents.data(using: .utf8) else {
        throw GitFixtureError.commandFailed("Failed to encode fixture contents.")
    }

    try data.write(to: fileURL)
}

@discardableResult
private func runGit(arguments: [String], in directoryURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git", isDirectory: false)
    process.arguments = ["-C", directoryURL.path] + arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    guard process.terminationStatus == 0 else {
        throw GitFixtureError.commandFailed(stderr.isEmpty ? stdout : stderr)
    }

    return stdout
}

private enum GitFixtureError: Error, CustomStringConvertible {
    case commandFailed(String)

    var description: String {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}
