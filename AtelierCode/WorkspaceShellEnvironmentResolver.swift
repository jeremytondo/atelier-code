//
//  WorkspaceShellEnvironmentResolver.swift
//  AtelierCode
//
//  Created by Codex on 3/23/26.
//

import Foundation
import Darwin

nonisolated enum WorkspaceShellEnvironmentSource: String, Sendable {
    case freshProbe = "fresh_probe"
    case cachedProbe = "cached_probe"
    case fallbackBootstrap = "fallback_bootstrap"
}

nonisolated struct WorkspaceShellEnvironmentSnapshot: Sendable {
    let workspaceRoot: String
    let shellPath: String
    let environment: [String: String]
    let capturedAt: Date
}

nonisolated struct WorkspaceShellResolvedEnvironment: Sendable {
    let environment: [String: String]
    let source: WorkspaceShellEnvironmentSource
    let shellPath: String
    let workspaceRoot: String
    let probeFailureReason: String?

    var diagnosticMessage: String {
        var parts = [
            "environment_resolution",
            "source=\(source.rawValue)",
            "workspace=\(workspaceRoot)",
            "shell=\(shellPath)"
        ]

        if let probeFailureReason, !probeFailureReason.isEmpty {
            parts.append("probe_failure=\(probeFailureReason.replacingOccurrences(of: " ", with: "_"))")
        }

        return parts.joined(separator: " ")
    }
}

nonisolated struct WorkspaceShellProbeError: Error, Equatable, Sendable {
    let reason: String
}

@MainActor
protocol WorkspaceShellEnvironmentResolving: AnyObject {
    func resolveEnvironment(
        for workspaceRoot: String,
        executableDirectory: String?,
        settingsOverrides: [String: String],
        launchOverrides: [String: String],
        preferFreshProbe: Bool
    ) -> WorkspaceShellResolvedEnvironment

    func invalidateCachedSnapshot(for workspaceRoot: String)
}

@MainActor
final class WorkspaceShellEnvironmentResolver: WorkspaceShellEnvironmentResolving {
    typealias ProbeHandler = (
        _ workspaceRoot: String,
        _ shellPath: String,
        _ currentEnvironment: [String: String],
        _ userHomeDirectory: String,
        _ timeout: TimeInterval
    ) -> Result<[String: String], WorkspaceShellProbeError>

    static let standard = WorkspaceShellEnvironmentResolver()

    private struct CacheKey: Hashable {
        let workspaceRoot: String
        let shellPath: String
    }

    private let currentEnvironment: [String: String]
    private let userHomeDirectory: String
    private let probeTimeout: TimeInterval
    private let probeHandler: ProbeHandler
    private let dateProvider: () -> Date

    private var snapshots: [CacheKey: WorkspaceShellEnvironmentSnapshot] = [:]
    private var staleKeys = Set<CacheKey>()

    init(
        currentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        userHomeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        probeTimeout: TimeInterval = 2,
        probeHandler: @escaping (
            _ workspaceRoot: String,
            _ shellPath: String,
            _ currentEnvironment: [String: String],
            _ userHomeDirectory: String,
            _ timeout: TimeInterval
        ) -> Result<[String: String], WorkspaceShellProbeError> = WorkspaceShellEnvironmentResolver.probeEnvironment,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.currentEnvironment = currentEnvironment
        self.userHomeDirectory = userHomeDirectory
        self.probeTimeout = probeTimeout
        self.probeHandler = probeHandler
        self.dateProvider = dateProvider
    }

