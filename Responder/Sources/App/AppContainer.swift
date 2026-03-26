import Foundation

struct AppContainer {
    let database: AppDatabase
    let llm: any OllamaClientProtocol
    let messagesStore: any MessagesStoreProtocol
    let sender: any MessageSenderProtocol
    let contextManager: any ContextManaging
    let summarizer: any Summarizing
    let memory: any MemoryStoring
    let policy: any PolicyEvaluating
    let autonomy: any AutonomyCoordinating
    let startupIssues: [String]
    let messagesDirectoryAccess: MessagesDirectoryAccess?

    static func live(database existingDatabase: AppDatabase? = nil) throws -> AppContainer {
        let database = try existingDatabase ?? AppDatabase()
        Task { await database.ensureAppSettingsJSONExportExists() }
        let llm = RoutingLLMClient(database: database)
        let startupIssues: [String]
        let messagesStore: any MessagesStoreProtocol
        let messagesDirectoryAccess = MessagesDirectoryAccessStore.load()
        do {
            messagesStore = try MessagesStoreReader(messagesDirectoryAccess: messagesDirectoryAccess)
            startupIssues = []
        } catch {
            messagesStore = RestrictedMessagesStore()
            startupIssues = [
                "Messages history is unavailable: \(error.localizedDescription). Grant Full Disk Access or choose the Messages folder if you want local conversation loading."
            ]
        }
        let sender = MessagesSender()
        let openRouter = OpenRouterClient()
        let contextManager = ContextManager(openRouter: openRouter)
        let memory = MemoryEngine(database: database)
        let summarizer = Summarizer(ollama: llm, database: database)
        let policy = PolicyEngine(ollama: llm, database: database)
        let autonomy = AutonomyEngine(
            store: messagesStore,
            sender: sender,
            contextManager: contextManager,
            summarizer: summarizer,
            memory: memory,
            policy: policy,
            database: database,
            ollama: llm
        )
        return AppContainer(
            database: database,
            llm: llm,
            messagesStore: messagesStore,
            sender: sender,
            contextManager: contextManager,
            summarizer: summarizer,
            memory: memory,
            policy: policy,
            autonomy: autonomy,
            startupIssues: startupIssues,
            messagesDirectoryAccess: messagesDirectoryAccess
        )
    }

    static func preview() -> AppContainer {
        let database = try! AppDatabase(inMemory: true)
        let llm = PreviewOllamaClient()
        let messagesStore = PreviewMessagesStore()
        let sender = PreviewMessagesSender()
        let openRouter = OpenRouterClient()
        let contextManager = ContextManager(openRouter: openRouter)
        let memory = MemoryEngine(database: database)
        let summarizer = Summarizer(ollama: llm, database: database)
        let policy = PolicyEngine(ollama: llm, database: database)
        let autonomy = AutonomyEngine(
            store: messagesStore,
            sender: sender,
            contextManager: contextManager,
            summarizer: summarizer,
            memory: memory,
            policy: policy,
            database: database,
            ollama: llm
        )
        return AppContainer(
            database: database,
            llm: llm,
            messagesStore: messagesStore,
            sender: sender,
            contextManager: contextManager,
            summarizer: summarizer,
            memory: memory,
            policy: policy,
            autonomy: autonomy,
            startupIssues: [],
            messagesDirectoryAccess: nil
        )
    }
}

actor PreviewOllamaClient: OllamaClientProtocol {
    func listModels() async throws -> [OllamaModelInfo] {
        [OllamaModelInfo(name: "llama3.2:latest", digest: nil, sizeBytes: nil, modifiedAt: .now, contextLimit: 8192)]
    }

    func modelDetails(for modelName: String) async throws -> OllamaModelInfo {
        OllamaModelInfo(name: modelName, digest: nil, sizeBytes: nil, modifiedAt: .now, contextLimit: 8192)
    }

    func generateReplyJSON(modelName: String, prompt: PromptPacket) async throws -> ReplyDraft {
        ReplyDraft(
            id: UUID(),
            conversationID: "",
            text: "Sounds good. I can do that.",
            confidence: 0.91,
            intent: "agree",
            riskFlags: [],
            memoryCandidates: .empty,
            createdAt: .now,
            modelName: modelName
        )
    }

    func summarize(modelName: String, conversation: ConversationRef, transcript: String, existingSummary: String) async throws -> String {
        existingSummary.isEmpty ? "The contact and user have been coordinating casually." : existingSummary
    }

    func classifyRisk(modelName: String, conversation: ConversationRef, messages: [ChatMessage], draft: ReplyDraft) async throws -> PolicyDecision? {
        nil
    }
}

actor PreviewMessagesStore: MessagesStoreProtocol {
    private let conversation = ConversationRef(
        id: "preview-conversation",
        title: "Alex",
        service: .iMessage,
        participants: [Participant(handle: "alex@example.com", displayName: "Alex", service: .iMessage)],
        isGroup: false,
        lastMessagePreview: "Can you send me the doc later?",
        lastMessageDate: .now,
        unreadCount: 1
    )

    func fetchConversations(limit: Int) async throws -> [ConversationRef] {
        [conversation]
    }

    func fetchConversation(id: String) async throws -> ConversationRef? {
        conversation
    }

    func fetchMessages(conversationID: String, limit: Int) async throws -> [ChatMessage] {
        [
            ChatMessage(id: "1", text: "Can you send me the doc later?", senderName: "Alex", senderHandle: "alex@example.com", date: .now.addingTimeInterval(-300), direction: .incoming, containsAttachmentPlaceholder: false, isUnsupportedContent: false),
            ChatMessage(id: "2", text: "Yep, I’ll send it this afternoon.", senderName: "Me", senderHandle: nil, date: .now.addingTimeInterval(-120), direction: .outgoing, containsAttachmentPlaceholder: false, isUnsupportedContent: false)
        ]
    }

    func latestCursor(conversationID: String) async throws -> MonitorCursor? {
        MonitorCursor(conversationID: conversationID, lastMessageID: "2", lastMessageDateValue: 2)
    }

    func invalidateContactLabelCaches() async {}
}

actor PreviewMessagesSender: MessageSenderProtocol {
    func send(text: String, to conversation: ConversationRef) async throws {}
}

actor RestrictedMessagesStore: MessagesStoreProtocol {
    func fetchConversations(limit: Int) async throws -> [ConversationRef] {
        []
    }

    func fetchConversation(id: String) async throws -> ConversationRef? {
        nil
    }

    func fetchMessages(conversationID: String, limit: Int) async throws -> [ChatMessage] {
        []
    }

    func latestCursor(conversationID: String) async throws -> MonitorCursor? {
        nil
    }

    func invalidateContactLabelCaches() async {}
}
