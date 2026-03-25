import Testing
@testable import AtelierCode

@MainActor
struct ThreadSessionTests {
    @Test func orderedTurnItemsUpdateInPlaceAsEventsArrive() async throws {
        let session = ThreadSession(threadID: "thread-1", title: "Thread")

        session.beginTurn(userPrompt: "Hello")
        session.appendAssistantTextDelta("Hello", itemID: "assistant-1")
        session.appendThinkingDelta("Reasoning", itemID: "reasoning-1")
        session.startActivity(id: "tool-1", kind: .tool, title: "swift test", detail: "Running")
        session.appendAssistantTextDelta(", world", itemID: "assistant-1")
        session.appendAssistantTextDelta("Follow-up", itemID: "assistant-2")
        session.appendThinkingDelta(" continues", itemID: "reasoning-1")

        #expect(session.messages.map(\.text) == ["Hello"])
        #expect(session.turnItems.map(\.id) == ["assistant-1", "reasoning-1", "tool-1", "assistant-2"])
        #expect(session.turnItems.map(\.kind) == [.assistant, .reasoning, .tool, .assistant])
        #expect(session.turnItems[0].text == "Hello, world")
        #expect(session.turnItems[1].text == "Reasoning continues")
        #expect(session.turnItems[2].detail == "Running")
        #expect(session.turnItems[3].text == "Follow-up")
    }

    @Test func activityItemsProgressCorrectly() async throws {
        let session = ThreadSession(threadID: "thread-1", title: "Thread")
        let changedFiles = [DiffFileChange(id: "diff-1", path: "AtelierCode/ContentView.swift", additions: 12, deletions: 3)]

        session.startActivity(
            id: "tool-1",
            kind: .tool,
            title: "xcodebuild",
            detail: "Launching",
            command: "xcodebuild test",
            workingDirectory: "/tmp/workspace"
        )
        session.updateActivity(id: "tool-1", detail: "Streaming output")
        session.appendActivityOutput(id: "tool-1", delta: "\nSecond chunk")
        session.completeActivity(id: "tool-1", detail: "Finished", exitCode: 0)
        session.startActivity(id: "file-1", kind: .fileChange, title: "ContentView.swift", detail: "Editing", files: changedFiles)
        session.completeActivity(id: "file-1", status: .completed, detail: "Applied patch", files: changedFiles)

        #expect(session.activityItems.count == 2)
        #expect(session.activityItems[0].detail == "Finished")
        #expect(session.activityItems[0].command == "xcodebuild test")
        #expect(session.activityItems[0].workingDirectory == "/tmp/workspace")
        #expect(session.activityItems[0].output == "\nSecond chunk")
        #expect(session.activityItems[0].status == .completed)
        #expect(session.activityItems[0].exitCode == 0)
        #expect(session.activityItems[1].kind == .fileChange)
        #expect(session.activityItems[1].files == changedFiles)
        #expect(session.activityItems[1].status == .completed)
        #expect(session.turnItems.map(\.kind) == [.tool, .fileChange])
    }

    @Test func transcriptPresentationGroupsContiguousActivityAndPreservesTurnOrdering() async throws {
        let presentation = TranscriptTurnPresentation(
            turnItems: [
                makeTurnItem(id: "assistant-1", kind: .assistant, text: "First"),
                makeTurnItem(id: "tool-1", kind: .tool, detail: "Preparing"),
                makeTurnItem(id: "tool-2", kind: .tool, detail: "Build failed", status: .failed),
                makeTurnItem(id: "reasoning-1", kind: .reasoning, text: "Thinking"),
                makeTurnItem(
                    id: "file-1",
                    kind: .fileChange,
                    title: "Patch",
                    detail: "Applying patch",
                    files: [DiffFileChange(id: "diff-1", path: "AtelierCode/ContentView.swift", additions: 4, deletions: 1)],
                    status: .running
                ),
                makeTurnItem(id: "assistant-2", kind: .assistant, text: "Second"),
                makeTurnItem(id: "tool-3", kind: .tool, title: "Run tests", detail: "Finished", status: .completed)
            ]
        )

        #expect(
            presentation.entries.map { entry in
                switch entry {
                case .item(let item):
                    return "item:\(item.id)"
                case .activitySection(let section):
                    return "section:\(section.kind.rawValue):\(section.items.map(\.id).joined(separator: ","))"
                }
            } == [
                "item:assistant-1",
                "section:tools:tool-1,tool-2",
                "item:reasoning-1",
                "section:fileChanges:file-1",
                "item:assistant-2",
                "section:tools:tool-3"
            ]
        )

