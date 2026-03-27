import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct WorkspaceGitStatusProviderTests {
    @Test func resolvesNamedBranch() async throws {
        let workspacePath = "/tmp/branch-workspace"
        let provider = WorkspaceGitStatusProvider(
            commandRunner: StubGitCommandRunner(results: [
                ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "true\n", stderr: "")
                ),
                ["-C", workspacePath, "symbolic-ref", "--quiet", "--short", "HEAD"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "main\n", stderr: "")
                )
            ])
        )

        let gitStatus = await provider.gitStatus(for: workspacePath)

        #expect(gitStatus == .branch("main"))
    }

    @Test func resolvesDetachedHeadWhenSymbolicRefFails() async throws {
        let workspacePath = "/tmp/detached-workspace"
        let provider = WorkspaceGitStatusProvider(
            commandRunner: StubGitCommandRunner(results: [
                ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "true\n", stderr: "")
                ),
                ["-C", workspacePath, "symbolic-ref", "--quiet", "--short", "HEAD"]: .success(
                    GitCommandResult(exitCode: 1, stdout: "", stderr: "fatal: ref HEAD is not a symbolic ref\n")
                ),
                ["-C", workspacePath, "rev-parse", "--short", "HEAD"]: .success(
                    GitCommandResult(exitCode: 0, stdout: "abc1234\n", stderr: "")
                )
            ])
        )

        let gitStatus = await provider.gitStatus(for: workspacePath)

        #expect(gitStatus == .detachedHead("abc1234"))
    }

    @Test func reportsNonRepositoryWhenRepositoryCheckFails() async throws {
        let workspacePath = "/tmp/non-repo-workspace"
        let provider = WorkspaceGitStatusProvider(
            commandRunner: StubGitCommandRunner(results: [
                ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]: .success(
                    GitCommandResult(exitCode: 128, stdout: "", stderr: "fatal: not a git repository\n")
                )
            ])
        )

        let gitStatus = await provider.gitStatus(for: workspacePath)

        #expect(gitStatus == .unavailable(.noRepository))
    }

    @Test func reportsMissingGitExecutable() async throws {
        let workspacePath = "/tmp/missing-git-workspace"
        let provider = WorkspaceGitStatusProvider(
            commandRunner: StubGitCommandRunner(results: [
                ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"]: .failure(
                    GitCommandRunnerError.executableUnavailable
                )
            ])
        )

        let gitStatus = await provider.gitStatus(for: workspacePath)

        #expect(gitStatus == .unavailable(.gitUnavailable))
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
