import Foundation

struct WorkspaceRecord: Codable, Equatable, Sendable, Identifiable {
    let canonicalPath: String
    let displayName: String
    let lastOpenedAt: Date

    var id: String { canonicalPath }

    var url: URL {
        URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }

    init(canonicalPath: String, displayName: String, lastOpenedAt: Date) {
        self.canonicalPath = WorkspaceRecord.canonicalizedPath(for: canonicalPath)
        self.displayName = displayName
        self.lastOpenedAt = lastOpenedAt
    }

    init(url: URL, lastOpenedAt: Date) {
        let canonicalURL = WorkspaceRecord.canonicalizedURL(for: url)
        let name = canonicalURL.lastPathComponent.isEmpty ? canonicalURL.path : canonicalURL.lastPathComponent

        self.init(canonicalPath: canonicalURL.path, displayName: name, lastOpenedAt: lastOpenedAt)
    }

    static func canonicalizedPath(for path: String) -> String {
        canonicalizedURL(for: URL(fileURLWithPath: path, isDirectory: true)).path
    }

    static func canonicalizedURL(for url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}

enum StartupDiagnosticSource: String, Codable, Equatable, Sendable {
    case embeddedBridge
    case restoredWorkspace
    case codexOverridePath
}

enum StartupDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case info
    case warning
    case error
}

struct StartupDiagnostic: Equatable, Sendable, Identifiable {
    let source: StartupDiagnosticSource
    let severity: StartupDiagnosticSeverity
    let message: String

    var id: String {
        "\(source.rawValue)-\(severity.rawValue)-\(message)"
    }
}

extension StartupDiagnostic {
    static func bridgePresent(at url: URL) -> Self {
        Self(
            source: .embeddedBridge,
            severity: .info,
            message: "Embedded bridge available at \(url.path)."
        )
    }

    static func bridgeMissing(expectedPath: URL) -> Self {
        Self(
            source: .embeddedBridge,
            severity: .error,
            message: "Embedded bridge missing at \(expectedPath.path)."
        )
    }

    static func restoredWorkspacePresent(_ workspace: WorkspaceRecord) -> Self {
        Self(
            source: .restoredWorkspace,
            severity: .info,
            message: "Restored workspace \(workspace.displayName) from \(workspace.canonicalPath)."
        )
    }

    static func restoredWorkspaceMissing(path: String) -> Self {
        Self(
            source: .restoredWorkspace,
            severity: .warning,
            message: "Could not restore workspace at \(path) because it no longer exists."
        )
    }

    static func codexOverridePresent(path: String) -> Self {
        Self(
            source: .codexOverridePath,
            severity: .info,
            message: "Codex override path available at \(path)."
        )
    }

    static func codexOverrideMissing(path: String) -> Self {
        Self(
            source: .codexOverridePath,
            severity: .warning,
            message: "Codex override path set to \(path), but that location does not exist."
        )
    }

    static func defaultBridgeDiagnostic(locator: BridgeExecutableLocator = BridgeExecutableLocator()) -> Self {
        do {
            return .bridgePresent(at: try locator.embeddedBridgeURL())
        } catch BridgeExecutableLocatorError.missingEmbeddedBridge(let expectedPath) {
            return .bridgeMissing(expectedPath: expectedPath)
        } catch {
            let expectedPath = locator.bundle.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent(BridgeExecutableLocator.executableName, isDirectory: false)
            return .bridgeMissing(expectedPath: expectedPath)
        }
    }
}

enum BridgeLifecycleState: String, Equatable, Sendable {
    case idle
    case starting
    case stopping
}

enum WorkspaceBridgeEnvironmentSource: String, Equatable, Sendable {
    case inherited
    case loginProbe = "login_probe"
    case fallback
}

struct WorkspaceBridgeEnvironmentDiagnostics: Equatable, Sendable {
    let source: WorkspaceBridgeEnvironmentSource
    let shellPath: String?
    let probeError: String?
    let pathDirectoryCount: Int
    let homeDirectory: String?

    var warningMessage: String? {
        guard source == .fallback else {
            return nil
        }

        if let probeError, probeError.isEmpty == false {
            return "Shell environment probe failed. The bridge is using fallback PATH entries. \(probeError)"
        }

        return "Shell environment probe did not succeed. The bridge is using fallback PATH entries."
    }
}

enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case ready
    case streaming
    case cancelling
    case error(message: String)
}

enum AuthState: Equatable, Sendable {
    case unknown
    case signedOut
    case signedIn(accountDescription: String)
}

enum AccountLoginMethod: String, Equatable, Sendable {
    case apiKey
    case chatgpt
    case chatgptAuthTokens
}

struct PendingLogin: Equatable, Sendable {
    var method: AccountLoginMethod
    var authURL: URL
    var loginID: String?
}

enum RateLimitBucketKind: String, Equatable, Sendable {
    case requests
    case tokens
    case other
}

struct RateLimitBucketState: Equatable, Sendable, Identifiable {
    let id: String
    var kind: RateLimitBucketKind
    var limit: Int?
    var remaining: Int?
    var resetAt: Date?
    var detail: String?
}

struct RateLimitState: Equatable, Sendable {
    var accountID: String?
    var buckets: [RateLimitBucketState]
}

struct ProviderCapabilitiesState: Equatable, Sendable {
    var supportsThreadLifecycle: Bool
    var supportsThreadArchiving: Bool
    var supportsApprovals: Bool
    var supportsAuthentication: Bool
    var supportedModes: [String]
}

struct ProviderSummaryState: Equatable, Sendable, Identifiable {
    let id: String
    var displayName: String
    var status: String
    var capabilities: ProviderCapabilitiesState
}

enum BridgeProviderIdentifier {
    nonisolated static let codex = "codex"
}

struct ThreadSummary: Equatable, Sendable, Identifiable {
    let id: String
    var providerID: String
    var title: String
    var previewText: String
    var updatedAt: Date
    var isVisibleInSidebar: Bool
    var isArchived: Bool
    var isRunning: Bool
    var hasUnreadActivity: Bool
    var lastErrorMessage: String?
    var isLocalOnly: Bool
    var isStale: Bool

    init(
        id: String,
        providerID: String = BridgeProviderIdentifier.codex,
        title: String,
        previewText: String,
        updatedAt: Date,
        isVisibleInSidebar: Bool = true,
        isArchived: Bool = false,
        isRunning: Bool = false,
        hasUnreadActivity: Bool = false,
        lastErrorMessage: String? = nil,
        isLocalOnly: Bool = false,
        isStale: Bool = false
    ) {
        self.id = id
        self.providerID = providerID
        self.title = title
        self.previewText = previewText
        self.updatedAt = updatedAt
        self.isVisibleInSidebar = isVisibleInSidebar
        self.isArchived = isArchived
        self.isRunning = isRunning
        self.hasUnreadActivity = hasUnreadActivity
        self.lastErrorMessage = lastErrorMessage
        self.isLocalOnly = isLocalOnly
        self.isStale = isStale
    }
}

struct PersistedThreadSummary: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var providerID: String
    var title: String
    var previewText: String
    var updatedAt: Date
    var isVisibleInSidebar: Bool
    var isArchived: Bool
    var isLocalOnly: Bool
    var isStale: Bool

    init(
        id: String,
        providerID: String = BridgeProviderIdentifier.codex,
        title: String,
        previewText: String,
        updatedAt: Date,
        isVisibleInSidebar: Bool,
        isArchived: Bool,
        isLocalOnly: Bool = false,
        isStale: Bool = false
    ) {
        self.id = id
        self.providerID = providerID
        self.title = title
        self.previewText = previewText
        self.updatedAt = updatedAt
        self.isVisibleInSidebar = isVisibleInSidebar
        self.isArchived = isArchived
        self.isLocalOnly = isLocalOnly
        self.isStale = isStale
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case providerID
        case title
        case previewText
        case updatedAt
        case isVisibleInSidebar
        case isArchived
        case isLocalOnly
        case isStale
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? BridgeProviderIdentifier.codex
        title = try container.decode(String.self, forKey: .title)
        previewText = try container.decode(String.self, forKey: .previewText)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isVisibleInSidebar = try container.decode(Bool.self, forKey: .isVisibleInSidebar)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        isLocalOnly = try container.decodeIfPresent(Bool.self, forKey: .isLocalOnly) ?? false
        isStale = try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
    }
}

