import XCTest
@testable import Responder

final class ResponderTests: XCTestCase {
    func testContextManagerPreservesPromptLayerOrder() throws {
        let manager = ContextManager()
        let conversation = ConversationRef(
            id: "c1",
            title: "Alex",
            service: .iMessage,
            participants: [Participant(handle: "alex@example.com", displayName: "Alex", service: .iMessage)],
            isGroup: false,
            lastMessagePreview: "",
            lastMessageDate: .now,
            unreadCount: 0
        )
        let packet = try manager.buildPrompt(
            modelName: "local-model",
            conversation: conversation,
            messages: [
                ChatMessage(id: "m1", text: "Hello", senderName: "Alex", senderHandle: "alex@example.com", date: .now, direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false)
            ],
            userMemory: UserProfileMemory(profileSummary: "Dry and concise", styleTraits: ["short"], bannedPhrases: [], backgroundFacts: [], replyHabits: []),
            contactMemory: .empty(memoryKey: "alex@example.com"),
            summary: .empty(conversationID: "c1"),
            contextLimit: 4096
        )

        XCTAssertEqual(packet.layers.map(\.id), ["user-memory", "contact-memory", "rolling-summary", "conversation-context", "recent-messages"])
    }

    func testContextManagerCompactsRecentMessagesBeforeExceedingLimit() throws {
        let manager = ContextManager()
        let conversation = ConversationRef(
            id: "c1",
            title: "Alex",
            service: .iMessage,
            participants: [Participant(handle: "alex@example.com", displayName: "Alex", service: .iMessage)],
            isGroup: false,
            lastMessagePreview: "",
            lastMessageDate: .now,
            unreadCount: 0
        )

        let messages = (0..<40).map {
            ChatMessage(id: "\($0)", text: String(repeating: "word ", count: 40), senderName: $0.isMultiple(of: 2) ? "Alex" : "Me", senderHandle: "alex@example.com", date: .now.addingTimeInterval(TimeInterval($0)), direction: $0.isMultiple(of: 2) ? .incoming : .outgoing, containsAttachmentPlaceholder: false, isUnsupportedContent: false)
        }

        let packet = try manager.buildPrompt(
            modelName: "local-model",
            conversation: conversation,
            messages: messages,
            userMemory: .empty,
            contactMemory: .empty(memoryKey: "alex@example.com"),
            summary: .empty(conversationID: "c1"),
            contextLimit: 1200
        )

        XCTAssertTrue(packet.contextUsage.compacted)
        XCTAssertLessThanOrEqual(packet.contextUsage.estimatedInputTokens + packet.contextUsage.reservedOutputTokens + packet.contextUsage.reservedHeadroomTokens, 1200)
    }

    func testMemoryEngineMergesCandidatesUniquely() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryEngine(database: database)
        let conversation = ConversationRef(
            id: "c1",
            title: "Alex",
            service: .iMessage,
            participants: [Participant(handle: "alex@example.com", displayName: "Alex", service: .iMessage)],
            isGroup: false,
            lastMessagePreview: "",
            lastMessageDate: .now,
            unreadCount: 0
        )

        try await memory.saveUserProfileMemory(UserProfileMemory(profileSummary: "", styleTraits: [], bannedPhrases: [], backgroundFacts: [], replyHabits: ["brief"] ))
        try await memory.saveContactMemory(ContactMemory(memoryKey: "alex@example.com", relationshipSummary: "", preferences: [], recurringTopics: [], boundaries: [], notes: ["prefers quick replies"]), conversationID: "c1")

        let draft = ReplyDraft(
            id: UUID(),
            conversationID: "c1",
            text: "Sounds good.",
            confidence: 0.9,
            intent: "acknowledge",
            riskFlags: [],
            memoryCandidates: MemoryCandidates(user: ["brief"], contact: ["prefers quick replies", "likes direct answers"]),
            createdAt: .now,
            modelName: "test"
        )

