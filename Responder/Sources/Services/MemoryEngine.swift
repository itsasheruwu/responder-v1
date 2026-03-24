import Foundation

actor MemoryEngine: MemoryStoring {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func loadUserProfileMemory() async throws -> UserProfileMemory {
        try await database.loadUserProfileMemory()
    }

    func saveUserProfileMemory(_ memory: UserProfileMemory) async throws {
        try await database.saveUserProfileMemory(memory)
        try await database.appendActivityLog(ActivityLogEntry(category: .startup, message: "Saved user profile memory."))
    }

    func loadContactMemory(memoryKey: String, conversationID: String) async throws -> ContactMemory {
        try await database.loadContactMemory(memoryKey: memoryKey, conversationID: conversationID)
    }

    func saveContactMemory(_ memory: ContactMemory, conversationID: String) async throws {
        try await database.saveContactMemory(memory, conversationID: conversationID)
        try await database.appendActivityLog(ActivityLogEntry(category: .startup, conversationID: conversationID, message: "Saved contact memory."))
    }

    func loadSummary(conversationID: String) async throws -> SummarySnapshot {
        try await database.loadSummary(conversationID: conversationID)
    }

    func saveSummary(_ summary: SummarySnapshot) async throws {
        try await database.saveSummary(summary)
    }

    func loadDraft(conversationID: String, modelName: String) async throws -> ReplyDraft {
        try await database.loadDraft(conversationID: conversationID, modelName: modelName)
    }

    func saveDraft(_ draft: ReplyDraft) async throws {
        try await database.saveDraft(draft)
    }

    func synchronizeMemories(conversation: ConversationRef, messages: [ChatMessage]) async throws {
        let updated = try await applyDerivedMemoryUpdates(conversation: conversation, messages: messages, acceptedDraft: nil)
        try await database.saveUserProfileMemory(updated.userMemory)
        try await database.saveContactMemory(updated.contactMemory, conversationID: conversation.id)
    }

    func mergeAcceptedDraft(_ draft: ReplyDraft, conversation: ConversationRef, recentMessages: [ChatMessage]) async throws {
        let syntheticOutgoing = ChatMessage(
            id: "draft-\(draft.id.uuidString)",
            text: draft.text,
            senderName: "Me",
            senderHandle: nil,
            date: draft.createdAt,
            direction: .outgoing,
            containsAttachmentPlaceholder: false,
            isUnsupportedContent: false
        )
        let updated = try await applyDerivedMemoryUpdates(
            conversation: conversation,
            messages: recentMessages + [syntheticOutgoing],
            acceptedDraft: draft
        )

        try await database.saveUserProfileMemory(updated.userMemory)
        try await database.saveContactMemory(updated.contactMemory, conversationID: conversation.id)
    }

    private func applyDerivedMemoryUpdates(
        conversation: ConversationRef,
        messages: [ChatMessage],
        acceptedDraft: ReplyDraft?
    ) async throws -> (userMemory: UserProfileMemory, contactMemory: ContactMemory) {
        var userMemory = try await database.loadUserProfileMemory()
        var contactMemory = try await database.loadContactMemory(memoryKey: conversation.memoryKey, conversationID: conversation.id)
        let outgoingMessages = messages.filter { $0.direction == .outgoing && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let incomingMessages = messages.filter { $0.direction == .incoming && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        userMemory.styleTraits = mergeUnique(userMemory.styleTraits, with: inferredUserStyleTraits(from: outgoingMessages), limit: 12)
        userMemory.replyHabits = mergeUnique(userMemory.replyHabits, with: inferredReplyHabits(from: outgoingMessages), limit: 12)
        userMemory.backgroundFacts = mergeUnique(userMemory.backgroundFacts, with: inferredStableUserFacts(from: outgoingMessages), limit: 12)

        contactMemory.notes = mergeUnique(contactMemory.notes, with: inferredContactNotes(from: incomingMessages), limit: 20)

        if let acceptedDraft {
            if !acceptedDraft.memoryCandidates.user.isEmpty {
                userMemory.replyHabits = mergeUnique(userMemory.replyHabits, with: acceptedDraft.memoryCandidates.user, limit: 12)
            }
            if !acceptedDraft.memoryCandidates.contact.isEmpty {
                contactMemory.notes = mergeUnique(contactMemory.notes, with: acceptedDraft.memoryCandidates.contact, limit: 20)
            }
        }
        return (userMemory, contactMemory)
    }

    private func inferredUserStyleTraits(from messages: [ChatMessage]) -> [String] {
        guard !messages.isEmpty else { return [] }
        let samples = messages.suffix(24)
        let shortMessages = samples.filter { $0.text.count <= 55 }.count
        let lowercasedMessages = samples.filter { isMostlyLowercase($0.text) }.count
        let emojiMessages = samples.filter { containsEmoji($0.text) }.count
        let lowPunctuationMessages = samples.filter { punctuationCount(in: $0.text) <= 1 }.count

        var traits: [String] = []
        if shortMessages * 2 >= samples.count { traits.append("brief messages") }
        if lowercasedMessages * 2 >= samples.count { traits.append("often uses lowercase") }
        if emojiMessages * 3 >= samples.count { traits.append("often uses emoji") }
        if lowPunctuationMessages * 2 >= samples.count { traits.append("light punctuation") }
        return traits
    }

    private func inferredReplyHabits(from messages: [ChatMessage]) -> [String] {
        guard !messages.isEmpty else { return [] }
        let samples = messages.suffix(24)
        var habits: [String] = []

        if samples.filter({ lineCount(in: $0.text) == 1 }).count * 2 >= samples.count {
            habits.append("usually sends one short message at a time")
        }
        if samples.filter({ $0.text.contains("?") }).count <= max(1, samples.count / 5) {
            habits.append("usually answers directly without many follow-up questions")
        }
        if samples.filter({ $0.text.count <= 80 }).count * 2 >= samples.count {
            habits.append("usually keeps replies under a few short sentences")
        }

        return habits
    }

    private func inferredStableUserFacts(from messages: [ChatMessage]) -> [String] {
        messages
            .suffix(12)
            .map(\.text)
            .filter { text in
                let normalized = normalize(text)
                return normalized.count >= 24 && normalized.count <= 120 && !containsEmoji(normalized)
            }
            .prefix(3)
            .map { "Recent self-stated detail: \($0)" }
    }

    private func inferredContactNotes(from messages: [ChatMessage]) -> [String] {
        guard !messages.isEmpty else { return [] }
        let samples = messages.suffix(24)
        var notes: [String] = []

        if samples.filter({ $0.text.count <= 55 }).count * 2 >= samples.count {
            notes.append("contact usually sends short messages")
        }
        if samples.filter({ containsEmoji($0.text) }).count * 3 >= samples.count {
            notes.append("contact often uses emoji")
        }
        if samples.filter({ $0.text.contains("?") }).count * 3 >= samples.count {
            notes.append("contact often asks direct questions")
        }

        let recentTopics = samples.reversed().lazy
            .map(\.text)
            .map(normalize)
            .filter { text in
                text.count >= 8 && text.count <= 120 && !text.hasPrefix("[")
            }
            .prefix(3)
            .map { "Recent topic: \($0)" }

        notes.append(contentsOf: recentTopics)
        return notes
    }

    private func mergeUnique(_ existing: [String], with candidates: [String], limit: Int) -> [String] {
        var merged: [String] = []
        var seen: Set<String> = []

        for entry in existing + candidates {
            let normalized = normalize(entry)
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized.lowercased()).inserted else { continue }
            merged.append(normalized)
        }

        if merged.count > limit {
            return Array(merged.suffix(limit))
        }
        return merged
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsEmoji(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x238C)
        }
    }

    private func isMostlyLowercase(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let lowercaseCount = letters.filter { CharacterSet.lowercaseLetters.contains($0) }.count
        return lowercaseCount * 10 >= letters.count * 8
    }

    private func punctuationCount(in text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.punctuationCharacters.contains($0) }.count
    }

    private func lineCount(in text: String) -> Int {
        max(1, text.split(whereSeparator: \.isNewline).count)
    }
}
