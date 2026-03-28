    import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct WorkspaceBridgeRuntimeTests {
    @Test func startupHandshakeBootstrapsWorkspaceState() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-bootstrap"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [
            "bridge is warming up",
            startupRecordJSON(port: 4242)
        ])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_in", displayName: "chatgpt (pro)"),
            modelListResultJSON(requestID: "ateliercode-model-list"),
            rateLimitUpdatedJSON(requestID: "ateliercode-account-read-2"),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Bootstrap Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.threadSummaries.count == 1 }

        #expect(controller.bridgeLifecycleState == .idle)
        #expect(controller.connectionStatus == .ready)
        #expect(controller.authState == .signedIn(accountDescription: "chatgpt (pro)"))
        #expect(controller.rateLimitState?.buckets.count == 1)
        #expect(controller.threadSummaries.map(\.title) == ["Bootstrap Thread"])
        #expect(controller.availableModels.first?.id == "gpt-5.4")
        #expect(controller.availableModels.first?.defaultReasoningEffort == .medium)
        #expect(controller.bridgeEnvironmentDiagnostics == WorkspaceBridgeEnvironmentDiagnostics(
            source: .loginProbe,
            shellPath: "/bin/zsh",
            probeError: nil,
            pathDirectoryCount: 5,
            homeDirectory: "/Users/tester"
        ))
        let sentMessageTypes = sentMessageTypes(from: socketClient.sentTexts)
        #expect(sentMessageTypes.contains("hello"))
        #expect(sentMessageTypes.contains("account.read"))
        #expect(sentMessageTypes.contains("model.list"))
        #expect(sentMessageTypes.contains("thread.list"))
    }

    @Test func modelListErrorsDoNotPoisonWorkspaceConnection() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-model-list-error"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4246)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            modelListErrorJSON(requestID: "ateliercode-model-list", message: "model/list is unavailable"),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready && controller.threadSummaries.count == 1 }

        #expect(controller.connectionStatus == .ready)
        #expect(controller.availableModels.isEmpty)
    }

    @Test func providerStatusUpdatesEnvironmentWarningAndExecutablePath() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-provider-status"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4244)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready }

        socketClient.enqueue(
            providerStatusJSON(
                status: "ready",
                detail: "Codex is ready.",
                executablePath: "/opt/homebrew/bin/codex",
                environmentSource: "fallback",
                probeError: "Shell environment probe timed out after 3000ms."
            )
        )
        try await waitUntil {
            controller.providerExecutablePath == "/opt/homebrew/bin/codex"
                && controller.bridgeEnvironmentDiagnostics?.source == .fallback
        }

        #expect(controller.providerExecutablePath == "/opt/homebrew/bin/codex")
        #expect(controller.bridgeEnvironmentDiagnostics == WorkspaceBridgeEnvironmentDiagnostics(
            source: .fallback,
            shellPath: "/bin/zsh",
            probeError: "Shell environment probe timed out after 3000ms.",
            pathDirectoryCount: 3,
            homeDirectory: "/Users/tester"
        ))
        #expect(controller.bridgeEnvironmentWarningMessage?.contains("fallback PATH entries") == true)
    }

    @Test func archivingPristineThreadStaysLocalAndAvoidsRolloutErrors() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-pristine-archive"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4243)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready }

        let startTask = Task { try await runtime.startThreadAndWait(title: "New Thread") }
        try await waitUntil { pendingCommandCount(in: runtime) == 1 }
        socketClient.enqueue(threadStartedJSON(requestID: "ateliercode-thread-start-4", threadID: "thread-1", threadTitle: "New Thread"))

        let session = try await startTask.value
        let sentCountBeforeArchive = socketClient.sentTexts.count

        try await runtime.archiveThread(id: session.threadID)

        #expect(session.messages.isEmpty)
        #expect(controller.threadSummary(id: session.threadID)?.isArchived == true)
        #expect(controller.connectionStatus == .ready)
        #expect(socketClient.sentTexts.count == sentCountBeforeArchive)
    }

    @Test func accountLoginResultOpensBrowserAndClearsPendingStateOnAuthChange() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-login"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4343)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        var openedURLs: [URL] = []
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { openedURLs.append($0) }
        )

        try await runtime.start()
        try await runtime.login()
        socketClient.enqueue(
            accountLoginResultJSON(
                requestID: "ateliercode-account-login-4",
                authURL: "https://example.com/login",
                loginID: "login-42"
            )
        )
        try await waitUntil { controller.pendingLogin != nil }

        #expect(openedURLs == [URL(string: "https://example.com/login")!])
        #expect(controller.pendingLogin == PendingLogin(
            method: .chatgpt,
            authURL: URL(string: "https://example.com/login")!,
            loginID: "login-42"
        ))

        socketClient.enqueue(authChangedJSON(requestID: nil, state: "signed_in", displayName: "chatgpt (pro)"))
        try await waitUntil { controller.pendingLogin == nil && controller.authState == .signedIn(accountDescription: "chatgpt (pro)") }

        #expect(controller.pendingLogin == nil)
        #expect(controller.authState == .signedIn(accountDescription: "chatgpt (pro)"))
    }

    @Test func signedOutAuthClearsRateLimitsAndAccountCommandEntries() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-signed-out"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4545)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_in", displayName: "chatgpt (pro)"),
            rateLimitUpdatedJSON(requestID: "ateliercode-account-read-2"),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil {
            controller.rateLimitState?.buckets.count == 1
                && controller.threadSummaries.count == 1
                && pendingCommandCount(in: runtime) == 0
        }

        #expect(controller.rateLimitState?.buckets.count == 1)
        #expect(controller.threadSummaries.count == 1)
        #expect(pendingCommandCount(in: runtime) == 0)

        try await runtime.refreshAccount()
        #expect(pendingCommandCount(in: runtime) == 1)
        socketClient.enqueue(authChangedJSON(requestID: "ateliercode-account-read-4", state: "signed_out", displayName: nil))
        try await waitUntil { controller.authState == .signedOut && pendingCommandCount(in: runtime) == 0 }

        #expect(controller.authState == .signedOut)
        #expect(controller.rateLimitState == nil)
        #expect(pendingCommandCount(in: runtime) == 0)

        try await runtime.logout()
        #expect(pendingCommandCount(in: runtime) == 1)
        socketClient.enqueue(authChangedJSON(requestID: "ateliercode-account-logout-5", state: "signed_out", displayName: nil))
        try await waitUntil { pendingCommandCount(in: runtime) == 0 }

        #expect(controller.rateLimitState == nil)
        #expect(pendingCommandCount(in: runtime) == 0)
    }

    @Test func successfulCancelAndApprovalFlowsDrainPendingCommands() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-pending-cleanup"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4646)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready && pendingCommandCount(in: runtime) == 0 }

        let session = controller.openThread(id: "thread-1", title: "Thread")
        session.enqueueApprovalRequest(
            ApprovalRequest(
                id: "approval-1",
                kind: .generic,
                title: "Approve",
                detail: "Please approve",
                command: nil,
                files: [],
                riskLevel: nil
            )
        )

        try await runtime.startTurn(prompt: "Ship it")
        #expect(pendingCommandCount(in: runtime) == 1)
        socketClient.enqueue(turnStartedJSON(requestID: "ateliercode-turn-start-4", threadID: "thread-1", turnID: "turn-1"))
        try await waitUntil { pendingCommandCount(in: runtime) == 0 && controller.connectionStatus == .streaming }

        #expect(pendingCommandCount(in: runtime) == 0)

        try await runtime.cancelTurn()
        #expect(pendingCommandCount(in: runtime) == 1)
        socketClient.enqueue(turnCompletedJSON(threadID: "thread-1", turnID: "turn-1", status: "cancelled"))
        try await waitUntil { pendingCommandCount(in: runtime) == 0 && session.turnState.phase == .cancelled }

        #expect(pendingCommandCount(in: runtime) == 0)

        let resolveTask = Task {
            try await runtime.resolveApproval(id: "approval-1", resolution: .approved)
        }
        try await waitUntil { pendingCommandCount(in: runtime) == 1 }
        socketClient.enqueue(
            approvalResolvedJSON(
                requestID: "ateliercode-approval-resolve-6",
                threadID: "thread-1",
                turnID: "turn-1",
                approvalID: "approval-1",
                resolution: "approved"
            )
        )
        try await resolveTask.value
        try await waitUntil { pendingCommandCount(in: runtime) == 0 && session.pendingApprovals.isEmpty }

        #expect(pendingCommandCount(in: runtime) == 0)
        #expect(approvalResolvePayload(from: socketClient.sentTexts.last) == ["approvalID": "approval-1", "resolution": "approved"])
    }

    @Test func structuredTurnEventsPopulateRichSessionState() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-structured-turn"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4666)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready }

        let session = controller.openThread(id: "thread-1", title: "Thread")

        try await runtime.startTurn(prompt: "Inspect the current turn")
        socketClient.enqueue(turnStartedJSON(requestID: "ateliercode-turn-start-4", threadID: "thread-1", turnID: "turn-1"))
        socketClient.enqueue(messageDeltaJSON(threadID: "thread-1", turnID: "turn-1", itemID: "assistant-1", delta: "Checking the transcript."))
        socketClient.enqueue(thinkingDeltaJSON(threadID: "thread-1", turnID: "turn-1", delta: "Checking the streamed reasoning."))
        socketClient.enqueue(toolStartedJSON(
            threadID: "thread-1",
            turnID: "turn-1",
            activityID: "tool-1",
            title: "Run tests",
            detail: "Checking the session state.",
            command: "swift test",
            workingDirectory: workspace.canonicalPath
        ))
        socketClient.enqueue(toolOutputJSON(threadID: "thread-1", turnID: "turn-1", activityID: "tool-1", delta: "Compiling...\n"))
        socketClient.enqueue(toolCompletedJSON(
            threadID: "thread-1",
            turnID: "turn-1",
            activityID: "tool-1",
            status: "completed",
            detail: "All tests passed.",
            exitCode: 0
        ))
        socketClient.enqueue(messageDeltaJSON(threadID: "thread-1", turnID: "turn-1", itemID: "assistant-2", delta: "I have the tool result."))
        socketClient.enqueue(fileChangeStartedJSON(
            threadID: "thread-1",
            turnID: "turn-1",
            activityID: "file-1",
            title: "AtelierCode/ContentView.swift",
            detail: "Preparing the patch."
        ))
        socketClient.enqueue(fileChangeCompletedJSON(
            threadID: "thread-1",
            turnID: "turn-1",
            activityID: "file-1",
            status: "completed",
            detail: "Applied the patch."
        ))
        socketClient.enqueue(approvalRequestedJSON(threadID: "thread-1", turnID: "turn-1", approvalID: "approval-1", workspacePath: workspace.canonicalPath))
        socketClient.enqueue(planUpdatedJSON(threadID: "thread-1", turnID: "turn-1"))
        socketClient.enqueue(diffUpdatedJSON(threadID: "thread-1", turnID: "turn-1"))

        try await waitUntil {
            session.turnItems.count == 5 &&
            session.pendingApprovals.count == 1 &&
            session.planState != nil &&
            session.aggregatedDiff != nil
        }

        #expect(session.messages.map(\.text) == ["Inspect the current turn"])
        #expect(session.turnItems.map(\.id) == ["assistant-1", "reasoning-turn-1", "tool-1", "assistant-2", "file-1"])
        #expect(session.turnItems.map(\.kind) == [.assistant, .reasoning, .tool, .assistant, .fileChange])
        #expect(session.turnItems[0].text == "Checking the transcript.")
        #expect(session.turnItems[1].text == "Checking the streamed reasoning.")
        #expect(session.turnItems[2].command == "swift test")
        #expect(session.turnItems[2].workingDirectory == workspace.canonicalPath)
        #expect(session.turnItems[2].output == "Compiling...\n")
        #expect(session.turnItems[2].exitCode == 0)
        #expect(session.turnItems[3].text == "I have the tool result.")
        #expect(session.turnItems[4].files == [
            DiffFileChange(id: "AtelierCode/ContentView.swift", path: "AtelierCode/ContentView.swift", additions: 4, deletions: 1)
        ])
        #expect(session.pendingApprovals[0].command == ApprovalCommandContext(command: "xcodebuild test -scheme AtelierCode", workingDirectory: workspace.canonicalPath))
        #expect(session.pendingApprovals[0].files == [
            DiffFileChange(id: "AtelierCode/ContentView.swift", path: "AtelierCode/ContentView.swift", additions: 4, deletions: 1)
        ])
        #expect(session.pendingApprovals[0].riskLevel == .medium)
        #expect(session.planState == PlanState(
            summary: "Wrap up phase 2.",
            steps: [
                PlanStep(id: "step-0", title: "Preserve structured activity", status: .completed),
                PlanStep(id: "step-1", title: "Render grouped turn sections", status: .inProgress)
            ]
        ))
        #expect(session.aggregatedDiff == AggregatedDiff(
            summary: "1 file changed",
            files: [DiffFileChange(id: "AtelierCode/ContentView.swift", path: "AtelierCode/ContentView.swift", additions: 4, deletions: 1)]
        ))
    }

    @Test func activityStartedBeforeTurnStartedRemainsVisible() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-early-activity"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4671)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready }

        let session = controller.openThread(id: "thread-1", title: "Thread")

        try await runtime.startTurn(prompt: "Inspect the early tool state")
        #expect(session.messages.map(\.text) == ["Inspect the early tool state"])
        #expect(session.turnState.phase == .inProgress)

        socketClient.enqueue(toolStartedJSON(
            threadID: "thread-1",
            turnID: "turn-1",
            activityID: "tool-1",
            title: "Read Files",
            detail: "Scanning the workspace.",
            command: "rg --files -g '*.swift' .",
            workingDirectory: workspace.canonicalPath
        ))

        try await waitUntil {
            session.turnItems.count == 1 &&
            session.turnItems[0].id == "tool-1" &&
            controller.connectionStatus == .streaming &&
            controller.isAwaitingTurnStart == false
        }

        #expect(session.turnItems[0].status == .running)
        #expect(session.turnItems[0].title == "Read Files")
        #expect(session.turnItems[0].command == "rg --files -g '*.swift' .")

        socketClient.enqueue(turnStartedJSON(requestID: "ateliercode-turn-start-4", threadID: "thread-1", turnID: "turn-1"))

        try await waitUntil {
            pendingCommandCount(in: runtime) == 0 &&
            session.turnItems.count == 1 &&
            session.turnItems[0].id == "tool-1"
        }

        #expect(session.turnItems[0].status == .running)
    }

    @Test func toolOutputStartsPlaceholderActivityWhenStartedEventIsMissing() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-tool-output-placeholder"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4668)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready }

        let session = controller.openThread(id: "thread-1", title: "Thread")

        try await runtime.startTurn(prompt: "Inspect output fallback")
        socketClient.enqueue(turnStartedJSON(requestID: "ateliercode-turn-start-4", threadID: "thread-1", turnID: "turn-1"))
        socketClient.enqueue(toolOutputJSON(threadID: "thread-1", turnID: "turn-1", activityID: "tool-1", delta: "Streaming...\n"))

        try await waitUntil {
            session.turnItems.count == 1 &&
            session.turnItems[0].id == "tool-1" &&
            session.turnItems[0].status == .running
        }

        #expect(session.turnItems[0].title == "Tool Call")
        #expect(session.turnItems[0].output == "Streaming...\n")

        socketClient.enqueue(toolCompletedJSON(
            threadID: "thread-1",
            turnID: "turn-1",
            activityID: "tool-1",
            status: "completed",
            detail: "Finished.",
            exitCode: 0
        ))

        try await waitUntil {
            session.turnItems[0].status == .completed && session.turnItems[0].detail == "Finished."
        }

        #expect(session.turnItems[0].status == .completed)
        #expect(session.turnItems[0].detail == "Finished.")
    }

    @Test func fastToolCompletionStaysRunningLongEnoughToRender() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-fast-tool-visible"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4669)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let sleepGate = SleepGate()
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in },
            minimumVisibleRunningActivityDuration: 0.2,
            sleep: { _ in await sleepGate.wait() }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready }

        let session = controller.openThread(id: "thread-1", title: "Thread")

        try await runtime.startTurn(prompt: "Make the spinner visible")
        socketClient.enqueue(turnStartedJSON(requestID: "ateliercode-turn-start-4", threadID: "thread-1", turnID: "turn-1"))
        socketClient.enqueue(toolStartedJSON(
            threadID: "thread-1",
            turnID: "turn-1",
            activityID: "tool-1",
            title: "Read Files",
            detail: "Scanning the workspace.",
            command: "rg --files",
            workingDirectory: workspace.canonicalPath
        ))

        try await waitUntil {
            session.turnItems.count == 1 && session.turnItems[0].status == .running
        }

        socketClient.enqueue(toolCompletedJSON(
            threadID: "thread-1",
            turnID: "turn-1",
            activityID: "tool-1",
            status: "completed",
            detail: "Finished reading files.",
            exitCode: 0
        ))

        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(session.turnItems[0].status == .running)

        await sleepGate.open()

        try await waitUntil {
            session.turnItems[0].status == .completed &&
            session.turnItems[0].detail == "Finished reading files."
        }

        #expect(session.turnItems[0].status == .completed)
    }

    @Test func completedTurnArchivesAssistantTranscriptAndCancelledTurnKeepsInlineRows() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-inline-turn-terminal"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4667)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready }

        let session = controller.openThread(id: "thread-1", title: "Thread")

        try await runtime.startTurn(prompt: "Ship it")
        socketClient.enqueue(turnStartedJSON(requestID: "ateliercode-turn-start-4", threadID: "thread-1", turnID: "turn-1"))
        socketClient.enqueue(messageDeltaJSON(threadID: "thread-1", turnID: "turn-1", itemID: "assistant-1", delta: "First"))
        socketClient.enqueue(toolStartedJSON(
            threadID: "thread-1",
            turnID: "turn-1",
            activityID: "tool-1",
            title: "Run tests",
            detail: "Preparing",
            command: "swift test",
            workingDirectory: workspace.canonicalPath
        ))
        socketClient.enqueue(messageDeltaJSON(threadID: "thread-1", turnID: "turn-1", itemID: "assistant-2", delta: " reply"))
        socketClient.enqueue(turnCompletedJSON(threadID: "thread-1", turnID: "turn-1", status: "completed"))

        try await waitUntil {
            session.turnState.phase == .completed &&
            session.messages.map(\.text) == ["Ship it", "First reply"]
        }

        #expect(session.messages.map(\.text) == ["Ship it", "First reply"])
        #expect(session.turnItems.map(\.kind) == [.assistant, .tool, .assistant])
        #expect(session.turnItems.map(\.status) == [.completed, .completed, .completed])

        try await runtime.startTurn(prompt: "Cancel it")
        socketClient.enqueue(turnStartedJSON(requestID: "ateliercode-turn-start-5", threadID: "thread-1", turnID: "turn-2"))
        socketClient.enqueue(messageDeltaJSON(threadID: "thread-1", turnID: "turn-2", itemID: "assistant-3", delta: "Partial"))
        socketClient.enqueue(toolStartedJSON(
            threadID: "thread-1",
            turnID: "turn-2",
            activityID: "tool-2",
            title: "Patch files",
            detail: "Applying changes",
            command: "apply_patch",
            workingDirectory: workspace.canonicalPath
        ))
        socketClient.enqueue(turnCompletedJSON(threadID: "thread-1", turnID: "turn-2", status: "cancelled"))

        try await waitUntil {
            session.turnState.phase == .cancelled &&
            session.turnItems.count == 2
        }

        #expect(session.messages.map(\.text) == ["Ship it", "First reply", "Cancel it"])
        #expect(session.turnItems.map(\.status) == [.cancelled, .cancelled])
        #expect(session.turnItems.map(\.kind) == [.assistant, .tool])
    }

    @Test func startThreadAndWaitReturnsCreatedSession() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-thread-start"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4747)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready }

        async let session = runtime.startThreadAndWait()
        try await waitUntil { pendingThreadStartCount(in: runtime) == 1 }

        socketClient.enqueue(threadStartedJSON(
            requestID: "ateliercode-thread-start-4",
            threadID: "thread-42",
            threadTitle: "Fresh Thread"
        ))

        let startedSession = try await session

        #expect(startedSession.threadID == "thread-42")
        #expect(startedSession.title == "Fresh Thread")
        #expect(controller.activeThreadSession?.threadID == "thread-42")
    }

    @Test func paginatedThreadListAccumulatesAcrossPagesBeforeReplacingSidebarState() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-thread-pages"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4746)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Bootstrap")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready }

        try await runtime.listThreads(archived: false)
        try await waitUntil { pendingCommandCount(in: runtime) == 1 }

        socketClient.enqueue(
            threadListResultJSON(
                requestID: "ateliercode-thread-list-4",
                threads: [
                    (id: "thread-10", title: "First Page", previewText: "Preview 1", updatedAt: "2026-03-24T10:00:10Z")
                ],
                nextCursor: "cursor-2"
            )
        )

        try await waitUntil {
            pendingCommandCount(in: runtime) == 1 &&
                commandPayload(from: socketClient.sentTexts.last)?["cursor"] as? String == "cursor-2"
        }

        socketClient.enqueue(
            threadListResultJSON(
                requestID: "ateliercode-thread-list-5",
                threads: [
                    (id: "thread-11", title: "Second Page", previewText: "Preview 2", updatedAt: "2026-03-24T10:00:11Z")
                ]
            )
        )

        try await waitUntil {
            pendingCommandCount(in: runtime) == 0 &&
                Set(controller.threadSummaries.map(\.id)) == Set(["thread-10", "thread-11"])
        }

        #expect(Set(controller.threadSummaries.map(\.id)) == Set(["thread-10", "thread-11"]))
    }

    @Test func bridgeFailureDuringListRefreshPreservesCachedRowsAndMarksSyncFailed() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-thread-list-failure"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4745)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Bootstrap")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready && controller.threadSummaries.count == 1 }

        try await runtime.listThreads(archived: false)
        try await waitUntil { controller.threadListSyncState == .syncing }

        processHandle.exit(code: 9)

        try await waitUntil {
            controller.connectionStatus == .error(message: "The embedded bridge exited unexpectedly with status 9.") &&
                controller.threadListSyncState == .failed
        }

        #expect(controller.threadSummaries.map(\.id) == ["thread-1"])
        #expect(controller.threadSummary(id: "thread-1")?.title == "Bootstrap")
        #expect(controller.threadListSyncState == .failed)
    }

    @Test func renameThreadSendsCommandAndUpdatesLoadedSession() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-thread-rename"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4749)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready }

        let session = controller.openThread(id: "thread-1", title: "Thread")
        let renameTask = Task {
            try await runtime.renameThread(id: "thread-1", title: "Renamed Thread")
        }

        try await waitUntil {
            pendingCommandCount(in: runtime) == 1 &&
            latestCommandPayload(ofType: "thread.rename", from: socketClient.sentTexts)?["title"] as? String == "Renamed Thread"
        }

        #expect(latestCommandPayload(ofType: "thread.rename", from: socketClient.sentTexts)?["title"] as? String == "Renamed Thread")

        socketClient.enqueue(threadStartedJSON(
            requestID: "ateliercode-thread-rename-4",
            threadID: "thread-1",
            threadTitle: "Renamed Thread"
        ))

        try await renameTask.value
        try await waitUntil {
            controller.threadSummary(id: "thread-1")?.title == "Renamed Thread" &&
            session.title == "Renamed Thread" &&
            pendingCommandCount(in: runtime) == 0
        }

        #expect(controller.threadSummary(id: "thread-1")?.title == "Renamed Thread")
        #expect(session.title == "Renamed Thread")
    }

    @Test func cancelledStartThreadAndWaitIgnoresLateThreadStartedEvent() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-thread-cancel"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4748)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready }

        let sessionTask = Task { try await runtime.startThreadAndWait() }
        try await waitUntil { pendingThreadStartCount(in: runtime) == 1 }

        sessionTask.cancel()

        do {
            _ = try await sessionTask.value
            Issue.record("Expected startThreadAndWait cancellation.")
        } catch is CancellationError {
        }

        try await waitUntil { pendingThreadStartCount(in: runtime) == 0 && abandonedThreadRequestCount(in: runtime) == 1 }

        socketClient.enqueue(threadStartedJSON(
            requestID: "ateliercode-thread-start-4",
            threadID: "thread-late",
            threadTitle: "Late Thread"
        ))

        try await waitUntil { controller.threadSummaries.contains(where: { $0.id == "thread-late" }) }

        #expect(controller.activeThreadSession == nil)
        #expect(abandonedThreadRequestCount(in: runtime) == 0)
    }

    @Test func streamedMessageDeltasCollapseIntoSingleAssistantTranscriptMessage() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-stream"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4848)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        try await waitUntil { controller.connectionStatus == .ready }

        let session = controller.openThread(id: "thread-1", title: "Thread")

        try await runtime.startTurn(prompt: "Show the transcript")
        socketClient.enqueue(turnStartedJSON(requestID: "ateliercode-turn-start-4", threadID: "thread-1", turnID: "turn-1"))
        socketClient.enqueue(messageDeltaJSON(threadID: "thread-1", turnID: "turn-1", delta: "First chunk"))
        socketClient.enqueue(messageDeltaJSON(threadID: "thread-1", turnID: "turn-1", delta: " and second chunk"))
        socketClient.enqueue(turnCompletedJSON(threadID: "thread-1", turnID: "turn-1", status: "completed"))
        try await waitUntil { session.turnState.phase == .completed }

        #expect(session.messages.count == 2)
        #expect(session.messages[0].text == "Show the transcript")
        #expect(session.messages[1].text == "First chunk and second chunk")
        #expect(session.turnState.phase == .completed)
        #expect(controller.connectionStatus == .ready)
    }

    @Test func unexpectedBridgeExitMarksConnectionErrorAndFailsInFlightTurn() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-exit"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4444)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = makeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        let session = controller.openThread(id: "thread-1", title: "Thread")
        session.beginTurn(userPrompt: "Keep going")
        controller.setConnectionStatus(.streaming)

        processHandle.exit(code: 9)
        try await waitUntil {
            controller.connectionStatus == .error(message: "The embedded bridge exited unexpectedly with status 9.") &&
            session.turnState.phase == .failed
        }

        #expect(controller.connectionStatus == .error(message: "The embedded bridge exited unexpectedly with status 9."))
        #expect(session.turnState.phase == .failed)
        #expect(session.turnState.failureDescription == "The embedded bridge exited unexpectedly with status 9.")
    }
}