        try await memory.mergeAcceptedDraft(
            draft,
            conversation: conversation,
            recentMessages: []
        )
        let updatedContact = try await memory.loadContactMemory(memoryKey: "alex@example.com", conversationID: "c1")
        XCTAssertEqual(updatedContact.notes.sorted(), ["likes direct answers", "prefers quick replies"])
    }

    func testPolicyBlocksGroupAutosend() async throws {
        let database = try AppDatabase(inMemory: true)
        let ollama = PreviewOllamaClient()
        let policy = PolicyEngine(ollama: ollama, database: database)

        let conversation = ConversationRef(
            id: "group",
            title: "Group",
            service: .iMessage,
            participants: [
                Participant(handle: "a@example.com", displayName: "A", service: .iMessage),
                Participant(handle: "b@example.com", displayName: "B", service: .iMessage)
            ],
            isGroup: true,
            lastMessagePreview: "",
            lastMessageDate: .now,
            unreadCount: 0
        )

        let decision = try await policy.evaluate(
            mode: .autonomousSend,
            conversation: conversation,
            messages: [],
            draft: ReplyDraft(id: UUID(), conversationID: "group", text: "Okay", confidence: 0.99, intent: "ack", riskFlags: [], memoryCandidates: .empty, createdAt: .now, modelName: "model"),
            config: .default(conversationID: "group", memoryKey: "group"),
            globalSettings: .default
        )

        XCTAssertEqual(decision.action, .block)
    }

    func testOnboardingStatePersists() async throws {
        let database = try AppDatabase(inMemory: true)
        let state = OnboardingState(
            hasEnteredSetupFlow: true,
            currentStep: .autonomy,
            privacyReviewed: true,
            modelReviewed: true,
            voiceSeeded: true,
            autonomyReviewed: false,
            isCompleted: false,
            completedAt: nil
        )

        try await database.saveOnboardingState(state)
        let loaded = try await database.loadOnboardingState()

        XCTAssertEqual(loaded, state)
    }

    func testRefreshModelsClearsUnavailableSelection() async throws {
        let database = try AppDatabase(inMemory: true)
        let previewLLM = PreviewOllamaClient()
        let container = AppContainer(
            database: database,
            llm: StaticModelsLLMClient(models: []),
            messagesStore: PreviewMessagesStore(),
            sender: PreviewMessagesSender(),
            contextManager: ContextManager(),
            summarizer: Summarizer(ollama: previewLLM, database: database),
            memory: MemoryEngine(database: database),
            policy: PolicyEngine(ollama: previewLLM, database: database),
            autonomy: AutonomyEngine(
                store: PreviewMessagesStore(),
                sender: PreviewMessagesSender(),
                contextManager: ContextManager(),
                summarizer: Summarizer(ollama: previewLLM, database: database),
                memory: MemoryEngine(database: database),
                policy: PolicyEngine(ollama: previewLLM, database: database),
                database: database,
                ollama: previewLLM
            ),
            startupIssues: []
        )
        let model = await MainActor.run { AppModel(container: container) }
        await MainActor.run {
            model.availableModels = [OllamaModelInfo(name: "stale", digest: nil, sizeBytes: nil, modifiedAt: nil, contextLimit: 4096)]
            model.selectedModelName = "stale"
        }

        await model.refreshModels()

        await MainActor.run {
            XCTAssertTrue(model.availableModels.isEmpty)
            XCTAssertEqual(model.selectedModelName, "")
        }
    }

    func testScheduledDraftSavePersistsLatestTextOnly() async throws {
        let database = try AppDatabase(inMemory: true)
        let previewLLM = PreviewOllamaClient()
        let container = AppContainer(
            database: database,
            llm: previewLLM,
            messagesStore: PreviewMessagesStore(),
            sender: PreviewMessagesSender(),
            contextManager: ContextManager(),
            summarizer: Summarizer(ollama: previewLLM, database: database),
            memory: MemoryEngine(database: database),
            policy: PolicyEngine(ollama: previewLLM, database: database),
            autonomy: AutonomyEngine(
                store: PreviewMessagesStore(),
                sender: PreviewMessagesSender(),
                contextManager: ContextManager(),
                summarizer: Summarizer(ollama: previewLLM, database: database),
                memory: MemoryEngine(database: database),
                policy: PolicyEngine(ollama: previewLLM, database: database),
                database: database,
                ollama: previewLLM
            ),
            startupIssues: []
        )
        let model = await MainActor.run { AppModel(container: container) }
        let draft = ReplyDraft.empty(conversationID: "c1", modelName: "model")

        await MainActor.run {
            model.currentDraft = draft
            model.scheduleDraftSave("first")
            model.scheduleDraftSave("second")
        }

        try await Task.sleep(nanoseconds: 700_000_000)

        let savedDraft = try await database.loadDraft(conversationID: "c1", modelName: "model")
        let currentDraftText = await MainActor.run { model.currentDraft?.text }
        XCTAssertEqual(currentDraftText, "second")
        XCTAssertEqual(savedDraft.text, "second")
    }

    func testMonitorCycleIgnoresOutgoingCursorChangesAndRetriesAfterFailure() async throws {
        let database = try AppDatabase(inMemory: true)
        let conversation = ConversationRef(
            id: "c1",
            title: "Alex",
            service: .iMessage,
            participants: [Participant(handle: "alex@example.com", displayName: "Alex", service: .iMessage)],
            isGroup: false,
            lastMessagePreview: "",
            lastMessageDate: .now,
            unreadCount: 0
        )
        let messagesStore = MonitorMessagesStore(conversation: conversation)
        let sender = PreviewMessagesSender()
        let llm = PreviewOllamaClient()
        let policy = PolicyEngine(ollama: llm, database: database)
        let memory = MemoryEngine(database: database)
        let autonomy = AutonomyEngine(
            store: messagesStore,
            sender: sender,
            contextManager: ContextManager(),
            summarizer: Summarizer(ollama: llm, database: database),
            memory: memory,
            policy: policy,
            database: database,
            ollama: llm
        )

        try await database.saveGlobalSettings(GlobalAutonomySettings(
            autonomyEnabled: true,
            emergencyStopEnabled: false,
            defaultQuietHoursStartHour: 22,
            defaultQuietHoursEndHour: 7,
            defaultConfidenceThreshold: 0.88,
            defaultMinimumMinutesBetweenSends: 30,
            defaultDailySendLimit: 5,
            monitorPollIntervalSeconds: 15
        ))
        var config = AutonomyContactConfig.default(conversationID: conversation.id, memoryKey: conversation.memoryKey)
        config.monitoringEnabled = true
        try await database.saveAutonomyConfig(config)

        await messagesStore.setLatest(MonitorCursor(conversationID: conversation.id, lastMessageID: "incoming-1", lastMessageDateValue: 1))
        _ = try await autonomy.monitorCycle(modelName: "model")
        let firstCallCount = await messagesStore.currentFetchConversationCallCount()
        XCTAssertEqual(firstCallCount, 1)
        let firstCursor = try await database.loadMonitorCursor(conversationID: conversation.id)
        XCTAssertEqual(firstCursor?.lastMessageID, "incoming-1")

        await messagesStore.setLatest(MonitorCursor(conversationID: conversation.id, lastMessageID: "incoming-1", lastMessageDateValue: 2))
        _ = try await autonomy.monitorCycle(modelName: "model")
        let unchangedCallCount = await messagesStore.currentFetchConversationCallCount()
        XCTAssertEqual(unchangedCallCount, 1)

        await messagesStore.setLatest(MonitorCursor(conversationID: conversation.id, lastMessageID: "incoming-2", lastMessageDateValue: 3))
        await messagesStore.setFailFetchConversation(true)
        await XCTAssertThrowsErrorAsync {
            _ = try await autonomy.monitorCycle(modelName: "model")
        }
        let retryCursor = try await database.loadMonitorCursor(conversationID: conversation.id)
        XCTAssertEqual(retryCursor?.lastMessageID, "incoming-1")

        await messagesStore.setFailFetchConversation(false)
        _ = try await autonomy.monitorCycle(modelName: "model")
        let finalCallCount = await messagesStore.currentFetchConversationCallCount()
        XCTAssertEqual(finalCallCount, 3)
        let finalCursor = try await database.loadMonitorCursor(conversationID: conversation.id)
        XCTAssertEqual(finalCursor?.lastMessageID, "incoming-2")
    }
}

