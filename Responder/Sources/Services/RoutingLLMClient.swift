import Foundation

actor RoutingLLMClient: OllamaClientProtocol {
    private let database: AppDatabase
    private let ollamaClient: OllamaClient
    private let openRouterClient: OpenRouterClient

    init(
        database: AppDatabase,
        ollamaClient: OllamaClient = OllamaClient(),
        openRouterClient: OpenRouterClient = OpenRouterClient()
    ) {
        self.database = database
        self.ollamaClient = ollamaClient
        self.openRouterClient = openRouterClient
    }

    func listModels() async throws -> [OllamaModelInfo] {
        let configuration = try await database.loadProviderConfiguration()
        switch configuration.selectedProvider {
        case .ollama:
            return try await ollamaClient.listModels()
        case .openRouter:
            return try await openRouterClient.listModels(configuration: configuration)
        }
    }

    func modelDetails(for modelName: String) async throws -> OllamaModelInfo {
        let configuration = try await database.loadProviderConfiguration()
        switch configuration.selectedProvider {
        case .ollama:
            return try await ollamaClient.modelDetails(for: modelName)
        case .openRouter:
            return try await openRouterClient.modelDetails(for: modelName, configuration: configuration)
        }
    }

    func generateReplyJSON(modelName: String, prompt: PromptPacket) async throws -> ReplyDraft {
        let configuration = try await database.loadProviderConfiguration()
        switch configuration.selectedProvider {
        case .ollama:
            return try await ollamaClient.generateReplyJSON(modelName: modelName, prompt: prompt)
        case .openRouter:
            return try await openRouterClient.generateReplyJSON(modelName: modelName, prompt: prompt, configuration: configuration)
        }
    }

    func summarize(modelName: String, conversation: ConversationRef, transcript: String, existingSummary: String) async throws -> String {
        let configuration = try await database.loadProviderConfiguration()
        switch configuration.selectedProvider {
        case .ollama:
            return try await ollamaClient.summarize(modelName: modelName, conversation: conversation, transcript: transcript, existingSummary: existingSummary)
        case .openRouter:
            return try await openRouterClient.summarize(
                modelName: modelName,
                conversation: conversation,
                transcript: transcript,
                existingSummary: existingSummary,
                configuration: configuration
            )
        }
    }

    func classifyRisk(modelName: String, conversation: ConversationRef, messages: [ChatMessage], draft: ReplyDraft) async throws -> PolicyDecision? {
        let configuration = try await database.loadProviderConfiguration()
        switch configuration.selectedProvider {
        case .ollama:
            return try await ollamaClient.classifyRisk(modelName: modelName, conversation: conversation, messages: messages, draft: draft)
        case .openRouter:
            return try await openRouterClient.classifyRisk(
                modelName: modelName,
                conversation: conversation,
                messages: messages,
                draft: draft,
                configuration: configuration
            )
        }
    }
}