    func resolveEnvironment(
        for workspaceRoot: String,
        executableDirectory: String?,
        settingsOverrides: [String: String],
        launchOverrides: [String: String],
        preferFreshProbe: Bool
    ) -> WorkspaceShellResolvedEnvironment {
        let canonicalWorkspaceRoot = Self.canonicalPath(workspaceRoot)
        let shellPath = GeminiProcessEnvironment.resolvedShellPath(currentEnvironment: currentEnvironment)
        let cacheKey = CacheKey(workspaceRoot: canonicalWorkspaceRoot, shellPath: shellPath)
        let shouldProbe = preferFreshProbe || staleKeys.contains(cacheKey) || snapshots[cacheKey] == nil
        let cachedSnapshot = snapshots[cacheKey]

        if !shouldProbe, let cachedSnapshot {
            return makeResolvedEnvironment(
                source: .cachedProbe,
                workspaceRoot: canonicalWorkspaceRoot,
                shellPath: shellPath,
                shellEnvironment: cachedSnapshot.environment,
                executableDirectory: executableDirectory,
                settingsOverrides: settingsOverrides,
                launchOverrides: launchOverrides,
                probeFailureReason: nil
            )
        }

        switch probeHandler(
            canonicalWorkspaceRoot,
            shellPath,
            currentEnvironment,
            userHomeDirectory,
            probeTimeout
        ) {
        case .success(let environment):
            let snapshot = WorkspaceShellEnvironmentSnapshot(
                workspaceRoot: canonicalWorkspaceRoot,
                shellPath: shellPath,
                environment: environment,
                capturedAt: dateProvider()
            )
            snapshots[cacheKey] = snapshot
            staleKeys.remove(cacheKey)
            return makeResolvedEnvironment(
                source: .freshProbe,
                workspaceRoot: canonicalWorkspaceRoot,
                shellPath: shellPath,
                shellEnvironment: environment,
                executableDirectory: executableDirectory,
                settingsOverrides: settingsOverrides,
                launchOverrides: launchOverrides,
                probeFailureReason: nil
            )

        case .failure(let error):
            if let cachedSnapshot {
                staleKeys.remove(cacheKey)
                return makeResolvedEnvironment(
                    source: .cachedProbe,
                    workspaceRoot: canonicalWorkspaceRoot,
                    shellPath: shellPath,
                    shellEnvironment: cachedSnapshot.environment,
                    executableDirectory: executableDirectory,
                    settingsOverrides: settingsOverrides,
                    launchOverrides: launchOverrides,
                    probeFailureReason: error.reason
                )
            }

            staleKeys.remove(cacheKey)
            return makeResolvedEnvironment(
                source: .fallbackBootstrap,
                workspaceRoot: canonicalWorkspaceRoot,
                shellPath: shellPath,
                shellEnvironment: [:],
                executableDirectory: executableDirectory,
                settingsOverrides: settingsOverrides,
                launchOverrides: launchOverrides,
                probeFailureReason: error.reason
            )
        }
    }

    func invalidateCachedSnapshot(for workspaceRoot: String) {
        let canonicalWorkspaceRoot = Self.canonicalPath(workspaceRoot)
        for key in snapshots.keys where key.workspaceRoot == canonicalWorkspaceRoot {
            staleKeys.insert(key)
        }
    }

    private func makeResolvedEnvironment(
        source: WorkspaceShellEnvironmentSource,
        workspaceRoot: String,
        shellPath: String,
        shellEnvironment: [String: String],
        executableDirectory: String?,
        settingsOverrides: [String: String],
        launchOverrides: [String: String],
        probeFailureReason: String?
    ) -> WorkspaceShellResolvedEnvironment {
        var mergedEnvironment = currentEnvironment
        for (name, value) in shellEnvironment {
            mergedEnvironment[name] = value
        }
        for (name, value) in settingsOverrides {
            mergedEnvironment[name] = value
        }
        for (name, value) in launchOverrides {
            mergedEnvironment[name] = value
        }

        let environment = GeminiProcessEnvironment.make(
            baseEnvironment: mergedEnvironment,
            userHomeDirectory: userHomeDirectory,
            executableDirectory: executableDirectory,
            workingDirectory: workspaceRoot
        )

        return WorkspaceShellResolvedEnvironment(
            environment: environment,
            source: source,
            shellPath: shellPath,
            workspaceRoot: workspaceRoot,
            probeFailureReason: probeFailureReason
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    nonisolated private static func probeEnvironment(
        workspaceRoot: String,
        shellPath: String,
        currentEnvironment: [String: String],
        userHomeDirectory: String,
        timeout: TimeInterval
    ) -> Result<[String: String], WorkspaceShellProbeError> {
        let shellURL = URL(fileURLWithPath: shellPath)
        guard FileManager.default.isExecutableFile(atPath: shellURL.path) else {
            return .failure(WorkspaceShellProbeError(reason: "shell_not_executable"))
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let group = DispatchGroup()
        group.enter()

        process.executableURL = shellURL
        process.arguments = GeminiProcessEnvironment.shellArguments(for: shellURL.lastPathComponent)
        process.environment = GeminiProcessEnvironment.shellEnvironment(
            currentEnvironment: currentEnvironment,
            userHomeDirectory: userHomeDirectory,
            shellPath: shellURL.path,
            workingDirectory: workspaceRoot
        )
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { _ in
            group.leave()
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            group.leave()
            return .failure(WorkspaceShellProbeError(reason: "probe_launch_failed"))
        }

        let didTimeOut = group.wait(timeout: .now() + timeout) == .timedOut
        if didTimeOut {
            process.terminate()
            if group.wait(timeout: .now() + 0.2) == .timedOut, process.processIdentifier > 0 {
                kill(process.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 0.2)
            }
            return .failure(WorkspaceShellProbeError(reason: "probe_timed_out"))
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let stderrText = String(decoding: stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let failureReason = stderrText.isEmpty
                ? "probe_exit_\(process.terminationStatus)"
                : "probe_exit_\(process.terminationStatus)"
            return .failure(WorkspaceShellProbeError(reason: failureReason))
        }

        let parsedEnvironment = GeminiProcessEnvironment.parseEnvironmentOutput(stdoutData)
        guard !parsedEnvironment.isEmpty else {
            return .failure(WorkspaceShellProbeError(reason: "probe_empty_output"))
        }

        return .success(parsedEnvironment)
    }
}
