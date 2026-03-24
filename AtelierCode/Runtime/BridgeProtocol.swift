import Foundation

enum BridgeProtocolVersion {
    static let current = 1
    static let supported = [current]
}

enum BridgeCommandType: String, Encodable, Sendable {
    case threadStart = "thread.start"
    case threadResume = "thread.resume"
    case threadList = "thread.list"
    case turnStart = "turn.start"
    case turnCancel = "turn.cancel"
    case approvalResolve = "approval.resolve"
    case accountRead = "account.read"
    case accountLogin = "account.login"
    case accountLogout = "account.logout"
}

enum BridgeEventType: String, Decodable, Sendable {
    case threadStarted = "thread.started"
    case turnStarted = "turn.started"
    case messageDelta = "message.delta"
    case thinkingDelta = "thinking.delta"
    case toolStarted = "tool.started"
    case toolOutput = "tool.output"
    case toolCompleted = "tool.completed"
    case fileChangeStarted = "fileChange.started"
    case fileChangeCompleted = "fileChange.completed"
    case approvalRequested = "approval.requested"
    case diffUpdated = "diff.updated"
    case planUpdated = "plan.updated"
    case turnCompleted = "turn.completed"
    case threadListResult = "thread.list.result"
    case accountLoginResult = "account.login.result"
    case authChanged = "auth.changed"
    case rateLimitUpdated = "rateLimit.updated"
    case error
    case providerStatus = "provider.status"
}

enum BridgeProviderConnectionStatus: String, Decodable, Sendable {
    case starting
    case ready
    case degraded
    case disconnected
    case error
}

enum BridgeAuthStateValue: String, Decodable, Sendable {
    case unknown
    case signedOut = "signed_out"
    case signedIn = "signed_in"
}

enum BridgeActivityStatusValue: String, Decodable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

enum BridgeTurnCompletionStatusValue: String, Decodable, Sendable {
    case completed
    case failed
    case cancelled
    case interrupted
}

enum BridgeApprovalKindValue: String, Decodable, Sendable {
    case command
    case fileChange
    case generic
}

enum BridgeApprovalResolutionValue: String, Encodable, Sendable {
    case approved
    case declined
    case cancelled
    case stale
}

enum BridgePlanStepStatusValue: String, Decodable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

enum BridgeThreadArchiveFilter: String, Encodable, Sendable {
    case exclude
    case include
    case only
}

enum BridgeLoginMethod: String, Codable, Sendable {
    case apiKey
    case chatgpt
    case chatgptAuthTokens
}

struct BridgeStartupRecord: Decodable, Equatable, Sendable {
    let recordType: String
    let bridgeVersion: String
    let protocolVersion: Int
    let transport: String
    let host: String
    let port: Int
    let pid: Int
    let startedAt: String
}

struct BridgeHelloPayload: Encodable, Sendable {
    let appVersion: String
    let protocolVersion: Int
    let supportedProtocolVersions: [Int]
    let clientName: String
    let platform: String?
    let transport: String
}

struct BridgeHelloEnvelope: Encodable, Sendable {
    let id: String
    let type = "hello"
    let timestamp: String
    let payload: BridgeHelloPayload
}

struct BridgeWelcomePayload: Decodable, Equatable, Sendable {
    let bridgeVersion: String
    let protocolVersion: Int
    let supportedProtocolVersions: [Int]
    let sessionID: String
    let transport: String
    let providers: [BridgeProviderSummary]
}

struct BridgeWelcomeEnvelope: Decodable, Equatable, Sendable {
    let type: String
    let timestamp: String
    let provider: String?
    let requestID: String
    let payload: BridgeWelcomePayload
}

struct BridgeProviderSummary: Decodable, Equatable, Sendable {
    let id: String
    let displayName: String
    let status: String
}

struct BridgeCommandEnvelope<Payload: Encodable>: Encodable {
    let id: String
    let type: BridgeCommandType
    let timestamp: String
    let provider: String
    let threadID: String?
    let turnID: String?
    let payload: Payload
}

struct BridgeThreadStartPayload: Encodable, Sendable {
    let workspacePath: String
    let title: String?
}

struct BridgeThreadResumePayload: Encodable, Sendable {
    let workspacePath: String
}

struct BridgeThreadListPayload: Encodable, Sendable {
    let workspacePath: String
    let cursor: String?
    let limit: Int?
    let archived: BridgeThreadArchiveFilter?
}

