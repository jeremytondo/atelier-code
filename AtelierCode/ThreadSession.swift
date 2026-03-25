import Foundation
import Observation

@MainActor
@Observable
final class ThreadSession {
    private(set) var threadID: String
    private(set) var title: String
    private(set) var messages: [ConversationMessage]
    private(set) var turnState: TurnState
    private(set) var turnItems: [TurnItem]
    private(set) var pendingApprovals: [ApprovalRequest]
    private(set) var planState: PlanState?
    private(set) var aggregatedDiff: AggregatedDiff?

    init(
        threadID: String,
        title: String,
        messages: [ConversationMessage] = [],
        turnState: TurnState? = nil,
        turnItems: [TurnItem] = [],
        pendingApprovals: [ApprovalRequest] = [],
        planState: PlanState? = nil,
        aggregatedDiff: AggregatedDiff? = nil
    ) {
        self.threadID = threadID
        self.title = title
        self.messages = messages
        self.turnState = turnState ?? TurnState()
        self.turnItems = turnItems
        self.pendingApprovals = pendingApprovals
        self.planState = planState
        self.aggregatedDiff = aggregatedDiff
    }

    var activityItems: [ActivityItem] {
        turnItems.compactMap(\.activityItem)
    }

    var reasoningText: String {
        turnItems
            .filter { $0.kind == .reasoning }
            .map(\.text)
            .joined()
    }

    func updateThreadIdentity(id: String, title: String) {
        threadID = id
        self.title = title
    }

    func startThread(id: String, title: String) {
        threadID = id
        self.title = title
        messages.removeAll()
        clearVolatilePerTurnState()
    }

    func resumeThread(id: String, title: String, messages: [ConversationMessage]) {
        threadID = id
        self.title = title
        self.messages = messages
        clearVolatilePerTurnState()
    }

    func beginTurn(userPrompt: String? = nil) {
        if let userPrompt, userPrompt.isEmpty == false {
            messages.append(
                ConversationMessage(
                    id: UUID().uuidString,
                    role: .user,
                    text: userPrompt
                )
            )
        }

        turnState = TurnState(phase: .inProgress, failureDescription: nil)
        turnItems.removeAll()
        pendingApprovals.removeAll()
        planState = nil
        aggregatedDiff = nil
    }

    func appendAssistantTextDelta(_ delta: String, itemID: String = "assistant") {
        guard delta.isEmpty == false else {
            return
        }

        appendTextDelta(delta, to: itemID, kind: .assistant, title: "Assistant")
    }

    func appendThinkingDelta(_ delta: String, itemID: String = "reasoning") {
        guard delta.isEmpty == false else {
            return
        }

        appendTextDelta(delta, to: itemID, kind: .reasoning, title: "Reasoning")
    }

    func startActivity(
        id: String,
        kind: ActivityKind,
        title: String,
        detail: String? = nil,
        command: String? = nil,
        workingDirectory: String? = nil,
        files: [DiffFileChange] = []
    ) {
        if let index = turnItems.firstIndex(where: { $0.id == id }) {
            turnItems[index].title = title
            turnItems[index].detail = detail
            turnItems[index].command = command
            turnItems[index].workingDirectory = workingDirectory
            turnItems[index].files = files
            turnItems[index].status = .running
            turnItems[index].exitCode = nil
            return
        }

        turnItems.append(
            TurnItem(
                id: id,
                kind: kind.turnItemKind,
                title: title,
                text: "",
                detail: detail,
                command: command,
                workingDirectory: workingDirectory,
                output: "",
                files: files,
                status: .running,
                exitCode: nil
            )
        )
    }

    func updateActivity(id: String, detail: String?) {
        guard let index = turnItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        turnItems[index].detail = detail
    }

    func hasTurnItem(id: String) -> Bool {
        turnItems.contains(where: { $0.id == id })
    }

    func appendActivityOutput(id: String, delta: String) {
        guard delta.isEmpty == false,
              let index = turnItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        if turnItems[index].output.isEmpty {
            turnItems[index].output = delta
        } else {
            turnItems[index].output += delta
        }
    }

