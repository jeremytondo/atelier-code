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

                    ConversationSurface(controller: controller)
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
                ConversationTranscript(session: controller.activeThreadSession)
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

        return session.messages.isEmpty == false
    }
}

private enum ConversationSurfaceState {
    case connecting
    case ready
    case error(String)
}

private struct ConversationTranscript: View {
    let session: ThreadSession?

    var body: some View {
        if let session {
            TranscriptBody(session: session)
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
    let session: ThreadSession
    @State private var transcriptWidth: CGFloat = 720

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                ForEach(session.messages) { message in
                    ConversationMessageBubble(
                        message: message,
                        maxWidth: min(transcriptWidth * 0.72, 720)
                    )
                        .id(message.id)
                }

                if session.turnState.thinkingText.isEmpty == false {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Reasoning", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(session.turnState.thinkingText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .id("thinking")
                }

                if let failureDescription = session.turnState.failureDescription {
                    StateCard(
                        title: "Turn Failed",
                        message: failureDescription
                    )
                    .id("failure")
                }
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
            lastMessageID: session.messages.last?.id,
            lastMessageText: session.messages.last?.text,
            thinkingText: session.turnState.thinkingText,
            failureDescription: session.turnState.failureDescription
        )
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        if let lastMessageID = session.messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessageID, anchor: .bottom)
            }
        } else if session.turnState.thinkingText.isEmpty == false {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("thinking", anchor: .bottom)
            }
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
}

private struct TranscriptScrollAnchor: Equatable {
    let lastMessageID: String?
    let lastMessageText: String?
    let thinkingText: String
    let failureDescription: String?
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
