//
//  ContentView.swift
//  AtelierCode
//
//  Created by Jeremy Margaritondo on 3/23/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    @State private var isShowingWorkspacePicker = false
    @State private var composerText = ""

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(
                appModel: appModel,
                isShowingWorkspacePicker: $isShowingWorkspacePicker
            )
        } detail: {
            ConversationDetailView(
                appModel: appModel,
                composerText: $composerText,
                isShowingWorkspacePicker: $isShowingWorkspacePicker
            )
        }
        .fileImporter(
            isPresented: $isShowingWorkspacePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first else {
                return
            }

            appModel.activateWorkspace(at: url)
        }
    }
}

private struct WorkspaceSidebar: View {
    let appModel: AppModel
    @Binding var isShowingWorkspacePicker: Bool

    var body: some View {
        List {
            Section {
                Button("Open Workspace...") {
                    isShowingWorkspacePicker = true
                }
                .accessibilityIdentifier("open-workspace-button")
            }

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
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(workspace.displayName)
                                        .font(.headline)
                                    Text(workspace.canonicalPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                Spacer(minLength: 0)

                                if appModel.activeWorkspaceController?.workspace.canonicalPath == workspace.canonicalPath {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("recent-workspace-\(workspace.displayName)")
                    }
                }
            }
        }
        .navigationTitle("Workspaces")
        .frame(minWidth: 300)
    }
}

private struct ConversationDetailView: View {
    let appModel: AppModel
    @Binding var composerText: String
    @Binding var isShowingWorkspacePicker: Bool

    var body: some View {
        if let controller = appModel.activeWorkspaceController {
            ActiveWorkspaceConversationView(
                appModel: appModel,
                controller: controller,
                composerText: $composerText
            )
        } else {
            ContentUnavailableView {
                Label("Pick a Workspace", systemImage: "folder.badge.plus")
            } description: {
                Text("Select a recent workspace or open a new one to start the bridge runtime.")
            } actions: {
                Button("Open Workspace...") {
                    isShowingWorkspacePicker = true
                }
            }
            .accessibilityIdentifier("conversation-empty-state")
        }
    }
}

private struct ActiveWorkspaceConversationView: View {
    let appModel: AppModel
    let controller: WorkspaceController
    @Binding var composerText: String

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    WorkspaceHeader(appModel: appModel, controller: controller)

                    if appModel.uiPreferences.showsStartupDiagnostics {
                        DiagnosticsSection(diagnostics: appModel.startupDiagnostics)
                    }

                    ConversationSurface(appModel: appModel, controller: controller)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            ComposerBar(appModel: appModel, composerText: $composerText)
                .padding(20)
                .background(.regularMaterial)
        }
    }
}