        let sections = presentation.entries.compactMap { entry -> TranscriptActivitySection? in
            guard case let .activitySection(section) = entry else {
                return nil
            }

            return section
        }

        #expect(sections.map(\.kind) == [.tools, .fileChanges, .tools])
        #expect(sections.map(\.status) == [.failed, .running, .completed])
        #expect(sections.map(\.defaultExpanded) == [false, true, false])
        #expect(sections.map(\.summary) == ["Build failed", "Applying patch", "Finished"])
        #expect(sections.map(\.ordinal) == [1, 1, 2])
    }

    @Test func approvalQueueHandlesResolveDuplicateAndStaleCases() async throws {
        let session = ThreadSession(threadID: "thread-1", title: "Thread")
        let request = ApprovalRequest(
            id: "approval-1",
            kind: .command,
            title: "Run command",
            detail: "swift test",
            command: ApprovalCommandContext(command: "swift test", workingDirectory: "/tmp/workspace"),
            files: [DiffFileChange(id: "diff-1", path: "Package.swift", additions: 1, deletions: 0)],
            riskLevel: .medium
        )

        session.enqueueApprovalRequest(request)
        session.enqueueApprovalRequest(request)

        #expect(session.pendingApprovals == [request])
        #expect(session.beginApprovalResolution(id: "approval-1", resolution: .approved))
        #expect(session.pendingApprovals.first?.pendingResolution == .approved)
        #expect(session.beginApprovalResolution(id: "approval-1", resolution: .declined) == false)

        session.clearApprovalResolution(id: "approval-1")
        #expect(session.pendingApprovals.first?.pendingResolution == nil)

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
        session.appendAssistantTextDelta("First")
        session.appendAssistantTextDelta(" response", itemID: "assistant-2")
        session.startActivity(id: "tool-1", kind: .tool, title: "xcodebuild")
        session.enqueueApprovalRequest(
            ApprovalRequest(
                id: "approval-1",
                kind: .command,
                title: "Run",
                detail: "xcodebuild",
                command: nil,
                files: [],
                riskLevel: nil
            )
        )
        session.completeTurn()
        #expect(session.turnState.phase == .completed)
        #expect(session.pendingApprovals.isEmpty)
        #expect(session.turnItems.allSatisfy { $0.status == .completed })
        #expect(session.messages.last?.text == "First response")

        session.beginTurn()
        session.appendAssistantTextDelta("Partial")
        session.startActivity(id: "tool-2", kind: .tool, title: "swift test")
        session.replacePlanState(PlanState(summary: nil, steps: [PlanStep(id: "step-1", title: "Run tests", status: .inProgress)]))
        session.cancelTurn()
        #expect(session.turnState.phase == .cancelled)
        #expect(session.turnItems.allSatisfy { $0.status == .cancelled })
        #expect(session.planState == nil)

        session.beginTurn()
        session.appendThinkingDelta("Checking")
        session.startActivity(id: "tool-3", kind: .tool, title: "Build")
        session.replaceAggregatedDiff(AggregatedDiff(summary: "Temp", files: []))
        session.failTurn("Bridge disconnected")
        #expect(session.turnState.phase == .failed)
        #expect(session.turnState.failureDescription == "Bridge disconnected")
        #expect(session.turnItems.allSatisfy { $0.status == .failed || $0.status == .cancelled })
        #expect(session.aggregatedDiff == nil)

        session.clearVolatilePerTurnState()
        #expect(session.turnState.phase == .idle)
        #expect(session.turnItems.isEmpty)
        #expect(session.pendingApprovals.isEmpty)
        #expect(session.planState == nil)
    }
}

private func makeTurnItem(
    id: String,
    kind: TurnItemKind,
    title: String = "Item",
    text: String = "",
    detail: String? = nil,
    command: String? = nil,
    files: [DiffFileChange] = [],
    status: ActivityStatus = .completed
) -> TurnItem {
    TurnItem(
        id: id,
        kind: kind,
        title: title,
        text: text,
        detail: detail,
        command: command,
        workingDirectory: nil,
        output: "",
        files: files,
        status: status,
        exitCode: nil
    )
}
