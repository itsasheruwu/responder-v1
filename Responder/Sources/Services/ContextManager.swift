import Foundation

struct ContextManager: ContextManaging {
    func buildPrompt(
        modelName: String,
        conversation: ConversationRef,
        messages: [ChatMessage],
        userMemory: UserProfileMemory,
        contactMemory: ContactMemory,
        summary: SummarySnapshot,
        contextLimit: Int
    ) throws -> PromptPacket {
        let reservedHeadroom = max(128, Int(Double(contextLimit) * 0.20))
        let reservedOutput = max(128, Int(Double(contextLimit) * 0.15))

        var recentMessages = messages
        var compacted = false
        var layers = makeLayers(conversation: conversation, messages: recentMessages, userMemory: userMemory, contactMemory: contactMemory, summary: summary)
        var usage = makeUsage(for: layers, contextLimit: contextLimit, reservedOutput: reservedOutput, reservedHeadroom: reservedHeadroom, rawMessageCount: recentMessages.count, compacted: compacted)

        while usage.estimatedInputTokens + usage.reservedOutputTokens + usage.reservedHeadroomTokens > contextLimit && recentMessages.count > 12 {
            compacted = true
            recentMessages.removeFirst()
            layers = makeLayers(conversation: conversation, messages: recentMessages, userMemory: userMemory, contactMemory: contactMemory, summary: summary)
            usage = makeUsage(for: layers, contextLimit: contextLimit, reservedOutput: reservedOutput, reservedHeadroom: reservedHeadroom, rawMessageCount: recentMessages.count, compacted: compacted)
        }

        guard usage.estimatedInputTokens + usage.reservedOutputTokens + usage.reservedHeadroomTokens <= contextLimit else {
            throw ResponderError.contextLimitExceeded
        }

        return PromptPacket(
            modelName: modelName,
            systemInstructions: SystemPrompt.base,
            layers: layers,
            combinedPrompt: layers.map { "\($0.title)\n\($0.content)" }.joined(separator: "\n\n"),
            contextUsage: usage
        )
    }

    private func makeLayers(
        conversation: ConversationRef,
        messages: [ChatMessage],
        userMemory: UserProfileMemory,
        contactMemory: ContactMemory,
        summary: SummarySnapshot
    ) -> [PromptLayer] {
        let transcriptLines: [String] = messages.map { message in
            let stamp = DateFormatter.localizedString(from: message.date, dateStyle: .none, timeStyle: .short)
            return "[\(stamp)] \(message.senderName): \(message.text)"
        }
        let transcript: String = transcriptLines.joined(separator: "\n")

        return [
            PromptLayer(id: "user-memory", title: "User Memory", content: userMemory.asSnapshot().promptText),
            PromptLayer(id: "contact-memory", title: "Contact Memory", content: contactMemory.asSnapshot().promptText),
            PromptLayer(id: "rolling-summary", title: "Rolling Summary", content: summary.text.isEmpty ? "No rolling summary yet." : summary.text),
            PromptLayer(id: "conversation-context", title: "Conversation Context", content: "Title: \(conversation.title)\nService: \(conversation.service.rawValue)\nGroup chat: \(conversation.isGroup ? "Yes" : "No")"),
            PromptLayer(id: "recent-messages", title: "Recent Raw Messages", content: transcript)
        ]
    }

    private func makeUsage(
        for layers: [PromptLayer],
        contextLimit: Int,
        reservedOutput: Int,
        reservedHeadroom: Int,
        rawMessageCount: Int,
        compacted: Bool
    ) -> ContextUsage {
        let combined = layers.map(\.content).joined(separator: "\n")
        let estimatedInput = max(1, combined.count / 4)
        return ContextUsage(
            estimatedInputTokens: estimatedInput,
            reservedOutputTokens: reservedOutput,
            reservedHeadroomTokens: reservedHeadroom,
            contextLimit: contextLimit,
            rawMessageCount: rawMessageCount,
            compacted: compacted
        )
    }
}
