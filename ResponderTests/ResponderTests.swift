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
}
