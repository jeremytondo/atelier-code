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
    var assistantMessageID: String?
    var thinkingText = ""
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

struct ActivityItem: Equatable, Sendable, Identifiable {
    let id: String
    let kind: ActivityKind
    var title: String
    var detail: String
    var status: ActivityStatus
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

struct ApprovalRequest: Equatable, Sendable, Identifiable {
    let id: String
    let kind: ApprovalKind
    var title: String
    var detail: String
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
