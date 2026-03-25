import Foundation

actor MemoryEngine: MemoryStoring {
    private let database: AppDatabase
    private let openRouterClient: OpenRouterClient

    init(
        database: AppDatabase,
        openRouterClient: OpenRouterClient = OpenRouterClient()
    ) {
        self.database = database
        self.openRouterClient = openRouterClient
    }

    func loadUserProfileMemory() async throws -> UserProfileMemory {
        let manual = try await database.loadUserProfileMemory()
        let derived = try await database.loadDerivedUserProfileMemory()
        return mergeUserMemory(manual: manual, derived: derived)
    }

    func saveUserProfileMemory(_ memory: UserProfileMemory) async throws {
        try await database.saveUserProfileMemory(memory)
        try await database.appendActivityLog(ActivityLogEntry(category: .startup, message: "Saved user profile memory."))
    }

    func loadContactMemory(memoryKey: String, conversationID: String) async throws -> ContactMemory {
        let manual = try await database.loadContactMemory(memoryKey: memoryKey, conversationID: conversationID)
        let derived = try await database.loadDerivedContactMemory(memoryKey: memoryKey)
        return mergeContactMemory(manual: manual, derived: derived)
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
        if updated.derivedUserMemory != updated.originalDerivedUserMemory {
            try await database.saveDerivedUserProfileMemory(updated.derivedUserMemory)
        }
        try await database.saveDerivedUserProfileMemoryMetadata(updated.userMetadata)
        if updated.derivedContactMemory != updated.originalDerivedContactMemory {
            try await database.saveDerivedContactMemory(updated.derivedContactMemory)
        }
        try await database.saveDerivedContactMemoryMetadata(updated.contactMetadata, memoryKey: conversation.memoryKey)
        if updated.transcriptFingerprint != updated.originalTranscriptFingerprint,
           let transcriptFingerprint = updated.transcriptFingerprint {
            try await database.saveMemoryTranscriptFingerprint(transcriptFingerprint, conversationID: conversation.id)
        }
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

        if updated.derivedUserMemory != updated.originalDerivedUserMemory {
            try await database.saveDerivedUserProfileMemory(updated.derivedUserMemory)
        }
        try await database.saveDerivedUserProfileMemoryMetadata(updated.userMetadata)
        if updated.derivedContactMemory != updated.originalDerivedContactMemory {
            try await database.saveDerivedContactMemory(updated.derivedContactMemory)
        }
        try await database.saveDerivedContactMemoryMetadata(updated.contactMetadata, memoryKey: conversation.memoryKey)
        if updated.transcriptFingerprint != updated.originalTranscriptFingerprint,
           let transcriptFingerprint = updated.transcriptFingerprint {
            try await database.saveMemoryTranscriptFingerprint(transcriptFingerprint, conversationID: conversation.id)
        }
    }

    private func applyDerivedMemoryUpdates(
        conversation: ConversationRef,
        messages: [ChatMessage],
        acceptedDraft: ReplyDraft?
    ) async throws -> (
        originalDerivedUserMemory: UserProfileMemory,
        originalDerivedContactMemory: ContactMemory,
        derivedUserMemory: UserProfileMemory,
        derivedContactMemory: ContactMemory,
        userMetadata: MemorySyncMetadata,
        contactMetadata: MemorySyncMetadata,
        originalTranscriptFingerprint: String?,
        transcriptFingerprint: String?
    ) {
        let manualUserMemory = try await database.loadUserProfileMemory()
        let manualContactMemory = try await database.loadContactMemory(memoryKey: conversation.memoryKey, conversationID: conversation.id)
        let originalDerivedUserMemory = try await database.loadDerivedUserProfileMemory()
        let originalDerivedContactMemory = try await database.loadDerivedContactMemory(memoryKey: conversation.memoryKey)
        let mergedUserMemory = mergeUserMemory(manual: manualUserMemory, derived: originalDerivedUserMemory)
        let mergedContactMemory = mergeContactMemory(manual: manualContactMemory, derived: originalDerivedContactMemory)
        var derivedUserMemory = originalDerivedUserMemory
        var derivedContactMemory = originalDerivedContactMemory
        let outgoingMessages = messages.filter { $0.direction == .outgoing && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let incomingMessages = messages.filter { $0.direction == .incoming && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let transcriptMessages = Array((incomingMessages + outgoingMessages).suffix(30))
        let transcriptFingerprint = makeTranscriptFingerprint(from: transcriptMessages)
        let originalTranscriptFingerprint = try await database.loadMemoryTranscriptFingerprint(conversationID: conversation.id)
        let openRouterConfigured = try await hasOpenRouterConfigured()
        var syncSource: MemorySyncSource = acceptedDraft == nil ? .heuristic : .acceptedDraft

        if openRouterConfigured,
           originalTranscriptFingerprint != transcriptFingerprint,
           let derivedMemory = try? await generateDerivedMemoriesWithOpenRouterIfAvailable(
            conversation: conversation,
            messages: transcriptMessages,
            userMemory: mergedUserMemory,
            contactMemory: mergedContactMemory
           ) {
            derivedUserMemory.profileSummary = mergeSummary(existing: derivedUserMemory.profileSummary, candidate: derivedMemory.userProfileSummary)
            derivedUserMemory.styleTraits = mergeUnique(derivedUserMemory.styleTraits, with: derivedMemory.userStyleTraits, limit: 12)
            derivedUserMemory.bannedPhrases = mergeUnique(derivedUserMemory.bannedPhrases, with: derivedMemory.userBannedPhrases, limit: 12)
            derivedUserMemory.backgroundFacts = mergeUnique(derivedUserMemory.backgroundFacts, with: derivedMemory.userBackgroundFacts, limit: 12)
            derivedUserMemory.replyHabits = mergeUnique(derivedUserMemory.replyHabits, with: derivedMemory.userReplyHabits, limit: 12)

            derivedContactMemory.relationshipSummary = mergeSummary(
                existing: derivedContactMemory.relationshipSummary,
                candidate: derivedMemory.contactRelationshipSummary
            )
            derivedContactMemory.preferences = mergeUnique(derivedContactMemory.preferences, with: derivedMemory.contactPreferences, limit: 12)
            derivedContactMemory.recurringTopics = mergeUnique(derivedContactMemory.recurringTopics, with: derivedMemory.contactRecurringTopics, limit: 12)
            derivedContactMemory.boundaries = mergeUnique(derivedContactMemory.boundaries, with: derivedMemory.contactBoundaries, limit: 12)
            derivedContactMemory.notes = mergeUnique(derivedContactMemory.notes, with: derivedMemory.contactNotes, limit: 20)
            syncSource = .openRouter
        }

        derivedUserMemory.styleTraits = mergeUnique(derivedUserMemory.styleTraits, with: inferredUserStyleTraits(from: outgoingMessages), limit: 12)
        derivedUserMemory.replyHabits = mergeUnique(derivedUserMemory.replyHabits, with: inferredReplyHabits(from: outgoingMessages), limit: 12)
        derivedUserMemory.backgroundFacts = mergeUnique(derivedUserMemory.backgroundFacts, with: inferredStableUserFacts(from: outgoingMessages), limit: 12)

        derivedContactMemory.relationshipSummary = inferredRelationshipSummary(
            conversation: conversation,
            incomingMessages: incomingMessages,
            outgoingMessages: outgoingMessages,
            existingSummary: derivedContactMemory.relationshipSummary
        )
        derivedContactMemory.notes = mergeUnique(derivedContactMemory.notes, with: inferredContactNotes(from: incomingMessages), limit: 20)

        if let acceptedDraft {
            if !acceptedDraft.memoryCandidates.user.isEmpty {
                derivedUserMemory.replyHabits = mergeUnique(derivedUserMemory.replyHabits, with: acceptedDraft.memoryCandidates.user, limit: 12)
            }
            if !acceptedDraft.memoryCandidates.contact.isEmpty {
                derivedContactMemory.notes = mergeUnique(derivedContactMemory.notes, with: acceptedDraft.memoryCandidates.contact, limit: 20)
            }
        }
        let metadata = MemorySyncMetadata(source: syncSource, syncedAt: .now)
        return (
            originalDerivedUserMemory,
            originalDerivedContactMemory,
            derivedUserMemory,
            derivedContactMemory,
            metadata,
            metadata,
            originalTranscriptFingerprint,
            openRouterConfigured ? transcriptFingerprint : originalTranscriptFingerprint
        )
    }

    private func generateDerivedMemoriesWithOpenRouterIfAvailable(
        conversation: ConversationRef,
        messages: [ChatMessage],
        userMemory: UserProfileMemory,
        contactMemory: ContactMemory
    ) async throws -> DerivedMemoryResponse? {
        let configuration = try await database.loadProviderConfiguration()
        guard !configuration.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return try await openRouterClient.deriveMemories(
            conversation: conversation,
            messages: messages,
            userMemory: userMemory,
            contactMemory: contactMemory,
            configuration: configuration
        )
    }

    private func hasOpenRouterConfigured() async throws -> Bool {
        let configuration = try await database.loadProviderConfiguration()
        return !configuration.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func inferredRelationshipSummary(
        conversation: ConversationRef,
        incomingMessages: [ChatMessage],
        outgoingMessages: [ChatMessage],
        existingSummary: String
    ) -> String {
        let normalizedExisting = normalize(existingSummary)
        if !normalizedExisting.isEmpty {
            return normalizedExisting
        }
        let fallback = inferredRelationshipSummaryFallback(
            conversation: conversation,
            incomingMessages: incomingMessages,
            outgoingMessages: outgoingMessages
        )
        return normalize(fallback)
    }

    private func inferredRelationshipSummaryFallback(
        conversation: ConversationRef,
        incomingMessages: [ChatMessage],
        outgoingMessages: [ChatMessage]
    ) -> String {
        let samples = Array((incomingMessages + outgoingMessages).suffix(24))

        if conversation.isGroup {
            let participantNames = conversation.participants.map(\.displayName).filter { !$0.isEmpty }
            if participantNames.isEmpty {
                return "Group conversation."
            }
            if participantNames.count <= 3 {
                return "Group chat with \(participantNames.joined(separator: ", "))."
            }
            return "Group chat with \(participantNames.prefix(3).joined(separator: ", ")) and \(participantNames.count - 3) others."
        }

        let contactName = conversation.participants.first?.displayName.nilIfEmpty ?? conversation.title.nilIfEmpty ?? "this contact"
        let relationshipCategory = inferredRelationshipCategory(from: samples)
        var fragments = ["One-on-one conversation with \(contactName)."]

        switch relationshipCategory {
        case .family:
            fragments.append("Likely a family relationship.")
        case .romantic:
            fragments.append("Likely a romantic relationship.")
        case .work:
            fragments.append("Likely a work relationship.")
        case .friend:
            fragments.append("Likely a friendship or social relationship.")
        case .unknown:
            break
        }

        if relationshipCategory == .unknown, let cadence = inferredConversationCadence(from: incomingMessages) {
            fragments.append(cadence)
        }

        return fragments.joined(separator: " ")
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

    private func inferredRelationshipCategory(from messages: [ChatMessage]) -> RelationshipCategory {
        guard !messages.isEmpty else { return .unknown }

        let normalizedTexts = messages.map { normalize($0.text).lowercased() }
        let familyScore = keywordScore(in: normalizedTexts, keywords: ["mom", "dad", "mother", "father", "sister", "brother", "grandma", "grandpa", "aunt", "uncle", "cousin", "family"])
        let romanticScore = keywordScore(in: normalizedTexts, keywords: ["love you", "miss you", "babe", "baby", "girlfriend", "boyfriend", "wife", "husband", "partner", "date night"])
        let workScore = keywordScore(in: normalizedTexts, keywords: ["meeting", "calendar", "deadline", "client", "project", "deck", "office", "team", "coworker", "manager", "shift"])
        let friendScore = keywordScore(in: normalizedTexts, keywords: ["hang out", "grab drinks", "dinner", "concert", "party", "lol", "lmao", "bro", "dude"])

        let ranked: [(RelationshipCategory, Int)] = [
            (.family, familyScore),
            (.romantic, romanticScore),
            (.work, workScore),
            (.friend, friendScore)
        ]
        .sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.rawValue < rhs.0.rawValue
            }
            return lhs.1 > rhs.1
        }

        guard let top = ranked.first, top.1 > 0 else { return .unknown }
        if ranked.count > 1, top.1 == ranked[1].1 {
            return .unknown
        }
        return top.0
    }

    private func inferredConversationCadence(from incomingMessages: [ChatMessage]) -> String? {
        guard !incomingMessages.isEmpty else { return nil }
        let samples = incomingMessages.suffix(12)
        let shortCount = samples.filter { $0.text.count <= 55 }.count
        let emojiCount = samples.filter { containsEmoji($0.text) }.count
        let questionCount = samples.filter { $0.text.contains("?") }.count

        if shortCount * 2 >= samples.count && emojiCount * 3 >= samples.count {
            return "The contact usually sends short, casual messages."
        }
        if questionCount * 3 >= samples.count {
            return "The contact often reaches out with direct questions."
        }
        if shortCount * 2 >= samples.count {
            return "The contact usually sends short messages."
        }
        return nil
    }

    private func keywordScore(in texts: [String], keywords: [String]) -> Int {
        texts.reduce(into: 0) { total, text in
            total += keywords.reduce(into: 0) { count, keyword in
                if text.contains(keyword) {
                    count += 1
                }
            }
        }
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

    private func mergeSummary(existing: String, candidate: String) -> String {
        let normalizedCandidate = normalize(candidate)
        if !normalizedCandidate.isEmpty {
            return normalizedCandidate
        }
        return normalize(existing)
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

    private func makeTranscriptFingerprint(from messages: [ChatMessage]) -> String {
        messages.map {
            [
                $0.direction.rawValue,
                normalize($0.senderName),
                normalize($0.text)
            ].joined(separator: "|")
        }.joined(separator: "\n")
    }

    private func mergeUserMemory(manual: UserProfileMemory, derived: UserProfileMemory) -> UserProfileMemory {
        UserProfileMemory(
            profileSummary: mergeManualSummary(manual.profileSummary, derived.profileSummary),
            styleTraits: mergeManualFirst(manual.styleTraits, derived.styleTraits, limit: 12),
            bannedPhrases: mergeManualFirst(manual.bannedPhrases, derived.bannedPhrases, limit: 12),
            backgroundFacts: mergeManualFirst(manual.backgroundFacts, derived.backgroundFacts, limit: 12),
            replyHabits: mergeManualFirst(manual.replyHabits, derived.replyHabits, limit: 12)
        )
    }

    private func mergeContactMemory(manual: ContactMemory, derived: ContactMemory) -> ContactMemory {
        ContactMemory(
            memoryKey: manual.memoryKey,
            relationshipSummary: mergeManualSummary(manual.relationshipSummary, derived.relationshipSummary),
            preferences: mergeManualFirst(manual.preferences, derived.preferences, limit: 12),
            recurringTopics: mergeManualFirst(manual.recurringTopics, derived.recurringTopics, limit: 12),
            boundaries: mergeManualFirst(manual.boundaries, derived.boundaries, limit: 12),
            notes: mergeManualFirst(manual.notes, derived.notes, limit: 20)
        )
    }

    private func mergeManualSummary(_ manual: String, _ derived: String) -> String {
        let normalizedManual = normalize(manual)
        return normalizedManual.isEmpty ? normalize(derived) : normalizedManual
    }

    private func mergeManualFirst(_ manual: [String], _ derived: [String], limit: Int) -> [String] {
        mergeUnique(manual, with: derived, limit: limit)
    }
}

private enum RelationshipCategory: String {
    case family
    case romantic
    case work
    case friend
    case unknown
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