struct BridgeTurnStartConfiguration: Encodable, Sendable {
    let cwd: String?
    let model: String?
    let reasoningEffort: String?
    let sandboxPolicy: String?
    let approvalPolicy: String?
    let summaryMode: String?
    let environment: [String: String]?
}

struct BridgeTurnStartPayload: Encodable, Sendable {
    let prompt: String
    let configuration: BridgeTurnStartConfiguration?
}

struct BridgeTurnCancelPayload: Encodable, Sendable {
    let reason: String?
}

struct BridgeApprovalResolvePayload: Encodable, Sendable {
    let approvalID: String
    let resolution: BridgeApprovalResolutionValue
    let rememberDecision: Bool?
}

struct BridgeAccountReadPayload: Encodable, Sendable {
    let forceRefresh: Bool?
}

struct BridgeAccountLoginPayload: Encodable, Sendable {
    let method: BridgeLoginMethod?
    let credentials: [String: String]?
}

struct BridgeAccountLogoutPayload: Encodable, Sendable {
    let scope: String?
}

struct BridgeThreadSummaryDTO: Decodable, Equatable, Sendable {
    let id: String
    let title: String
    let previewText: String
    let updatedAt: String
}

struct BridgeTurnStartedPayload: Decodable, Equatable, Sendable {
    let status: String
    let startedAt: String?
}

struct BridgeThreadStartedPayload: Decodable, Equatable, Sendable {
    let thread: BridgeThreadSummaryDTO
}

struct BridgeMessageDeltaPayload: Decodable, Equatable, Sendable {
    let messageID: String
    let delta: String
}

struct BridgeThinkingDeltaPayload: Decodable, Equatable, Sendable {
    let delta: String
}

struct BridgeToolStartedPayload: Decodable, Equatable, Sendable {
    let title: String
    let detail: String?
    let kind: String
    let command: String?
    let workingDirectory: String?
}

struct BridgeToolOutputPayload: Decodable, Equatable, Sendable {
    let stream: String?
    let delta: String
}

struct BridgeToolCompletedPayload: Decodable, Equatable, Sendable {
    let status: BridgeActivityStatusValue
    let detail: String?
    let exitCode: Int?
}

struct BridgeDiffFileSummaryDTO: Decodable, Equatable, Sendable {
    let id: String
    let path: String
    let additions: Int
    let deletions: Int
}

struct BridgeFileChangeStartedPayload: Decodable, Equatable, Sendable {
    let title: String
    let detail: String?
    let files: [BridgeDiffFileSummaryDTO]
}

struct BridgeFileChangeCompletedPayload: Decodable, Equatable, Sendable {
    let status: BridgeActivityStatusValue
    let detail: String?
    let files: [BridgeDiffFileSummaryDTO]
}

struct BridgeApprovalCommandContextDTO: Decodable, Equatable, Sendable {
    let command: String
    let workingDirectory: String?
}

struct BridgeApprovalRequestedPayload: Decodable, Equatable, Sendable {
    let approvalID: String
    let kind: BridgeApprovalKindValue
    let title: String
    let detail: String
    let command: BridgeApprovalCommandContextDTO?
    let files: [BridgeDiffFileSummaryDTO]?
    let riskLevel: String?
}

struct BridgeDiffUpdatedPayload: Decodable, Equatable, Sendable {
    let summary: String
    let files: [BridgeDiffFileSummaryDTO]
}

struct BridgePlanStepDTO: Decodable, Equatable, Sendable {
    let id: String
    let title: String
    let status: BridgePlanStepStatusValue
}

struct BridgePlanUpdatedPayload: Decodable, Equatable, Sendable {
    let summary: String?
    let steps: [BridgePlanStepDTO]
}

struct BridgeTurnCompletedPayload: Decodable, Equatable, Sendable {
    let status: BridgeTurnCompletionStatusValue
    let detail: String?
}

struct BridgeThreadListResultPayload: Decodable, Equatable, Sendable {
    let threads: [BridgeThreadSummaryDTO]
    let nextCursor: String?
}

struct BridgeAccountLoginResultPayload: Decodable, Equatable, Sendable {
    let method: BridgeLoginMethod
    let authURL: String?
    let loginID: String?
}

struct BridgeAccountSummaryDTO: Decodable, Equatable, Sendable {
    let id: String?
    let displayName: String
    let email: String?
}