private final class FakeBridgeProcessHandle: BridgeProcessHandle {
    var onExit: (@Sendable (Int32?) -> Void)?
    let stdoutLines: AsyncThrowingStream<String, Error>

    private let continuation: AsyncThrowingStream<String, Error>.Continuation

    init(lines: [String]) {
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        stdoutLines = AsyncThrowingStream<String, Error> { continuation = $0 }
        self.continuation = continuation

        for line in lines {
            continuation.yield(line)
        }
    }

    func terminate() {
        continuation.finish()
        onExit?(0)
    }

    func exit(code: Int32?) {
        continuation.finish()
        onExit?(code)
    }
}

private final class FakeBridgeSocketClient: BridgeSocketClient {
    private let stream: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator

    private(set) var sentTexts: [String] = []

    init(messages: [String]) {
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        stream = AsyncThrowingStream<String, Error> { continuation = $0 }
        self.continuation = continuation
        iterator = stream.makeAsyncIterator()

        for message in messages {
            continuation.yield(message)
        }
    }

    func connect() async throws {}

    func send(text: String) async throws {
        sentTexts.append(text)
    }

    func receiveText() async throws -> String {
        guard let message = try await iterator.next() else {
            throw CancellationError()
        }

        return message
    }

    func close() {
        continuation.finish()
    }

