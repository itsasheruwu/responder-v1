import Foundation

protocol OllamaClientProtocol: Sendable {
    func listModels() async throws -> [OllamaModelInfo]
    func modelDetails(for modelName: String) async throws -> OllamaModelInfo
    func generateReplyJSON(modelName: String, prompt: PromptPacket) async throws -> ReplyDraft
    func summarize(modelName: String, conversation: ConversationRef, transcript: String, existingSummary: String) async throws -> String
    func classifyRisk(modelName: String, conversation: ConversationRef, messages: [ChatMessage], draft: ReplyDraft) async throws -> PolicyDecision?
}

protocol MessagesStoreProtocol: Sendable {
    func fetchConversations(limit: Int) async throws -> [ConversationRef]
    func fetchConversation(id: String) async throws -> ConversationRef?
    func fetchMessages(conversationID: String, limit: Int) async throws -> [ChatMessage]
    func latestCursor(conversationID: String) async throws -> MonitorCursor?
}

protocol MessageSenderProtocol: Sendable {
    func send(text: String, to conversation: ConversationRef) async throws
}

protocol ContextManaging: Sendable {
    func buildPrompt(
        modelName: String,
        conversation: ConversationRef,
        messages: [ChatMessage],
        userMemory: UserProfileMemory,
        contactMemory: ContactMemory,
        summary: SummarySnapshot,
        contextLimit: Int
    ) throws -> PromptPacket
}

protocol Summarizing: Sendable {
    func compactIfNeeded(
        modelName: String,
        conversation: ConversationRef,
        messages: [ChatMessage],
        existingSummary: SummarySnapshot,
        contextLimit: Int
    ) async throws -> SummarySnapshot
}

protocol MemoryStoring: Sendable {
    func loadUserProfileMemory() async throws -> UserProfileMemory
    func saveUserProfileMemory(_ memory: UserProfileMemory) async throws
    func loadContactMemory(memoryKey: String, conversationID: String) async throws -> ContactMemory
    func saveContactMemory(_ memory: ContactMemory, conversationID: String) async throws
    func loadSummary(conversationID: String) async throws -> SummarySnapshot
    func saveSummary(_ summary: SummarySnapshot) async throws
    func loadDraft(conversationID: String, modelName: String) async throws -> ReplyDraft
    func saveDraft(_ draft: ReplyDraft) async throws
    func synchronizeMemories(conversation: ConversationRef, messages: [ChatMessage]) async throws
    func mergeAcceptedDraft(_ draft: ReplyDraft, conversation: ConversationRef, recentMessages: [ChatMessage]) async throws
}

protocol PolicyEvaluating: Sendable {
    func evaluate(
        mode: ReplyOperationMode,
        conversation: ConversationRef,
        messages: [ChatMessage],
        draft: ReplyDraft,
        config: AutonomyContactConfig,
        globalSettings: GlobalAutonomySettings
    ) async throws -> PolicyDecision
}

protocol AutonomyCoordinating: Sendable {
    func generateReply(
        conversationID: String,
        modelName: String,
        mode: ReplyOperationMode
    ) async throws -> DraftGenerationResult
    func sendDraft(_ draft: ReplyDraft, conversationID: String, mode: ReplyOperationMode) async throws
    func monitorCycle(modelName: String, activeConversationID: String?) async throws -> [ActivityLogEntry]
}
