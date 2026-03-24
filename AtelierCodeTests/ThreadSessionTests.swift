import Testing
@testable import AtelierCode

@MainActor
struct ThreadSessionTests {
    @Test func assistantAndThinkingDeltasAppendCorrectly() async throws {
        let session = ThreadSession(threadID: "thread-1", title: "Thread")

        session.beginTurn(userPrompt: "Hello")
        session.appendAssistantTextDelta("Hello")
        session.appendAssistantTextDelta(", world")
        session.appendThinkingDelta("Reasoning")
        session.appendThinkingDelta(" continues")

        #expect(session.messages.count == 2)
        #expect(session.messages.last?.text == "Hello, world")
        #expect(session.turnState.thinkingText == "Reasoning continues")
    }

    @Test func activityItemsProgressCorrectly() async throws {
        let session = ThreadSession(threadID: "thread-1", title: "Thread")

        session.startActivity(id: "tool-1", kind: .tool, title: "xcodebuild", detail: "Launching")
        session.updateActivity(id: "tool-1", detail: "Streaming output")
        session.completeActivity(id: "tool-1")
        session.startActivity(id: "file-1", kind: .fileChange, title: "ContentView.swift", detail: "Editing")
        session.completeActivity(id: "file-1", status: .completed, detail: "Applied patch")

        #expect(session.activityItems.count == 2)
        #expect(session.activityItems[0].detail == "Streaming output")
        #expect(session.activityItems[0].status == .completed)
        #expect(session.activityItems[1].kind == .fileChange)
        #expect(session.activityItems[1].status == .completed)
    }

    @Test func approvalQueueHandlesResolveDuplicateAndStaleCases() async throws {
        let session = ThreadSession(threadID: "thread-1", title: "Thread")
        let request = ApprovalRequest(id: "approval-1", kind: .command, title: "Run command", detail: "swift test")

        session.enqueueApprovalRequest(request)
        session.enqueueApprovalRequest(request)
        session.resolveApprovalRequest(id: "approval-1", resolution: .approved)
        session.resolveApprovalRequest(id: "approval-1", resolution: .stale)

        #expect(session.pendingApprovals.isEmpty)
    }

    @Test func planAndDiffReplacementUpdatesSessionState() async throws {
        let session = ThreadSession(threadID: "thread-1", title: "Thread")
        let plan = PlanState(
            summary: "Ship the feature",
            steps: [PlanStep(id: "step-1", title: "Implement", status: .inProgress)]
        )
        let diff = AggregatedDiff(
            summary: "One file changed",
            files: [DiffFileChange(id: "diff-1", path: "AtelierCode/ContentView.swift", additions: 20, deletions: 5)]
        )

        session.replacePlanState(plan)
        session.replaceAggregatedDiff(diff)

        #expect(session.planState == plan)
        #expect(session.aggregatedDiff == diff)
    }

    @Test func turnCompletionCancellationAndFailureCleanUpVolatileState() async throws {
        let session = ThreadSession(threadID: "thread-1", title: "Thread")

        session.beginTurn()
        session.startActivity(id: "tool-1", kind: .tool, title: "xcodebuild")
        session.enqueueApprovalRequest(ApprovalRequest(id: "approval-1", kind: .command, title: "Run", detail: "xcodebuild"))
        session.completeTurn()
        #expect(session.turnState.phase == .completed)
        #expect(session.pendingApprovals.isEmpty)

        session.beginTurn()
        session.startActivity(id: "tool-2", kind: .tool, title: "swift test")
        session.replacePlanState(PlanState(summary: nil, steps: [PlanStep(id: "step-1", title: "Run tests", status: .inProgress)]))
        session.cancelTurn()
        #expect(session.turnState.phase == .cancelled)
        #expect(session.activityItems.allSatisfy { $0.status == .cancelled })
        #expect(session.planState == nil)

        session.beginTurn()
        session.startActivity(id: "tool-3", kind: .tool, title: "Build")
        session.replaceAggregatedDiff(AggregatedDiff(summary: "Temp", files: []))
        session.failTurn("Bridge disconnected")
        #expect(session.turnState.phase == .failed)
        #expect(session.turnState.failureDescription == "Bridge disconnected")
        #expect(session.activityItems.allSatisfy { $0.status == .failed || $0.status == .cancelled })
        #expect(session.aggregatedDiff == nil)

        session.clearVolatilePerTurnState()
        #expect(session.turnState.phase == .idle)
        #expect(session.activityItems.isEmpty)
        #expect(session.pendingApprovals.isEmpty)
        #expect(session.planState == nil)
    }
}