    func enqueue(_ message: String) {
        continuation.yield(message)
    }
}

private actor SleepGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

@MainActor
private func makeRuntime(
    controller: WorkspaceController,
    executableLocator: BridgeExecutableLocator? = nil,
    processLauncher: ((URL) throws -> any BridgeProcessHandle)? = nil,
    socketFactory: ((URL) -> any BridgeSocketClient)? = nil,
    openURLAction: ((URL) -> Void)? = nil,
    appVersion: String? = nil,
    minimumVisibleRunningActivityDuration: TimeInterval = 0,
    now: @escaping () -> Date = Date.init,
    sleep: WorkspaceBridgeRuntime.SleepAction? = nil
) -> WorkspaceBridgeRuntime {
    WorkspaceBridgeRuntime(
        controller: controller,
        executableLocator: executableLocator,
        processLauncher: processLauncher,
        socketFactory: socketFactory,
        openURLAction: openURLAction,
        appVersion: appVersion,
        minimumVisibleRunningActivityDuration: minimumVisibleRunningActivityDuration,
        now: now,
        sleep: sleep
    )
}

private func bridgeFixtureBundle() throws -> Bundle {
    let appBundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("Fixture.app", isDirectory: true)
    let executableURL = appBundleURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("MacOS", isDirectory: true)
        .appendingPathComponent(BridgeExecutableLocator.executableName, isDirectory: false)

    try FileManager.default.createDirectory(
        at: executableURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: executableURL.path, contents: Data())

    return try #require(Bundle(url: appBundleURL))
}

