//
//  AtelierCodeTests.swift
//  AtelierCodeTests
//
//  Created by Jeremy Margaritondo on 3/23/26.
//

import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct AppModelTests {
    @Test func loadsPersistedPreferences() async throws {
        let workspaceURL = try temporaryDirectory()
        let codexURL = workspaceURL.appendingPathComponent("codex", isDirectory: false)
        FileManager.default.createFile(atPath: codexURL.path, contents: Data())

        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [WorkspaceRecord(url: workspaceURL, lastOpenedAt: .distantPast)],
            lastSelectedWorkspacePath: nil,
            codexPathOverride: codexURL.path
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)
        let runtimeCoordinator = TestRuntimeCoordinator()

        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )

        #expect(appModel.recentWorkspaces == snapshot.recentWorkspaces)
        #expect(appModel.codexPathOverride == codexURL.path)
        #expect(appModel.startupDiagnostics.isEmpty)
    }

    @Test func restoresValidLastSelectedWorkspace() async throws {
        let workspaceURL = try temporaryDirectory()
        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [WorkspaceRecord(url: workspaceURL, lastOpenedAt: .now)],
            lastSelectedWorkspacePath: workspaceURL.path,
            codexPathOverride: nil
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)
        let runtimeCoordinator = TestRuntimeCoordinator()

        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        #expect(appModel.lastSelectedWorkspacePath == workspaceURL.path)
        #expect(appModel.activeWorkspaceController?.workspace.canonicalPath == workspaceURL.path)
        #expect(appModel.activeWorkspaceController?.connectionStatus == .ready)
        #expect(appModel.selectedRoute?.workspacePath == workspaceURL.path)
        #expect(appModel.selectedRoute?.threadID == nil)
        #expect(appModel.startupDiagnostics.isEmpty)
        #expect(runtimeCoordinator.startCount == 1)
    }

    @Test func clearsInvalidRestoredWorkspaceAndRecordsDiagnostic() async throws {
        let workspaceURL = try temporaryDirectory()
        try FileManager.default.removeItem(at: workspaceURL)

        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [],
            lastSelectedWorkspacePath: workspaceURL.path,
            codexPathOverride: nil
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)

        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: TestRuntimeCoordinator()) }
        )

        #expect(appModel.lastSelectedWorkspacePath == nil)
        #expect(appModel.activeWorkspaceController == nil)
        #expect(appModel.startupDiagnostics.contains(where: { $0.source == .restoredWorkspace && $0.severity == .warning }))
        #expect(try store.loadSnapshot()?.lastSelectedWorkspacePath == nil)
    }

    @Test func deduplicatesAndCapsRecentWorkspaces() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        var workspaceURLs: [URL] = []

        for index in 0..<21 {
            let workspaceURL = try temporaryDirectory(named: "workspace-\(index)")
            workspaceURLs.append(workspaceURL)
            appModel.activateWorkspace(at: workspaceURL)
        }

        appModel.activateWorkspace(at: workspaceURLs[5])

        #expect(appModel.recentWorkspaces.count == 20)
        #expect(appModel.recentWorkspaces.first?.canonicalPath == workspaceURLs[5].path)
        #expect(Set(appModel.recentWorkspaces.map(\.canonicalPath)).count == appModel.recentWorkspaces.count)
    }

    @Test func roundTripsCodexOverride() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let codexURL = try temporaryDirectory(named: "codex-bin").appendingPathComponent("codex")
        FileManager.default.createFile(atPath: codexURL.path, contents: Data())

        appModel.setCodexPathOverride(codexURL.path)

        let restoredModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )

        #expect(restoredModel.codexPathOverride == codexURL.path)
    }

    @Test func roundTripsAppearancePreference() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )

        appModel.setAppearancePreference(.dark)

        let restoredModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )

        #expect(restoredModel.appearancePreference == .dark)
    }

    @Test func roundTripsComposerSelections() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )

        appModel.setComposerModelID("gpt-5.4")
        appModel.setComposerReasoningEffort(.xhigh)

        let restoredModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )

        #expect(restoredModel.composerModelID == "gpt-5.4")
        #expect(restoredModel.composerReasoningEffort == .xhigh)
    }

    @Test func selectingWorkspaceReturnsFromSettingsToConversationView() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "settings-navigation")

        await gitService.enqueueStatuses([.branch("main")], for: workspaceURL.path)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        appModel.showSettings()
        #expect(appModel.primaryView == .settings)

        appModel.selectWorkspace(path: workspaceURL.path)

        #expect(appModel.primaryView == .conversations)
        #expect(appModel.activeWorkspaceController?.workspace.canonicalPath == workspaceURL.path)
    }

    @Test func selectingDifferentWorkspaceRefreshesGitStatusForNewSelection() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let firstWorkspaceURL = try temporaryDirectory(named: "git-status-first")
        let secondWorkspaceURL = try temporaryDirectory(named: "git-status-second")

        await gitService.enqueueStatuses([.branch("main")], for: firstWorkspaceURL.path)
        appModel.activateWorkspace(at: firstWorkspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("main") }

        await gitService.enqueueStatuses([.detachedHead("abc1234")], for: secondWorkspaceURL.path)
        appModel.activateWorkspace(at: secondWorkspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .detachedHead("abc1234") }

        #expect(await gitService.requestedWorkspacePaths() == [firstWorkspaceURL.path, secondWorkspaceURL.path])
        #expect(appModel.activeWorkspaceController?.workspace.canonicalPath == secondWorkspaceURL.path)
        #expect(appModel.activeWorkspaceController?.gitStatus == .detachedHead("abc1234"))
    }

    @Test func appActivationRefreshesSelectedWorkspaceGitStatusAgain() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "git-status-reactivation")

        await gitService.enqueueStatuses([.branch("main"), .detachedHead("abc1234")], for: workspaceURL.path)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("main") }

        appModel.applicationDidBecomeActive()
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .detachedHead("abc1234") }

        #expect(await gitService.requestedWorkspacePaths() == [workspaceURL.path, workspaceURL.path])
        #expect(appModel.activeWorkspaceController?.gitStatus == .detachedHead("abc1234"))
    }

    @Test func keyWindowActivationRefreshesSelectedWorkspaceGitStatusAgain() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "git-status-window-key")

        await gitService.enqueueStatuses([.branch("main"), .branch("feature/window-key")], for: workspaceURL.path)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("main") }

        appModel.applicationWindowDidBecomeKey()
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("feature/window-key") }

        #expect(await gitService.requestedWorkspacePaths() == [workspaceURL.path, workspaceURL.path])
        #expect(appModel.activeWorkspaceController?.gitStatus == .branch("feature/window-key"))
    }

    @Test func openingThreadInAnotherWorkspaceRefreshesGitStatusForThatWorkspace() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let firstWorkspaceURL = try temporaryDirectory(named: "git-status-thread-open-first")
        let secondWorkspaceURL = try temporaryDirectory(named: "git-status-thread-open-second")

        await gitService.enqueueStatuses([.branch("main"), .branch("main")], for: firstWorkspaceURL.path)
        await gitService.enqueueStatuses([.branch("feature/initial"), .detachedHead("abc1234")], for: secondWorkspaceURL.path)

        appModel.activateWorkspace(at: firstWorkspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("main") }

        appModel.activateWorkspace(at: secondWorkspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("feature/initial") }
        appModel.activeWorkspaceController?.upsertThreadSummary(
            ThreadSummary(
                id: "thread-2",
                title: "Second Workspace Thread",
                previewText: "Open me",
                updatedAt: .now
            )
        )

        appModel.selectWorkspace(path: firstWorkspaceURL.path)
        try await waitUntil {
            appModel.activeWorkspaceController?.workspace.canonicalPath == firstWorkspaceURL.path &&
                appModel.activeWorkspaceController?.gitStatus == .branch("main")
        }

        let didOpen = await appModel.openThread(workspacePath: secondWorkspaceURL.path, threadID: "thread-2")

        #expect(didOpen)
        try await waitUntil {
            appModel.activeWorkspaceController?.workspace.canonicalPath == secondWorkspaceURL.path &&
                appModel.activeWorkspaceController?.gitStatus == .detachedHead("abc1234")
        }

        #expect(await gitService.requestedWorkspacePaths() == [
            firstWorkspaceURL.path,
            secondWorkspaceURL.path,
            firstWorkspaceURL.path,
            secondWorkspaceURL.path,
        ])
    }

    @Test func openingOrphanedLocalOnlyThreadRemovesItAndKeepsWorkspaceUsable() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "open-orphaned-local-thread")

        await gitService.enqueueStatuses([.branch("main")], for: workspaceURL.path)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.workspace.canonicalPath == workspaceURL.path }

        guard let controller = appModel.activeWorkspaceController else {
            Issue.record("Expected active workspace controller.")
            return
        }

        controller.replaceThreadList([
            ThreadSummary(
                id: "thread-real",
                title: "Real Thread",
                previewText: "Available",
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        ])
        controller.openThread(id: "thread-local", title: "Ghost Thread", isVisibleInSidebar: true)
        controller.clearThreadSession(id: "thread-local")
        controller.markThreadSelected("thread-local")
        appModel.selectWorkspace(path: workspaceURL.path)

        let didOpenGhost = await appModel.openThread(workspacePath: workspaceURL.path, threadID: "thread-local")

        #expect(didOpenGhost == false)
        #expect(controller.threadSummary(id: "thread-local") == nil)
        #expect(appModel.selectedRoute?.threadID == "thread-real")
        #expect(controller.connectionStatus == .ready)

        let didOpenReal = await appModel.openThread(workspacePath: workspaceURL.path, threadID: "thread-real")

        #expect(didOpenReal)
        #expect(appModel.selectedThreadSession?.threadID == "thread-real")
    }

    @Test func failedThreadOpenMarksOnlyThatThreadAndLeavesWorkspaceReady() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "failed-thread-open")

        runtimeCoordinator.resumeFailuresByThreadID["thread-bad"] = "Missing thread history"
        await gitService.enqueueStatuses([.branch("main")], for: workspaceURL.path)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.workspace.canonicalPath == workspaceURL.path }

        guard let controller = appModel.activeWorkspaceController else {
            Issue.record("Expected active workspace controller.")
            return
        }

        controller.replaceThreadList([
            ThreadSummary(
                id: "thread-bad",
                title: "Broken Thread",
                previewText: "Missing",
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
            ThreadSummary(
                id: "thread-good",
                title: "Healthy Thread",
                previewText: "Available",
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        ])

        let didOpenBad = await appModel.openThread(workspacePath: workspaceURL.path, threadID: "thread-bad")

        #expect(didOpenBad == false)
        #expect(controller.connectionStatus == .ready)
        #expect(controller.threadSummary(id: "thread-bad")?.lastErrorMessage == "Missing thread history")
        #expect(controller.threadSummary(id: "thread-bad")?.isStale == true)

        let didOpenGood = await appModel.openThread(workspacePath: workspaceURL.path, threadID: "thread-good")

        #expect(didOpenGood)
        #expect(appModel.selectedThreadSession?.threadID == "thread-good")
        #expect(controller.connectionStatus == .ready)
    }

    @Test func openingBranchPickerLoadsBranchesAndResetsWhenWorkspaceChanges() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let firstWorkspaceURL = try temporaryDirectory(named: "branch-picker-first")
        let secondWorkspaceURL = try temporaryDirectory(named: "branch-picker-second")

        await gitService.enqueueStatuses([.branch("main"), .branch("main")], for: firstWorkspaceURL.path)
        await gitService.setLocalBranches(["main", "release"], for: firstWorkspaceURL.path)
        appModel.activateWorkspace(at: firstWorkspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("main") }

        appModel.showSelectedWorkspaceBranchPicker()
        try await waitUntil {
            appModel.isSelectedWorkspaceBranchPickerPresented &&
                appModel.selectedWorkspaceBranchPickerFilteredBranches == ["main", "release"]
        }

        await gitService.enqueueStatuses([.branch("feature/detached-work")], for: secondWorkspaceURL.path)
        appModel.activateWorkspace(at: secondWorkspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("feature/detached-work") }

        #expect(appModel.isSelectedWorkspaceBranchPickerPresented == false)
    }

    @Test func dismissingAndReopeningBranchPickerStartsFreshSession() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "branch-picker-reopen")

        await gitService.enqueueStatuses([.branch("main"), .branch("main"), .branch("main")], for: workspaceURL.path)
        await gitService.setLocalBranches(["git-branches", "main"], for: workspaceURL.path)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("main") }

        appModel.showSelectedWorkspaceBranchPicker()
        try await waitUntil { appModel.selectedWorkspaceBranchPickerFilteredBranches == ["git-branches", "main"] }

        appModel.dismissSelectedWorkspaceBranchPicker()
        #expect(appModel.isSelectedWorkspaceBranchPickerPresented == false)

        appModel.showSelectedWorkspaceBranchPicker()
        try await waitUntil { appModel.selectedWorkspaceBranchPickerFilteredBranches == ["git-branches", "main"] }

        #expect(appModel.selectedWorkspaceBranchPickerFilterText.isEmpty)
    }

    @Test func openingBranchPickerShowsCurrentBranchWhenBranchCacheIsEmpty() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "branch-picker-current-branch-fallback")

        await gitService.enqueueStatuses([.branch("git-branches"), .branch("git-branches")], for: workspaceURL.path)
        await gitService.setLocalBranches([], for: workspaceURL.path)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("git-branches") }

        appModel.showSelectedWorkspaceBranchPicker()
        try await waitUntil {
            appModel.isSelectedWorkspaceBranchPickerPresented &&
                appModel.selectedWorkspaceBranchPickerFilteredBranches == ["git-branches"]
        }

        #expect(appModel.selectedWorkspaceBranchPickerCurrentBranchName == "git-branches")
    }

    @Test func openingBranchPickerRefreshesFromCurrentBranchToFullLocalBranchList() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "branch-picker-refreshes-full-list")

        await gitService.enqueueStatuses([.branch("git-branches"), .branch("git-branches")], for: workspaceURL.path)
        await gitService.setLocalBranches([], for: workspaceURL.path)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("git-branches") }

        await gitService.setLocalBranches(["git-branches", "main"], for: workspaceURL.path)
        appModel.showSelectedWorkspaceBranchPicker()

        try await waitUntil {
            appModel.selectedWorkspaceBranchPickerFilteredBranches == ["git-branches", "main"]
        }
    }

    @Test func submittingExistingBranchSwitchesAndRefreshesSelectedWorkspaceStatus() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "branch-picker-switch")

        await gitService.enqueueStatuses([.branch("main"), .branch("main"), .branch("release")], for: workspaceURL.path)
        await gitService.setLocalBranches(["main", "release"], for: workspaceURL.path)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("main") }

        appModel.showSelectedWorkspaceBranchPicker()
        try await waitUntil { appModel.selectedWorkspaceBranchPickerFilteredBranches == ["main", "release"] }

        appModel.setSelectedWorkspaceBranchPickerFilterText("release")
        await appModel.submitSelectedWorkspaceBranchPicker()
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("release") }

        #expect(appModel.isSelectedWorkspaceBranchPickerPresented == false)
        #expect(await gitService.switchedBranches(for: workspaceURL.path) == ["release"])
        #expect(await gitService.createdBranches(for: workspaceURL.path).isEmpty)
        #expect(await gitService.requestedWorkspacePaths() == [workspaceURL.path, workspaceURL.path, workspaceURL.path])
    }

    @Test func submittingCreateSelectionCreatesAndSwitchesToNewBranch() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "branch-picker-create-selection")

        await gitService.enqueueStatuses([.branch("main"), .branch("main"), .branch("feature/new-work")], for: workspaceURL.path)
        await gitService.setLocalBranches(["main", "release"], for: workspaceURL.path)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("main") }

        appModel.showSelectedWorkspaceBranchPicker()
        try await waitUntil { appModel.selectedWorkspaceBranchPickerFilteredBranches == ["main", "release"] }

        appModel.setSelectedWorkspaceBranchPickerFilterText("feature/new-work")

        #expect(appModel.selectedWorkspaceBranchPickerItems == [.create("feature/new-work")])
        #expect(appModel.selectedWorkspaceBranchPickerSelectedItemID == WorkspaceBranchPickerItem.create("feature/new-work").id)

        await appModel.submitSelectedWorkspaceBranchPicker()
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("feature/new-work") }

        #expect(appModel.isSelectedWorkspaceBranchPickerPresented == false)
        #expect(await gitService.createdBranches(for: workspaceURL.path) == ["feature/new-work"])
        #expect(await gitService.switchedBranches(for: workspaceURL.path).isEmpty)
    }

    @Test func movingBranchPickerSelectionUpdatesHighlightedItem() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "branch-picker-keyboard-selection")

        await gitService.enqueueStatuses([.branch("main"), .branch("main")], for: workspaceURL.path)
        await gitService.setLocalBranches(["main", "release"], for: workspaceURL.path)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("main") }

        appModel.showSelectedWorkspaceBranchPicker()
        try await waitUntil { appModel.selectedWorkspaceBranchPickerItems == [.branch("main"), .branch("release")] }

        #expect(appModel.selectedWorkspaceBranchPickerSelectedItemID == WorkspaceBranchPickerItem.branch("main").id)

        appModel.moveSelectedWorkspaceBranchPickerSelection(.down)
        #expect(appModel.selectedWorkspaceBranchPickerSelectedItemID == WorkspaceBranchPickerItem.branch("release").id)

        appModel.setSelectedWorkspaceBranchPickerFilterText("release-")
        #expect(
            appModel.selectedWorkspaceBranchPickerItems == [
                .create("release-")
            ]
        )
        #expect(appModel.selectedWorkspaceBranchPickerSelectedItemID == WorkspaceBranchPickerItem.create("release-").id)
    }

    @Test func failedBranchSwitchKeepsPickerOpenWithoutChangingWorkspaceRuntimeState() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let gitService = TestWorkspaceGitService()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            gitService: gitService,
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "branch-picker-failure")

        await gitService.enqueueStatuses([.branch("main"), .branch("main")], for: workspaceURL.path)
        await gitService.setLocalBranches(["main", "release"], for: workspaceURL.path)
        await gitService.failSwitch(
            to: "release",
            error: .gitRejected("error: Your local changes would be overwritten by checkout."),
            for: workspaceURL.path
        )
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }
        try await waitUntil { appModel.activeWorkspaceController?.gitStatus == .branch("main") }

        appModel.showSelectedWorkspaceBranchPicker()
        try await waitUntil { appModel.selectedWorkspaceBranchPickerFilteredBranches == ["main", "release"] }

        appModel.setSelectedWorkspaceBranchPickerFilterText("release")
        await appModel.submitSelectedWorkspaceBranchPicker()

        #expect(appModel.isSelectedWorkspaceBranchPickerPresented)
        #expect(appModel.selectedWorkspaceBranchPickerErrorMessage == "error: Your local changes would be overwritten by checkout.")
        #expect(appModel.activeWorkspaceController?.gitStatus == .branch("main"))
        #expect(appModel.activeWorkspaceController?.connectionStatus == .ready)
    }

    @Test func firstSendCreatesThreadBeforeStartingTurn() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-send")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        let didSend = await appModel.sendPrompt("Ship the conversation shell.")

        #expect(didSend)
        #expect(runtimeCoordinator.startThreadCount == 1)
        #expect(runtimeCoordinator.startTurnPrompts == ["Ship the conversation shell."])
        #expect(appModel.activeWorkspaceController?.activeThreadSession?.messages.map(\.text) == ["Ship the conversation shell."])
        #expect(appModel.activeWorkspaceController?.connectionStatus == .streaming)
    }

    @Test func draftThreadsStayHiddenUntilFirstPromptStartsConversation() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-draft-thread")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        let didCreateThread = await appModel.createThread()
        let controller = try #require(appModel.activeWorkspaceController)

        #expect(didCreateThread)
        #expect(runtimeCoordinator.startThreadCount == 0)
        #expect(appModel.selectedRoute?.threadID == nil)
        #expect(controller.lastActiveThreadID == nil)
        #expect(controller.visibleThreadSummaries.isEmpty)

        let didSend = await appModel.sendPrompt("Start the real conversation.")
        let threadID = try #require(controller.lastActiveThreadID)

        #expect(didSend)
        #expect(controller.threadSummary(id: threadID)?.isVisibleInSidebar == true)
        #expect(controller.visibleThreadSummaries.map(\.id) == [threadID])
        #expect(controller.threadSummary(id: threadID)?.title == "Start the real conversation.")

        controller.replaceThreadList([])

        #expect(controller.visibleThreadSummaries.map(\.id) == [threadID])
    }

    @Test func startedThreadsSurviveWorkspaceRefreshWhenRuntimeOmitsThem() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-refresh-survival")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        let didCreateThread = await appModel.createThread()
        let didSend = await appModel.sendPrompt("Keep this in the sidebar.")
        let controller = try #require(appModel.activeWorkspaceController)
        let threadID = try #require(controller.lastActiveThreadID)

        #expect(didCreateThread)
        #expect(didSend)
        #expect(controller.visibleThreadSummaries.map(\.id) == [threadID])

        runtimeCoordinator.queuedThreadListResponses = [[]]
        let prepared = await appModel.prepareWorkspaceForBrowsing(path: workspaceURL.path)

        #expect(prepared)
        #expect(controller.visibleThreadSummaries.map(\.id) == [threadID])
        #expect(controller.threadSummary(id: threadID)?.title == "Keep this in the sidebar.")
    }

    @Test func restartedAppRestoresCachedVisibleThreadsWhenRuntimeOmitsThem() async throws {
        let store = InMemoryAppPreferencesStore()
        let initialRuntimeCoordinator = TestRuntimeCoordinator()
        let initialAppModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: initialRuntimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-restart-survival")

        initialAppModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { initialAppModel.activeWorkspaceController?.connectionStatus == .ready }

        let didCreateThread = await initialAppModel.createThread()
        let didSend = await initialAppModel.sendPrompt("Restore this after relaunch.")
        let initialController = try #require(initialAppModel.activeWorkspaceController)
        let threadID = try #require(initialController.lastActiveThreadID)
        let persistedSnapshot = try #require(try store.loadSnapshot())

        #expect(didCreateThread)
        #expect(didSend)
        #expect(
            persistedSnapshot.workspaceStates.first(where: { $0.workspacePath == workspaceURL.path })?.threadSummaries.map(\.id) == [threadID]
        )
        #expect(
            persistedSnapshot.workspaceStates.first(where: { $0.workspacePath == workspaceURL.path })?.pinnedThreadIDs == [threadID]
        )

        let restoredRuntimeCoordinator = TestRuntimeCoordinator()
        let restoredAppModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: restoredRuntimeCoordinator) }
        )

        try await waitUntil { restoredAppModel.activeWorkspaceController?.connectionStatus == .ready }

        let restoredController = try #require(restoredAppModel.activeWorkspaceController)

        #expect(restoredAppModel.selectedRoute?.workspacePath == workspaceURL.path)
        #expect(restoredAppModel.selectedRoute?.threadID == nil)
        #expect(restoredController.lastActiveThreadID == threadID)
        #expect(restoredController.visibleThreadSummaries.map(\.id) == [threadID])

        restoredRuntimeCoordinator.queuedThreadListResponses = [[]]
        let prepared = await restoredAppModel.prepareWorkspaceForBrowsing(path: workspaceURL.path)

        #expect(prepared)
        #expect(restoredController.visibleThreadSummaries.map(\.id) == [threadID])
        #expect(restoredController.threadSummary(id: threadID)?.title == "Restore this after relaunch.")
    }

    @Test func restoredWorkspaceStateKeepsExpandedStateAndLastActiveThread() async throws {
        let workspaceURL = try temporaryDirectory(named: "restored-workspace-state")
        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [WorkspaceRecord(url: workspaceURL, lastOpenedAt: .now)],
            lastSelectedWorkspacePath: workspaceURL.path,
            codexPathOverride: nil,
            workspaceStates: [
                PersistedWorkspaceState(
                    workspacePath: workspaceURL.path,
                    isExpanded: false,
                    isShowingAllVisibleThreads: true,
                    lastActiveThreadID: "thread-2",
                    pinnedThreadIDs: ["thread-2"],
                    threadSummaries: [
                        PersistedThreadSummary(
                            id: "thread-1",
                            title: "First Thread",
                            previewText: "Preview 1",
                            updatedAt: .distantPast,
                            isVisibleInSidebar: true,
                            isArchived: false
                        ),
                        PersistedThreadSummary(
                            id: "thread-2",
                            title: "Second Thread",
                            previewText: "Preview 2",
                            updatedAt: .now,
                            isVisibleInSidebar: true,
                            isArchived: false
                        ),
                    ]
                )
            ]
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )

        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        let controller = try #require(appModel.activeWorkspaceController)

        #expect(controller.isExpanded == false)
        #expect(controller.isShowingAllVisibleThreads)
        #expect(controller.lastActiveThreadID == "thread-2")
        #expect(appModel.selectedRoute?.workspacePath == workspaceURL.path)
        #expect(appModel.selectedRoute?.threadID == nil)
    }

    @Test func sendAndCancelGatingTracksWorkspaceState() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-gating")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        #expect(appModel.canSendPrompt("Ready to go"))
        #expect(appModel.canCancelTurn == false)

        _ = await appModel.sendPrompt("Ready to go")

        #expect(appModel.canSendPrompt("Second turn") == false)
        #expect(appModel.canCancelTurn)

        await appModel.cancelActiveTurn()

        #expect(runtimeCoordinator.cancelCount == 1)
        #expect(appModel.canCancelTurn == false)
        #expect(appModel.canSendPrompt("Second turn"))
        #expect(appModel.activeWorkspaceController?.activeThreadSession?.turnState.phase == .cancelled)
    }

    @Test func resolveApprovalForwardsDecisionToActiveRuntime() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-approval")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }
        _ = await appModel.sendPrompt("Wait for approval")

        let session = try #require(appModel.activeWorkspaceController?.activeThreadSession)
        session.enqueueApprovalRequest(
            ApprovalRequest(
                id: "approval-1",
                kind: .command,
                title: "Approve command execution",
                detail: "swift test",
                command: ApprovalCommandContext(command: "swift test", workingDirectory: workspaceURL.path),
                files: [],
                riskLevel: .medium
            )
        )

        let didResolve = await appModel.resolveApproval(id: "approval-1", resolution: .approved)

        #expect(didResolve)
        #expect(runtimeCoordinator.resolveApprovalCalls.count == 1)
        #expect(runtimeCoordinator.resolveApprovalCalls.first?.0 == "approval-1")
        #expect(runtimeCoordinator.resolveApprovalCalls.first?.1 == .approved)
        #expect(session.pendingApprovals.isEmpty)
    }

    @Test func resolveApprovalIgnoresDuplicateInFlightDecision() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        runtimeCoordinator.shouldDelayApprovalResolution = true
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-approval-dedup")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }
        _ = await appModel.sendPrompt("Wait for approval")

        let session = try #require(appModel.activeWorkspaceController?.activeThreadSession)
        session.enqueueApprovalRequest(
            ApprovalRequest(
                id: "approval-1",
                kind: .command,
                title: "Approve command execution",
                detail: "swift test",
                command: ApprovalCommandContext(command: "swift test", workingDirectory: workspaceURL.path),
                files: [],
                riskLevel: .medium
            )
        )

        async let firstResult = appModel.resolveApproval(id: "approval-1", resolution: .approved)
        try await waitUntil { session.pendingApprovals.first?.pendingResolution == .approved }
        let secondResult = await appModel.resolveApproval(id: "approval-1", resolution: .declined)

        runtimeCoordinator.releaseDelayedApprovalResolutions()
        let firstDidResolve = await firstResult

        #expect(firstDidResolve)
        #expect(secondResult == false)
        #expect(runtimeCoordinator.resolveApprovalCalls.count == 1)
        #expect(runtimeCoordinator.resolveApprovalCalls.first?.1 == .approved)
    }

    @Test func reselectingActiveWorkspaceKeepsCurrentConversationSession() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-preserve")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }
        _ = await appModel.sendPrompt("Keep this transcript")

        let originalController = try #require(appModel.activeWorkspaceController)
        let originalSession = try #require(originalController.activeThreadSession)

        appModel.reopenWorkspace(WorkspaceRecord(url: workspaceURL, lastOpenedAt: .now))

        #expect(appModel.activeWorkspaceController === originalController)
        #expect(appModel.activeWorkspaceController?.activeThreadSession === originalSession)
        #expect(appModel.activeWorkspaceController?.activeThreadSession?.messages.first?.text == "Keep this transcript")
        #expect(runtimeCoordinator.startCount == 1)
    }

    @Test func sendPromptUsesWorkspaceWriteTurnConfiguration() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-config")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }
        _ = await appModel.sendPrompt("Create a README")

        let configuration = try #require(runtimeCoordinator.startTurnConfigurations.last ?? nil)
        #expect(configuration.cwd == workspaceURL.path)
        #expect(configuration.sandboxPolicy == "workspace-write")
        #expect(configuration.approvalPolicy == "on-request")
        #expect(configuration.summaryMode == "concise")
    }

    @Test func sendPromptUsesSelectedModelAndReasoningEffort() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        runtimeCoordinator.availableModels = [
            ComposerModelOption(
                id: "gpt-5.4",
                title: "GPT-5.4",
                defaultReasoningEffort: .medium,
                supportedReasoningEfforts: [.low, .medium, .high, .xhigh],
                isDefault: true
            )
        ]
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-config-model")

        appModel.setComposerModelID("gpt-5.4")
        appModel.setComposerReasoningEffort(.high)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }
        _ = await appModel.sendPrompt("Create a README with the selected model")

        let configuration = try #require(runtimeCoordinator.startTurnConfigurations.last ?? nil)
        #expect(configuration.model == "gpt-5.4")
        #expect(configuration.reasoningEffort == "high")
    }

    @Test func sendPromptOmitsUnavailableModelAndReasoningSelections() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-config-no-model-catalog")

        appModel.setComposerModelID("gpt-5.4")
        appModel.setComposerReasoningEffort(.high)
        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }
        _ = await appModel.sendPrompt("Create a README without a model catalog")

        let configuration = try #require(runtimeCoordinator.startTurnConfigurations.last ?? nil)
        #expect(configuration.model == nil)
        #expect(configuration.reasoningEffort == nil)
    }

    @Test func secondSendIsRejectedWhileWaitingForTurnStartAcknowledgement() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        runtimeCoordinator.shouldDelayTurnStart = true
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-double-send")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        let firstSendTask = Task { await appModel.sendPrompt("Ship the first turn") }
        try await waitUntil { runtimeCoordinator.pendingDelayedTurnStartCount == 1 }

        #expect(appModel.activeWorkspaceController?.isAwaitingTurnStart == true)
        #expect(appModel.canSendPrompt("Second turn") == false)

        let secondSend = await appModel.sendPrompt("Second turn")
        #expect(secondSend == false)
        #expect(runtimeCoordinator.startTurnPrompts == ["Ship the first turn"])

        runtimeCoordinator.releaseDelayedTurnStarts()

        let firstSend = await firstSendTask.value
        #expect(firstSend)
        #expect(appModel.activeWorkspaceController?.isAwaitingTurnStart == false)
        #expect(appModel.activeWorkspaceController?.activeThreadSession?.messages.map(\.text) == ["Ship the first turn"])
    }

    @Test func restoredExpandedWorkspacesPreloadThreadsWithoutChangingSelection() async throws {
        let firstWorkspaceURL = try temporaryDirectory(named: "restored-runtime-a")
        let secondWorkspaceURL = try temporaryDirectory(named: "restored-runtime-b")
        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [
                WorkspaceRecord(url: firstWorkspaceURL, lastOpenedAt: .distantPast),
                WorkspaceRecord(url: secondWorkspaceURL, lastOpenedAt: .now),
            ],
            lastSelectedWorkspacePath: secondWorkspaceURL.path,
            codexPathOverride: nil
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)
        let runtimeCoordinator = LifecycleProbeCoordinator(startDelayNanoseconds: 80_000_000)
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { LifecycleProbeRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )

        try await waitUntil {
            appModel.activeWorkspaceController?.workspace.canonicalPath == secondWorkspaceURL.path &&
                appModel.activeWorkspaceController?.connectionStatus == .ready &&
                runtimeCoordinator.records(for: secondWorkspaceURL.path).last?.isRunning == true
        }

        try await waitUntil {
            runtimeCoordinator.records(for: firstWorkspaceURL.path).last?.isRunning == true &&
                runtimeCoordinator.records(for: firstWorkspaceURL.path).last?.listThreadsCalls == 1
        }

        #expect(appModel.activeWorkspaceController?.workspace.canonicalPath == secondWorkspaceURL.path)
        #expect(runtimeCoordinator.records(for: firstWorkspaceURL.path).count == 1)
        #expect(runtimeCoordinator.records(for: firstWorkspaceURL.path).last?.listThreadsArchivedValues == [false])
        #expect(runtimeCoordinator.records(for: secondWorkspaceURL.path).count == 1)
    }

    @Test func switchingWorkspacesKeepsEachWorkspaceRuntimeRunning() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = LifecycleProbeCoordinator(startDelayNanoseconds: 80_000_000)
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { LifecycleProbeRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let firstWorkspaceURL = try temporaryDirectory(named: "stale-runtime-a")
        let secondWorkspaceURL = try temporaryDirectory(named: "stale-runtime-b")

        appModel.activateWorkspace(at: firstWorkspaceURL)
        appModel.activateWorkspace(at: secondWorkspaceURL)

        try await waitUntil {
            appModel.activeWorkspaceController?.workspace.canonicalPath == secondWorkspaceURL.path &&
            appModel.activeWorkspaceController?.connectionStatus == .ready &&
            runtimeCoordinator.records(for: firstWorkspaceURL.path).last?.isRunning == true &&
            runtimeCoordinator.records(for: secondWorkspaceURL.path).last?.isRunning == true
        }

        #expect(runtimeCoordinator.records(for: firstWorkspaceURL.path).count == 1)
        #expect(runtimeCoordinator.records(for: secondWorkspaceURL.path).count == 1)
        #expect(runtimeCoordinator.records(for: firstWorkspaceURL.path).last?.stopCount == 0)
        #expect(runtimeCoordinator.records(for: secondWorkspaceURL.path).last?.stopCount == 0)
    }

    @Test func preparingWorkspaceForBrowsingReloadsThreadsWithoutChangingSelection() async throws {
        let firstWorkspaceURL = try temporaryDirectory(named: "expand-runtime-a")
        let secondWorkspaceURL = try temporaryDirectory(named: "expand-runtime-b")
        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [
                WorkspaceRecord(url: firstWorkspaceURL, lastOpenedAt: .distantPast),
                WorkspaceRecord(url: secondWorkspaceURL, lastOpenedAt: .now),
            ],
            lastSelectedWorkspacePath: secondWorkspaceURL.path,
            codexPathOverride: nil
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)
        let runtimeCoordinator = LifecycleProbeCoordinator(startDelayNanoseconds: 80_000_000)
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { LifecycleProbeRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )

        try await waitUntil {
            appModel.activeWorkspaceController?.workspace.canonicalPath == secondWorkspaceURL.path &&
                runtimeCoordinator.records(for: secondWorkspaceURL.path).last?.isRunning == true
        }

        try await waitUntil {
            runtimeCoordinator.records(for: firstWorkspaceURL.path).last?.isRunning == true &&
                runtimeCoordinator.records(for: firstWorkspaceURL.path).last?.listThreadsCalls == 1
        }

        let prepared = await appModel.prepareWorkspaceForBrowsing(path: firstWorkspaceURL.path)

        #expect(prepared)

        try await waitUntil {
            runtimeCoordinator.records(for: firstWorkspaceURL.path).last?.isRunning == true &&
                runtimeCoordinator.records(for: firstWorkspaceURL.path).last?.listThreadsCalls == 2
        }

        #expect(appModel.activeWorkspaceController?.workspace.canonicalPath == secondWorkspaceURL.path)
        #expect(runtimeCoordinator.records(for: firstWorkspaceURL.path).last?.listThreadsArchivedValues == [false, false])
    }

    @Test func retryKeepsOnlyNewestRuntimeRunning() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = LifecycleProbeCoordinator(startDelayNanoseconds: 80_000_000)
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { LifecycleProbeRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "stale-retry")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        appModel.retryActiveWorkspaceConnection()
        appModel.retryActiveWorkspaceConnection()

        try await waitUntil {
            let records = runtimeCoordinator.records(for: workspaceURL.path)
            return records.count == 3 &&
                records.dropLast().allSatisfy { $0.isRunning == false && $0.stopCount >= 1 } &&
                records.last?.isRunning == true &&
                appModel.activeWorkspaceController?.connectionStatus == .ready
        }

        #expect(runtimeCoordinator.records(for: workspaceURL.path).count == 3)
    }
}

