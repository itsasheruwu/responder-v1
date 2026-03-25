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
            startupIssues: [],
            messagesDirectoryAccess: nil
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

    func testConversationLaunchPreferencePersists() async throws {
        let database = try AppDatabase(inMemory: true)
        let preference = ConversationLaunchPreference(
            conversationID: "chat-123",
            persistSelectionAcrossLaunches: true
        )

        try await database.saveConversationLaunchPreference(preference)
        let loaded = try await database.loadConversationLaunchPreference()

        XCTAssertEqual(loaded, preference)
    }

    func testProviderConfigurationPersists() async throws {
        let database = try AppDatabase(inMemory: true)
        let configuration = ProviderConfiguration(
            selectedProvider: .openRouter,
            openRouterAPIKey: "test-key",
            openRouterBaseURL: "https://example.com/api"
        )

        try await database.saveProviderConfiguration(configuration)
        let loaded = try await database.loadProviderConfiguration()

        XCTAssertEqual(loaded, configuration)
    }

    func testAutonomyContactConfigDecodesLegacyMinuteIntervalAsSeconds() throws {
        let data = Data("""
        {
          "conversationID": "c1",
          "memoryKey": "alex@example.com",
          "monitoringEnabled": true,
          "simulationMode": true,
          "autoSendEnabled": false,
          "confidenceThreshold": 0.88,
          "quietHoursStartHour": 22,
          "quietHoursEndHour": 7,
          "minimumMinutesBetweenSends": 2,
          "dailySendLimit": 5,
          "requiresCompletedSimulation": true
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AutonomyContactConfig.self, from: data)

        XCTAssertEqual(decoded.minimumSecondsBetweenSends, 120)
    }

    func testGlobalAutonomySettingsDecodesLegacyMinuteIntervalAsSeconds() throws {
        let data = Data("""
        {
          "autonomyEnabled": true,
          "emergencyStopEnabled": false,
          "defaultQuietHoursStartHour": 22,
          "defaultQuietHoursEndHour": 7,
          "defaultConfidenceThreshold": 0.88,
          "defaultMinimumMinutesBetweenSends": 3,
          "defaultDailySendLimit": 5,
          "monitorPollIntervalSeconds": 15
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(GlobalAutonomySettings.self, from: data)

        XCTAssertEqual(decoded.defaultMinimumSecondsBetweenSends, 180)
    }

    func testMessagesDirectoryAccessStoreRoundTripsSavedAccess() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            MessagesDirectoryAccessStore.clear()
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let saved = try MessagesDirectoryAccessStore.save(directoryURL: directoryURL)
        let loaded = MessagesDirectoryAccessStore.load()

        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(loaded?.directoryPath, directoryURL.path)
        XCTAssertFalse(loaded?.bookmarkData.isEmpty ?? true)
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
            startupIssues: [],
            messagesDirectoryAccess: nil
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

    func testMemoryEngineInfersAndPersistsRelationshipSummary() async throws {
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

        let messages = [
            ChatMessage(id: "i1", text: "Love you, talk after our date night?", senderName: "Alex", senderHandle: "alex@example.com", date: .now, direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false),
            ChatMessage(id: "o1", text: "Sounds good babe", senderName: "Me", senderHandle: nil, date: .now.addingTimeInterval(1), direction: .outgoing, containsAttachmentPlaceholder: false, isUnsupportedContent: false),
            ChatMessage(id: "i2", text: "Miss you already", senderName: "Alex", senderHandle: "alex@example.com", date: .now.addingTimeInterval(2), direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false)
        ]

        try await memory.synchronizeMemories(conversation: conversation, messages: messages)
        let updated = try await memory.loadContactMemory(memoryKey: conversation.memoryKey, conversationID: conversation.id)

        XCTAssertEqual(updated.relationshipSummary, "One-on-one conversation with Alex. Likely a romantic relationship.")
    }

    func testMemoryEngineUsesOpenRouterRelationshipSummaryWhenConfigured() async throws {
        let database = try AppDatabase(inMemory: true)
        try await database.saveProviderConfiguration(
            ProviderConfiguration(
                selectedProvider: .ollama,
                openRouterAPIKey: "test-key",
                openRouterBaseURL: "https://example.com/api/v1"
            )
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOpenRouterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockOpenRouterURLProtocol.reset(
            responseStatusCode: 200,
            responseBody: """
        {
          "choices": [{
            "message": {
              "content": "{\\"userProfileSummary\\":\\"You write concise, direct replies and usually stay focused on logistics.\\",\\"userStyleTraits\\":[\\"brief\\",\\"direct\\"],\\"userBannedPhrases\\":[],\\"userBackgroundFacts\\":[\\"You often coordinate deliverables and timelines.\\"],\\"userReplyHabits\\":[\\"usually answers quickly with a practical next step\\"],\\"contactRelationshipSummary\\":\\"Alex seems like a coworker you coordinate with directly, and the conversation is practical and task-focused.\\",\\"contactPreferences\\":[\\"prefers direct coordination\\"],\\"contactRecurringTopics\\":[\\"project deadlines\\",\\"client decks\\"],\\"contactBoundaries\\":[],\\"contactNotes\\":[\\"often reaches out about work tasks\\"]}"
            }
          }]
        }
        """
        )

        let memory = MemoryEngine(
            database: database,
            openRouterClient: OpenRouterClient(session: session)
        )
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

        let messages = [
            ChatMessage(id: "i1", text: "Project deadline moved to Friday", senderName: "Alex", senderHandle: "alex@example.com", date: .now, direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false),
            ChatMessage(id: "i2", text: "Can you update the client deck?", senderName: "Alex", senderHandle: "alex@example.com", date: .now.addingTimeInterval(1), direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false)
        ]

        try await memory.synchronizeMemories(conversation: conversation, messages: messages)
        let updatedUser = try await memory.loadUserProfileMemory()
        let updated = try await memory.loadContactMemory(memoryKey: conversation.memoryKey, conversationID: conversation.id)

        XCTAssertEqual(updatedUser.profileSummary, "You write concise, direct replies and usually stay focused on logistics.")
        XCTAssertTrue(updatedUser.styleTraits.contains("brief"))
        XCTAssertTrue(updatedUser.backgroundFacts.contains("You often coordinate deliverables and timelines."))
        XCTAssertEqual(updated.relationshipSummary, "Alex seems like a coworker you coordinate with directly, and the conversation is practical and task-focused.")
        XCTAssertTrue(updated.preferences.contains("prefers direct coordination"))
        XCTAssertTrue(updated.recurringTopics.contains("project deadlines"))
        XCTAssertTrue(updated.notes.contains("often reaches out about work tasks"))
    }

    func testManualMemoryRemainsSeparateFromDerivedMemory() async throws {
        let database = try AppDatabase(inMemory: true)
        try await database.saveUserProfileMemory(
            UserProfileMemory(
                profileSummary: "Manual voice summary",
                styleTraits: ["warm"],
                bannedPhrases: [],
                backgroundFacts: [],
                replyHabits: []
            )
        )
        try await database.saveContactMemory(
            ContactMemory(
                memoryKey: "alex@example.com",
                relationshipSummary: "Manual relationship note",
                preferences: ["prefers thoughtful replies"],
                recurringTopics: [],
                boundaries: [],
                notes: []
            ),
            conversationID: "c1"
        )
        try await database.saveProviderConfiguration(
            ProviderConfiguration(
                selectedProvider: .ollama,
                openRouterAPIKey: "test-key",
                openRouterBaseURL: "https://example.com/api/v1"
            )
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOpenRouterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockOpenRouterURLProtocol.reset(
            responseStatusCode: 200,
            responseBody: """
            {
              "choices": [{
                "message": {
                  "content": "{\\"userProfileSummary\\":\\"Derived voice summary\\",\\"userStyleTraits\\":[\\"brief\\"],\\"userBannedPhrases\\":[],\\"userBackgroundFacts\\":[\\"Derived fact\\"],\\"userReplyHabits\\":[\\"Derived habit\\"],\\"contactRelationshipSummary\\":\\"Derived relationship summary\\",\\"contactPreferences\\":[\\"Derived preference\\"],\\"contactRecurringTopics\\":[\\"Derived topic\\"],\\"contactBoundaries\\":[\\"Derived boundary\\"],\\"contactNotes\\":[\\"Derived note\\"]}"
                }
              }]
            }
            """
        )

        let memory = MemoryEngine(
            database: database,
            openRouterClient: OpenRouterClient(session: session)
        )
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
        let messages = [
            ChatMessage(id: "i1", text: "Can you send the notes?", senderName: "Alex", senderHandle: "alex@example.com", date: .now, direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false)
        ]

        try await memory.synchronizeMemories(conversation: conversation, messages: messages)

        let storedManualUser = try await database.loadUserProfileMemory()
        let storedManualContact = try await database.loadContactMemory(memoryKey: conversation.memoryKey, conversationID: conversation.id)
        let storedDerivedUser = try await database.loadDerivedUserProfileMemory()
        let storedDerivedContact = try await database.loadDerivedContactMemory(memoryKey: conversation.memoryKey)
        let mergedUser = try await memory.loadUserProfileMemory()
        let mergedContact = try await memory.loadContactMemory(memoryKey: conversation.memoryKey, conversationID: conversation.id)

        XCTAssertEqual(storedManualUser.profileSummary, "Manual voice summary")
        XCTAssertEqual(storedManualContact.relationshipSummary, "Manual relationship note")
        XCTAssertEqual(storedDerivedUser.profileSummary, "Derived voice summary")
        XCTAssertEqual(storedDerivedContact.relationshipSummary, "Derived relationship summary")
        XCTAssertEqual(mergedUser.profileSummary, "Manual voice summary")
        XCTAssertEqual(mergedContact.relationshipSummary, "Manual relationship note")
        XCTAssertTrue(mergedUser.styleTraits.contains("warm"))
        XCTAssertTrue(mergedUser.styleTraits.contains("brief"))
        XCTAssertTrue(mergedContact.preferences.contains("prefers thoughtful replies"))
        XCTAssertTrue(mergedContact.preferences.contains("Derived preference"))
    }

    func testMemoryFingerprintSkipsRepeatedOpenRouterUpdatesForUnchangedTranscript() async throws {
        let database = try AppDatabase(inMemory: true)
        try await database.saveProviderConfiguration(
            ProviderConfiguration(
                selectedProvider: .ollama,
                openRouterAPIKey: "test-key",
                openRouterBaseURL: "https://example.com/api/v1"
            )
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOpenRouterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockOpenRouterURLProtocol.reset(
            responseStatusCode: 200,
            responseBody: """
            {
              "choices": [{
                "message": {
                  "content": "{\\"userProfileSummary\\":\\"Derived once\\",\\"userStyleTraits\\":[],\\"userBannedPhrases\\":[],\\"userBackgroundFacts\\":[],\\"userReplyHabits\\":[],\\"contactRelationshipSummary\\":\\"Derived once\\",\\"contactPreferences\\":[],\\"contactRecurringTopics\\":[],\\"contactBoundaries\\":[],\\"contactNotes\\":[]}"
                }
              }]
            }
            """
        )

        let memory = MemoryEngine(
            database: database,
            openRouterClient: OpenRouterClient(session: session)
        )
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
        let messages = [
            ChatMessage(id: "i1", text: "Can you send the notes?", senderName: "Alex", senderHandle: "alex@example.com", date: .now, direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false)
        ]

        try await memory.synchronizeMemories(conversation: conversation, messages: messages)
        try await memory.synchronizeMemories(conversation: conversation, messages: messages)

        XCTAssertEqual(MockOpenRouterURLProtocol.requestCount, 1)
    }

    func testMemoryEnginePersistsOpenRouterSyncMetadata() async throws {
        let database = try AppDatabase(inMemory: true)
        try await database.saveProviderConfiguration(
            ProviderConfiguration(
                selectedProvider: .ollama,
                openRouterAPIKey: "test-key",
                openRouterBaseURL: "https://example.com/api/v1"
            )
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOpenRouterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockOpenRouterURLProtocol.reset(
            responseStatusCode: 200,
            responseBody: """
            {
              "choices": [{
                "message": {
                  "content": "{\\"userProfileSummary\\":\\"Derived once\\",\\"userStyleTraits\\":[],\\"userBannedPhrases\\":[],\\"userBackgroundFacts\\":[],\\"userReplyHabits\\":[],\\"contactRelationshipSummary\\":\\"Derived once\\",\\"contactPreferences\\":[],\\"contactRecurringTopics\\":[],\\"contactBoundaries\\":[],\\"contactNotes\\":[]}"
                }
              }]
            }
            """
        )

        let memory = MemoryEngine(
            database: database,
            openRouterClient: OpenRouterClient(session: session)
        )
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

        try await memory.synchronizeMemories(
            conversation: conversation,
            messages: [
                ChatMessage(id: "i1", text: "Can you send the notes?", senderName: "Alex", senderHandle: "alex@example.com", date: .now, direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false)
            ]
        )

        let userMetadata = try await database.loadDerivedUserProfileMemoryMetadata()
        let contactMetadata = try await database.loadDerivedContactMemoryMetadata(memoryKey: conversation.memoryKey)

        XCTAssertEqual(userMetadata?.source, .openRouter)
        XCTAssertEqual(contactMetadata?.source, .openRouter)
        XCTAssertNotNil(userMetadata?.syncedAt)
        XCTAssertNotNil(contactMetadata?.syncedAt)
    }

    func testMemoryEnginePersistsHeuristicSyncMetadataWithoutOpenRouter() async throws {
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

        try await memory.synchronizeMemories(
            conversation: conversation,
            messages: [
                ChatMessage(id: "i1", text: "Project deadline moved to Friday", senderName: "Alex", senderHandle: "alex@example.com", date: .now, direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false)
            ]
        )

        let userMetadata = try await database.loadDerivedUserProfileMemoryMetadata()
        let contactMetadata = try await database.loadDerivedContactMemoryMetadata(memoryKey: conversation.memoryKey)

        XCTAssertEqual(userMetadata?.source, .heuristic)
        XCTAssertEqual(contactMetadata?.source, .heuristic)
    }

    func testLoadConversationRefreshesDerivedRelationshipSummaryAutomatically() async throws {
        let database = try AppDatabase(inMemory: true)
        let previewLLM = PreviewOllamaClient()
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
        let messages = [
            ChatMessage(id: "i1", text: "Project deadline moved to Friday", senderName: "Alex", senderHandle: "alex@example.com", date: .now, direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false),
            ChatMessage(id: "i2", text: "Can you update the client deck?", senderName: "Alex", senderHandle: "alex@example.com", date: .now.addingTimeInterval(1), direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false)
        ]
        let store = ScriptedMessagesStore(conversations: [conversation], messagesByConversationID: [conversation.id: messages])
        let memory = MemoryEngine(database: database)
        let container = AppContainer(
            database: database,
            llm: StaticModelsLLMClient(models: [OllamaModelInfo(name: "model", digest: nil, sizeBytes: nil, modifiedAt: nil, contextLimit: 4096)]),
            messagesStore: store,
            sender: PreviewMessagesSender(),
            contextManager: ContextManager(),
            summarizer: Summarizer(ollama: previewLLM, database: database),
            memory: memory,
            policy: PolicyEngine(ollama: previewLLM, database: database),
            autonomy: AutonomyEngine(
                store: store,
                sender: PreviewMessagesSender(),
                contextManager: ContextManager(),
                summarizer: Summarizer(ollama: previewLLM, database: database),
                memory: memory,
                policy: PolicyEngine(ollama: previewLLM, database: database),
                database: database,
                ollama: previewLLM
            ),
            startupIssues: [],
            messagesDirectoryAccess: nil
        )
        let model = await MainActor.run { AppModel(container: container) }

        await MainActor.run {
            model.conversations = [conversation]
            model.selectedModelName = "model"
        }

        await model.loadConversation(id: conversation.id)

        await MainActor.run {
            XCTAssertEqual(model.contactMemory.relationshipSummary, "One-on-one conversation with Alex. Likely a work relationship.")
        }
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
            defaultMinimumSecondsBetweenSends: 30,
            defaultDailySendLimit: 5,
            monitorPollIntervalSeconds: 15
        ))
        var config = AutonomyContactConfig.default(conversationID: conversation.id, memoryKey: conversation.memoryKey)
        config.monitoringEnabled = true
        try await database.saveAutonomyConfig(config)

        await messagesStore.setLatest(MonitorCursor(conversationID: conversation.id, lastMessageID: "incoming-1", lastMessageDateValue: 1))
        _ = try await autonomy.monitorCycle(modelName: "model", activeConversationID: conversation.id)
        let firstCallCount = await messagesStore.currentFetchConversationCallCount()
        XCTAssertEqual(firstCallCount, 1)
        let firstCursor = try await database.loadMonitorCursor(conversationID: conversation.id)
        XCTAssertEqual(firstCursor?.lastMessageID, "incoming-1")

        await messagesStore.setLatest(MonitorCursor(conversationID: conversation.id, lastMessageID: "incoming-1", lastMessageDateValue: 2))
        _ = try await autonomy.monitorCycle(modelName: "model", activeConversationID: conversation.id)
        let unchangedCallCount = await messagesStore.currentFetchConversationCallCount()
        XCTAssertEqual(unchangedCallCount, 1)

        await messagesStore.setLatest(MonitorCursor(conversationID: conversation.id, lastMessageID: "incoming-2", lastMessageDateValue: 3))
        await messagesStore.setFailFetchConversation(true)
        await XCTAssertThrowsErrorAsync {
            _ = try await autonomy.monitorCycle(modelName: "model", activeConversationID: conversation.id)
        }
        let retryCursor = try await database.loadMonitorCursor(conversationID: conversation.id)
        XCTAssertEqual(retryCursor?.lastMessageID, "incoming-1")

        await messagesStore.setFailFetchConversation(false)
        _ = try await autonomy.monitorCycle(modelName: "model", activeConversationID: conversation.id)
        let finalCallCount = await messagesStore.currentFetchConversationCallCount()
        XCTAssertEqual(finalCallCount, 3)
        let finalCursor = try await database.loadMonitorCursor(conversationID: conversation.id)
        XCTAssertEqual(finalCursor?.lastMessageID, "incoming-2")
    }

    func testMonitorCycleSkipsInactiveConversationSelection() async throws {
        let database = try AppDatabase(inMemory: true)
        let llm = PreviewOllamaClient()
        let primaryConversation = ConversationRef(
            id: "c1",
            title: "Alex",
            service: .iMessage,
            participants: [Participant(handle: "alex@example.com", displayName: "Alex", service: .iMessage)],
            isGroup: false,
            lastMessagePreview: "",
            lastMessageDate: .now,
            unreadCount: 0
        )
        let secondaryConversation = ConversationRef(
            id: "c2",
            title: "Taylor",
            service: .iMessage,
            participants: [Participant(handle: "taylor@example.com", displayName: "Taylor", service: .iMessage)],
            isGroup: false,
            lastMessagePreview: "",
            lastMessageDate: .now,
            unreadCount: 0
        )
        let messagesStore = MultiConversationMonitorMessagesStore(conversations: [
            primaryConversation.id: primaryConversation,
            secondaryConversation.id: secondaryConversation
        ])
        let autonomy = AutonomyEngine(
            store: messagesStore,
            sender: PreviewMessagesSender(),
            contextManager: ContextManager(),
            summarizer: Summarizer(ollama: llm, database: database),
            memory: MemoryEngine(database: database),
            policy: PolicyEngine(ollama: llm, database: database),
            database: database,
            ollama: llm
        )

        try await database.saveGlobalSettings(GlobalAutonomySettings(
            autonomyEnabled: true,
            emergencyStopEnabled: false,
            defaultQuietHoursStartHour: 22,
            defaultQuietHoursEndHour: 7,
            defaultConfidenceThreshold: 0.88,
            defaultMinimumSecondsBetweenSends: 30,
            defaultDailySendLimit: 5,
            monitorPollIntervalSeconds: 15
        ))

        var primaryConfig = AutonomyContactConfig.default(
            conversationID: primaryConversation.id,
            memoryKey: primaryConversation.memoryKey
        )
        primaryConfig.monitoringEnabled = true
        try await database.saveAutonomyConfig(primaryConfig)

        var secondaryConfig = AutonomyContactConfig.default(
            conversationID: secondaryConversation.id,
            memoryKey: secondaryConversation.memoryKey
        )
        secondaryConfig.monitoringEnabled = true
        try await database.saveAutonomyConfig(secondaryConfig)

        await messagesStore.setLatest(
            MonitorCursor(conversationID: primaryConversation.id, lastMessageID: "incoming-1", lastMessageDateValue: 1),
            for: primaryConversation.id
        )
        await messagesStore.setLatest(
            MonitorCursor(conversationID: secondaryConversation.id, lastMessageID: "incoming-2", lastMessageDateValue: 2),
            for: secondaryConversation.id
        )

        _ = try await autonomy.monitorCycle(modelName: "model", activeConversationID: primaryConversation.id)

        let fetchCounts = await messagesStore.fetchConversationCallCounts()
        XCTAssertEqual(fetchCounts[primaryConversation.id], 1)
        XCTAssertNil(fetchCounts[secondaryConversation.id])
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

private actor MultiConversationMonitorMessagesStore: MessagesStoreProtocol {
    let conversations: [String: ConversationRef]
    var latestByConversationID: [String: MonitorCursor] = [:]
    var conversationFetchCounts: [String: Int] = [:]

    init(conversations: [String: ConversationRef]) {
        self.conversations = conversations
    }

    func fetchConversations(limit: Int) async throws -> [ConversationRef] {
        Array(conversations.values.prefix(limit))
    }

    func fetchConversation(id: String) async throws -> ConversationRef? {
        conversationFetchCounts[id, default: 0] += 1
        return conversations[id]
    }

    func fetchMessages(conversationID: String, limit: Int) async throws -> [ChatMessage] {
        guard let conversation = conversations[conversationID],
              let participant = conversation.participants.first else {
            return []
        }

        return [
            ChatMessage(
                id: "m-\(conversationID)",
                text: "Need this soon",
                senderName: participant.displayName,
                senderHandle: participant.handle,
                date: .now,
                direction: .incoming,
                containsAttachmentPlaceholder: false,
                isUnsupportedContent: false
            )
        ]
    }

    func latestCursor(conversationID: String) async throws -> MonitorCursor? {
        latestByConversationID[conversationID]
    }

    func setLatest(_ cursor: MonitorCursor?, for conversationID: String) {
        latestByConversationID[conversationID] = cursor
    }

    func fetchConversationCallCounts() -> [String: Int] {
        conversationFetchCounts
    }
}

private actor ScriptedMessagesStore: MessagesStoreProtocol {
    let conversations: [ConversationRef]
    let messagesByConversationID: [String: [ChatMessage]]

    init(conversations: [ConversationRef], messagesByConversationID: [String: [ChatMessage]]) {
        self.conversations = conversations
        self.messagesByConversationID = messagesByConversationID
    }

    func fetchConversations(limit: Int) async throws -> [ConversationRef] {
        Array(conversations.prefix(limit))
    }

    func fetchConversation(id: String) async throws -> ConversationRef? {
        conversations.first(where: { $0.id == id })
    }

    func fetchMessages(conversationID: String, limit: Int) async throws -> [ChatMessage] {
        Array((messagesByConversationID[conversationID] ?? []).prefix(limit))
    }

    func latestCursor(conversationID: String) async throws -> MonitorCursor? {
        nil
    }
}

private final class MockOpenRouterURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseStatusCode = 200
    nonisolated(unsafe) static var responseBody = ""
    nonisolated(unsafe) static var requestCount = 0

    static func reset(responseStatusCode: Int, responseBody: String) {
        Self.responseStatusCode = responseStatusCode
        Self.responseBody = responseBody
        Self.requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: Self.responseStatusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