private func startupRecordJSON(port: Int) -> String {
    """
    {"recordType":"bridge.startup","bridgeVersion":"0.1.0","protocolVersion":1,"transport":"websocket","host":"127.0.0.1","port":\(port),"pid":999,"startedAt":"2026-03-24T10:00:00Z"}
    """
}

private func welcomeJSON(requestID: String) -> String {
    """
    {"type":"welcome","timestamp":"2026-03-24T10:00:01Z","requestID":"\(requestID)","payload":{"bridgeVersion":"0.1.0","protocolVersion":1,"supportedProtocolVersions":[1],"sessionID":"session-1","transport":"websocket","providers":[{"id":"codex","displayName":"Codex","status":"available","capabilities":{"supportsThreadLifecycle":true,"supportsThreadArchiving":true,"supportsApprovals":true,"supportsAuthentication":true,"supportedModes":["default"]}}],"environment":{"source":"login_probe","shellPath":"/bin/zsh","probeError":null,"pathDirectoryCount":5,"homeDirectory":"/Users/tester"}}}
    """
}

private func providerStatusJSON(
    status: String,
    detail: String,
    executablePath: String? = nil,
    environmentSource: String? = nil,
    probeError: String? = nil
) -> String {
    let executableFragment = executablePath.map { "\"executablePath\":\"\(jsonEscaped($0))\"," } ?? ""
    let environmentFragment: String
    if let environmentSource {
        let probeErrorJSON = probeError.map { "\"\(jsonEscaped($0))\"" } ?? "null"
        environmentFragment = """
        "environment":{"source":"\(environmentSource)","shellPath":"/bin/zsh","probeError":\(probeErrorJSON),"pathDirectoryCount":3,"homeDirectory":"/Users/tester"}
        """
    } else {
        environmentFragment = "\"environment\":null"
    }

    return """
    {"type":"provider.status","timestamp":"2026-03-24T10:00:06Z","provider":"codex","payload":{"status":"\(status)","detail":"\(jsonEscaped(detail))",\(executableFragment)\(environmentFragment)}}
    """
}

