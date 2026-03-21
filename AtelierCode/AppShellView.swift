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

    var body: some View {
        Group {
            if let store = model.mountedStore, model.blockingSetupState == .none {
                ContentView(
                    store: store,
                    workspacePath: model.selectedWorkspacePath,
                    onOpenWorkspace: { openWorkspacePicker() },
                    onCloseWorkspace: { model.closeWorkspace() }
                )
            } else {
                AppShellStateView(
                    launchMode: model.launchMode,
                    setupState: model.blockingSetupState,
                    workspacePath: model.selectedWorkspacePath,
                    onOpenWorkspace: { openWorkspacePicker() },
                    onCloseWorkspace: { model.closeWorkspace() }
                )
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Color(nsColor: .controlBackgroundColor))
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
    let onOpenWorkspace: () -> Void
    let onCloseWorkspace: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("AtelierCode")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text(titleText)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("shell.state.title")

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
                    VStack(alignment: .leading, spacing: 12) {
                        Text(cardTitle)
                            .font(.title2.weight(.semibold))

                        Text(cardDetail)
                            .font(.body)
                        .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if launchMode == .live {
                        HStack(spacing: 10) {
                            Button(workspacePath == nil ? "Open Workspace" : "Switch Workspace") {
                                onOpenWorkspace()
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("workspace.open")

                            if workspacePath != nil {
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
                .frame(maxWidth: 520, minHeight: 220)

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
            return "Setup needs attention"
        }
    }

    private var cardDetail: String {
        switch setupState {
        case .none:
            return "Phase 1 keeps the app launchable even when a live Gemini session is not mounted."
        case .loading:
            return "This state is intentionally app-owned so previews and UI tests can launch without spawning Gemini."
        case .message:
            return "The shell can now surface blocking setup states without relying on the chat view to manage app launch."
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

#Preview("Ready") {
    AppShellView(model: .preview(.ready))
}

#Preview("Loading") {
    AppShellView(model: .preview(.loading))
}

#Preview("Activity") {
    AppShellView(model: .preview(.activity))
}