private struct WorkspaceHeader: View {
    let appModel: AppModel
    let controller: WorkspaceController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.workspace.displayName)
                        .font(.largeTitle.weight(.semibold))
                    Text(controller.workspace.canonicalPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)

                ConnectionBadge(status: controller.connectionStatus)
                    .accessibilityIdentifier("workspace-connection-status")
            }

            HStack(spacing: 12) {
                Label(controller.bridgeLifecycleState.label, systemImage: "bolt.horizontal.circle")
                Label(controller.authState.label, systemImage: "person.crop.circle")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if appModel.canRetryActiveWorkspace {
                    Button("Retry Connection") {
                        appModel.retryActiveWorkspaceConnection()
                    }
                    .accessibilityIdentifier("retry-connection-button")
                }

                Button("Clear Selection") {
                    appModel.clearSelectedWorkspace()
                }
                .accessibilityIdentifier("clear-selection-button")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

private struct ConversationSurface: View {
    let appModel: AppModel
    let controller: WorkspaceController

    var body: some View {
        Group {
            switch conversationState {
            case .connecting:
                StateCard(
                    title: "Connecting to the Bridge",
                    message: "The selected workspace has been restored and the runtime is starting."
                )
                .accessibilityIdentifier("conversation-connecting-state")
            case .error(let message):
                StateCard(
                    title: "Connection Error",
                    message: message
                )
                .accessibilityIdentifier("workspace-error-state")
            case .ready:
                ConversationTranscript(appModel: appModel, session: controller.activeThreadSession)
            }
        }
    }

    private var conversationState: ConversationSurfaceState {
        switch controller.connectionStatus {
        case .connecting where hasTranscript == false:
            return .connecting
        case .error(let message) where hasTranscript == false:
            return .error(message)
        default:
            return .ready
        }
    }

    private var hasTranscript: Bool {
        guard let session = controller.activeThreadSession else {
            return false
        }

        return session.messages.isEmpty == false ||
            session.turnItems.isEmpty == false ||
            session.pendingApprovals.isEmpty == false ||
            session.planState != nil ||
            session.aggregatedDiff != nil
    }
}

private enum ConversationSurfaceState {
    case connecting
    case ready
    case error(String)
}

private struct ConversationTranscript: View {
    let appModel: AppModel
    let session: ThreadSession?

    var body: some View {
        if let session {
            TranscriptBody(appModel: appModel, session: session)
        } else {
            StateCard(
                title: "Start the First Turn",
                message: "Send a prompt to create a new thread for this workspace. Existing threads stay hidden for now."
            )
            .accessibilityIdentifier("conversation-ready-empty-state")
        }
    }
}

private struct TranscriptBody: View {
    let appModel: AppModel
    let session: ThreadSession
    @State private var transcriptWidth: CGFloat = 720

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                ForEach(visibleMessages) { message in
                    ConversationMessageBubble(
                        message: message,
                        maxWidth: min(transcriptWidth * 0.72, 720)
                    )
                    .id(message.id)
                }

                TurnDetailsStack(
                    appModel: appModel,
                    session: session,
                    maxWidth: min(transcriptWidth * 0.72, 720)
                )

                if let failureDescription = session.turnState.failureDescription {
                    StateCard(
                        title: "Turn Failed",
                        message: failureDescription
                    )
                    .id("failure")
                }

                Color.clear
                    .frame(height: 1)
                    .id("transcript-end")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: TranscriptWidthPreferenceKey.self, value: geometry.size.width)
                }
            }
            .onPreferenceChange(TranscriptWidthPreferenceKey.self) { transcriptWidth = $0 }
            .onAppear {
                scrollToLatest(using: proxy)
            }
            .onChange(of: scrollAnchor) { _, _ in
                scrollToLatest(using: proxy)
            }
        }
    }

    private var scrollAnchor: TranscriptScrollAnchor {
        TranscriptScrollAnchor(
            messages: visibleMessages,
            turnState: session.turnState,
            turnItems: session.turnItems,
            pendingApprovals: session.pendingApprovals,
            planState: session.planState,
            aggregatedDiff: session.aggregatedDiff
        )
    }

    private var visibleMessages: [ConversationMessage] {
        guard session.turnState.phase == .completed,
              session.turnItems.contains(where: { $0.kind == .assistant }),
              let lastMessage = session.messages.last,
              lastMessage.role == .assistant else {
            return session.messages
        }

        return Array(session.messages.dropLast())
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("transcript-end", anchor: .bottom)
        }
    }
}

private struct ConversationMessageBubble: View {
    let message: ConversationMessage
    let maxWidth: CGFloat

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(message.role.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(message.role.accentColor)
                Text(message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(message.role.backgroundColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if message.role != .user {
                Spacer(minLength: 48)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-message-\(message.id)")
    }
}

private struct TurnDetailsStack: View {
    let appModel: AppModel
    let session: ThreadSession
    let maxWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.turnItems.isEmpty == false {
                ForEach(session.turnItems) { item in
                    TurnItemRow(item: item, maxWidth: maxWidth)
                }
            }

            if session.pendingApprovals.isEmpty == false {
                TurnSectionCard(
                    title: "Approvals",
                    systemImage: "checkmark.shield",
                    maxWidth: maxWidth,
                    accessibilityIdentifier: "turn-approvals-section"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(session.pendingApprovals) { approval in
                            ApprovalCard(appModel: appModel, approval: approval)
                        }
                    }
                }
            }

            if let planState = session.planState,
               planState.summary?.isEmpty == false || planState.steps.isEmpty == false {
                PlanSection(planState: planState, maxWidth: maxWidth)
            }

            if let aggregatedDiff = session.aggregatedDiff,
               aggregatedDiff.summary.isEmpty == false || aggregatedDiff.files.isEmpty == false {
                DiffSection(aggregatedDiff: aggregatedDiff, maxWidth: maxWidth)
            }
        }
    }
}

private struct TurnItemRow: View {
    let item: TurnItem
    let maxWidth: CGFloat

    var body: some View {
        Group {
            switch item.kind {
            case .assistant:
                AssistantTurnItemRow(item: item, maxWidth: maxWidth)
            case .reasoning:
                ReasoningTurnItemRow(item: item, maxWidth: maxWidth)
            case .tool, .fileChange:
                ActivityTurnItemRow(item: item, maxWidth: maxWidth)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("turn-item-\(item.id)")
    }
}

private struct AssistantTurnItemRow: View {
    let item: TurnItem
    let maxWidth: CGFloat

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Text("Assistant")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.blue)

                    Spacer(minLength: 0)

                    ActivityStatusBadge(status: item.status)
                }