private func authChangedJSON(requestID: String?, state: String, displayName: String?) -> String {
    let requestFragment = requestID.map { "\"requestID\":\"\($0)\"," } ?? ""
    let accountFragment = displayName.map { "\"account\":{\"displayName\":\"\($0)\"}" } ?? "\"account\":null"
    return """
    {"type":"auth.changed","timestamp":"2026-03-24T10:00:02Z",\(requestFragment)"payload":{"state":"\(state)",\(accountFragment)}}
    """
}

private func rateLimitUpdatedJSON(requestID: String) -> String {
    """
    {"type":"rateLimit.updated","timestamp":"2026-03-24T10:00:03Z","requestID":"\(requestID)","payload":{"accountID":"account-1","buckets":[{"id":"requests:primary","kind":"requests","detail":"Requests: 10% used"}]}}
    """
}

private func modelListResultJSON(requestID: String) -> String {
    """
    {"type":"model.list.result","timestamp":"2026-03-24T10:00:03Z","requestID":"\(requestID)","payload":{"models":[{"id":"gpt-5.4","model":"gpt-5.4","displayName":"GPT-5.4","hidden":false,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Lower latency"},{"reasoningEffort":"medium","description":"Balanced"},{"reasoningEffort":"high","description":"More reasoning"}],"inputModalities":["text","image"],"supportsPersonality":true,"isDefault":true}]}}
    """
}

