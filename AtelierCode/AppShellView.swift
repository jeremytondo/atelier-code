//
//  AppShellView.swift
//  AtelierCode
//
//  Created by Codex on 3/21/26.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct AppShellView: View {
    @Bindable var model: AppShellModel
    @State private var isShowingSettings = false

    var body: some View {
        Group {
            if let store = model.mountedStore, !model.showsSetupSurface {
                ContentView(
                    store: store,
                    workspacePath: model.selectedWorkspacePath,
                    geminiModel: model.geminiSettings.defaultModel,
                    onOpenWorkspace: { openWorkspacePicker() },
                    onCloseWorkspace: { model.closeWorkspace() },
                    onShowSettings: { isShowingSettings = true },
                    onReconnect: { model.reconnectWorkspace() },
                    onResetSession: { model.resetWorkspaceSession() }
                )
            } else {
                AppShellStateView(
                    launchMode: model.launchMode,
                    setupState: model.presentedSetupState,
                    workspacePath: model.selectedWorkspacePath,
                    connectionStatusText: model.connectionStatusText,
                    isConnectionErrorVisible: model.isConnectionErrorVisible,
                    geminiSettings: model.geminiSettings,
                    suggestedCommand: model.mountedStore?.recoveryIssue?.suggestedCommand,
                    onOpenWorkspace: { openWorkspacePicker() },
                    onCloseWorkspace: { model.closeWorkspace() },
                    onShowSettings: { isShowingSettings = true },
                    onReconnect: { model.reconnectWorkspace() },
                    onResetSession: { model.resetWorkspaceSession() }
                )
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $isShowingSettings) {
            GeminiSettingsView(
                initialSettings: model.geminiSettings,
                onSave: { settings in
                    model.saveGeminiSettings(
                        executableOverridePath: settings.executableOverridePath,
                        defaultModel: settings.defaultModel,
                        autoConnectOnLaunch: settings.autoConnectOnLaunch
                    )
                    isShowingSettings = false
                },
                onCancel: {
                    isShowingSettings = false
                }
            )
        }
    }

    private func openWorkspacePicker() {
        guard model.launchMode == .live else { return }

        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = "Choose a workspace"
        panel.message = "Open a folder to start or switch the active ACP workspace."
        panel.prompt = model.selectedWorkspacePath == nil ? "Open Workspace" : "Switch Workspace"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        if let selectedWorkspacePath = model.selectedWorkspacePath {
            panel.directoryURL = URL(fileURLWithPath: selectedWorkspacePath, isDirectory: true)
        }

        guard panel.runModal() == .OK, let workspaceURL = panel.url else { return }
        model.openWorkspace(at: workspaceURL.path)
        #endif
    }
}

private struct AppShellStateView: View {
    let launchMode: AppLaunchMode
    let setupState: AppBlockingSetupState
    let workspacePath: String?
    let connectionStatusText: String
    let isConnectionErrorVisible: Bool
    let geminiSettings: GeminiAppSettings
    let suggestedCommand: String?
    let onOpenWorkspace: () -> Void
    let onCloseWorkspace: () -> Void
    let onShowSettings: () -> Void
    let onReconnect: () -> Void
    let onResetSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("AtelierCode")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))

                        Text(titleText)
                            .font(.title3.weight(.semibold))
                            .accessibilityIdentifier("shell.state.title")
                    }

                    Spacer()

                    Text(connectionStatusText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(isConnectionErrorVisible ? Color.red : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(isConnectionErrorVisible ? Color.red.opacity(0.12) : Color.black.opacity(0.05))
                        )
                }

                if let detailText {
                    Text(detailText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(workspaceText)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text("Model: \(geminiSettings.defaultModel)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
            .background(.thinMaterial)

            Spacer()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .overlay {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(cardTitle)
                            .font(.title2.weight(.semibold))

                        Text(cardDetail)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let suggestedCommand, !suggestedCommand.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Suggested Terminal command")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.secondary)

                                Text(suggestedCommand)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                    )
                            }
                        }

                        if launchMode == .live {
                            HStack(spacing: 10) {
                                Button(workspacePath == nil ? "Open Workspace" : "Switch Workspace") {
                                    onOpenWorkspace()
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("workspace.open")

                                Button("Settings") {
                                    onShowSettings()
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("settings.open")

                                if workspacePath != nil {
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

                                    Button("Close Workspace") {
                                        onCloseWorkspace()
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("workspace.close")
                                }
                            }
                        }

                        Text(modeText)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 560, minHeight: 260)

            Spacer()
        }
    }

    private var titleText: String {
        setupState.title ?? "Workspace shell"
    }

    private var detailText: String? {
        switch setupState {
        case .none:
            return "The shell is mounted, but there is no active ACP session surface yet."
        case .loading, .message:
            return setupState.detail
        }
    }

    private var workspaceText: String {
        "Workspace: \(workspacePath ?? "No workspace selected")"
    }

    private var cardTitle: String {
        switch setupState {
        case .none:
            return "Waiting for an ACP store"
        case .loading:
            return "Rendering a deterministic non-live shell"
        case .message:
            return "Setup or recovery is ready"
        }
    }

    private var cardDetail: String {
        switch setupState {
        case .none:
            return "Phase 1 keeps the app launchable even when a live Gemini session is not mounted."
        case .loading:
            return "This state is intentionally app-owned so previews and UI tests can launch without spawning Gemini."
        case .message:
            return "Phase 3 turns Gemini setup and transport failures into app-owned recovery states with settings, reconnect, and reset controls."
        }
    }

    private var modeText: String {
        switch launchMode {
        case .live:
            return "Launch mode: live"
        case .preview:
            return "Launch mode: preview"
        case .uiTest:
            return "Launch mode: ui_test"
        }
    }
}

private struct GeminiSettingsView: View {
    @State private var executableOverridePath: String
    @State private var defaultModel: String
    @State private var autoConnectOnLaunch: Bool

    let onSave: (GeminiAppSettings) -> Void
    let onCancel: () -> Void

    init(
        initialSettings: GeminiAppSettings,
        onSave: @escaping (GeminiAppSettings) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _executableOverridePath = State(initialValue: initialSettings.executableOverridePath ?? "")
        _defaultModel = State(initialValue: initialSettings.defaultModel)
        _autoConnectOnLaunch = State(initialValue: initialSettings.autoConnectOnLaunch)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Gemini Settings")
                .font(.title2.weight(.semibold))

            Text("These preferences are applied the next time AtelierCode builds a live Gemini ACP session.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Executable override path")
                    .font(.headline)

                TextField("/opt/homebrew/bin/gemini", text: $executableOverridePath)
                    .textFieldStyle(.roundedBorder)

                Text("Leave empty to use automatic Gemini discovery.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Default Gemini model")
                    .font(.headline)

                TextField("gemini-2.5-pro", text: $defaultModel)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Auto-connect on launch", isOn: $autoConnectOnLaunch)

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    onSave(
                        GeminiAppSettings(
                            executableOverridePath: executableOverridePath,
                            defaultModel: defaultModel,
                            autoConnectOnLaunch: autoConnectOnLaunch
                        )
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 520)
    }
}

#Preview("Ready") {
    AppShellView(model: .preview(.ready))
}

#Preview("Loading") {
    AppShellView(model: .preview(.loading))
}

#Preview("Activity") {
    AppShellView(model: .preview(.activity))
}
