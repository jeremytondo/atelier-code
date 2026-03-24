//
//  ContentView.swift
//  AtelierCode
//
//  Created by Jeremy Margaritondo on 3/23/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationSplitView {
            List {
                Section("Recent Workspaces") {
                    if appModel.recentWorkspaces.isEmpty {
                        Text("No recent workspaces yet.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("recent-workspaces-empty-state")
                    } else {
                        ForEach(appModel.recentWorkspaces) { workspace in
                            Button {
                                appModel.reopenWorkspace(workspace)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(workspace.displayName)
                                    Text(workspace.canonicalPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Workspaces")
            .frame(minWidth: 280)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AtelierCode")
                            .font(.largeTitle.weight(.semibold))
                            .accessibilityIdentifier("app-shell-title")
                        Text("State-driven shell for workspace, thread, and startup diagnostics.")
                            .foregroundStyle(.secondary)
                    }

                    if appModel.uiPreferences.showsStartupDiagnostics {
                        DiagnosticsSection(diagnostics: appModel.startupDiagnostics)
                    }

                    WorkspaceSummarySection(
                        appModel: appModel,
                        controller: appModel.activeWorkspaceController
                    )

                    ThreadSessionSection(session: appModel.activeWorkspaceController?.activeThreadSession)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DiagnosticsSection: View {
    let diagnostics: [StartupDiagnostic]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Startup Diagnostics")
                .font(.title2.weight(.semibold))

            if diagnostics.isEmpty {
                Text("No startup diagnostics recorded.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diagnostics) { diagnostic in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(diagnostic.severity.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(diagnostic.severity.color)
                        Text(diagnostic.message)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .accessibilityIdentifier("startup-diagnostics-section")
    }
}

private struct WorkspaceSummarySection: View {
    let appModel: AppModel
    let controller: WorkspaceController?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selected Workspace")
                .font(.title2.weight(.semibold))

            if let controller {
                VStack(alignment: .leading, spacing: 8) {
                    Text(controller.workspace.displayName)
                        .font(.headline)
                    Text(controller.workspace.canonicalPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Bridge lifecycle: \(controller.bridgeLifecycleState.rawValue.capitalized)")
                    Text("Connection: \(controller.connectionStatus.label)")
                    Text("Auth: \(controller.authState.label)")
                    Text("Threads in sidebar: \(controller.threadSummaries.count)")

                    Button("Clear Selection") {
                        appModel.clearSelectedWorkspace()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text("Select or restore a workspace to see controller state.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("workspace-summary-empty-state")
            }
        }
    }
}

private struct ThreadSessionSection: View {
    let session: ThreadSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thread Session")
                .font(.title2.weight(.semibold))

            if let session {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.title)
                        .font(.headline)
                    Text("Messages: \(session.messages.count)")
                    Text("Turn: \(session.turnState.phase.label)")
                    Text("Pending approvals: \(session.pendingApprovals.count)")
                    Text("Activity items: \(session.activityItems.count)")
                    Text("Plan steps: \(session.planState?.steps.count ?? 0)")
                    Text("Diff files: \(session.aggregatedDiff?.files.count ?? 0)")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text("No active thread yet. Open or resume a thread once bridge integration arrives.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("thread-session-empty-state")
            }
        }
    }
}

#Preview {
    let workspaceRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AtelierCodePreview", isDirectory: true)
    try? FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

    let preferencesStore = PreviewPreferencesStore()
    try? preferencesStore.saveSnapshot(
        AppPreferencesSnapshot(
            recentWorkspaces: [WorkspaceRecord(url: workspaceRoot, lastOpenedAt: .now)],
            lastSelectedWorkspacePath: workspaceRoot.path,
            codexPathOverride: "/usr/local/bin/codex",
            uiPreferences: UIPreferences(showsStartupDiagnostics: true)
        )
    )

    let appModel = AppModel(
        preferencesStore: preferencesStore,
        bridgeDiagnosticProvider: {
            .bridgePresent(at: URL(fileURLWithPath: "/Applications/AtelierCode.app/Contents/MacOS/ateliercode-agent-bridge"))
        }
    )

    if let controller = appModel.activeWorkspaceController {
        controller.setBridgeLifecycleState(.starting)
        controller.setConnectionStatus(.ready)
        controller.setAuthState(.signedIn(accountDescription: "Preview Account"))
        controller.replaceThreadList([
            ThreadSummary(
                id: "preview-thread",
                title: "App state foundation",
                previewText: "State shell is wired.",
                updatedAt: .now
            )
        ])

        let session = controller.resumeThread(
            id: "preview-thread",
            title: "App state foundation",
            messages: [
                ConversationMessage(id: "user-1", role: .user, text: "Show the state model preview."),
                ConversationMessage(id: "assistant-1", role: .assistant, text: "Preview shell is ready.")
            ]
        )
        session.beginTurn()
        session.appendThinkingDelta("Wiring placeholder session state.")
        session.startActivity(
            id: "activity-1",
            kind: .tool,
            title: "Preview bridge activity",
            detail: "Populating sample data"
        )
        session.completeActivity(id: "activity-1")
        session.enqueueApprovalRequest(
            ApprovalRequest(
                id: "approval-1",
                kind: .command,
                title: "Run preview command",
                detail: "xcodebuild test"
            )
        )
        session.replacePlanState(
            PlanState(
                summary: "Finish the shell pass",
                steps: [
                    PlanStep(id: "step-1", title: "Model graph", status: .completed),
                    PlanStep(id: "step-2", title: "Shell UI", status: .inProgress)
                ]
            )
        )
        session.replaceAggregatedDiff(
            AggregatedDiff(
                summary: "Adds initial app state scaffolding.",
                files: [
                    DiffFileChange(id: "diff-1", path: "AtelierCode/AppModel.swift", additions: 120, deletions: 0)
                ]
            )
        )
    }

    return ContentView()
        .environment(appModel)
}

private final class PreviewPreferencesStore: AppPreferencesStore {
    private var storedSnapshot: AppPreferencesSnapshot?

    func loadSnapshot() throws -> AppPreferencesSnapshot? {
        storedSnapshot
    }

    func saveSnapshot(_ snapshot: AppPreferencesSnapshot) throws {
        storedSnapshot = snapshot
    }
}

private extension StartupDiagnosticSeverity {
    var label: String {
        rawValue.capitalized
    }

    var color: Color {
        switch self {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

private extension ConnectionStatus {
    var label: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .ready:
            return "Ready"
        case .streaming:
            return "Streaming"
        case .cancelling:
            return "Cancelling"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

private extension AuthState {
    var label: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .signedOut:
            return "Signed Out"
        case .signedIn(let accountDescription):
            return "Signed In (\(accountDescription))"
        }
    }
}

private extension TurnState.Phase {
    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .inProgress:
            return "In Progress"
        case .completed:
            return "Completed"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        }
    }
}