private func modelListErrorJSON(requestID: String, message: String) -> String {
    """
    {"type":"error","timestamp":"2026-03-24T10:00:03Z","requestID":"\(requestID)","payload":{"code":"provider_command_failed","message":"\(jsonEscaped(message))"}}
    """
}

private func threadListResultJSON(requestID: String, threadTitle: String) -> String {
    """
    {"type":"thread.list.result","timestamp":"2026-03-24T10:00:04Z","requestID":"\(requestID)","payload":{"threads":[{"id":"thread-1","providerID":"codex","title":"\(threadTitle)","previewText":"Preview","updatedAt":"2026-03-24T10:00:04Z","archived":false,"running":false,"errorMessage":null}],"nextCursor":null}}
    """
}

private func threadListResultJSON(
    requestID: String,
    threads: [(id: String, title: String, previewText: String, updatedAt: String)],
    nextCursor: String? = nil
) -> String {
    let threadsJSON = threads.map { thread in
        """
        {"id":"\(thread.id)","providerID":"codex","title":"\(jsonEscaped(thread.title))","previewText":"\(jsonEscaped(thread.previewText))","updatedAt":"\(thread.updatedAt)","archived":false,"running":false,"errorMessage":null}
        """
    }.joined(separator: ",")
    let nextCursorJSON = nextCursor.map { "\"\(jsonEscaped($0))\"" } ?? "null"

    return """
    {"type":"thread.list.result","timestamp":"2026-03-24T10:00:04Z","requestID":"\(requestID)","payload":{"threads":[\(threadsJSON)],"nextCursor":\(nextCursorJSON)}}
    """
}

