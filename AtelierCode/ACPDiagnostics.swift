//
//  ACPDiagnostics.swift
//  AtelierCode
//
//  Created by Codex on 3/23/26.
//

import Foundation

nonisolated enum ACPTransportLifecycleEventKind: String, Codable, Equatable, Sendable {
    case processStarted
    case firstResponseReceived
    case sendFailure
    case terminationObserved
    case cleanupCompleted
    case recoverableSessionLoadFailure

    var title: String {
        switch self {
        case .processStarted:
            return "Process started"
        case .firstResponseReceived:
            return "First response received"
        case .sendFailure:
            return "Send failure"
        case .terminationObserved:
            return "Termination observed"
        case .cleanupCompleted:
            return "Cleanup completed"
        case .recoverableSessionLoadFailure:
            return "Session resume failed"
        }
    }
}

nonisolated struct ACPTransportLifecycleEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let occurredAt: Date
    let kind: ACPTransportLifecycleEventKind
    let detail: String?

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        kind: ACPTransportLifecycleEventKind,
        detail: String? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.detail = detail
    }
}

nonisolated struct ACPTransportFailureContext: Equatable, Sendable {
    let occurredAt: Date
    let classificationHint: ACPRecoveryIssueKind?
    let processExitStatus: Int?
    let terminationReason: String?
    let lastRequestMethod: String?
    let lastRequestID: Int?
    let wasPromptInFlight: Bool
    let diagnostics: [String]
    let lifecycleEvents: [ACPTransportLifecycleEvent]
}

nonisolated struct ACPTransportFailureSnapshot: Codable, Equatable, Sendable {
    let occurredAt: Date
    let workspacePath: String
    let model: String
    let recoveryKind: ACPRecoveryIssueKind
    let title: String
    let explanation: String
    let underlyingError: String
    let processExitStatus: Int?
    let terminationReason: String?
    let lastRequestMethod: String?
    let lastRequestID: Int?
    let wasPromptInFlight: Bool
    let lastUserPrompt: String?
    let lastAssistantMessage: String?
    let lastTerminalCommand: String?
    let lastTerminalCwd: String?
    let diagnostics: [String]
    let lifecycleEvents: [ACPTransportLifecycleEvent]
    let recentActivities: [ACPMessageActivity]
    let recentTerminals: [ACPTerminalState]
    let recommendedAction: String?

    var timestampText: String {
        Self.displayFormatter.string(from: occurredAt)
    }

    var diagnosticsText: String {
        diagnostics.isEmpty ? "No Gemini stderr diagnostics captured." : diagnostics.joined(separator: "\n")
    }

    var copyableReport: String {
        var sections: [String] = []
        sections.append("Title: \(title)")
        sections.append("When: \(timestampText)")
        sections.append("Workspace: \(workspacePath)")
        sections.append("Model: \(model)")
        sections.append("Kind: \(recoveryKind.rawValue)")
        sections.append("Explanation: \(explanation)")
        sections.append("Underlying error: \(underlyingError)")

        if let processExitStatus {
            sections.append("Exit status: \(processExitStatus)")
        }

        if let terminationReason, !terminationReason.isEmpty {
            sections.append("Termination reason: \(terminationReason)")
        }

        if let lastRequestMethod {
            let requestDescription: String
            if let lastRequestID {
                requestDescription = "\(lastRequestMethod) (#\(lastRequestID))"
            } else {
                requestDescription = lastRequestMethod
            }
            sections.append("Last request: \(requestDescription)")
        }

        sections.append("Prompt in flight: \(wasPromptInFlight ? "yes" : "no")")

        if let lastUserPrompt, !lastUserPrompt.isEmpty {
            sections.append("Last user prompt: \(lastUserPrompt)")
        }

        if let lastAssistantMessage, !lastAssistantMessage.isEmpty {
            sections.append("Last assistant message: \(lastAssistantMessage)")
        }

        if let lastTerminalCommand, !lastTerminalCommand.isEmpty {
            sections.append("Last terminal command: \(lastTerminalCommand)")
        }

        if let lastTerminalCwd, !lastTerminalCwd.isEmpty {
            sections.append("Last terminal cwd: \(lastTerminalCwd)")
        }

        if !diagnostics.isEmpty {
            sections.append("Gemini diagnostics:\n\(diagnostics.joined(separator: "\n"))")
        }

        if !lifecycleEvents.isEmpty {
            let lines = lifecycleEvents.map { event in
                let timestamp = Self.displayFormatter.string(from: event.occurredAt)
                if let detail = event.detail, !detail.isEmpty {
                    return "- \(timestamp): \(event.kind.title) (\(detail))"
                }
                return "- \(timestamp): \(event.kind.title)"
            }
            sections.append("Lifecycle events:\n\(lines.joined(separator: "\n"))")
        }

        if !recentActivities.isEmpty {
            let lines = recentActivities.map { activity in
                if let detail = activity.detail, !detail.isEmpty {
                    return "- [\(activity.kind.rawValue)] \(activity.title): \(detail)"
                }
                return "- [\(activity.kind.rawValue)] \(activity.title)"
            }
            sections.append("Recent host activity:\n\(lines.joined(separator: "\n"))")
        }

        if !recentTerminals.isEmpty {
            let lines = recentTerminals.map { terminal in
                let status: String
                if let exitCode = terminal.exitStatus?.exitCode {
                    status = "exit \(exitCode)"
                } else if let signal = terminal.exitStatus?.signal {
                    status = signal
                } else if terminal.isReleased {
                    status = "released"
                } else {
                    status = "running"
                }
                return "- \(terminal.command) [\(status)] @ \(terminal.cwd)"
            }
            sections.append("Recent terminals:\n\(lines.joined(separator: "\n"))")
        }

        if let recommendedAction, !recommendedAction.isEmpty {
            sections.append("Recommended next action: \(recommendedAction)")
        }

        return sections.joined(separator: "\n\n")
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

@MainActor
protocol ACPWorkspaceFailurePersisting: AnyObject {
    func snapshot(for workspaceRoot: String) -> ACPTransportFailureSnapshot?
    func save(snapshot: ACPTransportFailureSnapshot, for workspaceRoot: String)
    func removeSnapshot(for workspaceRoot: String)
}

@MainActor
final class ACPWorkspaceFailureStore: ACPWorkspaceFailurePersisting {
    static let standard = ACPWorkspaceFailureStore()

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "AtelierCode.ACPWorkspaceFailureSnapshots"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func snapshot(for workspaceRoot: String) -> ACPTransportFailureSnapshot? {
        storedSnapshots[Self.canonicalWorkspaceRoot(workspaceRoot)]
    }

    func save(snapshot: ACPTransportFailureSnapshot, for workspaceRoot: String) {
        var snapshots = storedSnapshots
        snapshots[Self.canonicalWorkspaceRoot(workspaceRoot)] = snapshot
        persist(snapshots)
    }

    func removeSnapshot(for workspaceRoot: String) {
        var snapshots = storedSnapshots
        snapshots.removeValue(forKey: Self.canonicalWorkspaceRoot(workspaceRoot))
        persist(snapshots)
    }

    private var storedSnapshots: [String: ACPTransportFailureSnapshot] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [:] }
        return (try? decoder.decode([String: ACPTransportFailureSnapshot].self, from: data)) ?? [:]
    }

    private func persist(_ snapshots: [String: ACPTransportFailureSnapshot]) {
        guard let data = try? encoder.encode(snapshots) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private static func canonicalWorkspaceRoot(_ workspaceRoot: String) -> String {
        URL(fileURLWithPath: workspaceRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
