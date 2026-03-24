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
            codexPathOverride: codexURL.path,
            uiPreferences: UIPreferences(showsStartupDiagnostics: false)
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)

        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) }
        )

        #expect(appModel.recentWorkspaces == snapshot.recentWorkspaces)
        #expect(appModel.codexPathOverride == codexURL.path)
        #expect(appModel.uiPreferences == UIPreferences(showsStartupDiagnostics: false))
        #expect(appModel.startupDiagnostics.contains(where: { $0.source == .embeddedBridge }))
        #expect(appModel.startupDiagnostics.contains(where: { $0.source == .codexOverridePath }))
    }

    @Test func restoresValidLastSelectedWorkspace() async throws {
        let workspaceURL = try temporaryDirectory()
        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [WorkspaceRecord(url: workspaceURL, lastOpenedAt: .now)],
            lastSelectedWorkspacePath: workspaceURL.path,
            codexPathOverride: nil,
            uiPreferences: UIPreferences()
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)

        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) }
        )

        #expect(appModel.lastSelectedWorkspacePath == workspaceURL.path)
        #expect(appModel.activeWorkspaceController?.workspace.canonicalPath == workspaceURL.path)
        #expect(appModel.startupDiagnostics.contains(where: { $0.source == .restoredWorkspace && $0.severity == .info }))
    }

    @Test func clearsInvalidRestoredWorkspaceAndRecordsDiagnostic() async throws {
        let workspaceURL = try temporaryDirectory()
        try FileManager.default.removeItem(at: workspaceURL)

        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [],
            lastSelectedWorkspacePath: workspaceURL.path,
            codexPathOverride: nil,
            uiPreferences: UIPreferences()
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)

        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) }
        )

        #expect(appModel.lastSelectedWorkspacePath == nil)
        #expect(appModel.activeWorkspaceController == nil)
        #expect(appModel.startupDiagnostics.contains(where: { $0.source == .restoredWorkspace && $0.severity == .warning }))
        #expect(try store.loadSnapshot()?.lastSelectedWorkspacePath == nil)
    }

    @Test func deduplicatesAndCapsRecentWorkspaces() async throws {
        let store = InMemoryAppPreferencesStore()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) }
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

    @Test func roundTripsCodexOverrideAndUIPreferences() async throws {
        let store = InMemoryAppPreferencesStore()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) }
        )
        let codexURL = try temporaryDirectory(named: "codex-bin").appendingPathComponent("codex")
        FileManager.default.createFile(atPath: codexURL.path, contents: Data())

        appModel.setCodexPathOverride(codexURL.path)
        appModel.updateUIPreferences { preferences in
            preferences.showsStartupDiagnostics = false
        }

        let restoredModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) }
        )

        #expect(restoredModel.codexPathOverride == codexURL.path)
        #expect(restoredModel.uiPreferences == UIPreferences(showsStartupDiagnostics: false))
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
