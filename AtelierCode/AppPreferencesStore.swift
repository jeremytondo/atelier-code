import Foundation

protocol AppPreferencesStore {
    func loadSnapshot() throws -> AppPreferencesSnapshot?
    func saveSnapshot(_ snapshot: AppPreferencesSnapshot) throws
}

struct AppPreferencesSnapshot: Codable, Equatable, Sendable {
    var recentWorkspaces: [WorkspaceRecord]
    var lastSelectedWorkspacePath: String?
    var codexPathOverride: String?
    var uiPreferences: UIPreferences
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