    func completeActivity(
        id: String,
        status: ActivityStatus = .completed,
        detail: String? = nil,
        files: [DiffFileChange]? = nil,
        exitCode: Int? = nil
    ) {
        guard let index = turnItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        turnItems[index].status = status

        if let detail {
            turnItems[index].detail = detail
        }

        if let files {
            turnItems[index].files = files
        }

        turnItems[index].exitCode = exitCode
    }

    func enqueueApprovalRequest(_ request: ApprovalRequest) {
        guard pendingApprovals.contains(where: { $0.id == request.id }) == false else {
            return
        }

        pendingApprovals.append(request)
    }

    func beginApprovalResolution(id: String, resolution: ApprovalResolution) -> Bool {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }),
              pendingApprovals[index].pendingResolution == nil else {
            return false
        }

        pendingApprovals[index].pendingResolution = resolution
        return true
    }

    func clearApprovalResolution(id: String) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }) else {
            return
        }

        pendingApprovals[index].pendingResolution = nil
    }

    func resolveApprovalRequest(id: String, resolution _: ApprovalResolution) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }) else {
            return
        }

        pendingApprovals.remove(at: index)
    }

    func replacePlanState(_ planState: PlanState?) {
        self.planState = planState
    }

    func replaceAggregatedDiff(_ aggregatedDiff: AggregatedDiff?) {
        self.aggregatedDiff = aggregatedDiff
    }

    func completeTurn() {
        turnState.phase = .completed
        pendingApprovals.removeAll()
        markRunningTurnItems(as: .completed)
        appendCompletedAssistantTranscript()
    }

    func cancelTurn() {
        turnState.phase = .cancelled
        pendingApprovals.removeAll()
        markRunningTurnItems(as: .cancelled)

        planState = nil
        aggregatedDiff = nil
    }

    func failTurn(_ message: String) {
        turnState.phase = .failed
        turnState.failureDescription = message
        pendingApprovals.removeAll()
        markRunningTurnItems(as: .failed)

        planState = nil
        aggregatedDiff = nil
    }

    func clearVolatilePerTurnState() {
        turnState = TurnState()
        pendingApprovals.removeAll()
        turnItems.removeAll()
        planState = nil
        aggregatedDiff = nil
    }

    private func appendTextDelta(_ delta: String, to itemID: String, kind: TurnItemKind, title: String) {
        if let index = turnItems.firstIndex(where: { $0.id == itemID }) {
            turnItems[index].text += delta
            turnItems[index].status = .running
            return
        }

        turnItems.append(
            TurnItem(
                id: itemID,
                kind: kind,
                title: title,
                text: delta,
                detail: nil,
                command: nil,
                workingDirectory: nil,
                output: "",
                files: [],
                status: .running,
                exitCode: nil
            )
        )
    }

    private func appendCompletedAssistantTranscript() {
        let assistantText = turnItems
            .filter { $0.kind == .assistant }
            .map(\.text)
            .joined()

        guard assistantText.isEmpty == false else {
            return
        }

        messages.append(
            ConversationMessage(
                id: UUID().uuidString,
                role: .assistant,
                text: assistantText
            )
        )
    }

    private func markRunningTurnItems(as status: ActivityStatus) {
        for index in turnItems.indices where turnItems[index].status == .running {
            turnItems[index].status = status
        }
    }
}

private extension TurnItem {
    var activityItem: ActivityItem? {
        guard let kind = activityKind else {
            return nil
        }

        return ActivityItem(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            command: command,
            workingDirectory: workingDirectory,
            output: output,
            files: files,
            status: status,
            exitCode: exitCode
        )
    }

    var activityKind: ActivityKind? {
        switch kind {
        case .assistant, .reasoning:
            return nil
        case .tool:
            return .tool
        case .fileChange:
            return .fileChange
        }
    }
}

private extension ActivityKind {
    var turnItemKind: TurnItemKind {
        switch self {
        case .tool:
            return .tool
        case .fileChange:
            return .fileChange
        }
    }
}
