import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var recentWorkspaces: [WorkspaceRecord]
    private(set) var lastSelectedWorkspacePath: String?
    private(set) var codexPathOverride: String?
    private(set) var uiPreferences: UIPreferences
    private(set) var startupDiagnostics: [StartupDiagnostic]
    private(set) var activeWorkspaceController: WorkspaceController?

    @ObservationIgnored private let preferencesStore: any AppPreferencesStore
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let bridgeDiagnosticProvider: () -> StartupDiagnostic
    @ObservationIgnored private let now: () -> Date

    init(
        preferencesStore: any AppPreferencesStore = UserDefaultsAppPreferencesStore(),
        fileManager: FileManager = .default,
        bridgeDiagnosticProvider: @escaping () -> StartupDiagnostic = { StartupDiagnostic.defaultBridgeDiagnostic() },
        now: @escaping () -> Date = Date.init
    ) {
        self.preferencesStore = preferencesStore
        self.fileManager = fileManager
        self.bridgeDiagnosticProvider = bridgeDiagnosticProvider
        self.now = now

        let loadedSnapshot = try? preferencesStore.loadSnapshot()
        let normalizedRecentWorkspaces = Self.normalizeRecentWorkspaces(loadedSnapshot?.recentWorkspaces ?? [])
        let selectedPath = loadedSnapshot?.lastSelectedWorkspacePath.map(WorkspaceRecord.canonicalizedPath(for:))
        let codexOverridePath = loadedSnapshot?.codexPathOverride
        let preferences = loadedSnapshot?.uiPreferences ?? UIPreferences()

        recentWorkspaces = normalizedRecentWorkspaces
        lastSelectedWorkspacePath = selectedPath
        codexPathOverride = codexOverridePath
        uiPreferences = preferences
        startupDiagnostics = [bridgeDiagnosticProvider()]
        activeWorkspaceController = nil

        if let codexOverridePath {
            startupDiagnostics.append(Self.codexOverrideDiagnostic(path: codexOverridePath, fileManager: fileManager))
        }

        if let selectedPath {
            if Self.workspaceExists(atPath: selectedPath, fileManager: fileManager) {
                let restoredWorkspace = normalizedRecentWorkspaces.first(where: { $0.canonicalPath == selectedPath })
                    ?? WorkspaceRecord(
                        canonicalPath: selectedPath,
                        displayName: URL(fileURLWithPath: selectedPath).lastPathComponent,
                        lastOpenedAt: now()
                    )
                activeWorkspaceController = WorkspaceController(workspace: restoredWorkspace)
                startupDiagnostics.append(.restoredWorkspacePresent(restoredWorkspace))
            } else {
                lastSelectedWorkspacePath = nil
                startupDiagnostics.append(.restoredWorkspaceMissing(path: selectedPath))
            }
        }

        if let loadedSnapshot, loadedSnapshot != snapshot {
            persistPreferences()
        }
    }

    var snapshot: AppPreferencesSnapshot {
        AppPreferencesSnapshot(
            recentWorkspaces: recentWorkspaces,
            lastSelectedWorkspacePath: lastSelectedWorkspacePath,
            codexPathOverride: codexPathOverride,
            uiPreferences: uiPreferences
        )
    }

    func activateWorkspace(at url: URL) {
        let workspace = WorkspaceRecord(url: url, lastOpenedAt: now())
        activeWorkspaceController = WorkspaceController(workspace: workspace)
        lastSelectedWorkspacePath = workspace.canonicalPath
        recentWorkspaces = Self.upsertingRecentWorkspace(workspace, into: recentWorkspaces)
        persistPreferences()
    }

    func reopenWorkspace(_ workspace: WorkspaceRecord) {
        activateWorkspace(at: workspace.url)
    }

    func clearSelectedWorkspace() {
        activeWorkspaceController = nil
        lastSelectedWorkspacePath = nil
        persistPreferences()
    }

    func setCodexPathOverride(_ path: String?) {
        codexPathOverride = path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        persistPreferences()
    }

    func updateUIPreferences(_ update: (inout UIPreferences) -> Void) {
        update(&uiPreferences)
        persistPreferences()
    }

    private func persistPreferences() {
        try? preferencesStore.saveSnapshot(snapshot)
    }

    private static func normalizeRecentWorkspaces(_ workspaces: [WorkspaceRecord]) -> [WorkspaceRecord] {
        var seenPaths = Set<String>()
        let normalized = workspaces
            .map {
                WorkspaceRecord(
                    canonicalPath: $0.canonicalPath,
                    displayName: $0.displayName,
                    lastOpenedAt: $0.lastOpenedAt
                )
            }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }

        var uniqueWorkspaces: [WorkspaceRecord] = []

        for workspace in normalized where seenPaths.insert(workspace.canonicalPath).inserted {
            uniqueWorkspaces.append(workspace)

            if uniqueWorkspaces.count == 20 {
                break
            }
        }

        return uniqueWorkspaces
    }

    private static func upsertingRecentWorkspace(
        _ workspace: WorkspaceRecord,
        into workspaces: [WorkspaceRecord]
    ) -> [WorkspaceRecord] {
        var updated = workspaces.filter { $0.canonicalPath != workspace.canonicalPath }
        updated.insert(workspace, at: 0)
        return Array(updated.prefix(20))
    }

    private static func workspaceExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private static func codexOverrideDiagnostic(path: String, fileManager: FileManager) -> StartupDiagnostic {
        let canonicalPath = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let exists = fileManager.fileExists(atPath: canonicalPath)
        return exists ? .codexOverridePresent(path: canonicalPath) : .codexOverrideMissing(path: canonicalPath)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
