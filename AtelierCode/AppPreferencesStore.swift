import Foundation

protocol AppPreferencesStore {
    func loadSnapshot() throws -> AppPreferencesSnapshot?
    func saveSnapshot(_ snapshot: AppPreferencesSnapshot) throws
}

struct AppPreferencesSnapshot: Codable, Equatable, Sendable {
    var recentWorkspaces: [WorkspaceRecord]
    var lastSelectedWorkspacePath: String?
    var codexPathOverride: String?
    var appearancePreference: AppAppearancePreference
    var workspaceStates: [PersistedWorkspaceState]

    init(
        recentWorkspaces: [WorkspaceRecord],
        lastSelectedWorkspacePath: String?,
        codexPathOverride: String?,
        appearancePreference: AppAppearancePreference = .system,
        workspaceStates: [PersistedWorkspaceState] = []
    ) {
        self.recentWorkspaces = recentWorkspaces
        self.lastSelectedWorkspacePath = lastSelectedWorkspacePath
        self.codexPathOverride = codexPathOverride
        self.appearancePreference = appearancePreference
        self.workspaceStates = workspaceStates
    }

    private enum CodingKeys: String, CodingKey {
        case recentWorkspaces
        case lastSelectedWorkspacePath
        case codexPathOverride
        case appearancePreference
        case workspaceStates
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recentWorkspaces = try container.decodeIfPresent([WorkspaceRecord].self, forKey: .recentWorkspaces) ?? []
        lastSelectedWorkspacePath = try container.decodeIfPresent(String.self, forKey: .lastSelectedWorkspacePath)
        codexPathOverride = try container.decodeIfPresent(String.self, forKey: .codexPathOverride)
        appearancePreference = try container.decodeIfPresent(AppAppearancePreference.self, forKey: .appearancePreference) ?? .system
        workspaceStates = try container.decodeIfPresent([PersistedWorkspaceState].self, forKey: .workspaceStates) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recentWorkspaces, forKey: .recentWorkspaces)
        try container.encodeIfPresent(lastSelectedWorkspacePath, forKey: .lastSelectedWorkspacePath)
        try container.encodeIfPresent(codexPathOverride, forKey: .codexPathOverride)
        try container.encode(appearancePreference, forKey: .appearancePreference)
        try container.encode(workspaceStates, forKey: .workspaceStates)
    }
}

struct UserDefaultsAppPreferencesStore: AppPreferencesStore {
    private let userDefaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "ateliercode.app-preferences"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func loadSnapshot() throws -> AppPreferencesSnapshot? {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return nil
        }

        return try decoder.decode(AppPreferencesSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: AppPreferencesSnapshot) throws {
        let data = try encoder.encode(snapshot)
        userDefaults.set(data, forKey: storageKey)
    }
}