struct PersistedWorkspaceUIState: Codable, Equatable, Sendable {
    var isExpanded: Bool
    var isShowingAllVisibleThreads: Bool
    var lastActiveProviderID: String?
    var lastActiveThreadID: String?

    init(
        isExpanded: Bool = true,
        isShowingAllVisibleThreads: Bool = false,
        lastActiveProviderID: String? = nil,
        lastActiveThreadID: String? = nil
    ) {
        self.isExpanded = isExpanded
        self.isShowingAllVisibleThreads = isShowingAllVisibleThreads
        self.lastActiveProviderID = lastActiveProviderID
        self.lastActiveThreadID = lastActiveThreadID
    }
}

struct PersistedCachedThreadListState: Codable, Equatable, Sendable {
    var threadSummaries: [PersistedThreadSummary]
    var lastSuccessfulActiveListAt: Date?
    var lastSuccessfulArchivedListAt: Date?

    init(
        threadSummaries: [PersistedThreadSummary] = [],
        lastSuccessfulActiveListAt: Date? = nil,
        lastSuccessfulArchivedListAt: Date? = nil
    ) {
        self.threadSummaries = threadSummaries
        self.lastSuccessfulActiveListAt = lastSuccessfulActiveListAt
        self.lastSuccessfulArchivedListAt = lastSuccessfulArchivedListAt
    }
}

struct PersistedWorkspaceState: Codable, Equatable, Sendable, Identifiable {
    let workspacePath: String
    var uiState: PersistedWorkspaceUIState
    var cachedThreadList: PersistedCachedThreadListState

    var id: String { workspacePath }

    var isExpanded: Bool {
        get { uiState.isExpanded }
        set { uiState.isExpanded = newValue }
    }

    var isShowingAllVisibleThreads: Bool {
        get { uiState.isShowingAllVisibleThreads }
        set { uiState.isShowingAllVisibleThreads = newValue }
    }

    var lastActiveThreadID: String? {
        get { uiState.lastActiveThreadID }
        set { uiState.lastActiveThreadID = newValue }
    }

    var pinnedThreadIDs: [String] {
        cachedThreadList.threadSummaries
            .filter(\.isLocalOnly)
            .map(\.id)
            .sorted()
    }

    var threadSummaries: [PersistedThreadSummary] {
        get { cachedThreadList.threadSummaries }
        set { cachedThreadList.threadSummaries = newValue }
    }

    init(
        workspacePath: String,
        uiState: PersistedWorkspaceUIState = PersistedWorkspaceUIState(),
        cachedThreadList: PersistedCachedThreadListState = PersistedCachedThreadListState()
    ) {
        self.workspacePath = workspacePath
        self.uiState = uiState
        self.cachedThreadList = cachedThreadList
    }

