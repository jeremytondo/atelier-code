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

struct UIPreferences: Codable, Equatable, Sendable {
    var showsStartupDiagnostics = true
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

struct ThreadSummary: Equatable, Sendable, Identifiable {
    let id: String
    var title: String
    var previewText: String
    var updatedAt: Date
}

enum ConversationRole: String, Equatable, Sendable {
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
        statusCounts.running > 0
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

        return turnItems.contains {
            $0.kind == .assistant || $0.kind == .tool || $0.kind == .fileChange
        } == false
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
