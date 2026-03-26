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

    func loadUserProfileMemoryForPrompt(memoryKey: String) async throws -> UserProfileMemory {
        let manual = try await database.loadUserProfileMemory()
        let globalDerived = try await database.loadDerivedUserProfileMemory()
        let openRouterSlice = try await database.loadDerivedUserOpenRouterSlice(memoryKey: memoryKey) ?? .empty
        let mergedDerived = mergeUserDerivedLayers(global: globalDerived, contactOpenRouterSlice: openRouterSlice)
        return mergeUserMemory(manual: manual, derived: mergedDerived)
    }

    func saveUserProfileMemory(_ memory: UserProfileMemory) async throws {
        try await database.saveUserProfileMemory(memory)
        try await database.appendActivityLog(ActivityLogEntry(category: .memory, message: "Saved user profile memory."))
    }

    func loadContactMemory(memoryKey: String, conversationID: String) async throws -> ContactMemory {
        let manual = try await database.loadContactMemory(memoryKey: memoryKey, conversationID: conversationID)
        let derived = try await database.loadDerivedContactMemory(memoryKey: memoryKey)
        return mergeContactMemory(manual: manual, derived: derived)
    }

    func saveContactMemory(_ memory: ContactMemory, conversationID: String) async throws {
        try await database.saveContactMemory(memory, conversationID: conversationID)
        try await database.appendActivityLog(
            ActivityLogEntry(category: .memory, conversationID: conversationID, message: "Saved contact memory.")
        )
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

    @discardableResult
    func synchronizeMemories(conversation: ConversationRef, messages: [ChatMessage]) async throws -> MemorySyncOutcome {
        let updated = try await applyDerivedMemoryUpdates(conversation: conversation, messages: messages, acceptedDraft: nil)
        if updated.derivedUserMemory != updated.originalDerivedUserMemory {
            try await database.saveDerivedUserProfileMemory(updated.derivedUserMemory)
        }
        try await database.saveDerivedUserProfileMemoryMetadata(updated.userMetadata)
        if updated.openRouterUserSlice != updated.originalOpenRouterUserSlice {
            try await database.saveDerivedUserOpenRouterSlice(updated.openRouterUserSlice, memoryKey: conversation.memoryKey)
        }
        if updated.derivedContactMemory != updated.originalDerivedContactMemory {
            try await database.saveDerivedContactMemory(updated.derivedContactMemory)
        }
        try await database.saveDerivedContactMemoryMetadata(updated.contactMetadata, memoryKey: conversation.memoryKey)
        if updated.transcriptFingerprint != updated.originalTranscriptFingerprint,
           let transcriptFingerprint = updated.transcriptFingerprint {
            try await database.saveMemoryTranscriptFingerprint(transcriptFingerprint, conversationID: conversation.id)
        }
        if let error = updated.openRouterDerivationError {
            try await database.appendActivityLog(
                ActivityLogEntry(
                    category: .memory,
                    severity: .warning,
                    conversationID: conversation.id,
                    message: "OpenRouter memory derivation failed; heuristics still ran.",
                    metadata: ["error": error]
                )
            )
        }
        return MemorySyncOutcome(lastOpenRouterDerivationError: updated.openRouterDerivationError)
    }

    @discardableResult
    func mergeAcceptedDraft(_ draft: ReplyDraft, conversation: ConversationRef, recentMessages: [ChatMessage]) async throws -> MemorySyncOutcome {
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
        if updated.openRouterUserSlice != updated.originalOpenRouterUserSlice {
            try await database.saveDerivedUserOpenRouterSlice(updated.openRouterUserSlice, memoryKey: conversation.memoryKey)
        }
        if updated.derivedContactMemory != updated.originalDerivedContactMemory {
            try await database.saveDerivedContactMemory(updated.derivedContactMemory)
        }
        try await database.saveDerivedContactMemoryMetadata(updated.contactMetadata, memoryKey: conversation.memoryKey)
        if updated.transcriptFingerprint != updated.originalTranscriptFingerprint,
           let transcriptFingerprint = updated.transcriptFingerprint {
            try await database.saveMemoryTranscriptFingerprint(transcriptFingerprint, conversationID: conversation.id)
        }
        if let error = updated.openRouterDerivationError {
            try await database.appendActivityLog(
                ActivityLogEntry(
                    category: .memory,
                    severity: .warning,
                    conversationID: conversation.id,
                    message: "OpenRouter memory derivation failed; heuristics still ran.",
                    metadata: ["error": error]
                )
            )
        }
        return MemorySyncOutcome(lastOpenRouterDerivationError: updated.openRouterDerivationError)
    }

    private struct DerivedMemoryUpdateResult {
        let originalDerivedUserMemory: UserProfileMemory
        let originalDerivedContactMemory: ContactMemory
        let derivedUserMemory: UserProfileMemory
        let derivedContactMemory: ContactMemory
        let openRouterUserSlice: UserProfileMemory
        let originalOpenRouterUserSlice: UserProfileMemory
        let userMetadata: MemorySyncMetadata
        let contactMetadata: MemorySyncMetadata
        let originalTranscriptFingerprint: String?
        let transcriptFingerprint: String?
        let openRouterDerivationError: String?
    }

    private func applyDerivedMemoryUpdates(
        conversation: ConversationRef,
        messages: [ChatMessage],
        acceptedDraft: ReplyDraft?
    ) async throws -> DerivedMemoryUpdateResult {
        let manualUserMemory = try await database.loadUserProfileMemory()
        let manualContactMemory = try await database.loadContactMemory(memoryKey: conversation.memoryKey, conversationID: conversation.id)
        let originalDerivedUserMemory = try await database.loadDerivedUserProfileMemory()
        let originalDerivedContactMemory = try await database.loadDerivedContactMemory(memoryKey: conversation.memoryKey)
        var openRouterUserSlice = try await database.loadDerivedUserOpenRouterSlice(memoryKey: conversation.memoryKey) ?? .empty
        let originalOpenRouterUserSlice = openRouterUserSlice

        let nonEmptyTextMessages = messages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let outgoingMessages = nonEmptyTextMessages.filter { $0.direction == .outgoing }
        let incomingMessages = nonEmptyTextMessages.filter { $0.direction == .incoming }

        let transcriptMessages = MemoryTranscriptWindow.recentMessagesForDerivation(
            nonEmptyTextMessages,
            maxCount: MemoryTranscriptWindow.defaultMaxMessageCount,
            maxAge: MemoryTranscriptWindow.defaultMaxAge
        )

        let mergedUserForOpenRouterInput = mergeUserMemory(
            manual: manualUserMemory,
            derived: mergeUserDerivedLayers(global: originalDerivedUserMemory, contactOpenRouterSlice: openRouterUserSlice)
        )
        let mergedContactMemory = mergeContactMemory(manual: manualContactMemory, derived: originalDerivedContactMemory)

        var derivedUserMemory = originalDerivedUserMemory
        var derivedContactMemory = originalDerivedContactMemory
        let transcriptFingerprint = makeTranscriptFingerprint(from: transcriptMessages)
        let originalTranscriptFingerprint = try await database.loadMemoryTranscriptFingerprint(conversationID: conversation.id)
        let openRouterConfigured = try await hasOpenRouterConfigured()
        var syncSource: MemorySyncSource = acceptedDraft == nil ? .heuristic : .acceptedDraft
        var openRouterDerivationError: String?

        let suppressedUserKeys = try await database.suppressedNormalizedKeys(scope: .user, memoryKey: nil)
        let suppressedContactKeys = try await database.suppressedNormalizedKeys(scope: .contact, memoryKey: conversation.memoryKey)

        if openRouterConfigured, originalTranscriptFingerprint != transcriptFingerprint {
            do {
                let derivedMemory = try await openRouterClient.deriveMemories(
                    conversation: conversation,
                    messages: transcriptMessages,
                    userMemory: mergedUserForOpenRouterInput,
                    contactMemory: mergedContactMemory,
                    configuration: try await database.loadProviderConfiguration()
                )
                let sliceKey = conversation.memoryKey
                let mergedOpenProfile = mergeLLMSummary(
                    existing: openRouterUserSlice.singleLine(kind: .profileSummary, bucket: .derivedUserOpenRouter),
                    candidate: derivedMemory.userProfileSummary
                )
                let oldOpenProfile = openRouterUserSlice.items.first {
                    $0.bucket == .derivedUserOpenRouter && $0.kind == .profileSummary && !$0.suppressed
                }
                let profileSupersedes: UUID? = {
                    guard let old = oldOpenProfile else { return nil }
                    let on = MemoryNormalization.key(for: old.text)
                    let nn = MemoryNormalization.key(for: mergedOpenProfile)
                    return (!on.isEmpty && on != nn) ? old.id : nil
                }()
                openRouterUserSlice.replaceBucketScalar(
                    kind: .profileSummary,
                    bucket: .derivedUserOpenRouter,
                    memoryKey: sliceKey,
                    text: mergedOpenProfile,
                    source: .openRouter,
                    supersedesItemID: profileSupersedes
                )
                openRouterUserSlice.replaceBucketList(
                    kind: .styleTrait,
                    bucket: .derivedUserOpenRouter,
                    memoryKey: sliceKey,
                    values: mergeUniqueDerivedStableFirst(
                        existing: openRouterUserSlice.strings(kind: .styleTrait, bucket: .derivedUserOpenRouter),
                        candidates: filterSuppressed(derivedMemory.userStyleTraits, suppressedUserKeys),
                        limit: 12
                    ),
                    source: .openRouter
                )
                openRouterUserSlice.replaceBucketList(
                    kind: .bannedPhrase,
                    bucket: .derivedUserOpenRouter,
                    memoryKey: sliceKey,
                    values: mergeUniqueDerivedStableFirst(
                        existing: openRouterUserSlice.strings(kind: .bannedPhrase, bucket: .derivedUserOpenRouter),
                        candidates: filterSuppressed(derivedMemory.userBannedPhrases, suppressedUserKeys),
                        limit: 12
                    ),
                    source: .openRouter
                )
                openRouterUserSlice.replaceBucketList(
                    kind: .backgroundFact,
                    bucket: .derivedUserOpenRouter,
                    memoryKey: sliceKey,
                    values: mergeUniqueDerivedStableFirst(
                        existing: openRouterUserSlice.strings(kind: .backgroundFact, bucket: .derivedUserOpenRouter),
                        candidates: filterSuppressed(derivedMemory.userBackgroundFacts, suppressedUserKeys),
                        limit: 12
                    ),
                    source: .openRouter
                )
                openRouterUserSlice.replaceBucketList(
                    kind: .replyHabit,
                    bucket: .derivedUserOpenRouter,
                    memoryKey: sliceKey,
                    values: mergeUniqueDerivedStableFirst(
                        existing: openRouterUserSlice.strings(kind: .replyHabit, bucket: .derivedUserOpenRouter),
                        candidates: filterSuppressed(derivedMemory.userReplyHabits, suppressedUserKeys),
                        limit: 12
                    ),
                    source: .openRouter
                )

                let mergedRel = mergeLLMSummary(
                    existing: derivedContactMemory.strings(kind: .relationshipSummary, bucket: .derivedContact).first ?? "",
                    candidate: derivedMemory.contactRelationshipSummary
                )
                let oldRel = derivedContactMemory.items.first {
                    $0.bucket == .derivedContact && $0.kind == .relationshipSummary && !$0.suppressed
                }
                let relSupersedes: UUID? = {
                    guard let old = oldRel else { return nil }
                    let on = MemoryNormalization.key(for: old.text)
                    let nn = MemoryNormalization.key(for: mergedRel)
                    return (!on.isEmpty && on != nn) ? old.id : nil
                }()
                derivedContactMemory.replaceBucketScalar(
                    kind: .relationshipSummary,
                    bucket: .derivedContact,
                    text: mergedRel,
                    source: .openRouter,
                    supersedesItemID: relSupersedes
                )
                derivedContactMemory.replaceBucketList(
                    kind: .preference,
                    bucket: .derivedContact,
                    values: mergeUniqueDerivedStableFirst(
                        existing: derivedContactMemory.strings(kind: .preference, bucket: .derivedContact),
                        candidates: filterSuppressed(derivedMemory.contactPreferences, suppressedContactKeys),
                        limit: 12
                    ),
                    source: .openRouter
                )
                derivedContactMemory.replaceBucketList(
                    kind: .recurringTopic,
                    bucket: .derivedContact,
                    values: mergeUniqueDerivedStableFirst(
                        existing: derivedContactMemory.strings(kind: .recurringTopic, bucket: .derivedContact),
                        candidates: filterSuppressed(derivedMemory.contactRecurringTopics, suppressedContactKeys),
                        limit: 12
                    ),
                    source: .openRouter
                )
                derivedContactMemory.replaceBucketList(
                    kind: .boundary,
                    bucket: .derivedContact,
                    values: mergeUniqueDerivedStableFirst(
                        existing: derivedContactMemory.strings(kind: .boundary, bucket: .derivedContact),
                        candidates: filterSuppressed(derivedMemory.contactBoundaries, suppressedContactKeys),
                        limit: 12
                    ),
                    source: .openRouter
                )
                derivedContactMemory.replaceBucketList(
                    kind: .note,
                    bucket: .derivedContact,
                    values: mergeUniqueDerivedStableFirst(
                        existing: derivedContactMemory.strings(kind: .note, bucket: .derivedContact),
                        candidates: filterSuppressed(derivedMemory.contactNotes, suppressedContactKeys),
                        limit: 20
                    ),
                    source: .openRouter
                )
                syncSource = .openRouter
            } catch {
                openRouterDerivationError = error.localizedDescription
            }
        }

        derivedUserMemory.replaceBucketList(
            kind: .styleTrait,
            bucket: .derivedUserGlobal,
            memoryKey: nil,
            values: mergeUniqueDerivedStableFirst(
                existing: derivedUserMemory.strings(kind: .styleTrait, bucket: .derivedUserGlobal),
                candidates: filterSuppressed(inferredUserStyleTraits(from: outgoingMessages), suppressedUserKeys),
                limit: 12
            ),
            source: .heuristic
        )
        derivedUserMemory.replaceBucketList(
            kind: .replyHabit,
            bucket: .derivedUserGlobal,
            memoryKey: nil,
            values: mergeUniqueDerivedStableFirst(
                existing: derivedUserMemory.strings(kind: .replyHabit, bucket: .derivedUserGlobal),
                candidates: filterSuppressed(inferredReplyHabits(from: outgoingMessages), suppressedUserKeys),
                limit: 12
            ),
            source: .heuristic
        )
        derivedUserMemory.replaceBucketList(
            kind: .backgroundFact,
            bucket: .derivedUserGlobal,
            memoryKey: nil,
            values: mergeUniqueDerivedStableFirst(
                existing: derivedUserMemory.strings(kind: .backgroundFact, bucket: .derivedUserGlobal),
                candidates: filterSuppressed(inferredStableUserFacts(from: outgoingMessages), suppressedUserKeys),
                limit: 12
            ),
            source: .heuristic
        )

        let heuristicSamples = MemoryTranscriptWindow.recentMessagesForDerivation(
            nonEmptyTextMessages,
            maxCount: 24,
            maxAge: nil
        )
        let inferredRel = inferredRelationshipSummary(
            conversation: conversation,
            incomingMessages: incomingMessages,
            outgoingMessages: outgoingMessages,
            heuristicSampleMessages: heuristicSamples,
            existingSummary: derivedContactMemory.strings(kind: .relationshipSummary, bucket: .derivedContact).first ?? ""
        )
        derivedContactMemory.replaceBucketScalar(
            kind: .relationshipSummary,
            bucket: .derivedContact,
            text: inferredRel,
            source: .heuristic
        )
        derivedContactMemory.replaceBucketList(
            kind: .note,
            bucket: .derivedContact,
            values: mergeUniqueDerivedStableFirst(
                existing: derivedContactMemory.strings(kind: .note, bucket: .derivedContact),
                candidates: filterSuppressed(inferredContactNotes(from: incomingMessages), suppressedContactKeys),
                limit: 20
            ),
            source: .heuristic
        )

        if let acceptedDraft {
            if !acceptedDraft.memoryCandidates.user.isEmpty {
                derivedUserMemory.replaceBucketList(
                    kind: .replyHabit,
                    bucket: .derivedUserGlobal,
                    memoryKey: nil,
                    values: mergeUniqueDerivedStableFirst(
                        existing: derivedUserMemory.strings(kind: .replyHabit, bucket: .derivedUserGlobal),
                        candidates: filterSuppressed(acceptedDraft.memoryCandidates.user, suppressedUserKeys),
                        limit: 12
                    ),
                    source: .acceptedDraft
                )
            }
            if !acceptedDraft.memoryCandidates.contact.isEmpty {
                derivedContactMemory.replaceBucketList(
                    kind: .note,
                    bucket: .derivedContact,
                    values: mergeUniqueDerivedStableFirst(
                        existing: derivedContactMemory.strings(kind: .note, bucket: .derivedContact),
                        candidates: filterSuppressed(acceptedDraft.memoryCandidates.contact, suppressedContactKeys),
                        limit: 20
                    ),
                    source: .acceptedDraft
                )
            }
        }

        let syncedAt = Date.now
        let userMetadata = MemorySyncMetadata(
            source: syncSource,
            syncedAt: syncedAt,
            lastError: openRouterDerivationError
        )
        let contactMetadata = MemorySyncMetadata(
            source: syncSource,
            syncedAt: syncedAt,
            lastError: openRouterDerivationError
        )

        let newFingerprint: String?
        if openRouterConfigured {
            newFingerprint = transcriptFingerprint
        } else {
            newFingerprint = originalTranscriptFingerprint
        }

        return DerivedMemoryUpdateResult(
            originalDerivedUserMemory: originalDerivedUserMemory,
            originalDerivedContactMemory: originalDerivedContactMemory,
            derivedUserMemory: derivedUserMemory,
            derivedContactMemory: derivedContactMemory,
            openRouterUserSlice: openRouterUserSlice,
            originalOpenRouterUserSlice: originalOpenRouterUserSlice,
            userMetadata: userMetadata,
            contactMetadata: contactMetadata,
            originalTranscriptFingerprint: originalTranscriptFingerprint,
            transcriptFingerprint: newFingerprint,
            openRouterDerivationError: openRouterDerivationError
        )
    }

    private func hasOpenRouterConfigured() async throws -> Bool {
        let configuration = try await database.loadProviderConfiguration()
        return !configuration.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func filterSuppressed(_ candidates: [String], _ suppressed: Set<String>) -> [String] {
        candidates.filter {
            let key = MemoryNormalization.key(for: $0)
            return key.isEmpty || !suppressed.contains(key)
        }
    }

    func pinMemoryItem(id: UUID, pinned: Bool) async throws {
        guard let item = try await database.fetchMemoryItem(id: id) else { return }
        try await database.setMemoryItemPinned(id: id, pinned: pinned)
        try await resyncStorage(for: item)
        try await database.appendActivityLog(
            ActivityLogEntry(
                category: .memory,
                conversationID: item.conversationID,
                message: pinned ? "Pinned memory item." : "Unpinned memory item.",
                metadata: ["itemID": id.uuidString, "bucket": item.bucket.rawValue]
            )
        )
    }

    func deleteMemoryItem(id: UUID) async throws {
        guard let item = try await database.fetchMemoryItem(id: id) else { return }
        try await database.deleteMemoryItem(id: id)
        try await resyncStorage(for: item)
        try await database.appendActivityLog(
            ActivityLogEntry(
                category: .memory,
                severity: .warning,
                conversationID: item.conversationID,
                message: "Deleted memory item.",
                metadata: ["itemID": id.uuidString, "bucket": item.bucket.rawValue]
            )
        )
    }

    func forgetMemoryItem(id: UUID) async throws {
        guard let item = try await database.fetchMemoryItem(id: id) else { return }
        try await database.suppressMemoryItem(id: id)
        try await resyncStorage(for: item)
        try await database.appendActivityLog(
            ActivityLogEntry(
                category: .memory,
                conversationID: item.conversationID,
                message: "Marked memory item as forgotten (suppressed for re-derivation).",
                metadata: ["itemID": id.uuidString, "bucket": item.bucket.rawValue]
            )
        )
    }

    private func resyncStorage(for item: MemoryItem) async throws {
        switch item.bucket {
        case .manualUser:
            let m = try await database.loadUserProfileMemory()
            try await database.saveUserProfileMemory(m)
        case .derivedUserGlobal:
            let m = try await database.loadDerivedUserProfileMemory()
            try await database.saveDerivedUserProfileMemory(m)
        case .derivedUserOpenRouter:
            guard let mk = item.memoryKey else { return }
            guard let slice = try await database.loadDerivedUserOpenRouterSlice(memoryKey: mk) else { return }
            try await database.saveDerivedUserOpenRouterSlice(slice, memoryKey: mk)
        case .manualContact:
            guard let mk = item.memoryKey else { return }
            let cid: String
            if let existing = item.conversationID {
                cid = existing
            } else {
                cid = try await database.loadContactMemoryConversationID(memoryKey: mk) ?? ""
            }
            guard !cid.isEmpty else { return }
            let m = try await database.loadContactMemory(memoryKey: mk, conversationID: cid)
            try await database.saveContactMemory(m, conversationID: cid)
        case .derivedContact:
            guard let mk = item.memoryKey else { return }
            let m = try await database.loadDerivedContactMemory(memoryKey: mk)
            try await database.saveDerivedContactMemory(m)
        }
    }

    private func inferredRelationshipSummary(
        conversation: ConversationRef,
        incomingMessages: [ChatMessage],
        outgoingMessages: [ChatMessage],
        heuristicSampleMessages: [ChatMessage],
        existingSummary: String
    ) -> String {
        let normalizedExisting = normalize(existingSummary)
        if !normalizedExisting.isEmpty {
            return normalizedExisting
        }
        let fallback = inferredRelationshipSummaryFallback(
            conversation: conversation,
            incomingMessages: incomingMessages,
            outgoingMessages: outgoingMessages,
            samples: heuristicSampleMessages
        )
        return normalize(fallback)
    }

    private func inferredRelationshipSummaryFallback(
        conversation: ConversationRef,
        incomingMessages: [ChatMessage],
        outgoingMessages: [ChatMessage],
        samples: [ChatMessage]
    ) -> String {
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
        let samples = Array(messages.suffix(24))
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
        let samples = Array(messages.suffix(24))
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

    /// Heuristic “self-stated” lines are easy to misfire on random chatter, mixed languages, or PII-shaped text; keep conservative.
    private func inferredStableUserFacts(from messages: [ChatMessage]) -> [String] {
        messages
            .suffix(12)
            .map(\.text)
            .filter { text in
                let normalized = normalize(text)
                guard normalized.count >= 24, normalized.count <= 120, !containsEmoji(normalized) else { return false }
                guard isMostlyASCIIContent(normalized) else { return false }
                guard !containsLikelyPIIShape(normalized) else { return false }
                return true
            }
            .prefix(3)
            .map { "Recent self-stated detail: \($0)" }
    }

    private func inferredContactNotes(from messages: [ChatMessage]) -> [String] {
        guard !messages.isEmpty else { return [] }
        let samples = Array(messages.suffix(24))
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
            .filter { [self] text in
                text.count >= 8 && text.count <= 120 && !text.hasPrefix("[") && !containsLikelyPIIShape(text)
            }
            .prefix(3)
            .map { "Recent topic: \($0)" }

        notes.append(contentsOf: recentTopics)
        return notes
    }

    private func inferredRelationshipCategory(from messages: [ChatMessage]) -> RelationshipCategory {
        guard !messages.isEmpty else { return .unknown }

        let normalizedTexts = messages.map { normalize($0.text).lowercased() }
        // English-centric keyword cues (documented limitation for non-English threads).
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

    /// **List cap policy:** preserve primary entries first (manual order before candidates in `mergeUniqueDerivedStableFirst`),
    /// then add new unique candidates only while room remains. Never drop primary in favor of newcomers via `suffix(limit)`.
    private func mergeUniqueDerivedStableFirst(existing: [String], candidates: [String], limit: Int) -> [String] {
        var merged: [String] = []
        var seen: Set<String> = []

        for entry in existing {
            let normalized = normalize(entry)
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized.lowercased()).inserted else { continue }
            merged.append(normalized)
            if merged.count >= limit { return merged }
        }

        for entry in candidates {
            guard merged.count < limit else { break }
            let normalized = normalize(entry)
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized.lowercased()).inserted else { continue }
            merged.append(normalized)
        }

        return merged
    }

    private func mergeLLMSummary(existing: String, candidate: String, maxSentences: Int = 4, maxUTF16Scalars: Int = 480) -> String {
        let e = normalize(existing)
        let c = normalize(candidate)
        if c.isEmpty { return e }
        if e.isEmpty { return Self.truncateSummary(c, maxSentences: maxSentences, maxUTF16Scalars: maxUTF16Scalars) }

        let eLower = e.lowercased()
        let cLower = c.lowercased()
        if cLower == eLower { return e }
        if eLower.contains(cLower) { return e }
        if cLower.contains(eLower) { return Self.truncateSummary(c, maxSentences: maxSentences, maxUTF16Scalars: maxUTF16Scalars) }

        let merged = Self.truncateSummary("\(e) \(c)", maxSentences: maxSentences, maxUTF16Scalars: maxUTF16Scalars)
        return merged
    }

    private static func truncateSummary(_ text: String, maxSentences: Int, maxUTF16Scalars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var chunks = trimmed.components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if chunks.count > maxSentences {
            chunks = Array(chunks.prefix(maxSentences))
        }
        var merged = chunks.map { chunk in
            chunk.hasSuffix(".") || chunk.hasSuffix("!") || chunk.hasSuffix("?") ? chunk : "\(chunk)."
        }.joined(separator: " ")
        if merged.count > maxUTF16Scalars {
            merged = String(merged.prefix(maxUTF16Scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return merged
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isMostlyASCIIContent(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !scalars.isEmpty else { return false }
        let asciiLetters = scalars.filter { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }.count
        return asciiLetters * 10 >= scalars.count * 6
    }

    private func containsLikelyPIIShape(_ text: String) -> Bool {
        if text.contains("@"), text.contains(".") { return true }
        let digits = text.filter(\.isNumber).count
        if digits >= 9 { return true }
        let pattern = #"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b"#
        if text.range(of: pattern, options: .regularExpression) != nil { return true }
        return false
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

    private func mergeUserDerivedLayers(global: UserProfileMemory, contactOpenRouterSlice: UserProfileMemory) -> UserProfileMemory {
        UserProfileMemory(
            items: UserProfileMemory.itemsFromLegacyCodableFields(
                profileSummary: mergeLLMSummary(
                    existing: global.singleLine(kind: .profileSummary, bucket: .derivedUserGlobal),
                    candidate: contactOpenRouterSlice.singleLine(kind: .profileSummary, bucket: .derivedUserOpenRouter)
                ),
                styleTraits: mergeListsDerivedOnly(
                    global: global,
                    slice: contactOpenRouterSlice,
                    kind: .styleTrait,
                    limit: 12
                ),
                bannedPhrases: mergeListsDerivedOnly(
                    global: global,
                    slice: contactOpenRouterSlice,
                    kind: .bannedPhrase,
                    limit: 12
                ),
                backgroundFacts: mergeListsDerivedOnly(
                    global: global,
                    slice: contactOpenRouterSlice,
                    kind: .backgroundFact,
                    limit: 12
                ),
                replyHabits: mergeListsDerivedOnly(
                    global: global,
                    slice: contactOpenRouterSlice,
                    kind: .replyHabit,
                    limit: 12
                ),
                bucket: .derivedUserGlobal,
                openRouterMemoryKey: nil
            )
        )
    }

    private func mergeListsDerivedOnly(
        global: UserProfileMemory,
        slice: UserProfileMemory,
        kind: MemoryItemKind,
        limit: Int
    ) -> [String] {
        mergeUniqueDerivedStableFirst(
            existing: global.strings(kind: kind, bucket: .derivedUserGlobal),
            candidates: slice.strings(kind: kind, bucket: .derivedUserOpenRouter),
            limit: limit
        )
    }

    private func mergeUserMemory(manual: UserProfileMemory, derived: UserProfileMemory) -> UserProfileMemory {
        UserProfileMemory(items: manual.items + derived.items)
    }

    private func mergeContactMemory(manual: ContactMemory, derived: ContactMemory) -> ContactMemory {
        ContactMemory(memoryKey: manual.memoryKey, items: manual.items + derived.items)
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