private func accountLoginResultJSON(requestID: String, authURL: String, loginID: String) -> String {
    """
    {"type":"account.login.result","timestamp":"2026-03-24T10:00:05Z","requestID":"\(requestID)","payload":{"method":"chatgpt","authURL":"\(authURL)","loginID":"\(loginID)"}}
    """
}

private func turnStartedJSON(requestID: String, threadID: String, turnID: String) -> String {
    """
    {"type":"turn.started","timestamp":"2026-03-24T10:00:06Z","requestID":"\(requestID)","threadID":"\(threadID)","turnID":"\(turnID)","payload":{"status":"in_progress"}}
    """
}

private func threadStartedJSON(requestID: String, threadID: String, threadTitle: String) -> String {
    """
    {"type":"thread.started","timestamp":"2026-03-24T10:00:05Z","requestID":"\(requestID)","threadID":"\(threadID)","payload":{"thread":{"id":"\(threadID)","providerID":"codex","title":"\(threadTitle)","previewText":"Preview","updatedAt":"2026-03-24T10:00:05Z","archived":false,"running":false,"errorMessage":null}}}
    """
}

private func messageDeltaJSON(threadID: String, turnID: String, itemID: String? = nil, delta: String) -> String {
    let itemFragment = itemID.map { "\"itemID\":\"\($0)\"," } ?? ""
    let messageID = itemID ?? "assistant-1"
    return """
    {"type":"message.delta","timestamp":"2026-03-24T10:00:06Z","threadID":"\(threadID)","turnID":"\(turnID)",\(itemFragment)"payload":{"messageID":"\(messageID)","delta":"\(jsonEscaped(delta))"}}
    """
}

private func thinkingDeltaJSON(threadID: String, turnID: String, delta: String) -> String {
    """
    {"type":"thinking.delta","timestamp":"2026-03-24T10:00:06Z","threadID":"\(threadID)","turnID":"\(turnID)","payload":{"delta":"\(jsonEscaped(delta))"}}
    """
}

private func toolStartedJSON(
    threadID: String,
    turnID: String,
    activityID: String,
    title: String,
    detail: String,
    command: String,
    workingDirectory: String
) -> String {
    """
    {"type":"tool.started","timestamp":"2026-03-24T10:00:06Z","threadID":"\(threadID)","turnID":"\(turnID)","activityID":"\(activityID)","payload":{"title":"\(jsonEscaped(title))","detail":"\(jsonEscaped(detail))","kind":"command","command":"\(jsonEscaped(command))","workingDirectory":"\(jsonEscaped(workingDirectory))"}}
    """
}

private func toolOutputJSON(threadID: String, turnID: String, activityID: String, delta: String) -> String {
    """
    {"type":"tool.output","timestamp":"2026-03-24T10:00:06Z","threadID":"\(threadID)","turnID":"\(turnID)","activityID":"\(activityID)","payload":{"stream":"combined","delta":"\(jsonEscaped(delta))"}}
    """
}

private func toolCompletedJSON(
    threadID: String,
    turnID: String,
    activityID: String,
    status: String,
    detail: String,
    exitCode: Int
) -> String {
    """
    {"type":"tool.completed","timestamp":"2026-03-24T10:00:06Z","threadID":"\(threadID)","turnID":"\(turnID)","activityID":"\(activityID)","payload":{"status":"\(status)","detail":"\(jsonEscaped(detail))","exitCode":\(exitCode)}}
    """
}

private func fileChangeStartedJSON(
    threadID: String,
    turnID: String,
    activityID: String,
    title: String,
    detail: String
) -> String {
    """
    {"type":"fileChange.started","timestamp":"2026-03-24T10:00:06Z","threadID":"\(threadID)","turnID":"\(turnID)","activityID":"\(activityID)","payload":{"title":"\(jsonEscaped(title))","detail":"\(jsonEscaped(detail))","files":[{"id":"AtelierCode/ContentView.swift","path":"AtelierCode/ContentView.swift","additions":4,"deletions":1}]}}
    """
}

