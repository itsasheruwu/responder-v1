import Foundation

actor AutonomyEngine: AutonomyCoordinating {
    private let store: any MessagesStoreProtocol
    private let sender: any MessageSenderProtocol
    private let contextManager: any ContextManaging
    private let summarizer: any Summarizing
    private let memory: any MemoryStoring
    private let policy: any PolicyEvaluating
    private let database: AppDatabase
    private let ollama: any OllamaClientProtocol

    init(
        store: any MessagesStoreProtocol,
        sender: any MessageSenderProtocol,
        contextManager: any ContextManaging,
        summarizer: any Summarizing,
        memory: any MemoryStoring,
        policy: any PolicyEvaluating,
        database: AppDatabase,
        ollama: any OllamaClientProtocol
    ) {
        self.store = store
        self.sender = sender
        self.contextManager = contextManager
        self.summarizer = summarizer
        self.memory = memory
        self.policy = policy
        self.database = database
        self.ollama = ollama
    }

    func generateReply(
        conversationID: String,
        modelName: String,
        mode: ReplyOperationMode
    ) async throws -> DraftGenerationResult {
        guard let conversation = try await store.fetchConversation(id: conversationID) else {
            throw ResponderError.conversationUnavailable
        }

        let messages = try await store.fetchMessages(conversationID: conversationID, limit: 80)
        let userMemory = try await memory.loadUserProfileMemory()
        let contactMemory = try await memory.loadContactMemory(memoryKey: conversation.memoryKey, conversationID: conversation.id)
        let existingSummary = try await memory.loadSummary(conversationID: conversation.id)
        let selectedModel = try? await database.loadSelectedModel()
        let contextLimit = selectedModel?.model.name == modelName ? selectedModel?.model.contextLimit ?? 4096 : ((try? await ollama.modelDetails(for: modelName).contextLimit) ?? 4096)
        let updatedSummary = try await summarizer.compactIfNeeded(
            modelName: modelName,
            conversation: conversation,
            messages: messages,
            existingSummary: existingSummary,
            contextLimit: contextLimit
        )
        let packet = try contextManager.buildPrompt(
            modelName: modelName,
            conversation: conversation,
            messages: messages,
            userMemory: userMemory,
            contactMemory: contactMemory,
            summary: updatedSummary,
            contextLimit: contextLimit
        )
        var draft = try await ollama.generateReplyJSON(modelName: modelName, prompt: packet)
        draft = ReplyDraft(
            id: draft.id,
            conversationID: conversation.id,
            text: draft.text,
            confidence: draft.confidence,
            intent: draft.intent,
            riskFlags: draft.riskFlags,
            memoryCandidates: draft.memoryCandidates,
            createdAt: draft.createdAt,
            modelName: modelName
        )
        let config = try await database.loadAutonomyConfig(conversationID: conversation.id, memoryKey: conversation.memoryKey)
        let global = try await database.loadGlobalSettings()
        let decision = try await policy.evaluate(
            mode: mode,
            conversation: conversation,
            messages: messages,
            draft: draft,
            config: config,
            globalSettings: global
        )

        try await memory.saveDraft(draft)
        try await database.appendActivityLog(
            ActivityLogEntry(
                category: .generation,
                conversationID: conversation.id,
                message: "Generated draft in \(mode.rawValue) mode.",
                metadata: ["confidence": String(format: "%.2f", draft.confidence), "policy": decision.action.rawValue]
            )
        )
        try await database.appendActivityLog(
            ActivityLogEntry(
                category: .policy,
                severity: decision.action == .block ? .warning : .info,
                conversationID: conversation.id,
                message: "Policy decision: \(decision.action.rawValue)",
                metadata: ["reasons": decision.reasons.joined(separator: " | ")]
            )
        )

        if mode == .simulation {
            let record = SimulationRunRecord(
                id: UUID(),
                conversationID: conversation.id,
                createdAt: .now,
                draftText: draft.text,
                decision: decision.action,
                confidence: draft.confidence
            )
            try await database.appendSimulationRun(record)

            if decision.action == .allow {
                var updatedConfig = config
                updatedConfig.lastSimulationPassedAt = .now
                try await database.saveAutonomyConfig(updatedConfig)
            }
        }

        return DraftGenerationResult(
            conversation: conversation,
            messages: messages,
            promptPacket: packet,
            draft: draft,
            policyDecision: decision,
            summarySnapshot: updatedSummary,
            userMemory: userMemory,
            contactMemory: contactMemory
        )
    }

    func sendDraft(_ draft: ReplyDraft, conversationID: String, mode: ReplyOperationMode) async throws {
        guard let conversation = try await store.fetchConversation(id: conversationID) else {
            throw ResponderError.conversationUnavailable
        }
        let recentMessages = try await store.fetchMessages(conversationID: conversation.id, limit: 60)

        if mode == .autonomousSend {
            let config = try await database.loadAutonomyConfig(conversationID: conversation.id, memoryKey: conversation.memoryKey)
            let global = try await database.loadGlobalSettings()
            let decision = try await policy.evaluate(mode: mode, conversation: conversation, messages: recentMessages, draft: draft, config: config, globalSettings: global)
            guard decision.action == .allow else {
                throw ResponderError.sendBlocked("Auto-send was blocked by policy: \(decision.reasons.joined(separator: ", "))")
            }
        }

        try await sender.send(text: draft.text, to: conversation)
        try await memory.mergeAcceptedDraft(draft, conversation: conversation, recentMessages: recentMessages)
        try await database.appendActivityLog(
            ActivityLogEntry(
                category: .send,
                conversationID: conversation.id,
                message: "\(mode == .autonomousSend ? "Auto-sent" : "Sent"):\(draft.text.prefix(80))"
            )
        )
    }

    func monitorCycle(modelName: String, activeConversationID: String?) async throws -> [ActivityLogEntry] {
        let global = try await database.loadGlobalSettings()
        guard global.autonomyEnabled, !global.emergencyStopEnabled else {
            return []
        }

        let configs = try await database.loadAllAutonomyConfigs()
        var entries: [ActivityLogEntry] = []

        for config in configs where config.monitoringEnabled {
            if let activeConversationID, config.conversationID != activeConversationID {
                continue
            }
            guard let latest = try await store.latestCursor(conversationID: config.conversationID) else { continue }
            let previous = try await database.loadMonitorCursor(conversationID: config.conversationID)
            if latest.lastMessageID == previous?.lastMessageID {
                continue
            }

            let mode: ReplyOperationMode = config.autoSendEnabled ? .autonomousSend : .simulation
            let result = try await generateReply(conversationID: config.conversationID, modelName: modelName, mode: mode)

            let log = ActivityLogEntry(
                category: .autonomy,
                severity: result.policyDecision.action == .block ? .warning : .info,
                conversationID: config.conversationID,
                message: "Monitor cycle produced \(result.policyDecision.action.rawValue) in \(mode.rawValue) mode."
            )
            try await database.appendActivityLog(log)
            entries.append(log)

            if mode == .autonomousSend && result.policyDecision.action == .allow {
                try await sendDraft(result.draft, conversationID: config.conversationID, mode: .autonomousSend)
            }

            try await database.saveMonitorCursor(latest)
        }

        return entries
    }
}