    init(
        workspacePath: String,
        isExpanded: Bool = true,
        isShowingAllVisibleThreads: Bool = false,
        lastActiveThreadID: String? = nil,
        pinnedThreadIDs: [String] = [],
        threadSummaries: [PersistedThreadSummary] = [],
        lastSuccessfulActiveListAt: Date? = nil,
        lastSuccessfulArchivedListAt: Date? = nil
    ) {
        let pinnedThreadIDSet = Set(pinnedThreadIDs)
        let cachedThreadSummaries = threadSummaries.map { summary in
            var summary = summary
            if pinnedThreadIDSet.contains(summary.id) {
                summary.isLocalOnly = true
            }
            return summary
        }

        self.init(
            workspacePath: workspacePath,
            uiState: PersistedWorkspaceUIState(
                isExpanded: isExpanded,
                isShowingAllVisibleThreads: isShowingAllVisibleThreads,
                lastActiveThreadID: lastActiveThreadID
            ),
            cachedThreadList: PersistedCachedThreadListState(
                threadSummaries: cachedThreadSummaries,
                lastSuccessfulActiveListAt: lastSuccessfulActiveListAt,
                lastSuccessfulArchivedListAt: lastSuccessfulArchivedListAt
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case workspacePath
        case uiState
        case cachedThreadList
        case isExpanded
        case isShowingAllVisibleThreads
        case lastActiveThreadID
        case pinnedThreadIDs
        case threadSummaries
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let workspacePath = try container.decode(String.self, forKey: .workspacePath)

        if let uiState = try container.decodeIfPresent(PersistedWorkspaceUIState.self, forKey: .uiState) {
            let cachedThreadList = try container.decodeIfPresent(
                PersistedCachedThreadListState.self,
                forKey: .cachedThreadList
            ) ?? PersistedCachedThreadListState()
            self.init(
                workspacePath: workspacePath,
                uiState: uiState,
                cachedThreadList: cachedThreadList
            )
            return
        }

        let isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        let isShowingAllVisibleThreads = try container.decodeIfPresent(Bool.self, forKey: .isShowingAllVisibleThreads) ?? false
        let lastActiveThreadID = try container.decodeIfPresent(String.self, forKey: .lastActiveThreadID)
        let pinnedThreadIDs = try container.decodeIfPresent([String].self, forKey: .pinnedThreadIDs) ?? []
        let threadSummaries = try container.decodeIfPresent([PersistedThreadSummary].self, forKey: .threadSummaries) ?? []

        self.init(
            workspacePath: workspacePath,
            isExpanded: isExpanded,
            isShowingAllVisibleThreads: isShowingAllVisibleThreads,
            lastActiveThreadID: lastActiveThreadID,
            pinnedThreadIDs: pinnedThreadIDs,
            threadSummaries: threadSummaries
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspacePath, forKey: .workspacePath)
        try container.encode(uiState, forKey: .uiState)
        try container.encode(cachedThreadList, forKey: .cachedThreadList)
    }
}

extension ThreadSummary {
    init(persistedSummary: PersistedThreadSummary) {
        self.init(
            id: persistedSummary.id,
            providerID: persistedSummary.providerID,
            title: persistedSummary.title,
            previewText: persistedSummary.previewText,
            updatedAt: persistedSummary.updatedAt,
            isVisibleInSidebar: persistedSummary.isVisibleInSidebar,
            isArchived: persistedSummary.isArchived,
            isLocalOnly: persistedSummary.isLocalOnly,
            isStale: persistedSummary.isStale
        )
    }

    var persistedSummary: PersistedThreadSummary {
        PersistedThreadSummary(
            id: id,
            providerID: providerID,
            title: title,
            previewText: previewText,
            updatedAt: updatedAt,
            isVisibleInSidebar: isVisibleInSidebar,
            isArchived: isArchived,
            isLocalOnly: isLocalOnly,
            isStale: isStale
        )
    }
}

struct WorkspaceThreadRoute: Equatable, Sendable {
    var workspacePath: String
    var providerID: String?
    var threadID: String?
}

enum AppPrimaryView: String, Equatable, Sendable {
    case conversations
    case settings
}

enum SettingsSection: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "slider.horizontal.3"
        }
    }
}

enum AppAppearancePreference: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var description: String {
        switch self {
        case .system:
            return "Follow your Mac appearance automatically."
        case .light:
            return "Always use the light appearance."
        case .dark:
            return "Always use the dark appearance."
        }
    }
}

struct ComposerModelOption: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let defaultReasoningEffort: ComposerReasoningEffort?
    let supportedReasoningEfforts: [ComposerReasoningEffort]
    let isDefault: Bool
}

enum ComposerReasoningEffort: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case appDefault = "default"
    case minimal
    case low
    case medium
    case high
    case xhigh
    case none

    var id: String { rawValue }

    static let serverSupportedDefaults: [Self] = [.low, .medium, .high, .xhigh]

    var bridgeValue: String? {
        self == .appDefault ? nil : rawValue
    }

    var title: String {
        switch self {
        case .appDefault:
            return "Default Effort"
        case .minimal:
            return "Minimal"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "Extra High"
        case .none:
            return "None"
        }
    }

    init(storedValue: String?) {
        self = ComposerReasoningEffort(rawValue: storedValue ?? ComposerReasoningEffort.appDefault.rawValue) ?? .appDefault
    }

    init?(bridgeValue: String?) {
        guard let bridgeValue,
              let effort = ComposerReasoningEffort(rawValue: bridgeValue),
              effort != .appDefault else {
            return nil
        }

        self = effort
    }
}

enum ConversationRole: String, Codable, Equatable, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct ConversationMessage: Equatable, Sendable, Identifiable {
    let id: String
    let role: ConversationRole
    var text: String
}