struct BridgeAuthChangedPayload: Decodable, Equatable, Sendable {
    let state: BridgeAuthStateValue
    let account: BridgeAccountSummaryDTO?
}

struct BridgeRateLimitBucketDTO: Decodable, Equatable, Sendable {
    let id: String
    let kind: String
    let limit: Int?
    let remaining: Int?
    let resetAt: String?
    let detail: String?
}

struct BridgeRateLimitUpdatedPayload: Decodable, Equatable, Sendable {
    let accountID: String?
    let buckets: [BridgeRateLimitBucketDTO]
}

enum BridgeJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: BridgeJSONValue])
    case array([BridgeJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: BridgeJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([BridgeJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value in bridge payload."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct BridgeErrorPayload: Decodable, Equatable, Sendable {
    let code: String
    let message: String
    let retryable: Bool?
    let detail: [String: BridgeJSONValue]?
}

struct BridgeProviderStatusPayload: Decodable, Equatable, Sendable {
    let status: BridgeProviderConnectionStatus
    let detail: String
}

enum BridgeEventPayload: Equatable, Sendable {
    case threadStarted(BridgeThreadStartedPayload)
    case turnStarted(BridgeTurnStartedPayload)
    case messageDelta(BridgeMessageDeltaPayload)
    case thinkingDelta(BridgeThinkingDeltaPayload)
    case toolStarted(BridgeToolStartedPayload)
    case toolOutput(BridgeToolOutputPayload)
    case toolCompleted(BridgeToolCompletedPayload)
    case fileChangeStarted(BridgeFileChangeStartedPayload)
    case fileChangeCompleted(BridgeFileChangeCompletedPayload)
    case approvalRequested(BridgeApprovalRequestedPayload)
    case diffUpdated(BridgeDiffUpdatedPayload)
    case planUpdated(BridgePlanUpdatedPayload)
    case turnCompleted(BridgeTurnCompletedPayload)
    case threadListResult(BridgeThreadListResultPayload)
    case accountLoginResult(BridgeAccountLoginResultPayload)
    case authChanged(BridgeAuthChangedPayload)
    case rateLimitUpdated(BridgeRateLimitUpdatedPayload)
    case error(BridgeErrorPayload)
    case providerStatus(BridgeProviderStatusPayload)
}

struct BridgeEventEnvelope: Decodable, Equatable, Sendable {
    let type: BridgeEventType
    let timestamp: String
    let provider: String?
    let requestID: String?
    let threadID: String?
    let turnID: String?
    let itemID: String?
    let activityID: String?
    let payload: BridgeEventPayload

    private enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case provider
        case requestID
        case threadID
        case turnID
        case itemID
        case activityID
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(BridgeEventType.self, forKey: .type)

        self.type = type
        timestamp = try container.decode(String.self, forKey: .timestamp)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        itemID = try container.decodeIfPresent(String.self, forKey: .itemID)
        activityID = try container.decodeIfPresent(String.self, forKey: .activityID)

        switch type {
        case .threadStarted:
            payload = .threadStarted(try container.decode(BridgeThreadStartedPayload.self, forKey: .payload))
        case .turnStarted:
            payload = .turnStarted(try container.decode(BridgeTurnStartedPayload.self, forKey: .payload))
        case .messageDelta:
            payload = .messageDelta(try container.decode(BridgeMessageDeltaPayload.self, forKey: .payload))
        case .thinkingDelta:
            payload = .thinkingDelta(try container.decode(BridgeThinkingDeltaPayload.self, forKey: .payload))
        case .toolStarted:
            payload = .toolStarted(try container.decode(BridgeToolStartedPayload.self, forKey: .payload))
        case .toolOutput:
            payload = .toolOutput(try container.decode(BridgeToolOutputPayload.self, forKey: .payload))
        case .toolCompleted:
            payload = .toolCompleted(try container.decode(BridgeToolCompletedPayload.self, forKey: .payload))
        case .fileChangeStarted:
            payload = .fileChangeStarted(try container.decode(BridgeFileChangeStartedPayload.self, forKey: .payload))
        case .fileChangeCompleted:
            payload = .fileChangeCompleted(try container.decode(BridgeFileChangeCompletedPayload.self, forKey: .payload))
        case .approvalRequested:
            payload = .approvalRequested(try container.decode(BridgeApprovalRequestedPayload.self, forKey: .payload))
        case .diffUpdated:
            payload = .diffUpdated(try container.decode(BridgeDiffUpdatedPayload.self, forKey: .payload))
        case .planUpdated:
            payload = .planUpdated(try container.decode(BridgePlanUpdatedPayload.self, forKey: .payload))
        case .turnCompleted:
            payload = .turnCompleted(try container.decode(BridgeTurnCompletedPayload.self, forKey: .payload))
        case .threadListResult:
            payload = .threadListResult(try container.decode(BridgeThreadListResultPayload.self, forKey: .payload))
        case .accountLoginResult:
            payload = .accountLoginResult(try container.decode(BridgeAccountLoginResultPayload.self, forKey: .payload))
        case .authChanged:
            payload = .authChanged(try container.decode(BridgeAuthChangedPayload.self, forKey: .payload))
        case .rateLimitUpdated:
            payload = .rateLimitUpdated(try container.decode(BridgeRateLimitUpdatedPayload.self, forKey: .payload))
        case .error:
            payload = .error(try container.decode(BridgeErrorPayload.self, forKey: .payload))
        case .providerStatus:
            payload = .providerStatus(try container.decode(BridgeProviderStatusPayload.self, forKey: .payload))
        }
    }
}

enum BridgeInboundMessage: Decodable, Equatable, Sendable {
    case welcome(BridgeWelcomeEnvelope)
    case event(BridgeEventEnvelope)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)

        if rawType == "welcome" {
            self = .welcome(try BridgeWelcomeEnvelope(from: decoder))
        } else {
            self = .event(try BridgeEventEnvelope(from: decoder))
        }
    }
}

