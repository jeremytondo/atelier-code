import Foundation
import Observation

@MainActor
@Observable
final class ThreadSession {
    private(set) var threadID: String
    private(set) var title: String
    private(set) var messages: [ConversationMessage]
    private(set) var turnState: TurnState
    private(set) var pendingApprovals: [ApprovalRequest]
    private(set) var activityItems: [ActivityItem]
    private(set) var planState: PlanState?
    private(set) var aggregatedDiff: AggregatedDiff?

    init(
        threadID: String,
        title: String,
        messages: [ConversationMessage] = [],
        turnState: TurnState? = nil,
        pendingApprovals: [ApprovalRequest] = [],
        activityItems: [ActivityItem] = [],
        planState: PlanState? = nil,
        aggregatedDiff: AggregatedDiff? = nil
    ) {
        self.threadID = threadID
        self.title = title
        self.messages = messages
        self.turnState = turnState ?? TurnState()
        self.pendingApprovals = pendingApprovals
        self.activityItems = activityItems
        self.planState = planState
        self.aggregatedDiff = aggregatedDiff
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

        turnState = TurnState(phase: .inProgress, assistantMessageID: nil, thinkingText: "", failureDescription: nil)
        pendingApprovals.removeAll()
        activityItems.removeAll()
        planState = nil
        aggregatedDiff = nil
    }

    func appendAssistantTextDelta(_ delta: String) {
        guard delta.isEmpty == false else {
            return
        }

        if let assistantMessageID = turnState.assistantMessageID,
           let index = messages.firstIndex(where: { $0.id == assistantMessageID }) {
            messages[index].text += delta
            return
        }

        let message = ConversationMessage(
            id: UUID().uuidString,
            role: .assistant,
            text: delta
        )
        messages.append(message)
        turnState.assistantMessageID = message.id
    }

    func appendThinkingDelta(_ delta: String) {
        guard delta.isEmpty == false else {
            return
        }

        turnState.thinkingText += delta
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
        if let index = activityItems.firstIndex(where: { $0.id == id }) {
            activityItems[index].title = title
            activityItems[index].detail = detail
            activityItems[index].command = command
            activityItems[index].workingDirectory = workingDirectory
            activityItems[index].files = files
            activityItems[index].status = .running
            activityItems[index].exitCode = nil
            return
        }

        activityItems.append(
            ActivityItem(
                id: id,
                kind: kind,
                title: title,
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
        guard let index = activityItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        activityItems[index].detail = detail
    }

    func appendActivityOutput(id: String, delta: String) {
        guard delta.isEmpty == false,
              let index = activityItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        if activityItems[index].output.isEmpty {
            activityItems[index].output = delta
        } else {
            activityItems[index].output += delta
        }
    }

    func completeActivity(
        id: String,
        status: ActivityStatus = .completed,
        detail: String? = nil,
        files: [DiffFileChange]? = nil,
        exitCode: Int? = nil
    ) {
        guard let index = activityItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        activityItems[index].status = status

        if let detail {
            activityItems[index].detail = detail
        }

        if let files {
            activityItems[index].files = files
        }

        activityItems[index].exitCode = exitCode
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
        markRunningActivities(as: .completed)
    }

    func cancelTurn() {
        turnState.phase = .cancelled
        pendingApprovals.removeAll()
        markRunningActivities(as: .cancelled)

        planState = nil
        aggregatedDiff = nil
    }

    func failTurn(_ message: String) {
        turnState.phase = .failed
        turnState.failureDescription = message
        pendingApprovals.removeAll()
        markRunningActivities(as: .failed)

        planState = nil
        aggregatedDiff = nil
    }

    func clearVolatilePerTurnState() {
        turnState = TurnState()
        pendingApprovals.removeAll()
        activityItems.removeAll()
        planState = nil
        aggregatedDiff = nil
    }

    private func markRunningActivities(as status: ActivityStatus) {
        for index in activityItems.indices where activityItems[index].status == .running {
            activityItems[index].status = status
        }
    }
}