struct TurnState: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case idle
        case inProgress
        case completed
        case cancelled
        case failed
    }

    var phase: Phase = .idle
    var failureDescription: String?
}

enum ActivityKind: String, Equatable, Sendable {
    case tool
    case fileChange
}

enum ActivityStatus: String, Equatable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

struct ApprovalCommandContext: Equatable, Sendable {
    var command: String
    var workingDirectory: String?
}

enum TurnItemKind: String, Equatable, Sendable {
    case assistant
    case reasoning
    case tool
    case fileChange
}

struct TurnItem: Equatable, Sendable, Identifiable {
    let id: String
    let kind: TurnItemKind
    var title: String
    var text: String
    var detail: String?
    var command: String?
    var workingDirectory: String?
    var output: String
    var files: [DiffFileChange]
    var status: ActivityStatus
    var exitCode: Int?
}

enum TranscriptTurnEntry: Equatable, Sendable, Identifiable {
    case item(TurnItem)
    case activitySection(TranscriptActivitySection)

    var id: String {
        switch self {
        case .item(let item):
            return item.id
        case .activitySection(let section):
            return section.id
        }
    }
}

enum TranscriptActivitySectionKind: String, Equatable, Sendable {
    case tools
    case fileChanges
}

enum TranscriptActivitySectionStatus: String, Equatable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

struct TranscriptActivitySectionStatusCounts: Equatable, Sendable {
    let running: Int
    let completed: Int
    let failed: Int
    let cancelled: Int

    var distinctStatusCount: Int {
        [running, completed, failed, cancelled].filter { $0 > 0 }.count
    }

    var isMixed: Bool {
        distinctStatusCount > 1
    }

    func count(for status: TranscriptActivitySectionStatus) -> Int {
        switch status {
        case .running:
            return running
        case .completed:
            return completed
        case .failed:
            return failed
        case .cancelled:
            return cancelled
        }
    }
}

struct TranscriptActivitySection: Equatable, Sendable, Identifiable {
    let id: String
    let kind: TranscriptActivitySectionKind
    let ordinal: Int
    let items: [TurnItem]
    let status: TranscriptActivitySectionStatus
    let statusCounts: TranscriptActivitySectionStatusCounts
    let summary: String

    var itemCount: Int {
        items.count
    }

    var hasMixedStatuses: Bool {
        statusCounts.isMixed
    }

    var defaultExpanded: Bool {
        false
    }
}

struct TranscriptTurnPresentation: Equatable, Sendable {
    let entries: [TranscriptTurnEntry]
    let showsAssistantWaitingIndicator: Bool

    init(turnState: TurnState = TurnState(), turnItems: [TurnItem]) {
        entries = Self.makeEntries(from: turnItems)
        showsAssistantWaitingIndicator = Self.shouldShowAssistantWaitingIndicator(
            turnState: turnState,
            turnItems: turnItems
        )
    }

    private static func makeEntries(from turnItems: [TurnItem]) -> [TranscriptTurnEntry] {
        struct PendingSection {
            let kind: TranscriptActivitySectionKind
            var items: [TurnItem]
        }

        var entries: [TranscriptTurnEntry] = []
        var pendingSection: PendingSection?
        var sectionOrdinals: [TranscriptActivitySectionKind: Int] = [:]

        func flushPendingSection() {
            guard let section = pendingSection else {
                return
            }

            let ordinal = (sectionOrdinals[section.kind] ?? 0) + 1
            sectionOrdinals[section.kind] = ordinal

            entries.append(
                .activitySection(
                    TranscriptActivitySection(
                        id: "\(section.kind.rawValue)-\(ordinal)-\(section.items[0].id)",
                        kind: section.kind,
                        ordinal: ordinal,
                        items: section.items,
                        status: makeSectionStatus(for: section.items),
                        statusCounts: makeSectionStatusCounts(for: section.items),
                        summary: makeSectionSummary(for: section.items, kind: section.kind)
                    )
                )
            )

            pendingSection = nil
        }

        for item in turnItems {
            guard let sectionKind = item.transcriptActivitySectionKind else {
                flushPendingSection()
                entries.append(.item(item))
                continue
            }

            if pendingSection?.kind == sectionKind {
                pendingSection?.items.append(item)
            } else {
                flushPendingSection()
                pendingSection = PendingSection(kind: sectionKind, items: [item])
            }
        }

        flushPendingSection()
        return entries
    }