extension BridgeThreadSummaryDTO {
    func toThreadSummary() -> ThreadSummary {
        ThreadSummary(
            id: id,
            title: title,
            previewText: previewText,
            updatedAt: bridgeDate(from: updatedAt) ?? .distantPast
        )
    }
}

extension BridgeDiffFileSummaryDTO {
    func toDiffFileChange() -> DiffFileChange {
        DiffFileChange(id: id, path: path, additions: additions, deletions: deletions)
    }
}

extension BridgePlanStepDTO {
    func toPlanStep() -> PlanStep {
        let status: PlanStepStatus
        switch self.status {
        case .pending:
            status = .pending
        case .inProgress:
            status = .inProgress
        case .completed:
            status = .completed
        }

        return PlanStep(
            id: id,
            title: title,
            status: status
        )
    }
}

extension BridgeApprovalRequestedPayload {
    func toApprovalRequest() -> ApprovalRequest {
        let kind: ApprovalKind
        switch self.kind {
        case .command:
            kind = .command
        case .fileChange:
            kind = .fileChange
        case .generic:
            kind = .generic
        }

        return ApprovalRequest(
            id: approvalID,
            kind: kind,
            title: title,
            detail: detail,
            command: command?.toApprovalCommandContext(),
            files: (files ?? []).map { $0.toDiffFileChange() },
            riskLevel: riskLevel.flatMap(ApprovalRiskLevel.init(rawValue:))
        )
    }
}

extension BridgeApprovalCommandContextDTO {
    func toApprovalCommandContext() -> ApprovalCommandContext {
        ApprovalCommandContext(
            command: command,
            workingDirectory: workingDirectory
        )
    }
}

extension BridgeRateLimitBucketDTO {
    func toRateLimitBucketState() -> RateLimitBucketState {
        let bucketKind: RateLimitBucketKind
        switch kind {
        case "requests":
            bucketKind = .requests
        case "tokens":
            bucketKind = .tokens
        default:
            bucketKind = .other
        }

        return RateLimitBucketState(
            id: id,
            kind: bucketKind,
            limit: limit,
            remaining: remaining,
            resetAt: resetAt.flatMap { bridgeDate(from: $0) },
            detail: detail
        )
    }
}

extension BridgeLoginMethod {
    func toAccountLoginMethod() -> AccountLoginMethod {
        switch self {
        case .apiKey:
            return .apiKey
        case .chatgpt:
            return .chatgpt
        case .chatgptAuthTokens:
            return .chatgptAuthTokens
        }
    }
}

private func bridgeDate(from string: String) -> Date? {
    ISO8601DateFormatter().date(from: string)
}