                Text(item.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Spacer(minLength: 48)
        }
    }
}

private struct ReasoningTurnItemRow: View {
    let item: TurnItem
    let maxWidth: CGFloat

    var body: some View {
        TurnSectionCard(
            title: "Reasoning",
            systemImage: "sparkles",
            maxWidth: maxWidth,
            accessibilityIdentifier: "turn-reasoning-section"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(item.status.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    ActivityStatusBadge(status: item.status)
                }

                Text(item.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ApprovalCard: View {
    let appModel: AppModel
    let approval: ApprovalRequest

    private var isResolving: Bool {
        approval.pendingResolution != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(approval.title)
                        .font(.headline)

                    if approval.detail.isEmpty == false {
                        Text(approval.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                if let riskLevel = approval.riskLevel {
                    RiskBadge(riskLevel: riskLevel)
                }
            }

            if let command = approval.command {
                CommandContextView(command: command.command, workingDirectory: command.workingDirectory)
            }

            if approval.files.isEmpty == false {
                FileSummaryList(files: approval.files)
            }

            HStack(spacing: 10) {
                Button("Approve") {
                    Task {
                        _ = await appModel.resolveApproval(id: approval.id, resolution: .approved)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResolving)
                .accessibilityIdentifier("approval-\(approval.id)-approve-button")

                Button("Decline") {
                    Task {
                        _ = await appModel.resolveApproval(id: approval.id, resolution: .declined)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isResolving)
                .accessibilityIdentifier("approval-\(approval.id)-decline-button")
            }

            if let pendingResolution = approval.pendingResolution {
                Text(pendingResolution == .approved ? "Sending approval..." : "Sending decline...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ActivityTurnItemRow: View {
    let item: TurnItem
    let maxWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.headline)

                    if let detail = item.detail, detail.isEmpty == false {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                ActivityStatusBadge(status: item.status)
            }

            if item.command?.isEmpty == false || item.workingDirectory != nil {
                CommandContextView(command: item.command ?? "", workingDirectory: item.workingDirectory)
            }

            if item.output.isEmpty == false {
                Text(item.output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if item.files.isEmpty == false {
                FileSummaryList(files: item.files)
            }

            if let exitCode = item.exitCode {
                Text("Exit code: \(exitCode)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(exitCode == 0 ? .green : .secondary)
                    .monospacedDigit()
            }
        }
        .padding(14)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct PlanSection: View {
    let planState: PlanState
    let maxWidth: CGFloat

    private var completedCount: Int {
        planState.steps.filter { $0.status == .completed }.count
    }

    private var inProgressCount: Int {
        planState.steps.filter { $0.status == .inProgress }.count
    }

    var body: some View {
        TurnSectionCard(
            title: "Plan",
            systemImage: "list.bullet.clipboard",
            maxWidth: maxWidth,
            accessibilityIdentifier: "turn-plan-section"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if let summary = planState.summary, summary.isEmpty == false {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    PlanCountBadge(text: "\(completedCount)/\(planState.steps.count) done")

                    if inProgressCount > 0 {
                        PlanCountBadge(text: "\(inProgressCount) active")
                    }
                }

                if planState.steps.isEmpty == false {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(planState.steps) { step in
                            PlanStepRow(step: step)
                        }
                    }
                }
            }
        }
    }
}

private struct DiffSection: View {
    let aggregatedDiff: AggregatedDiff
    let maxWidth: CGFloat

    private var totalAdditions: Int {
        aggregatedDiff.files.reduce(0) { $0 + $1.additions }
    }

    private var totalDeletions: Int {
        aggregatedDiff.files.reduce(0) { $0 + $1.deletions }
    }

    var body: some View {
        TurnSectionCard(
            title: "Turn Diff",
            systemImage: "arrow.triangle.branch",
            maxWidth: maxWidth,
            accessibilityIdentifier: "turn-diff-section"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Text(aggregatedDiff.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        DiffCountBadge(value: totalAdditions, label: "+", color: .green)
                        DiffCountBadge(value: totalDeletions, label: "-", color: .red)
                    }
                }

                if aggregatedDiff.files.isEmpty == false {
                    FileSummaryList(files: aggregatedDiff.files)
                }
            }
        }
    }
}

private struct TurnSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let maxWidth: CGFloat
    let accessibilityIdentifier: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        maxWidth: CGFloat,
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.maxWidth = maxWidth
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            content
        }
        .padding(16)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct CommandContextView: View {
    let command: String
    let workingDirectory: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if command.isEmpty == false {
                Text(command)
                    .font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled)
            }

            if let workingDirectory, workingDirectory.isEmpty == false {
                Text(workingDirectory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct FileSummaryList: View {
    let files: [DiffFileChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(files) { file in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(file.path)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        DiffCountBadge(value: file.additions, label: "+", color: .green)
                        DiffCountBadge(value: file.deletions, label: "-", color: .red)
                    }
                }
            }
        }
    }
}

private struct PlanStepRow: View {
    let step: PlanStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(step.status.tintColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            Text(step.title)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Text(step.status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(step.status.tintColor)
        }
    }
}

private struct ActivityStatusBadge: View {
    let status: ActivityStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(status.tintColor)
            .background(status.tintColor.opacity(0.14), in: Capsule())
    }
}

private struct RiskBadge: View {
    let riskLevel: ApprovalRiskLevel

    var body: some View {
        Text(riskLevel.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(riskLevel.tintColor)
            .background(riskLevel.tintColor.opacity(0.14), in: Capsule())
    }
}

private struct PlanCountBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(.secondary)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

private struct DiffCountBadge: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        Text("\(label)\(value)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(color)
    }
}

private struct ComposerBar: View {
    let appModel: AppModel
    @Binding var composerText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                ComposerTextView(
                    text: $composerText,
                    isEnabled: appModel.activeWorkspaceController != nil,
                    onSubmit: sendPrompt
                )
                .frame(minHeight: 84, maxHeight: 180)
                .accessibilityIdentifier("conversation-composer")

                if composerText.isEmpty {
                    Text("Send a prompt to Codex...")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )

            HStack {
                Text(composerHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if appModel.canCancelTurn {
                    Button("Cancel") {
                        Task {
                            await appModel.cancelActiveTurn()
                        }
                    }
                    .accessibilityIdentifier("conversation-cancel-button")
                }

                Button("Send") {
                    sendPrompt()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(appModel.canSendPrompt(composerText) == false)
                .accessibilityIdentifier("conversation-send-button")
            }
        }
    }

    private var composerHint: String {
        guard let controller = appModel.activeWorkspaceController else {
            return "Pick a workspace to start a conversation."
        }

        switch controller.connectionStatus {
        case .ready:
            return controller.isAwaitingTurnStart
                ? "Waiting for the bridge to acknowledge the new turn."
                : "Press Enter to send. Press Shift-Enter for a new line."
        case .streaming:
            return "A turn is streaming. Cancel if you need to stop it."
        case .cancelling:
            return "Waiting for the runtime to cancel the active turn."
        case .connecting:
            return "Waiting for the workspace runtime to connect."
        case .disconnected:
            return "Reconnect the workspace before sending."
        case .error(let message):
            return message
        }
    }

    private func sendPrompt() {
        let prompt = composerText

        Task {
            if await appModel.sendPrompt(prompt) {
                composerText = ""
            }
        }
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        textView.setAccessibilityIdentifier("conversation-composer")

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }

        textView.isEditable = isEnabled
        textView.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        textView.onSubmit = onSubmit
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            text = textView.string
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func doCommand(by commandSelector: Selector) {
        switch commandSelector {
        case #selector(insertNewline(_:)),
             #selector(insertNewlineIgnoringFieldEditor(_:)):
            onSubmit?()
        case #selector(insertLineBreak(_:)):
            insertNewline(nil)
        default:
            super.doCommand(by: commandSelector)
        }
    }
}

private struct DiagnosticsSection: View {
    let diagnostics: [StartupDiagnostic]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Startup Diagnostics")
                .font(.headline)

            ForEach(diagnostics) { diagnostic in
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(diagnostic.severity.color)
                        .frame(width: 10, height: 10)
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(diagnostic.severity.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(diagnostic.severity.color)
                        Text(diagnostic.message)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .accessibilityIdentifier("startup-diagnostics-section")
    }
}

private struct StateCard: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct ConnectionBadge: View {
    let status: ConnectionStatus

    var body: some View {
        Text(status.shortLabel)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(status.accentColor)
            .background(status.accentColor.opacity(0.14), in: Capsule())
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
        },
        runtimeFactory: { PreviewWorkspaceRuntime(controller: $0) }
    )

    if let controller = appModel.activeWorkspaceController {
        controller.setBridgeLifecycleState(.idle)
        controller.setConnectionStatus(.ready)
        controller.setAuthState(.signedIn(accountDescription: "Preview Account"))

        let session = controller.openThread(id: "preview-thread", title: "Conversation MVP")
        session.beginTurn(userPrompt: "Show me the new conversation shell.")
        session.appendAssistantTextDelta("The real transcript is now the primary workspace experience.")
        session.completeTurn()
    }

    return ContentView()
        .environment(appModel)
        .frame(width: 1180, height: 760)
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

@MainActor
private final class PreviewWorkspaceRuntime: WorkspaceConversationRuntime {
    private let controller: WorkspaceController

    init(controller: WorkspaceController) {
        self.controller = controller
    }

    func start() async throws {}

    func stop() async {
        controller.setAwaitingTurnStart(false)
    }

    func startThreadAndWait(title: String?) async throws -> ThreadSession {
        controller.openThread(id: UUID().uuidString, title: title ?? "Preview Thread")
    }

    func resumeThreadAndWait(id: String) async throws -> ThreadSession {
        controller.resumeThread(id: id, title: "Preview Thread")
    }

    func startTurn(prompt: String, configuration: BridgeTurnStartConfiguration?) async throws {
        let session = controller.activeThreadSession ?? controller.openThread(id: UUID().uuidString, title: "Preview Thread")
        session.beginTurn(userPrompt: prompt)
        controller.setAwaitingTurnStart(false)
        session.appendAssistantTextDelta("Preview assistant response.")
        session.completeTurn()
        controller.setConnectionStatus(.ready)
    }

    func cancelTurn(reason: String?) async throws {
        controller.setAwaitingTurnStart(false)
        controller.activeThreadSession?.cancelTurn()
        controller.setConnectionStatus(.ready)
    }

    func resolveApproval(id: String, resolution: ApprovalResolution) async throws {
        controller.activeThreadSession?.resolveApprovalRequest(id: id, resolution: resolution)
    }
}

private struct TranscriptScrollAnchor: Equatable {
    let messages: [ConversationMessage]
    let turnState: TurnState
    let turnItems: [TurnItem]
    let pendingApprovals: [ApprovalRequest]
    let planState: PlanState?
    let aggregatedDiff: AggregatedDiff?
}

private struct TranscriptWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 720

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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

private extension BridgeLifecycleState {
    var label: String {
        switch self {
        case .idle:
            return "Runtime Idle"
        case .starting:
            return "Runtime Starting"
        case .stopping:
            return "Runtime Stopping"
        }
    }
}

private extension ConnectionStatus {
    var shortLabel: String {
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
        case .error:
            return "Error"
        }
    }

    var accentColor: Color {
        switch self {
        case .disconnected:
            return .secondary
        case .connecting, .cancelling:
            return .orange
        case .ready:
            return .green
        case .streaming:
            return .blue
        case .error:
            return .red
        }
    }
}

private extension AuthState {
    var label: String {
        switch self {
        case .unknown:
            return "Account Unknown"
        case .signedOut:
            return "Signed Out"
        case .signedIn(let accountDescription):
            return accountDescription
        }
    }
}

private extension ActivityStatus {
    var label: String {
        switch self {
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    var tintColor: Color {
        switch self {
        case .running:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        }
    }
}

private extension ApprovalRiskLevel {
    var label: String {
        rawValue.capitalized
    }

    var tintColor: Color {
        switch self {
        case .low:
            return .green
        case .medium:
            return .orange
        case .high:
            return .red
        }
    }
}

private extension PlanStepStatus {
    var label: String {
        switch self {
        case .pending:
            return "Pending"
        case .inProgress:
            return "In Progress"
        case .completed:
            return "Completed"
        }
    }

    var tintColor: Color {
        switch self {
        case .pending:
            return .secondary
        case .inProgress:
            return .orange
        case .completed:
            return .green
        }
    }
}

private extension ConversationRole {
    var label: String {
        switch self {
        case .system:
            return "System"
        case .user:
            return "You"
        case .assistant:
            return "Codex"
        case .tool:
            return "Tool"
        }
    }

    var accentColor: Color {
        switch self {
        case .system:
            return .secondary
        case .user:
            return .mint
        case .assistant:
            return .accentColor
        case .tool:
            return .orange
        }
    }

    var backgroundColor: Color {
        switch self {
        case .user:
            return Color.mint.opacity(0.16)
        case .assistant:
            return Color.accentColor.opacity(0.1)
        case .system, .tool:
            return Color.secondary.opacity(0.08)
        }
    }
}