private func fileChangeCompletedJSON(
    threadID: String,
    turnID: String,
    activityID: String,
    status: String,
    detail: String
) -> String {
    """
    {"type":"fileChange.completed","timestamp":"2026-03-24T10:00:06Z","threadID":"\(threadID)","turnID":"\(turnID)","activityID":"\(activityID)","payload":{"status":"\(status)","detail":"\(jsonEscaped(detail))","files":[{"id":"AtelierCode/ContentView.swift","path":"AtelierCode/ContentView.swift","additions":4,"deletions":1}]}}
    """
}

private func approvalRequestedJSON(threadID: String, turnID: String, approvalID: String, workspacePath: String) -> String {
    """
    {"type":"approval.requested","timestamp":"2026-03-24T10:00:06Z","threadID":"\(threadID)","turnID":"\(turnID)","payload":{"approvalID":"\(approvalID)","kind":"command","title":"Approve command execution","detail":"The command needs confirmation.","command":{"command":"xcodebuild test -scheme AtelierCode","workingDirectory":"\(jsonEscaped(workspacePath))"},"files":[{"id":"AtelierCode/ContentView.swift","path":"AtelierCode/ContentView.swift","additions":4,"deletions":1}],"riskLevel":"medium"}}
    """
}

private func approvalResolvedJSON(
    requestID: String,
    threadID: String,
    turnID: String,
    approvalID: String,
    resolution: String
) -> String {
    """
    {"type":"approval.resolved","timestamp":"2026-03-24T10:00:06Z","requestID":"\(requestID)","threadID":"\(threadID)","turnID":"\(turnID)","payload":{"approvalID":"\(approvalID)","resolution":"\(resolution)"}}
    """
}

private func planUpdatedJSON(threadID: String, turnID: String) -> String {
    """
    {"type":"plan.updated","timestamp":"2026-03-24T10:00:06Z","threadID":"\(threadID)","turnID":"\(turnID)","payload":{"summary":"Wrap up phase 2.","steps":[{"id":"step-0","title":"Preserve structured activity","status":"completed"},{"id":"step-1","title":"Render grouped turn sections","status":"in_progress"}]}}
    """
}

private func diffUpdatedJSON(threadID: String, turnID: String) -> String {
    """
    {"type":"diff.updated","timestamp":"2026-03-24T10:00:06Z","threadID":"\(threadID)","turnID":"\(turnID)","payload":{"summary":"1 file changed","files":[{"id":"AtelierCode/ContentView.swift","path":"AtelierCode/ContentView.swift","additions":4,"deletions":1}]}}
    """
}

private func turnCompletedJSON(threadID: String, turnID: String, status: String) -> String {
    """
    {"type":"turn.completed","timestamp":"2026-03-24T10:00:07Z","threadID":"\(threadID)","turnID":"\(turnID)","payload":{"status":"\(status)","detail":null}}
    """
}

private func approvalResolvePayload(from message: String?) -> [String: String]? {
    guard let payload = commandPayload(from: message) else {
        return nil
    }

    return [
        "approvalID": payload["approvalID"] as? String ?? "",
        "resolution": payload["resolution"] as? String ?? ""
    ]
}

private func pendingCommandCount(in runtime: WorkspaceBridgeRuntime) -> Int {
    guard let pendingCommands = Mirror(reflecting: runtime).children.first(where: { $0.label == "pendingCommands" })?.value else {
        return 0
    }

    return Mirror(reflecting: pendingCommands).children.count
}

private func pendingThreadStartCount(in runtime: WorkspaceBridgeRuntime) -> Int {
    let mirror = Mirror(reflecting: runtime)
    guard let pendingThreadStarts = mirror.children.first(where: { $0.label == "pendingThreadStarts" })?.value
        ?? mirror.children.first(where: { $0.label == "pendingThreadSessions" })?.value else {
        return 0
    }

    return Mirror(reflecting: pendingThreadStarts).children.count
}

private func abandonedThreadRequestCount(in runtime: WorkspaceBridgeRuntime) -> Int {
    guard let abandonedThreadRequests = Mirror(reflecting: runtime).children.first(where: { $0.label == "abandonedThreadRequestIDs" })?.value else {
        return 0
    }

    return Mirror(reflecting: abandonedThreadRequests).children.count
}

private func sentMessageTypes(from messages: [String]) -> [String] {
    messages.compactMap { message in
        guard let object = commandObject(from: message) else {
            return nil
        }

        return object["type"] as? String
    }
}

private func commandPayload(from message: String?) -> [String: Any]? {
    guard let message,
          let object = commandObject(from: message),
          let payload = object["payload"] as? [String: Any] else {
        return nil
    }

    return payload
}

private func latestCommandPayload(ofType type: String, from messages: [String]) -> [String: Any]? {
    for message in messages.reversed() {
        guard let object = commandObject(from: message),
              object["type"] as? String == type,
              let payload = object["payload"] as? [String: Any] else {
            continue
        }

        return payload
    }

    return nil
}

private func commandObject(from message: String) -> [String: Any]? {
    guard let data = message.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }

    return object
}

private func jsonEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollNanoseconds: UInt64 = 10_000_000,
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))

    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }

        try await Task.sleep(nanoseconds: pollNanoseconds)
    }

    Issue.record("Timed out waiting for test condition.")
}