    private static func shouldShowAssistantWaitingIndicator(
        turnState: TurnState,
        turnItems: [TurnItem]
    ) -> Bool {
        guard turnState.phase == .inProgress else {
            return false
        }

        if turnItems.contains(where: {
            ($0.kind == .tool || $0.kind == .fileChange) && $0.status == .running
        }) {
            return false
        }

        if let latestMeaningfulItem = turnItems.last(where: { $0.kind != .reasoning }) {
            return latestMeaningfulItem.kind != .assistant || latestMeaningfulItem.status != .running
        }

        return true
    }

    private static func makeSectionStatus(for items: [TurnItem]) -> TranscriptActivitySectionStatus {
        if items.contains(where: { $0.status == .running }) {
            return .running
        }

        if items.contains(where: { $0.status == .failed }) {
            return .failed
        }

        if items.contains(where: { $0.status == .cancelled }) {
            return .cancelled
        }

        return .completed
    }

    private static func makeSectionStatusCounts(for items: [TurnItem]) -> TranscriptActivitySectionStatusCounts {
        TranscriptActivitySectionStatusCounts(
            running: items.filter { $0.status == .running }.count,
            completed: items.filter { $0.status == .completed }.count,
            failed: items.filter { $0.status == .failed }.count,
            cancelled: items.filter { $0.status == .cancelled }.count
        )
    }

    private static func makeSectionSummary(
        for items: [TurnItem],
        kind: TranscriptActivitySectionKind
    ) -> String {
        if let detail = items.lazy.compactMap(\.detail).last(where: { $0.isEmpty == false }) {
            return detail
        }

        if let command = items.lazy.compactMap(\.command).last(where: { $0.isEmpty == false }) {
            return command
        }

        switch kind {
        case .tools:
            return items.last?.title ?? "Tool activity"
        case .fileChanges:
            let fileCount = items.reduce(0) { partialResult, item in
                partialResult + max(item.files.count, item.title.contains("file changed") ? 1 : 0)
            }

            if fileCount == 1 {
                return "1 file changed"
            }

            if fileCount > 1 {
                return "\(fileCount) files changed"
            }

            return items.last?.title ?? "File changes"
        }
    }
}

struct ActivityItem: Equatable, Sendable, Identifiable {
    let id: String
    let kind: ActivityKind
    var title: String
    var detail: String?
    var command: String?
    var workingDirectory: String?
    var output: String
    var files: [DiffFileChange]
    var status: ActivityStatus
    var exitCode: Int?
}

enum ApprovalKind: String, Equatable, Sendable {
    case command
    case fileChange
    case generic
}

enum ApprovalResolution: String, Equatable, Sendable {
    case approved
    case declined
    case cancelled
    case stale
}

enum ApprovalRiskLevel: String, Equatable, Sendable {
    case low
    case medium
    case high
}

struct ApprovalRequest: Equatable, Sendable, Identifiable {
    let id: String
    let kind: ApprovalKind
    var title: String
    var detail: String
    var command: ApprovalCommandContext?
    var files: [DiffFileChange]
    var riskLevel: ApprovalRiskLevel?
    var pendingResolution: ApprovalResolution? = nil
}

enum PlanStepStatus: String, Equatable, Sendable {
    case pending
    case inProgress
    case completed
}

struct PlanStep: Equatable, Sendable, Identifiable {
    let id: String
    var title: String
    var status: PlanStepStatus
}

struct PlanState: Equatable, Sendable {
    var summary: String?
    var steps: [PlanStep]
}

struct DiffFileChange: Equatable, Sendable, Identifiable {
    let id: String
    var path: String
    var additions: Int
    var deletions: Int
}

struct AggregatedDiff: Equatable, Sendable {
    var summary: String
    var files: [DiffFileChange]
}

extension TurnItem {
    var transcriptActivitySectionKind: TranscriptActivitySectionKind? {
        switch kind {
        case .assistant, .reasoning:
            return nil
        case .tool:
            return .tools
        case .fileChange:
            return .fileChanges
        }
    }
}