private actor StaticModelsLLMClient: OllamaClientProtocol {
    let models: [OllamaModelInfo]

    init(models: [OllamaModelInfo]) {
        self.models = models
    }

    func listModels() async throws -> [OllamaModelInfo] { models }
    func modelDetails(for modelName: String) async throws -> OllamaModelInfo {
        models.first(where: { $0.name == modelName }) ?? OllamaModelInfo(name: modelName, digest: nil, sizeBytes: nil, modifiedAt: nil, contextLimit: 4096)
    }
    func generateReplyJSON(modelName: String, prompt: PromptPacket) async throws -> ReplyDraft { ReplyDraft.empty(conversationID: "", modelName: modelName) }
    func summarize(modelName: String, conversation: ConversationRef, transcript: String, existingSummary: String) async throws -> String { existingSummary }
    func classifyRisk(modelName: String, conversation: ConversationRef, messages: [ChatMessage], draft: ReplyDraft) async throws -> PolicyDecision? { nil }
}

private actor MonitorMessagesStore: MessagesStoreProtocol {
    let conversation: ConversationRef
    var latest: MonitorCursor?
    var failFetchConversation = false
    var fetchConversationCallCount = 0

    init(conversation: ConversationRef) {
        self.conversation = conversation
    }

    func fetchConversations(limit: Int) async throws -> [ConversationRef] { [conversation] }

    func fetchConversation(id: String) async throws -> ConversationRef? {
        fetchConversationCallCount += 1
        if failFetchConversation {
            throw ResponderError.conversationUnavailable
        }
        return conversation
    }

    func fetchMessages(conversationID: String, limit: Int) async throws -> [ChatMessage] {
        [
            ChatMessage(id: "m1", text: "Need this soon", senderName: "Alex", senderHandle: "alex@example.com", date: .now, direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false)
        ]
    }

    func latestCursor(conversationID: String) async throws -> MonitorCursor? { latest }

    func setLatest(_ latest: MonitorCursor?) {
        self.latest = latest
    }

    func setFailFetchConversation(_ shouldFail: Bool) {
        failFetchConversation = shouldFail
    }

    func currentFetchConversationCallCount() -> Int {
        fetchConversationCallCount
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
    }
}
