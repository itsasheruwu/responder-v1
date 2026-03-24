import Foundation

actor Summarizer: Summarizing {
    private let ollama: any OllamaClientProtocol
    private let database: AppDatabase

    init(ollama: any OllamaClientProtocol, database: AppDatabase) {
        self.ollama = ollama
        self.database = database
    }

    func compactIfNeeded(
        modelName: String,
        conversation: ConversationRef,
        messages: [ChatMessage],
        existingSummary: SummarySnapshot,
        contextLimit: Int
    ) async throws -> SummarySnapshot {
        let estimatedTranscriptTokens = messages.map(\.text).joined(separator: "\n").count / 4
        guard estimatedTranscriptTokens > Int(Double(contextLimit) * 0.65), messages.count > 12 else {
            return existingSummary
        }

        let olderMessages = Array(messages.dropLast(12))
        let transcriptLines: [String] = olderMessages.map { message in
            let stamp = DateFormatter.localizedString(from: message.date, dateStyle: .short, timeStyle: .short)
            return "[\(stamp)] \(message.senderName): \(message.text)"
        }
        let transcriptText: String = transcriptLines.joined(separator: "\n")

        let summaryText = try await ollama.summarize(
            modelName: modelName,
            conversation: conversation,
            transcript: transcriptText,
            existingSummary: existingSummary.text
        )

        let summary = SummarySnapshot(conversationID: conversation.id, text: summaryText, updatedAt: .now)
        try await database.saveSummary(summary)
        try await database.appendActivityLog(
            ActivityLogEntry(
                category: .summarization,
                conversationID: conversation.id,
                message: "Updated rolling summary after transcript compaction.",
                metadata: ["messageCount": "\(olderMessages.count)"]
            )
        )
        return summary
    }
}
