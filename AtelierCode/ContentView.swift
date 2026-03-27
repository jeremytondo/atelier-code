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
            AppDetailView(
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 10) {
                        Button {
                            isShowingWorkspacePicker = true
                        } label: {
                            Label("Open Workspace", systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityIdentifier("open-workspace-button")

                        if appModel.selectedWorkspaceController != nil {
                            Button {
                                Task {
                                    _ = await appModel.createThread()
                                }
                            } label: {
                                Label("New Thread", systemImage: "square.and.pencil")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityIdentifier("sidebar-new-thread-button")
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Workspaces")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .tracking(0.8)

                        if appModel.workspaceControllers.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No workspaces yet.")
                                    .font(.subheadline)

                                Text("Open a folder to start a workspace.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityIdentifier("recent-workspaces-empty-state")
                        } else {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(appModel.workspaceControllers, id: \.workspace.canonicalPath) { controller in
                                    WorkspaceTreeRow(appModel: appModel, controller: controller)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }

            SidebarDestinationButton(
                title: "Settings",
                systemImage: "gearshape",
                isSelected: appModel.primaryView == .settings
            ) {
                appModel.showSettings()
            }
            .padding(16)
            .accessibilityIdentifier("sidebar-settings-button")
        }
        .frame(minWidth: 340)
    }
}

private struct AppDetailView: View {
    let appModel: AppModel
    @Binding var composerText: String
    @Binding var isShowingWorkspacePicker: Bool

    var body: some View {
        Group {
            switch appModel.primaryView {
            case .conversations:
                ConversationDetailView(
                    appModel: appModel,
                    composerText: $composerText,
                    isShowingWorkspacePicker: $isShowingWorkspacePicker
                )
            case .settings:
                SettingsDetailView(appModel: appModel)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DetailStatusBar(appModel: appModel)
        }
    }
}

private struct SidebarDestinationButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .frame(width: 20, height: 20)

                Text(title)
                    .font(.subheadline)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var backgroundColor: Color {
        isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.04)
    }

    private var borderColor: Color {
        isSelected ? Color.accentColor.opacity(0.22) : Color(nsColor: .separatorColor).opacity(0.14)
    }
}

private struct WorkspaceTreeRow: View {
    let appModel: AppModel
    let controller: WorkspaceController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceHeaderRow(
                appModel: appModel,
                controller: controller
            )

            if controller.isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    if controller.visibleThreadSummaries.isEmpty {
                        Text("No active threads yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 34)
                    } else {
                        ForEach(controller.displayedThreadSummaries) { threadSummary in
                            WorkspaceThreadRow(
                                appModel: appModel,
                                workspacePath: controller.workspace.canonicalPath,
                                threadSummary: threadSummary
                            )
                        }
                    }

                    HStack(spacing: 12) {
                        if controller.canShowMoreVisibleThreads {
                            Button("Show More") {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    controller.setShowingAllVisibleThreads(true)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("show-more-threads-\(controller.workspace.displayName)")
                        } else if controller.canShowLessVisibleThreads {
                            Button("Show Less") {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    controller.setShowingAllVisibleThreads(false)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("show-less-threads-\(controller.workspace.displayName)")
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 34)
                    .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .sidebarCardBackground()
    }
}

private struct WorkspaceHeaderRow: View {
    let appModel: AppModel
    let controller: WorkspaceController
    @State private var isHovering = false

    private var runningCount: Int {
        controller.threadSummaries.filter(\.isRunning).count
    }

    private var syncStatusBadge: (text: String, color: Color)? {
        switch controller.threadListSyncState {
        case .idle:
            return nil
        case .syncing:
            return ("Syncing", .teal)
        case .failed:
            return ("Cached", .orange)
        }
    }

    private var showsHoverActions: Bool {
        isHovering
    }

    private var disclosureIconName: String {
        controller.isExpanded ? "chevron.down" : "chevron.right"
    }

    private var canRetryConnection: Bool {
        switch controller.connectionStatus {
        case .disconnected, .error:
            return true
        case .connecting, .ready, .streaming, .cancelling:
            return false
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                toggleExpansion()
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        Image(controller.isExpanded ? "workspace-folder-open" : "workspace-folder-closed")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                            .opacity(isHovering ? 0 : 1)

                        Image(systemName: disclosureIconName)
                            .font(.caption.weight(.medium))
                            .opacity(isHovering ? 1 : 0)
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .animation(.easeInOut(duration: 0.16), value: controller.isExpanded)
                    .animation(.easeInOut(duration: 0.16), value: isHovering)
                        .accessibilityIdentifier("workspace-expand-\(controller.workspace.displayName)")

                    Text(controller.workspace.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)
                }
                .frame(minHeight: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recent-workspace-\(controller.workspace.displayName)")
            .accessibilityLabel(controller.workspace.displayName)
            .accessibilityValue(controller.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides the threads for this workspace")

            HStack(alignment: .center, spacing: 10) {
                if let syncStatusBadge {
                    SidebarThreadBadge(text: syncStatusBadge.text, color: syncStatusBadge.color)
                }

                if let warningMessage = controller.bridgeEnvironmentWarningMessage {
                    SidebarThreadBadge(text: "Env Warning", color: .orange)
                        .help(warningMessage)
                }

                if runningCount > 0 {
                    SidebarThreadBadge(text: runningCount == 1 ? "1 running" : "\(runningCount) running", color: .blue)
                }

                HStack(spacing: 8) {
                    Button {
                        appModel.selectWorkspace(path: controller.workspace.canonicalPath)
                        Task {
                            _ = await appModel.createThread()
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace-new-thread-\(controller.workspace.displayName)")
                    .help("Create a new thread")

                    Menu {
                        Button("Open in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([controller.workspace.url])
                        }

                        if canRetryConnection {
                            Button("Retry Connection") {
                                appModel.selectWorkspace(path: controller.workspace.canonicalPath)
                                appModel.retryActiveWorkspaceConnection()
                            }
                        }

                        Divider()

                        Button("Remove Workspace") {
                            appModel.removeWorkspace(path: controller.workspace.canonicalPath)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(BorderlessButtonMenuStyle())
                    .menuIndicator(.hidden)
                    .accessibilityIdentifier("workspace-menu-\(controller.workspace.displayName)")
                    .help("Workspace options")
                }
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
                .opacity(showsHoverActions ? 1 : 0)
                .allowsHitTesting(showsHoverActions)
                .animation(.easeInOut(duration: 0.16), value: showsHoverActions)
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("New Thread") {
                appModel.selectWorkspace(path: controller.workspace.canonicalPath)
                Task {
                    _ = await appModel.createThread()
                }
            }

            Button("Open in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([controller.workspace.url])
            }

            if canRetryConnection {
                Button("Retry Connection") {
                    appModel.selectWorkspace(path: controller.workspace.canonicalPath)
                    appModel.retryActiveWorkspaceConnection()
                }
            }

            Divider()

            Button("Remove Workspace") {
                appModel.removeWorkspace(path: controller.workspace.canonicalPath)
            }
        }
    }

    private func toggleExpansion() {
        let shouldExpand = controller.isExpanded == false

        guard controller.isExpanded != shouldExpand else {
            return
        }

        withAnimation(.easeInOut(duration: 0.16)) {
            controller.setExpanded(shouldExpand)
        }

        guard shouldExpand else {
            return
        }

        Task {
            _ = await appModel.prepareWorkspaceForBrowsing(path: controller.workspace.canonicalPath)
        }
    }
}

private struct WorkspaceThreadRow: View {
    let appModel: AppModel
    let workspacePath: String
    let threadSummary: ThreadSummary
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var isRenameFieldFocused: Bool

    private var isSelected: Bool {
        appModel.selectedRoute?.workspacePath == workspacePath && appModel.selectedRoute?.threadID == threadSummary.id
    }

    private var showsHoverActions: Bool {
        isHovering || isSelected || isRenaming
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }

        if isHovering || isRenaming {
            return Color.secondary.opacity(0.08)
        }

        return .clear
    }

    private var rowBorderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.2)
        }

        if isHovering || isRenaming {
            return Color(nsColor: .separatorColor).opacity(0.24)
        }

        return .clear
    }

    private var renameCandidate: String {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCommitRename: Bool {
        renameCandidate.isEmpty == false && renameCandidate != threadSummary.title
    }

    private var showsStatusBadges: Bool {
        threadSummary.isRunning ||
            threadSummary.lastErrorMessage != nil ||
            threadSummary.isArchived ||
            threadSummary.isLocalOnly ||
            threadSummary.isStale
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if isRenaming {
                rowContent
            } else {
                Button(action: openThread) {
                    rowContent
                }
                .buttonStyle(.plain)
            }

            Menu {
                threadActionMenuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(showsHoverActions ? Color.secondary : Color.clear)
                    .frame(width: 28, height: 28)
                    .background(
                        (isHovering || isRenaming) ? Color.primary.opacity(0.06) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(BorderlessButtonMenuStyle())
            .menuIndicator(.hidden)
            .accessibilityIdentifier("thread-menu-\(threadSummary.id)")
            .help("Thread options")
            .opacity(showsHoverActions ? 1 : 0)
            .allowsHitTesting(showsHoverActions)
            .animation(.easeInOut(duration: 0.16), value: showsHoverActions)
        }
        .padding(.trailing, 6)
        .background(
            rowBackgroundColor,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(rowBorderColor, lineWidth: 1)
        }
        .shadow(color: .clear, radius: 0)
        .onAppear {
            draftTitle = threadSummary.title
        }
        .onChange(of: threadSummary.title) { _, newValue in
            if isRenaming == false {
                draftTitle = newValue
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            threadActionMenuItems
        }
        .accessibilityIdentifier("thread-row-\(threadSummary.id)")
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(threadSummary.hasUnreadActivity ? Color.accentColor : Color.clear)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    if isRenaming {
                        HStack(spacing: 8) {
                            TextField("Thread title", text: $draftTitle)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                                .focused($isRenameFieldFocused)
                                .onSubmit(commitRename)
                                .onExitCommand(perform: cancelRename)

                            Button(action: commitRename) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(canCommitRename ? Color.accentColor : Color.secondary.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .disabled(canCommitRename == false)
                            .help("Save thread title")
                            .keyboardShortcut(.defaultAction)

                            Button(action: cancelRename) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel renaming")
                            .keyboardShortcut(.cancelAction)
                        }
                    } else {
                        Text(threadSummary.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if showsStatusBadges {
                    HStack(spacing: 6) {
                        if threadSummary.isRunning {
                            SidebarThreadBadge(text: "Running", color: .blue)
                        }

                        if threadSummary.lastErrorMessage != nil {
                            SidebarThreadBadge(text: "Error", color: .red)
                        }

                        if threadSummary.isArchived {
                            SidebarThreadBadge(text: "Archived", color: .secondary)
                        }

                        if threadSummary.isLocalOnly {
                            SidebarThreadBadge(text: "Local", color: .teal)
                        }

                        if threadSummary.isStale {
                            SidebarThreadBadge(text: "Stale", color: .orange)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var threadActionMenuItems: some View {
        Button(threadSummary.isArchived ? "Unarchive" : "Archive") {
            if threadSummary.isArchived {
                Task {
                    _ = await appModel.unarchiveThread(workspacePath: workspacePath, threadID: threadSummary.id)
                }
            } else {
                Task {
                    _ = await appModel.archiveThread(workspacePath: workspacePath, threadID: threadSummary.id)
                }
            }
        }

        Button("Rename") {
            beginRename()
        }

        Button("Fork") {
            Task {
                _ = await appModel.forkThread(workspacePath: workspacePath, threadID: threadSummary.id)
            }
        }
    }

    private func beginRename() {
        draftTitle = threadSummary.title
        isRenaming = true

        Task { @MainActor in
            isRenameFieldFocused = true
        }
    }

    private func cancelRename() {
        draftTitle = threadSummary.title
        isRenaming = false
        isRenameFieldFocused = false
    }

    private func commitRename() {
        guard canCommitRename else {
            cancelRename()
            return
        }

        let nextTitle = renameCandidate
        Task {
            let succeeded = await appModel.renameThread(
                workspacePath: workspacePath,
                threadID: threadSummary.id,
                title: nextTitle
            )

            await MainActor.run {
                if succeeded {
                    draftTitle = nextTitle
                    isRenaming = false
                    isRenameFieldFocused = false
                } else {
                    isRenameFieldFocused = true
                }
            }
        }
    }

    private func openThread() {
        Task {
            _ = await appModel.openThread(
                workspacePath: workspacePath,
                threadID: threadSummary.id
            )
        }
    }
}

private struct SidebarThreadBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct ConversationDetailView: View {
    let appModel: AppModel
    @Binding var composerText: String
    @Binding var isShowingWorkspacePicker: Bool

    var body: some View {
        Group {
            if let controller = appModel.selectedWorkspaceController {
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
        .navigationTitle(appModel.selectedThreadSummary?.title ?? appModel.selectedWorkspaceController?.workspace.displayName ?? "AtelierCode")
    }
}

private struct SettingsDetailView: View {
    let appModel: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Settings")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.6)

                    ForEach(SettingsSection.allCases) { section in
                        SidebarDestinationButton(
                            title: section.title,
                            systemImage: section.systemImage,
                            isSelected: appModel.selectedSettingsSection == section
                        ) {
                            appModel.selectSettingsSection(section)
                        }
                        .accessibilityIdentifier("settings-section-\(section.rawValue)")
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(width: 260)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color.secondary.opacity(0.04))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.2))
                    .frame(width: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(appModel.selectedSettingsSection.title)
                        .font(.largeTitle.weight(.semibold))

                    Text("Manage how AtelierCode looks and behaves.")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    switch appModel.selectedSettingsSection {
                    case .general:
                        SettingsGeneralSection(appModel: appModel)
                    }
                }
                .padding(32)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Settings")
    }
}

private struct SettingsGeneralSection: View {
    let appModel: AppModel

    var body: some View {
        SettingsCard(
            title: "Dark Mode",
            description: "Choose whether AtelierCode follows the system appearance or always uses light or dark mode."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(
                    "Dark Mode",
                    selection: Binding(
                        get: { appModel.appearancePreference },
                        set: { appModel.setAppearancePreference($0) }
                    )
                ) {
                    ForEach(AppAppearancePreference.allCases) { preference in
                        Text(preference.title)
                            .tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("settings-dark-mode-picker")

                Text(appModel.appearancePreference.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-dark-mode-description")
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let description: String
    let content: Content

    init(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))

                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-card-\(title)")
    }
}

private struct ActiveWorkspaceConversationView: View {
    let appModel: AppModel
    let controller: WorkspaceController
    @Binding var composerText: String
    @State private var composerHeight: CGFloat = 260

    private let floatingComposerMaxWidth: CGFloat = 740
    private let contentPadding: CGFloat = 24
    private let floatingComposerBottomPadding: CGFloat = 20
    private let transcriptComposerSpacing: CGFloat = 20

    private var composerClearance: CGFloat {
        composerHeight + floatingComposerBottomPadding + transcriptComposerSpacing
    }

    private var isDraftingNewThread: Bool {
        appModel.selectedRoute?.workspacePath == controller.workspace.canonicalPath &&
            appModel.selectedRoute?.threadID == nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if (isDraftingNewThread || controller.visibleThreadSummaries.isEmpty),
               appModel.selectedThreadSession == nil {
                VStack(spacing: 4) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)

                    Text("Start a new thread in:")
                        .foregroundStyle(.secondary)

                    WorkspacePickerButton(appModel: appModel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, composerClearance)
                .accessibilityIdentifier("conversation-ready-empty-state")
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ConversationSurface(
                                appModel: appModel,
                                controller: controller,
                                bottomInset: composerClearance
                            )
                            .frame(maxWidth: floatingComposerMaxWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .padding(.horizontal, contentPadding)
                        .padding(.top, contentPadding)
                        .padding(.bottom, composerClearance)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: geometry.size.height)
                    }
                }
            }

            ComposerBar(appModel: appModel, composerText: $composerText)
                .frame(maxWidth: floatingComposerMaxWidth)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(key: ComposerHeightPreferenceKey.self, value: geometry.size.height)
                    }
                }
                .padding(.horizontal, contentPadding)
                .padding(.bottom, floatingComposerBottomPadding)
        }
        .onPreferenceChange(ComposerHeightPreferenceKey.self) { composerHeight = $0 }
        .task(id: selectedThreadLoadKey) {
            guard let selectedRoute = appModel.selectedRoute,
                  selectedRoute.workspacePath == controller.workspace.canonicalPath,
                  let threadID = selectedRoute.threadID,
                  appModel.selectedThreadSession == nil else {
                return
            }

            _ = await appModel.openThread(
                workspacePath: selectedRoute.workspacePath,
                threadID: threadID
            )
        }
    }

    private var selectedThreadLoadKey: String? {
        guard let selectedRoute = appModel.selectedRoute,
              selectedRoute.workspacePath == controller.workspace.canonicalPath,
              let threadID = selectedRoute.threadID else {
            return nil
        }

        return "\(selectedRoute.workspacePath)#\(threadID)"
    }
}

private struct ConversationSurface: View {
    let appModel: AppModel
    let controller: WorkspaceController
    let bottomInset: CGFloat

    var body: some View {
        Group {
            if isLoadingSelectedThread {
                StateCard(
                    title: "Loading Thread",
                    message: "Restoring the selected conversation in this workspace."
                )
                .padding(.bottom, bottomInset)
                .accessibilityIdentifier("conversation-loading-thread-state")
            } else if case .connecting = controller.connectionStatus, hasTranscript == false {
                StateCard(
                    title: "Connecting to the Bridge",
                    message: "The selected workspace has been restored and the runtime is starting."
                )
                .padding(.bottom, bottomInset)
                .accessibilityIdentifier("conversation-connecting-state")
            } else if case .error(let message) = controller.connectionStatus, hasTranscript == false {
                StateCard(
                    title: "Connection Error",
                    message: message
                )
                .padding(.bottom, bottomInset)
                .accessibilityIdentifier("workspace-error-state")
            } else {
                ConversationTranscript(
                    appModel: appModel,
                    session: appModel.selectedThreadSession,
                    hasSelectedThread: appModel.selectedThreadSummary != nil,
                    hasVisibleThreads: controller.visibleThreadSummaries.isEmpty == false,
                    bottomInset: bottomInset
                )
            }
        }
    }

    private var hasTranscript: Bool {
        guard let session = appModel.selectedThreadSession else {
            return false
        }

        return session.messages.isEmpty == false ||
            session.turnItems.isEmpty == false ||
            session.pendingApprovals.isEmpty == false ||
            session.planState != nil ||
            session.aggregatedDiff != nil
    }

    private var isLoadingSelectedThread: Bool {
        appModel.selectedThreadSummary != nil && appModel.selectedThreadSession == nil
    }
}

private struct ConversationTranscript: View {
    let appModel: AppModel
    let session: ThreadSession?
    let hasSelectedThread: Bool
    let hasVisibleThreads: Bool
    let bottomInset: CGFloat

    var body: some View {
        if let session {
            TranscriptBody(appModel: appModel, session: session, bottomInset: bottomInset)
        } else if hasSelectedThread {
            ContentUnavailableView {
                Label("Loading Thread", systemImage: "arrow.triangle.2.circlepath")
            } description: {
                Text("Restoring the selected thread history.")
            }
            .padding(.bottom, bottomInset)
            .frame(maxWidth: .infinity, minHeight: 420)
            .accessibilityIdentifier("conversation-loading-empty-state")
        } else if hasVisibleThreads {
            ContentUnavailableView {
                Label("Select a Thread", systemImage: "text.bubble")
            } description: {
                Text("Choose a thread from the sidebar to inspect or continue it.")
            }
            .padding(.bottom, bottomInset)
            .frame(maxWidth: .infinity, minHeight: 420)
            .accessibilityIdentifier("conversation-select-thread-state")
        }
    }
}

private struct WorkspacePickerButton: View {
    let appModel: AppModel

    private var currentWorkspace: WorkspaceRecord? {
        appModel.selectedWorkspaceController?.workspace
    }

    var body: some View {
        Menu {
            ForEach(appModel.workspaceControllers, id: \.workspace.canonicalPath) { controller in
                Button {
                    appModel.selectWorkspaceForNewThread(path: controller.workspace.canonicalPath)
                } label: {
                    HStack {
                        Text(controller.workspace.displayName)
                        if controller.workspace.canonicalPath == currentWorkspace?.canonicalPath {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button("Open Workspace...") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false

                guard panel.runModal() == .OK, let url = panel.url else {
                    return
                }

                appModel.activateWorkspace(at: url)
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentWorkspace?.displayName ?? "No Workspace")
                    .font(.title2.bold())
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityIdentifier("new-thread-workspace-picker")
    }
}

private struct DetailStatusBar: View {
    let appModel: AppModel

    var body: some View {
        HStack(spacing: 12) {
            ForEach(appModel.detailStatusItems) { item in
                DetailStatusBarItem(appModel: appModel, item: item)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.32))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-status-bar")
    }
}

private struct DetailStatusBarItem: View {
    let appModel: AppModel
    let item: DetailStatusItem

    var body: some View {
        ZStack {
            if item.isInteractive && item.id == "git-reference" {
                Button {
                    appModel.toggleSelectedWorkspaceBranchPicker()
                } label: {
                    content
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workspace-status-\(item.id)")
                .accessibilityLabel(item.text)
            } else {
                content
                    .accessibilityIdentifier("workspace-status-\(item.id)")
                    .accessibilityLabel(item.text)
            }
        }
        .popover(
            isPresented: item.id == "git-reference" ? branchPickerPresentation : .constant(false),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            BranchPickerPopover(appModel: appModel)
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .font(.caption.weight(.semibold))

            Text(item.text)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(item.isPlaceholder ? .tertiary : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .ignore)
    }

    private var branchPickerPresentation: Binding<Bool> {
        Binding(
            get: { appModel.isSelectedWorkspaceBranchPickerPresented },
            set: { isPresented in
                if isPresented == false {
                    appModel.dismissSelectedWorkspaceBranchPicker()
                }
            }
        )
    }
}

private struct BranchPickerPopover: View {
    let appModel: AppModel
    @FocusState private var isFilterFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search or create branch", text: filterTextBinding)
                    .textFieldStyle(.plain)
                    .focused($isFilterFieldFocused)
                    .onSubmit {
                        Task {
                            await appModel.submitSelectedWorkspaceBranchPicker()
                        }
                    }
                    .accessibilityIdentifier("branch-picker-filter")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Branches")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            if appModel.isSelectedWorkspaceBranchPickerLoading &&
                appModel.selectedWorkspaceBranchPickerFilteredBranches.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Loading local branches…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            } else {
                BranchPickerBranchList(appModel: appModel)
            }

            if let errorMessage = appModel.selectedWorkspaceBranchPickerErrorMessage,
               errorMessage.isEmpty == false {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("branch-picker-error")
            }
        }
        .padding(16)
        .frame(width: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("branch-picker-popover")
        .onAppear {
            isFilterFieldFocused = true
        }
        .onMoveCommand { direction in
            switch direction {
            case .up:
                appModel.moveSelectedWorkspaceBranchPickerSelection(.up)
            case .down:
                appModel.moveSelectedWorkspaceBranchPickerSelection(.down)
            default:
                break
            }
        }
        .onExitCommand {
            appModel.dismissSelectedWorkspaceBranchPicker()
        }
    }

    private var filterTextBinding: Binding<String> {
        Binding(
            get: { appModel.selectedWorkspaceBranchPickerFilterText },
            set: { appModel.setSelectedWorkspaceBranchPickerFilterText($0) }
        )
    }
}

private struct BranchPickerBranchList: View {
    let appModel: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if appModel.selectedWorkspaceBranchPickerItems.isEmpty {
                        Text(emptyStateText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .accessibilityIdentifier("branch-picker-empty-state")
                    } else {
                        ForEach(appModel.selectedWorkspaceBranchPickerItems) { item in
                            BranchPickerRow(
                                item: item,
                                isCurrentBranch: currentBranchName(for: item) == appModel.selectedWorkspaceBranchPickerCurrentBranchName,
                                isSelected: appModel.selectedWorkspaceBranchPickerSelectedItemID == item.id,
                                isDisabled: appModel.isSelectedWorkspaceBranchPickerPerformingAction
                            ) {
                                Task {
                                    await performAction(for: item)
                                }
                            }
                            .id(item.id)
                        }
                    }
                }
                .padding(2)
            }
            .onChange(of: appModel.selectedWorkspaceBranchPickerSelectedItemID) { _, selectedItemID in
                guard let selectedItemID else {
                    return
                }

                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(selectedItemID, anchor: .center)
                }
            }
        }
        .frame(minHeight: 140, maxHeight: 220)
        .background(Color.secondary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 1)
        }
    }

    private var emptyStateText: String {
        let filterText = appModel.selectedWorkspaceBranchPickerFilterText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if filterText.isEmpty {
            return "No local branches found."
        }

        return "No branches match \"\(filterText)\"."
    }

    private func currentBranchName(for item: WorkspaceBranchPickerItem) -> String? {
        guard case .branch(let branchName) = item else {
            return nil
        }

        return branchName
    }

    private func performAction(for item: WorkspaceBranchPickerItem) async {
        switch item {
        case .branch(let branchName):
            await appModel.selectBranchFromPicker(branchName)
        case .create:
            await appModel.createSelectedWorkspaceBranchFromPicker()
        }
    }
}

private struct BranchPickerRow: View {
    let item: WorkspaceBranchPickerItem
    let isCurrentBranch: Bool
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if isCurrentBranch {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: isSelected ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }

        if isCurrentBranch {
            return Color.accentColor.opacity(0.07)
        }

        return Color.clear
    }

    private var borderColor: Color {
        isSelected ? Color.accentColor.opacity(0.4) : .clear
    }

    private var iconName: String {
        switch item {
        case .branch:
            return "arrow.triangle.branch"
        case .create:
            return "plus"
        }
    }

    private var title: String {
        switch item {
        case .branch(let branchName):
            return branchName
        case .create:
            return "Create and check out branch"
        }
    }

    private var subtitle: String? {
        switch item {
        case .branch:
            return nil
        case .create(let branchName):
            return branchName
        }
    }

    private var accessibilityIdentifier: String {
        switch item {
        case .branch(let branchName):
            return "branch-picker-item-\(branchName)"
        case .create:
            return "branch-picker-create-item"
        }
    }
}

private struct TranscriptBody: View {
    let appModel: AppModel
    let session: ThreadSession
    let bottomInset: CGFloat
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
                    .frame(height: bottomInset)
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
            .onChange(of: bottomInset) { _, _ in
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
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("transcript-end", anchor: .bottom)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-message-\(message.id)")
    }
}

private struct TurnDetailsStack: View {
    let appModel: AppModel
    let session: ThreadSession
    let maxWidth: CGFloat
    @State private var expandedActivitySectionIDs: Set<String> = []

    private var presentation: TranscriptTurnPresentation {
        TranscriptTurnPresentation(turnState: session.turnState, turnItems: session.turnItems)
    }

    private var transcriptEntries: [TranscriptTurnEntry] {
        presentation.entries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.turnItems.isEmpty == false {
                ForEach(transcriptEntries) { entry in
                    TranscriptTurnEntryRow(
                        entry: entry,
                        maxWidth: maxWidth,
                        expandedActivitySectionIDs: $expandedActivitySectionIDs
                    )
                }
            }

            if presentation.showsAssistantWaitingIndicator {
                AssistantWaitingIndicatorRow(maxWidth: maxWidth)
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
        .onChange(of: transcriptEntries) { _, newEntries in
            let validSectionIDs: Set<String> = Set(
                newEntries.compactMap { entry in
                    guard case let .activitySection(section) = entry else {
                        return nil
                    }

                    return section.id
                }
            )

            expandedActivitySectionIDs.formIntersection(validSectionIDs)
        }
    }
}

private struct TranscriptTurnEntryRow: View {
    let entry: TranscriptTurnEntry
    let maxWidth: CGFloat
    @Binding var expandedActivitySectionIDs: Set<String>

    var body: some View {
        switch entry {
        case .item(let item):
            TurnItemRow(item: item, maxWidth: maxWidth)
        case .activitySection(let section):
            ActivitySectionCard(
                section: section,
                maxWidth: maxWidth,
                expandedActivitySectionIDs: $expandedActivitySectionIDs
            )
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

private struct ActivitySectionCard: View {
    let section: TranscriptActivitySection
    let maxWidth: CGFloat
    @Binding var expandedActivitySectionIDs: Set<String>

    private var isExpanded: Bool {
        section.defaultExpanded || expandedActivitySectionIDs.contains(section.id)
    }

    private var itemCountLabel: String {
        section.itemCount == 1 ? "1 item" : "\(section.itemCount) items"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggleExpansion) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(section.kind.title, systemImage: section.kind.systemImage)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(section.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)

                        HStack(spacing: 8) {
                            if section.hasMixedStatuses {
                                ForEach(section.statusCountChips) { chip in
                                    ActivityStatusCountChip(
                                        chip: chip,
                                        accessibilityIdentifier: section.statusCountAccessibilityIdentifier(
                                            for: chip.status
                                        )
                                    )
                                }

                                if section.status.activityStatus == .running {
                                    ActivityStatusAccessory(
                                        status: .running,
                                        accessibilityIdentifier: section.statusAccessoryAccessibilityIdentifier
                                    )
                                }
                            } else {
                                PlanCountBadge(text: itemCountLabel)
                                ActivityStatusAccessory(
                                    status: section.status.activityStatus,
                                    accessibilityIdentifier: section.statusAccessoryAccessibilityIdentifier
                                )
                            }

                            Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(section.toggleAccessibilityIdentifier)
            .accessibilityValue(section.accessibilityValue)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(section.items) { item in
                        ActivityTurnItemRow(item: item, maxWidth: maxWidth)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(section.accessibilityIdentifier)
    }

    private func toggleExpansion() {
        guard section.defaultExpanded == false else {
            return
        }

        if expandedActivitySectionIDs.contains(section.id) {
            expandedActivitySectionIDs.remove(section.id)
        } else {
            expandedActivitySectionIDs.insert(section.id)
        }
    }
}

private struct AssistantTurnItemRow: View {
    let item: TurnItem
    let maxWidth: CGFloat

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Assistant")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.blue)

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

private struct AssistantWaitingIndicatorRow: View {
    let maxWidth: CGFloat

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                AnimatedEllipsisIndicator()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.10), in: Capsule())
            .frame(maxWidth: maxWidth, alignment: .leading)

            Spacer(minLength: 48)
        }
        .accessibilityIdentifier("assistant-waiting-indicator")
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

    private var visibleDetail: String? {
        guard let detail = item.detail, detail.isEmpty == false else {
            return nil
        }

        return detail.isMeaningfullyDifferent(from: [item.title, item.command]) ? detail : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.headline)

                    if let detail = visibleDetail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                ActivityStatusAccessory(
                    status: item.status,
                    accessibilityIdentifier: "turn-item-\(item.id)-status-accessory"
                )
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

            if let exitCode = item.exitCode, exitCode != 0 {
                Text("Exit code: \(exitCode)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
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

private struct ActivitySpinner: View {
    let color: Color
    var size: CGFloat = 12
    var lineWidth: CGFloat = 2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let rotation = Angle.degrees((elapsed * 220).truncatingRemainder(dividingBy: 360))

            ZStack {
                Circle()
                    .stroke(color.opacity(0.18), lineWidth: lineWidth)

                Circle()
                    .trim(from: 0.12, to: 0.72)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(rotation)
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

private struct AnimatedEllipsisIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.24)) { context in
            let visibleDots = (Int(context.date.timeIntervalSinceReferenceDate / 0.24) % 3) + 1

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .opacity(index < visibleDots ? 1 : 0.28)
                }
            }
            .frame(height: 10)
        }
    }
}

private struct RunningActivityStatusAccessory: View {
    let status: ActivityStatus

    var body: some View {
        ActivitySpinner(color: status.tintColor, size: 18, lineWidth: 2.6)
            .padding(9)
            .background(Color.secondary.opacity(0.10), in: Circle())
    }
}

private struct ActivityStatusAccessory: View {
    let status: ActivityStatus
    let accessibilityIdentifier: String

    var body: some View {
        if status == .running {
            RunningActivityStatusAccessory(status: status)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Running")
                .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            ActivityStatusBadge(status: status)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

private struct ActivityStatusCountChip: View {
    let chip: TranscriptActivityStatusCountChip
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 6) {
            if chip.status == .running {
                ActivitySpinner(color: chip.status.activityStatus.tintColor)
            }

            Text(chip.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(chip.status.activityStatus.tintColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(chip.status.activityStatus.tintColor.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
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

private struct TranscriptActivityStatusCountChip: Identifiable {
    let status: TranscriptActivitySectionStatus
    let count: Int

    var id: String {
        status.rawValue
    }

    var text: String {
        "\(count) \(status.countLabel)"
    }
}

private struct ComposerBar: View {
    let appModel: AppModel
    @Binding var composerText: String
    @State private var isFocused = false

    private var isComposerEnabled: Bool {
        appModel.selectedWorkspaceController != nil && appModel.selectedThreadSummary?.isArchived != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                ComposerTextView(
                    text: $composerText,
                    isEnabled: isComposerEnabled,
                    isFocused: $isFocused,
                    onSubmit: sendPrompt
                )
                .frame(minHeight: 84, maxHeight: 180)
                .accessibilityIdentifier("conversation-composer")

                if composerText.isEmpty {
                    Text("Send a prompt to Codex...")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, ComposerMetrics.textHorizontalInset)
                        .padding(.top, ComposerMetrics.textVerticalInset)
                        .allowsHitTesting(false)
                }
            }

            HStack(alignment: .center, spacing: 8) {
                if appModel.availableComposerModels.isEmpty == false {
                    Menu {
                        Button {
                            appModel.setComposerModelID(nil)
                        } label: {
                            ComposerMenuItemLabel(
                                title: "Default Model",
                                isSelected: appModel.effectiveComposerModelID == nil
                            )
                        }

                        Divider()

                        ForEach(appModel.availableComposerModels) { option in
                            Button {
                                appModel.setComposerModelID(option.id)
                            } label: {
                                ComposerMenuItemLabel(
                                    title: option.title,
                                    isSelected: appModel.effectiveComposerModelID == option.id
                                )
                            }
                        }
                    } label: {
                        ComposerMenuChip(title: appModel.composerModelTitle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("composer-model-button")

                    Menu {
                        ForEach(appModel.availableComposerReasoningEfforts) { effort in
                            Button {
                                appModel.setComposerReasoningEffort(effort)
                            } label: {
                                ComposerMenuItemLabel(
                                    title: effort.title,
                                    isSelected: appModel.effectiveComposerReasoningEffort == effort
                                )
                            }
                        }
                    } label: {
                        ComposerMenuChip(title: appModel.composerReasoningEffortTitle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("composer-reasoning-button")
                }

                Spacer(minLength: 0)

                if appModel.canCancelTurn {
                    Button {
                        Task {
                            await appModel.cancelActiveTurn()
                        }
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.04), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    }
                    .accessibilityIdentifier("conversation-cancel-button")
                }
            }
            .padding(.leading, ComposerMetrics.textHorizontalInset)

            if showsDisabledBanner {
                Text(disabledBannerText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, ComposerMetrics.textHorizontalInset)
                    .accessibilityIdentifier("composer-disabled-banner")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(editorBorderColor, lineWidth: isFocused ? 1.25 : 1)
        }
        .shadow(color: editorShadowColor, radius: isFocused ? 14 : 6, y: isFocused ? 5 : 2)
    }

    private var editorBorderColor: Color {
        if isFocused {
            return Color.accentColor.opacity(0.38)
        }

        return Color.white.opacity(0.06)
    }

    private var editorShadowColor: Color {
        if isFocused {
            return Color.accentColor.opacity(0.12)
        }

        return Color.black.opacity(0.12)
    }

    private var showsDisabledBanner: Bool {
        isComposerEnabled == false
    }

    private var disabledBannerText: String {
        guard let controller = appModel.selectedWorkspaceController else {
            return "Pick a workspace to start a conversation."
        }

        if appModel.selectedThreadSummary?.isArchived == true {
            return "Archived threads are read-only."
        }

        switch controller.connectionStatus {
        case .connecting:
            return "Connecting workspace runtime..."
        case .disconnected:
            return "Reconnect the workspace to continue."
        case .error(let message):
            return message
        case .ready, .streaming, .cancelling:
            return ""
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

private struct ComposerMenuChip: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
        }
        .font(.footnote.weight(.medium))
        .foregroundColor(Color(nsColor: .placeholderTextColor).opacity(0.7))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct ComposerMenuItemLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Group {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    @Binding var isFocused: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
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
        textView.textContainerInset = NSSize(
            width: ComposerMetrics.textHorizontalInset,
            height: ComposerMetrics.textVerticalInset
        )
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
        @Binding private var isFocused: Bool

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            _text = text
            _isFocused = isFocused
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused = false
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

private enum ComposerMetrics {
    static let textHorizontalInset: CGFloat = 13
    static let textVerticalInset: CGFloat = 10
}

private extension View {
    func sidebarCardBackground(cornerRadius: CGFloat = 16) -> some View {
        background(
            Color.secondary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.14), lineWidth: 1)
        }
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

#Preview {
    ContentView()
        .environment(makePreviewAppModel())
        .frame(width: 1180, height: 760)
}

@MainActor
private func makePreviewAppModel() -> AppModel {
    let workspaceRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AtelierCodePreview", isDirectory: true)
    try? FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

    let preferencesStore = PreviewPreferencesStore()
    try? preferencesStore.saveSnapshot(
        AppPreferencesSnapshot(
            recentWorkspaces: [WorkspaceRecord(url: workspaceRoot, lastOpenedAt: .now)],
            lastSelectedWorkspacePath: workspaceRoot.path,
            codexPathOverride: "/usr/local/bin/codex"
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

    return appModel
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

    func refreshModels() async throws {
        controller.setAvailableModels([])
    }

    func listThreads(archived: Bool) async throws {
        controller.setShowingArchivedThreads(archived)
    }

    func startThreadAndWait(title: String?) async throws -> ThreadSession {
        controller.openThread(id: UUID().uuidString, title: title ?? "Preview Thread", isVisibleInSidebar: false)
    }

    func resumeThreadAndWait(id: String) async throws -> ThreadSession {
        controller.resumeThread(id: id, title: "Preview Thread")
    }

    func readThreadAndWait(id: String, includeTurns: Bool) async throws -> ThreadSession {
        controller.resumeThread(id: id, title: "Preview Thread")
    }

    func forkThreadAndWait(id: String) async throws -> ThreadSession {
        controller.resumeThread(id: "\(id)-fork", title: "Preview Thread")
    }

    func renameThread(id: String, title: String) async throws {
        controller.updateThreadSummary(id: id) { summary in
            summary.title = title
        }
        controller.threadSession(id: id)?.updateThreadIdentity(id: id, title: title)
    }

    func archiveThread(id: String) async throws {
        controller.setThreadArchived(true, for: id)
    }

    func unarchiveThreadAndWait(id: String) async throws -> ThreadSession {
        controller.setThreadArchived(false, for: id)
        return controller.resumeThread(id: id, title: "Preview Thread")
    }

    func rollbackThreadAndWait(id: String, numTurns: Int) async throws -> ThreadSession {
        let messages = Array((controller.threadSession(id: id)?.messages ?? []).dropLast(max(0, numTurns)))
        return controller.resumeThread(id: id, title: "Preview Thread", messages: messages)
    }

    func startTurn(threadID: String, prompt: String, configuration: BridgeTurnStartConfiguration?) async throws {
        let session = controller.threadSession(id: threadID)
            ?? controller.openThread(id: threadID, title: "Preview Thread", isVisibleInSidebar: false)
        session.beginTurn(userPrompt: prompt)
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.setCurrentTurnID("preview-turn", for: threadID)
        session.appendAssistantTextDelta("Preview assistant response.")
        session.completeTurn()
        controller.setCurrentTurnID(nil, for: threadID)
        controller.setConnectionStatus(.ready)
    }

    func cancelTurn(threadID: String, reason: String?) async throws {
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.threadSession(id: threadID)?.cancelTurn()
        controller.setCurrentTurnID(nil, for: threadID)
        controller.setConnectionStatus(.ready)
    }

    func resolveApproval(threadID: String, id: String, resolution: ApprovalResolution) async throws {
        controller.threadSession(id: threadID)?.resolveApprovalRequest(id: id, resolution: resolution)
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

private struct ComposerHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 260

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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

private extension TranscriptActivitySectionStatus {
    var activityStatus: ActivityStatus {
        switch self {
        case .running:
            return .running
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }

    var countLabel: String {
        switch self {
        case .running:
            return "running"
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        }
    }
}

private extension TranscriptActivitySectionKind {
    var title: String {
        switch self {
        case .tools:
            return "Tools"
        case .fileChanges:
            return "File Changes"
        }
    }

    var systemImage: String {
        switch self {
        case .tools:
            return "hammer"
        case .fileChanges:
            return "doc.text"
        }
    }

    var accessibilityIdentifierPrefix: String {
        switch self {
        case .tools:
            return "turn-tools-section"
        case .fileChanges:
            return "turn-file-changes-section"
        }
    }
}

private extension TranscriptActivitySection {
    var statusCountChips: [TranscriptActivityStatusCountChip] {
        [
            TranscriptActivityStatusCountChip(status: .running, count: statusCounts.running),
            TranscriptActivityStatusCountChip(status: .completed, count: statusCounts.completed),
            TranscriptActivityStatusCountChip(status: .failed, count: statusCounts.failed),
            TranscriptActivityStatusCountChip(status: .cancelled, count: statusCounts.cancelled)
        ]
        .filter { $0.count > 0 }
    }

    var accessibilityIdentifier: String {
        "\(kind.accessibilityIdentifierPrefix)-\(ordinal)"
    }

    var toggleAccessibilityIdentifier: String {
        "\(accessibilityIdentifier)-toggle"
    }

    var statusAccessoryAccessibilityIdentifier: String {
        "\(accessibilityIdentifier)-status-accessory"
    }

    func statusCountAccessibilityIdentifier(
        for status: TranscriptActivitySectionStatus
    ) -> String {
        "\(accessibilityIdentifier)-status-count-\(status.rawValue)"
    }

    var accessibilityValue: String {
        if hasMixedStatuses {
            return statusCountChips
                .map(\.text)
                .joined(separator: ", ")
        }

        return "\(itemCount) \(itemCount == 1 ? "item" : "items"), \(status.countLabel)"
    }
}

private extension Date {
    var relativeThreadTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: .now)
    }
}

private extension String {
    func isMeaningfullyDifferent(from candidates: [String?]) -> Bool {
        let normalizedSelf = normalizedComparisonValue
        guard normalizedSelf.isEmpty == false else {
            return false
        }

        return candidates
            .compactMap { $0?.normalizedComparisonValue }
            .filter { $0.isEmpty == false }
            .contains(normalizedSelf) == false
    }

    var normalizedComparisonValue: String {
        lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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