struct AppPreferencesStoreTests {
    @Test func missingAppearancePreferenceDefaultsToSystem() throws {
        let suiteName = "AtelierCodeTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let workspaceURL = try temporaryDirectory(named: "legacy-preferences")
        let isoFormatter = ISO8601DateFormatter()
        let snapshotData = Data(
            """
            {
              "recentWorkspaces": [
                {
                  "canonicalPath": "\(workspaceURL.path)",
                  "displayName": "\(workspaceURL.lastPathComponent)",
                  "lastOpenedAt": "\(isoFormatter.string(from: .now))"
                }
              ],
              "lastSelectedWorkspacePath": "\(workspaceURL.path)"
            }
            """.utf8
        )

        userDefaults.set(snapshotData, forKey: "ateliercode.app-preferences")

        let store = UserDefaultsAppPreferencesStore(userDefaults: userDefaults)
        let loadedSnapshot = try store.loadSnapshot()
        let snapshot = try #require(loadedSnapshot)

        #expect(snapshot.appearancePreference == .system)
        #expect(snapshot.workspaceStates.isEmpty)
    }
}

func temporaryDirectory(named name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class InMemoryAppPreferencesStore: AppPreferencesStore {
    private var storedSnapshot: AppPreferencesSnapshot?

    init(snapshot: AppPreferencesSnapshot? = nil) {
        self.storedSnapshot = snapshot
    }

    func loadSnapshot() throws -> AppPreferencesSnapshot? {
        storedSnapshot
    }

    func saveSnapshot(_ snapshot: AppPreferencesSnapshot) throws {
        storedSnapshot = snapshot
    }
}

@MainActor
private final class TestRuntimeCoordinator {
    var startCount = 0
    var stopCount = 0
    var startThreadCount = 0
    var startTurnPrompts: [String] = []
    var startTurnConfigurations: [BridgeTurnStartConfiguration?] = []
    var availableModels: [ComposerModelOption] = []
    var cancelCount = 0
    var resolveApprovalCalls: [(String, ApprovalResolution)] = []
    var queuedThreadListResponses: [[ThreadSummary]] = []
    var resumeFailuresByThreadID: [String: String] = [:]
    var readFailuresByThreadID: [String: String] = [:]
    var shouldDelayTurnStart = false
    var shouldDelayApprovalResolution = false
    private var pendingDelayedTurnStarts: [CheckedContinuation<Void, Never>] = []
    private var pendingDelayedApprovalResolutions: [CheckedContinuation<Void, Never>] = []

    var pendingDelayedTurnStartCount: Int {
        pendingDelayedTurnStarts.count
    }

    func enqueueDelayedTurnStart(_ continuation: CheckedContinuation<Void, Never>) {
        pendingDelayedTurnStarts.append(continuation)
    }

    func releaseDelayedTurnStarts() {
        let continuations = pendingDelayedTurnStarts
        pendingDelayedTurnStarts.removeAll()
        continuations.forEach { $0.resume() }
    }

    func awaitDelayedApprovalResolutionIfNeeded() async {
        guard shouldDelayApprovalResolution else {
            return
        }

        await withCheckedContinuation { continuation in
            pendingDelayedApprovalResolutions.append(continuation)
        }
    }

    func releaseDelayedApprovalResolutions() {
        let continuations = pendingDelayedApprovalResolutions
        pendingDelayedApprovalResolutions.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
private final class TestWorkspaceRuntime: WorkspaceConversationRuntime {
    private let controller: WorkspaceController
    private let coordinator: TestRuntimeCoordinator

    init(controller: WorkspaceController, coordinator: TestRuntimeCoordinator) {
        self.controller = controller
        self.coordinator = coordinator
    }

    func start() async throws {
        coordinator.startCount += 1
        controller.setAvailableModels(coordinator.availableModels)
        controller.setBridgeLifecycleState(.idle)
        controller.setConnectionStatus(.ready)
    }

    func stop() async {
        coordinator.stopCount += 1
        controller.setAwaitingTurnStart(false)
        controller.setConnectionStatus(.disconnected)
    }

    func refreshModels() async throws {
        controller.setAvailableModels(coordinator.availableModels)
    }

    func listThreads(archived: Bool) async throws {
        controller.setShowingArchivedThreads(archived)
        if coordinator.queuedThreadListResponses.isEmpty == false {
            controller.replaceThreadList(coordinator.queuedThreadListResponses.removeFirst(), archived: archived)
        }
    }

    func startThreadAndWait(
        title: String?,
        configuration _: BridgeConversationConfiguration? = nil
    ) async throws -> ThreadSession {
        coordinator.startThreadCount += 1
        return controller.openThread(
            id: "thread-\(coordinator.startThreadCount)",
            title: title ?? "New Conversation",
            isVisibleInSidebar: false
        )
    }

    func resumeThreadAndWait(id: String) async throws -> ThreadSession {
        if let message = coordinator.resumeFailuresByThreadID[id] {
            throw TestWorkspaceRuntimeError(message: message)
        }

        return controller.resumeThread(id: id, title: "Resumed Conversation")
    }

    func readThreadAndWait(id: String, includeTurns: Bool) async throws -> ThreadSession {
        if let message = coordinator.readFailuresByThreadID[id] {
            throw TestWorkspaceRuntimeError(message: message)
        }

        return controller.resumeThread(id: id, title: "Read Conversation")
    }

    func forkThreadAndWait(id: String) async throws -> ThreadSession {
        coordinator.startThreadCount += 1
        return controller.resumeThread(
            id: "\(id)-fork-\(coordinator.startThreadCount)",
            title: "Forked Conversation",
            messages: controller.threadSession(id: id)?.messages ?? []
        )
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
        return controller.resumeThread(id: id, title: "Resumed Conversation")
    }

    func rollbackThreadAndWait(id: String, numTurns: Int) async throws -> ThreadSession {
        let messages = Array((controller.threadSession(id: id)?.messages ?? []).dropLast(max(0, numTurns)))
        return controller.resumeThread(id: id, title: "Resumed Conversation", messages: messages)
    }

    func startTurn(threadID: String, prompt: String, configuration: BridgeTurnStartConfiguration?) async throws {
        coordinator.startTurnPrompts.append(prompt)
        coordinator.startTurnConfigurations.append(configuration)

        if coordinator.shouldDelayTurnStart {
            await withCheckedContinuation { continuation in
                coordinator.enqueueDelayedTurnStart(continuation)
            }
        }

        let session = controller.threadSession(id: threadID)
            ?? controller.openThread(id: threadID, title: "New Conversation", isVisibleInSidebar: false)
        session.beginTurn(userPrompt: prompt)
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.setCurrentTurnID("test-turn", for: threadID)
        controller.setConnectionStatus(.streaming)
    }

    func cancelTurn(threadID: String, reason: String?) async throws {
        coordinator.cancelCount += 1
        controller.setConnectionStatus(.cancelling)
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.threadSession(id: threadID)?.cancelTurn()
        controller.setCurrentTurnID(nil, for: threadID)
        controller.setConnectionStatus(.ready)
    }

    func resolveApproval(threadID: String, id: String, resolution: ApprovalResolution) async throws {
        coordinator.resolveApprovalCalls.append((id, resolution))
        await coordinator.awaitDelayedApprovalResolutionIfNeeded()
        controller.threadSession(id: threadID)?.resolveApprovalRequest(id: id, resolution: resolution)
    }
}

private struct TestWorkspaceRuntimeError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private actor TestWorkspaceGitService: WorkspaceGitServing {
    private var queuedStatusesByWorkspacePath: [String: [WorkspaceGitStatus]] = [:]
    private var localBranchesByWorkspacePath: [String: [String]] = [:]
    private var requestedPaths: [String] = []
    private var switchFailuresByWorkspacePath: [String: [String: WorkspaceGitBranchManagerError]] = [:]
    private var switchedBranchesByWorkspacePath: [String: [String]] = [:]
    private var createdBranchesByWorkspacePath: [String: [String]] = [:]

    func enqueueStatuses(_ statuses: [WorkspaceGitStatus], for workspacePath: String) {
        queuedStatusesByWorkspacePath[workspacePath, default: []].append(contentsOf: statuses)
    }

    func setLocalBranches(_ branches: [String], for workspacePath: String) {
        localBranchesByWorkspacePath[workspacePath] = branches
    }

    func failSwitch(to branchName: String, error: WorkspaceGitBranchManagerError, for workspacePath: String) {
        switchFailuresByWorkspacePath[workspacePath, default: [:]][branchName] = error
    }

    func requestedWorkspacePaths() -> [String] {
        requestedPaths
    }

    func switchedBranches(for workspacePath: String) -> [String] {
        switchedBranchesByWorkspacePath[workspacePath] ?? []
    }

    func createdBranches(for workspacePath: String) -> [String] {
        createdBranchesByWorkspacePath[workspacePath] ?? []
    }

    func snapshot(for workspacePath: String) async -> WorkspaceGitSnapshot {
        requestedPaths.append(workspacePath)

        let localBranches = localBranchesByWorkspacePath[workspacePath] ?? []
        if queuedStatusesByWorkspacePath[workspacePath]?.isEmpty == false {
            return WorkspaceGitSnapshot(
                status: queuedStatusesByWorkspacePath[workspacePath]!.removeFirst(),
                localBranches: localBranches
            )
        }

        return WorkspaceGitSnapshot(
            status: .unavailable(.lookupFailed),
            localBranches: localBranches
        )
    }

    func switchToBranch(named branchName: String, for workspacePath: String) async throws -> WorkspaceGitSnapshot {
        if let error = switchFailuresByWorkspacePath[workspacePath]?[branchName] {
            throw error
        }

        switchedBranchesByWorkspacePath[workspacePath, default: []].append(branchName)
        let localBranches = localBranchesByWorkspacePath[workspacePath] ?? []
        return WorkspaceGitSnapshot(
            status: .branch(branchName),
            localBranches: localBranches.isEmpty ? [branchName] : localBranches
        )
    }

    func createAndSwitchToBranch(named branchName: String, for workspacePath: String) async throws -> WorkspaceGitSnapshot {
        createdBranchesByWorkspacePath[workspacePath, default: []].append(branchName)
        if localBranchesByWorkspacePath[workspacePath]?.contains(branchName) != true {
            localBranchesByWorkspacePath[workspacePath, default: []].append(branchName)
        }

        let localBranches = localBranchesByWorkspacePath[workspacePath] ?? [branchName]
        return WorkspaceGitSnapshot(
            status: .branch(branchName),
            localBranches: localBranches.sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        )
    }
}

@MainActor
private final class LifecycleProbeCoordinator {
    final class Record {
        let workspacePath: String
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var isRunning = false
        private(set) var listThreadsCalls = 0
        private(set) var listThreadsArchivedValues: [Bool] = []

        init(workspacePath: String) {
            self.workspacePath = workspacePath
        }

        func recordStart() {
            startCount += 1
            isRunning = true
        }

        func recordStop() {
            stopCount += 1
            isRunning = false
        }

        func recordListThreads(archived: Bool) {
            listThreadsCalls += 1
            listThreadsArchivedValues.append(archived)
        }
    }

    let startDelayNanoseconds: UInt64
    private(set) var recordsByWorkspacePath: [String: [Record]] = [:]

    init(startDelayNanoseconds: UInt64) {
        self.startDelayNanoseconds = startDelayNanoseconds
    }

    func register(workspacePath: String) -> Record {
        let record = Record(workspacePath: workspacePath)
        recordsByWorkspacePath[workspacePath, default: []].append(record)
        return record
    }

    func records(for workspacePath: String) -> [Record] {
        recordsByWorkspacePath[workspacePath] ?? []
    }
}

@MainActor
private final class LifecycleProbeRuntime: WorkspaceConversationRuntime {
    private let controller: WorkspaceController
    private let coordinator: LifecycleProbeCoordinator
    private let record: LifecycleProbeCoordinator.Record

    init(controller: WorkspaceController, coordinator: LifecycleProbeCoordinator) {
        self.controller = controller
        self.coordinator = coordinator
        self.record = coordinator.register(workspacePath: controller.workspace.canonicalPath)
    }

    func start() async throws {
        controller.setBridgeLifecycleState(.starting)
        controller.setConnectionStatus(.connecting)

        do {
            try await Task.sleep(nanoseconds: coordinator.startDelayNanoseconds)
        } catch {}

        record.recordStart()
        controller.setBridgeLifecycleState(.idle)
        controller.setConnectionStatus(.ready)
    }

    func stop() async {
        record.recordStop()
        controller.setAwaitingTurnStart(false)
        controller.setBridgeLifecycleState(.idle)
        controller.setConnectionStatus(.disconnected)
    }

    func refreshModels() async throws {
        controller.setAvailableModels([])
    }

    func listThreads(archived: Bool) async throws {
        record.recordListThreads(archived: archived)
        controller.setShowingArchivedThreads(archived)
    }

    func startThreadAndWait(
        title: String?,
        configuration _: BridgeConversationConfiguration? = nil
    ) async throws -> ThreadSession {
        controller.openThread(id: UUID().uuidString, title: title ?? "New Conversation", isVisibleInSidebar: false)
    }

    func resumeThreadAndWait(id: String) async throws -> ThreadSession {
        controller.resumeThread(id: id, title: "Recovered Conversation")
    }

    func readThreadAndWait(id: String, includeTurns: Bool) async throws -> ThreadSession {
        controller.resumeThread(id: id, title: "Recovered Conversation")
    }

    func forkThreadAndWait(id: String) async throws -> ThreadSession {
        controller.resumeThread(id: "\(id)-fork", title: "Recovered Conversation")
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
        return controller.resumeThread(id: id, title: "Recovered Conversation")
    }

    func rollbackThreadAndWait(id: String, numTurns: Int) async throws -> ThreadSession {
        let messages = Array((controller.threadSession(id: id)?.messages ?? []).dropLast(max(0, numTurns)))
        return controller.resumeThread(id: id, title: "Recovered Conversation", messages: messages)
    }

    func startTurn(threadID: String, prompt: String, configuration: BridgeTurnStartConfiguration?) async throws {
        let session = controller.threadSession(id: threadID)
            ?? controller.openThread(id: threadID, title: "New Conversation", isVisibleInSidebar: false)
        session.beginTurn(userPrompt: prompt)
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.setCurrentTurnID("probe-turn", for: threadID)
        controller.setConnectionStatus(.streaming)
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

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollNanoseconds: UInt64 = 10_000_000,
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))

    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }

        try await Task.sleep(nanoseconds: pollNanoseconds)
    }

    Issue.record("Timed out waiting for test condition.")
}
