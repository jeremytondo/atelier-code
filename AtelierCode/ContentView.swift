//
//  ContentView.swift
//  AtelierCode
//
//  Created by Jeremy Margaritondo on 3/12/26.
//

import SwiftUI

struct ContentView: View {
    @Bindable var store: ACPStore
    let workspacePath: String?
    let geminiModel: String
    let onOpenWorkspace: () -> Void
    let onCloseWorkspace: () -> Void
    let onShowSettings: () -> Void
    let onReconnect: () -> Void
    let onResetSession: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header

                    Divider()

                    if let snapshot = store.latestFailureSnapshot {
                        FailureDetailsCard(
                            snapshot: snapshot,
                            isActiveFailure: store.recoveryIssue != nil,
                            onReconnect: onReconnect,
                            onResetSession: onResetSession,
                            onCopyDiagnostics: { store.copyLatestFailureDiagnostics() }
                        )

                        Divider()
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if store.messages.isEmpty {
                                placeholder
                            }

                            ForEach(store.messages) { message in
                                MessageRow(
                                    message: message,
                                    activities: store.activities(for: message.id)
                                )
                                .id(message.id)
                            }
                        }
                        .padding(20)
                    }
                    .background(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .windowBackgroundColor),
                                Color(nsColor: .underPageBackgroundColor)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                    Divider()

                    composer
                }

                Divider()

                HostActivitySidebar(store: store)
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            }
            .frame(minWidth: 980, minHeight: 560)
            .background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: store.scrollTargetMessageID) { _, newValue in
                guard let newValue else { return }

                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AtelierCode")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("Ready-state ACP chat surface")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Workspace: \(workspacePath ?? "No workspace selected")")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text("Model: \(geminiModel)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            HStack(spacing: 10) {
                Button("Settings") {
                    onShowSettings()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.open")

                Button("Switch Workspace") {
                    onOpenWorkspace()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("workspace.open")

                Button("Close Workspace") {
                    onCloseWorkspace()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("workspace.close")

                Button("Reconnect") {
                    onReconnect()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("workspace.reconnect")

                Button("Reset Session") {
                    onResetSession()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("workspace.reset")

                if store.hasFailureDetails {
                    Button("Copy Diagnostics") {
                        store.copyLatestFailureDiagnostics()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("workspace.copyDiagnostics")
                }

                Text(store.statusText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(store.isErrorVisible ? Color.red : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(store.isErrorVisible ? Color.red.opacity(0.12) : Color.black.opacity(0.05))
                    )
                    .accessibilityIdentifier("shell.status")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.thinMaterial)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Waiting for your first prompt")
                .font(.title3.weight(.semibold))

            Text("The app shell now decides whether a live ACP store is mounted, so previews and UI tests can render this surface without starting Gemini.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Ask the local Gemini agent anything…", text: $store.draftPrompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1 ... 5)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .foregroundStyle(Color(nsColor: .textColor))
                .disabled(store.isSending)
                .onSubmit {
                    Task {
                        await store.sendPrompt()
                    }
                }

            Button {
                Task {
                    if store.isSending {
                        await store.cancelPrompt()
                    } else {
                        await store.sendPrompt()
                    }
                }
            } label: {
                Text(sendButtonTitle)
                    .frame(minWidth: 88)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isSending ? !store.canCancelPrompt : !store.canSendPrompt)
        }
        .padding(20)
        .background(.ultraThinMaterial)
    }

    private var sendButtonTitle: String {
        if store.connectionState == .cancelling {
            return "Cancelling"
        }

        if store.isSending {
            return "Cancel"
        }

        return "Send"
    }
}

private struct FailureDetailsCard: View {
    let snapshot: ACPTransportFailureSnapshot
    let isActiveFailure: Bool
    let onReconnect: () -> Void
    let onResetSession: () -> Void
    let onCopyDiagnostics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isActiveFailure ? snapshot.title : "Most recent ACP failure")
                        .font(.headline.weight(.semibold))

                    Text(snapshot.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text(snapshot.timestampText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            failureMetadata

            if !snapshot.diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Gemini diagnostics")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(snapshot.diagnosticsText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.black.opacity(0.06))
                        )
                }
            }

            if !snapshot.lifecycleEvents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transport lifecycle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(snapshot.lifecycleEvents.suffix(5)) { event in
                        Text(lifecycleLine(for: event))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Reconnect") {
                    onReconnect()
                }
                .buttonStyle(.borderedProminent)

                Button("Reset Session") {
                    onResetSession()
                }
                .buttonStyle(.bordered)

                Button("Copy Diagnostics") {
                    onCopyDiagnostics()
                }
                .buttonStyle(.bordered)
            }

            if let recommendedAction = snapshot.recommendedAction, !recommendedAction.isEmpty {
                Text(recommendedAction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.38, green: 0.12, blue: 0.08).opacity(0.12),
                    Color(nsColor: .textBackgroundColor).opacity(0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .stroke(Color.red.opacity(0.14), lineWidth: 1)
        )
    }

    private var failureMetadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lastRequestMethod = snapshot.lastRequestMethod {
                Text(requestLine(for: lastRequestMethod))
            }

            if let processExitStatus = snapshot.processExitStatus {
                Text("Exit status: \(processExitStatus)")
            }

            if let terminationReason = snapshot.terminationReason, !terminationReason.isEmpty {
                Text("Termination: \(terminationReason)")
            }

            if let lastTerminalCommand = snapshot.lastTerminalCommand {
                let cwdText = snapshot.lastTerminalCwd.map { " (\($0))" } ?? ""
                Text("Last terminal: \(lastTerminalCommand)\(cwdText)")
            }

            if snapshot.wasPromptInFlight {
                Text("A prompt was in flight when the failure happened.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func requestLine(for method: String) -> String {
        if let requestID = snapshot.lastRequestID {
            return "Last ACP request: \(method) (#\(requestID))"
        }

        return "Last ACP request: \(method)"
    }

    private func lifecycleLine(for event: ACPTransportLifecycleEvent) -> String {
        let detailSuffix: String
        if let detail = event.detail, !detail.isEmpty {
            detailSuffix = " • \(detail)"
        } else {
            detailSuffix = ""
        }

        return "\(event.kind.title) • \(event.occurredAt.formatted(date: .omitted, time: .standard))\(detailSuffix)"
    }
}

private struct MessageRow: View {
    let message: ConversationMessage
    let activities: [ACPMessageActivity]

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 10) {
            HStack {
                if message.role == .user {
                    Spacer(minLength: 60)
                }

                messageContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 460, alignment: .leading)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(borderColor, lineWidth: 1)
                    )

                if message.role != .user {
                    Spacer(minLength: 60)
                }
            }

            if message.role == .assistant, !activities.isEmpty {
                activityStack
                    .padding(.leading, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.text.isEmpty, message.role == .assistant {
            Text("Waiting for Gemini response...")
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
        } else {
            Text(message.text)
                .textSelection(.enabled)
                .font(.body)
                .foregroundStyle(foregroundColor)
        }
    }

    private var foregroundColor: Color {
        switch message.role {
        case .assistant:
            return Color(nsColor: .textColor)
        case .system:
            return Color.secondary
        case .user:
            return .white
        }
    }

    private var bubbleBackground: AnyShapeStyle {
        switch message.role {
        case .assistant:
            return AnyShapeStyle(
                Color(nsColor: .textBackgroundColor)
            )
        case .system:
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        case .user:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color(red: 0.15, green: 0.35, blue: 0.74), Color(red: 0.09, green: 0.55, blue: 0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var borderColor: Color {
        switch message.role {
        case .assistant:
            return Color(nsColor: .separatorColor).opacity(0.35)
        case .system:
            return Color(nsColor: .separatorColor).opacity(0.25)
        case .user:
            return Color.white.opacity(0.18)
        }
    }

    private var activityStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(activities) { activity in
                ActivityCard(activity: activity)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct HostActivitySidebar: View {
    @Bindable var store: ACPStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Host activity")
                        .font(.title3.weight(.semibold))

                    Text("Permissions, tools, and terminals stay inspectable here while the chat keeps its inline activity trail.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !store.pendingPermissionRequests.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pending permissions")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(store.pendingPermissionRequests) { prompt in
                            PermissionPromptCard(store: store, prompt: prompt)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Terminal sessions")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if store.visibleTerminalStates.isEmpty {
                        SidebarEmptyState(text: "Terminal sessions will appear here when the agent starts host work.")
                    } else {
                        ForEach(store.visibleTerminalStates) { terminal in
                            TerminalInspectorCard(terminal: terminal)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Event stream")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if store.hostActivities.isEmpty {
                        SidebarEmptyState(text: "Tool progress, permission events, and terminal output will stream here.")
                    } else {
                        ForEach(store.hostActivities.sorted(by: { $0.sequence > $1.sequence })) { activity in
                            ActivityCard(activity: activity)
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct PermissionPromptCard: View {
    @Bindable var store: ACPStore
    let prompt: ACPPermissionPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(prompt.title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(sourceLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(sourceColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(sourceColor.opacity(0.12))
                    )
            }

            Text(prompt.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(prompt.actions) { action in
                    PermissionActionButton(title: action.title, role: action.role) {
                        store.resolvePermissionRequest(prompt, with: action)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(sourceColor.opacity(0.22), lineWidth: 1)
        )
    }

    private var sourceLabel: String {
        switch prompt.source {
        case .agentTool:
            return "Tool"
        case .fileRead:
            return "File read"
        case .terminalCreate:
            return "Terminal"
        case .terminalKill:
            return "Kill"
        case .terminalRelease:
            return "Release"
        }
    }

    private var sourceColor: Color {
        switch prompt.source {
        case .agentTool:
            return Color(red: 0.15, green: 0.43, blue: 0.74)
        case .fileRead:
            return Color(red: 0.22, green: 0.48, blue: 0.34)
        case .terminalCreate:
            return Color(red: 0.63, green: 0.37, blue: 0.14)
        case .terminalKill, .terminalRelease:
            return Color(red: 0.72, green: 0.22, blue: 0.18)
        }
    }

}

private struct TerminalInspectorCard: View {
    let terminal: ACPTerminalState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(terminal.command)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Spacer()

                Text(statusLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(statusColor.opacity(0.12))
                    )
            }

            Text(terminal.cwd)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if !terminal.output.isEmpty {
                Text(terminal.output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .textColor))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.06))
                    )
            } else {
                SidebarEmptyState(text: "No terminal output yet.")
            }

            if terminal.truncated {
                Text("Output truncated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(statusColor.opacity(0.22), lineWidth: 1)
        )
    }

    private var statusLabel: String {
        if terminal.isReleased {
            return "Released"
        }

        if let exitStatus = terminal.exitStatus {
            if let exitCode = exitStatus.exitCode {
                return "Exit \(exitCode)"
            }

            if let signal = exitStatus.signal {
                return signal
            }
        }

        return "Running"
    }

    private var statusColor: Color {
        if terminal.isReleased {
            return Color(red: 0.52, green: 0.37, blue: 0.18)
        }

        if terminal.exitStatus != nil {
            return Color(red: 0.22, green: 0.48, blue: 0.34)
        }

        return Color(red: 0.15, green: 0.43, blue: 0.74)
    }
}

private struct SidebarEmptyState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            )
    }
}

private struct PermissionActionButton: View {
    let title: String
    let role: ACPPermissionPromptActionRole
    let action: () -> Void

    var body: some View {
        switch role {
        case .primary:
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
        case .secondary, .destructive:
            Button(title, action: action)
                .buttonStyle(.bordered)
        }
    }
}

private struct ActivityCard: View {
    let activity: ACPMessageActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(activity.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(primaryTextColor)

                Spacer(minLength: 12)

                if let badge = badgeText {
                    Text(badge)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(badgeColor.opacity(0.12))
                        )
                }
            }

            if let detail = activity.detail, !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(activity.kind == .thinking ? 3 : nil)
                    .textSelection(.enabled)
            }

            if !activity.commands.isEmpty {
                Text(activity.commands.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(secondaryTextColor)
                    .textSelection(.enabled)
            }

            if let terminal = activity.terminal {
                if let newOutput = terminal.newOutput, !newOutput.isEmpty {
                    Text(newOutput)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .textColor))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.black.opacity(0.06))
                        )
                }

                if terminal.truncated {
                    Text("Output truncated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(badgeColor)
                .frame(width: 4)
                .padding(.vertical, 8)
                .padding(.leading, 8)
        }
    }

    private var badgeText: String? {
        switch activity.kind {
        case .thinking:
            return "Thinking"
        case .tool:
            return "Tool"
        case .availableCommands:
            return "Commands"
        case .permission:
            return "Permission"
        case .terminal:
            return "Terminal"
        }
    }

    private var badgeColor: Color {
        switch activity.kind {
        case .thinking:
            return Color(red: 0.62, green: 0.42, blue: 0.18)
        case .tool:
            return Color(red: 0.12, green: 0.45, blue: 0.72)
        case .availableCommands:
            return Color(red: 0.22, green: 0.46, blue: 0.34)
        case .permission:
            return Color(red: 0.73, green: 0.42, blue: 0.14)
        case .terminal:
            return Color(red: 0.35, green: 0.33, blue: 0.62)
        }
    }

    private var cardBackground: Color {
        Color(nsColor: .textBackgroundColor).opacity(0.92)
    }

    private var cardBorderColor: Color {
        badgeColor.opacity(0.35)
    }

    private var primaryTextColor: Color {
        Color(nsColor: .textColor)
    }

    private var secondaryTextColor: Color {
        Color(nsColor: .secondaryLabelColor)
    }
}
