import Foundation

enum ConversationService: String, Codable, Sendable, CaseIterable {
    case iMessage
    case sms = "SMS"
    case rcs = "RCS"
    case unknown

    init(rawService: String?) {
        switch rawService?.lowercased() {
        case "imessage":
            self = .iMessage
        case "sms":
            self = .sms
        case "rcs":
            self = .rcs
        default:
            self = .unknown
        }
    }
}

struct Participant: Identifiable, Hashable, Codable, Sendable {
    var id: String { handle }
    let handle: String
    let displayName: String
    let service: ConversationService
}

struct ConversationRef: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let service: ConversationService
    let participants: [Participant]
    let isGroup: Bool
    let lastMessagePreview: String
    let lastMessageDate: Date?
    let unreadCount: Int

    var memoryKey: String {
        if let first = participants.first, participants.count == 1 {
            return first.handle
        }
        return id
    }

    var subtitle: String {
        if participants.isEmpty {
            return service.rawValue
        }
        return participants.map(\.displayName).joined(separator: ", ")
    }
}

enum MessageDirection: String, Codable, Sendable {
    case incoming
    case outgoing
}

struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let text: String
    let senderName: String
    let senderHandle: String?
    let date: Date
    let direction: MessageDirection
    let containsAttachmentPlaceholder: Bool
    let isUnsupportedContent: Bool
}

struct OllamaModelInfo: Identifiable, Hashable, Codable, Sendable {
    var id: String { name }
    let name: String
    let digest: String?
    let sizeBytes: Int64?
    let modifiedAt: Date?
    let contextLimit: Int
}

enum AIProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case ollama
    case openRouter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama:
            return "Ollama"
        case .openRouter:
            return "OpenRouter"
        }
    }

    var supportsLocalPrivacy: Bool {
        switch self {
        case .ollama:
            return true
        case .openRouter:
            return false
        }
    }
}

struct ProviderConfiguration: Hashable, Codable, Sendable {
    var selectedProvider: AIProvider
    var openRouterAPIKey: String
    var openRouterBaseURL: String
    /// When true and an OpenRouter API key is set, prompt memory selection uses embedding similarity vs recent transcript (falls back to keyword overlap on failure).
    var useEmbeddingMemoryRetrieval: Bool
    /// OpenRouter routing id for `/v1/embeddings` (see OpenRouter models list).
    var memoryEmbeddingModel: String

    static let `default` = ProviderConfiguration(
        selectedProvider: .ollama,
        openRouterAPIKey: "",
        openRouterBaseURL: "https://openrouter.ai/api/v1",
        useEmbeddingMemoryRetrieval: false,
        memoryEmbeddingModel: "openai/text-embedding-3-small"
    )

    enum CodingKeys: String, CodingKey {
        case selectedProvider
        case openRouterAPIKey
        case openRouterBaseURL
        case useEmbeddingMemoryRetrieval
        case memoryEmbeddingModel
    }

    init(
        selectedProvider: AIProvider,
        openRouterAPIKey: String,
        openRouterBaseURL: String,
        useEmbeddingMemoryRetrieval: Bool = false,
        memoryEmbeddingModel: String = "openai/text-embedding-3-small"
    ) {
        self.selectedProvider = selectedProvider
        self.openRouterAPIKey = openRouterAPIKey
        self.openRouterBaseURL = openRouterBaseURL
        self.useEmbeddingMemoryRetrieval = useEmbeddingMemoryRetrieval
        self.memoryEmbeddingModel = memoryEmbeddingModel
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedProvider = try c.decodeIfPresent(AIProvider.self, forKey: .selectedProvider) ?? .ollama
        openRouterAPIKey = try c.decodeIfPresent(String.self, forKey: .openRouterAPIKey) ?? ""
        openRouterBaseURL = try c.decodeIfPresent(String.self, forKey: .openRouterBaseURL) ?? "https://openrouter.ai/api/v1"
        useEmbeddingMemoryRetrieval = try c.decodeIfPresent(Bool.self, forKey: .useEmbeddingMemoryRetrieval) ?? false
        memoryEmbeddingModel = try c.decodeIfPresent(String.self, forKey: .memoryEmbeddingModel) ?? "openai/text-embedding-3-small"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selectedProvider, forKey: .selectedProvider)
        try c.encode(openRouterAPIKey, forKey: .openRouterAPIKey)
        try c.encode(openRouterBaseURL, forKey: .openRouterBaseURL)
        try c.encode(useEmbeddingMemoryRetrieval, forKey: .useEmbeddingMemoryRetrieval)
        try c.encode(memoryEmbeddingModel, forKey: .memoryEmbeddingModel)
    }
}

struct SelectedModelState: Hashable, Codable, Sendable {
    let provider: AIProvider
    let model: OllamaModelInfo
}

struct ConversationLaunchPreference: Hashable, Codable, Sendable {
    var conversationID: String?
    var persistSelectionAcrossLaunches: Bool

    static let `default` = ConversationLaunchPreference(
        conversationID: nil,
        persistSelectionAcrossLaunches: false
    )
}

struct MessagesDirectoryAccess: Hashable, Codable, Sendable {
    var directoryPath: String
    var bookmarkData: Data
}

struct PromptLayer: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let content: String
}

struct ContextUsage: Hashable, Codable, Sendable {
    let estimatedInputTokens: Int
    let reservedOutputTokens: Int
    let reservedHeadroomTokens: Int
    let contextLimit: Int
    let rawMessageCount: Int
    let compacted: Bool

    var utilization: Double {
        guard contextLimit > 0 else { return 0 }
        return Double(estimatedInputTokens + reservedOutputTokens + reservedHeadroomTokens) / Double(contextLimit)
    }

    var isNearLimit: Bool {
        utilization >= 0.8
    }
}

struct PromptPacket: Hashable, Codable, Sendable {
    let modelName: String
    let systemInstructions: String
    let layers: [PromptLayer]
    let combinedPrompt: String
    let contextUsage: ContextUsage
}

struct MemorySnapshot: Hashable, Codable, Sendable {
    let title: String
    var entries: [String]

    static let empty = MemorySnapshot(title: "", entries: [])

    var promptText: String {
        guard !entries.isEmpty else { return "None recorded." }
        return entries.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

enum MemorySyncSource: String, Hashable, Codable, Sendable {
    case manual
    case openRouter
    case heuristic
    case acceptedDraft

    var displayName: String {
        switch self {
        case .manual:
            return "Manual"
        case .openRouter:
            return "OpenRouter"
        case .heuristic:
            return "Heuristic"
        case .acceptedDraft:
            return "Draft Feedback"
        }
    }
}

struct MemorySyncMetadata: Hashable, Codable, Sendable {
    var source: MemorySyncSource
    var syncedAt: Date
    /// Non-fatal issue for this sync leg (e.g. OpenRouter derivation failed while heuristics still ran).
    var lastError: String?
}

struct MemorySyncOutcome: Hashable, Sendable {
    var lastOpenRouterDerivationError: String?
}

/// User-scoped memory as atomic items (manual + derived layers distinguished by `MemoryItem.bucket` on each row).
/// Legacy JSON used parallel string fields; `Decoder` migrates that shape into `items` on read (see `MemoryItem` / persistence).
struct UserProfileMemory: Hashable, Codable, Sendable {
    var items: [MemoryItem]

    static let empty = UserProfileMemory(items: [])

    /// Memberwise initializer for tests and tooling (prefers `itemsFromLegacyCodableFields` when migrating strings).
    init(profileSummary: String, styleTraits: [String], bannedPhrases: [String], backgroundFacts: [String], replyHabits: [String]) {
        items = Self.migrateLegacyStrings(
            profileSummary: profileSummary,
            styleTraits: styleTraits,
            bannedPhrases: bannedPhrases,
            backgroundFacts: backgroundFacts,
            replyHabits: replyHabits,
            bucket: .manualUser,
            openRouterMemoryKey: nil
        )
    }

    var profileSummary: String {
        get {
            mergedSingleLine(kind: .profileSummary, manualBucket: .manualUser, derivedBuckets: [.derivedUserGlobal, .derivedUserOpenRouter])
        }
        set { replaceManualScalar(kind: .profileSummary, text: newValue, bucket: .manualUser) }
    }

    var styleTraits: [String] {
        get {
            mergedList(kind: .styleTrait, manualBucket: .manualUser, derivedBuckets: [.derivedUserGlobal, .derivedUserOpenRouter])
        }
        set { replaceManualList(kind: .styleTrait, values: newValue, bucket: .manualUser) }
    }

    var bannedPhrases: [String] {
        get {
            mergedList(kind: .bannedPhrase, manualBucket: .manualUser, derivedBuckets: [.derivedUserGlobal, .derivedUserOpenRouter])
        }
        set { replaceManualList(kind: .bannedPhrase, values: newValue, bucket: .manualUser) }
    }

    var backgroundFacts: [String] {
        get {
            mergedList(kind: .backgroundFact, manualBucket: .manualUser, derivedBuckets: [.derivedUserGlobal, .derivedUserOpenRouter])
        }
        set { replaceManualList(kind: .backgroundFact, values: newValue, bucket: .manualUser) }
    }

    var replyHabits: [String] {
        get {
            mergedList(kind: .replyHabit, manualBucket: .manualUser, derivedBuckets: [.derivedUserGlobal, .derivedUserOpenRouter])
        }
        set { replaceManualList(kind: .replyHabit, values: newValue, bucket: .manualUser) }
    }

    /// Uses merged getters so the same fact is not repeated once per underlying `MemoryItem` row (manual + derived layers).
    func asSnapshot() -> MemorySnapshot {
        var entries: [String] = []
        let p = profileSummary
        if !p.isEmpty { entries.append("Profile: \(p)") }
        let styles = styleTraits
        if !styles.isEmpty { entries.append("Style traits: \(styles.joined(separator: ", "))") }
        let banned = bannedPhrases
        if !banned.isEmpty { entries.append("Avoid: \(banned.joined(separator: ", "))") }
        let facts = backgroundFacts
        if !facts.isEmpty { entries.append("Facts: \(facts.joined(separator: ", "))") }
        let habits = replyHabits
        if !habits.isEmpty { entries.append("Habits: \(habits.joined(separator: ", "))") }
        return MemorySnapshot(title: "User Memory", entries: entries)
    }

    func asSnapshot(forPromptItems selection: [MemoryItem]) -> MemorySnapshot {
        Self.snapshotFromItems(selection, title: "User Memory")
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case schemaVersion
        case profileSummary
        case styleTraits
        case bannedPhrases
        case backgroundFacts
        case replyHabits
    }

    init(items: [MemoryItem]) {
        self.items = items
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.items) {
            items = try c.decode([MemoryItem].self, forKey: .items)
            return
        }
        let profileSummary = try c.decodeIfPresent(String.self, forKey: .profileSummary) ?? ""
        let styleTraits = try c.decodeIfPresent([String].self, forKey: .styleTraits) ?? []
        let bannedPhrases = try c.decodeIfPresent([String].self, forKey: .bannedPhrases) ?? []
        let backgroundFacts = try c.decodeIfPresent([String].self, forKey: .backgroundFacts) ?? []
        let replyHabits = try c.decodeIfPresent([String].self, forKey: .replyHabits) ?? []
        items = Self.migrateLegacyStrings(
            profileSummary: profileSummary,
            styleTraits: styleTraits,
            bannedPhrases: bannedPhrases,
            backgroundFacts: backgroundFacts,
            replyHabits: replyHabits,
            bucket: .manualUser,
            openRouterMemoryKey: nil
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .schemaVersion)
        try c.encode(items, forKey: .items)
    }

    private static func migrateLegacyStrings(
        profileSummary: String,
        styleTraits: [String],
        bannedPhrases: [String],
        backgroundFacts: [String],
        replyHabits: [String],
        bucket: MemoryItemBucket,
        openRouterMemoryKey: String?
    ) -> [MemoryItem] {
        let itemSource: MemorySyncSource = switch bucket {
        case .manualUser: .manual
        case .derivedUserOpenRouter: .openRouter
        default: .heuristic
        }
        var out: [MemoryItem] = []
        let now = Date.now
        if !profileSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(
                MemoryItem(
                    bucket: bucket,
                    scope: .user,
                    memoryKey: openRouterMemoryKey,
                    kind: .profileSummary,
                    text: profileSummary,
                    source: itemSource,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }
        func appendLines(_ values: [String], kind: MemoryItemKind) {
            for raw in values {
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                out.append(
                    MemoryItem(
                        bucket: bucket,
                        scope: .user,
                        memoryKey: openRouterMemoryKey,
                        kind: kind,
                        text: t,
                        source: itemSource,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }
        }
        appendLines(styleTraits, kind: .styleTrait)
        appendLines(bannedPhrases, kind: .bannedPhrase)
        appendLines(backgroundFacts, kind: .backgroundFact)
        appendLines(replyHabits, kind: .replyHabit)
        return out
    }

    static func itemsFromLegacyCodableFields(
        profileSummary: String,
        styleTraits: [String],
        bannedPhrases: [String],
        backgroundFacts: [String],
        replyHabits: [String],
        bucket: MemoryItemBucket,
        openRouterMemoryKey: String?
    ) -> [MemoryItem] {
        migrateLegacyStrings(
            profileSummary: profileSummary,
            styleTraits: styleTraits,
            bannedPhrases: bannedPhrases,
            backgroundFacts: backgroundFacts,
            replyHabits: replyHabits,
            bucket: bucket,
            openRouterMemoryKey: openRouterMemoryKey
        )
    }

    static func snapshotFromItems(_ items: [MemoryItem], title: String) -> MemorySnapshot {
        let active = MemoryItemVisibility.activeItems(items)
        var entries: [String] = []
        let profile = uniqueTextsForSnapshot(active, kind: .profileSummary).joined(separator: " ")
        if !profile.isEmpty { entries.append("Profile: \(profile)") }
        let styles = uniqueTextsForSnapshot(active, kind: .styleTrait)
        if !styles.isEmpty { entries.append("Style traits: \(styles.joined(separator: ", "))") }
        let banned = uniqueTextsForSnapshot(active, kind: .bannedPhrase)
        if !banned.isEmpty { entries.append("Avoid: \(banned.joined(separator: ", "))") }
        let facts = uniqueTextsForSnapshot(active, kind: .backgroundFact)
        if !facts.isEmpty { entries.append("Facts: \(facts.joined(separator: ", "))") }
        let habits = uniqueTextsForSnapshot(active, kind: .replyHabit)
        if !habits.isEmpty { entries.append("Habits: \(habits.joined(separator: ", "))") }
        let rel = uniqueTextsForSnapshot(active, kind: .relationshipSummary).joined(separator: " ")
        if !rel.isEmpty { entries.append("Relationship: \(rel)") }
        let prefs = uniqueTextsForSnapshot(active, kind: .preference)
        if !prefs.isEmpty { entries.append("Preferences: \(prefs.joined(separator: ", "))") }
        let topics = uniqueTextsForSnapshot(active, kind: .recurringTopic)
        if !topics.isEmpty { entries.append("Topics: \(topics.joined(separator: ", "))") }
        let bounds = uniqueTextsForSnapshot(active, kind: .boundary)
        if !bounds.isEmpty { entries.append("Boundaries: \(bounds.joined(separator: ", "))") }
        let noteLines = uniqueTextsForSnapshot(active, kind: .note)
        if !noteLines.isEmpty { entries.append("Notes: \(noteLines.joined(separator: ", "))") }
        return MemorySnapshot(title: title, entries: entries)
    }

    /// Dedupes by `normalizedKey` (manual bucket wins, then derived global, then OpenRouter slice) so prompt snippets are not repeated.
    private static func snapshotBucketDisplayOrder(_ bucket: MemoryItemBucket) -> Int {
        switch bucket {
        case .manualUser, .manualContact: return 0
        case .derivedUserGlobal, .derivedContact: return 1
        case .derivedUserOpenRouter: return 2
        }
    }

    private static func uniqueTextsForSnapshot(_ items: [MemoryItem], kind: MemoryItemKind) -> [String] {
        let slice = items.filter { $0.kind == kind }
        let sorted = slice.sorted { a, b in
            let oa = snapshotBucketDisplayOrder(a.bucket)
            let ob = snapshotBucketDisplayOrder(b.bucket)
            if oa != ob { return oa < ob }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.id.uuidString < b.id.uuidString
        }
        return dedupeNormalizedTexts(sorted)
    }

    private static func dedupeNormalizedTexts(_ rows: [MemoryItem]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for row in rows {
            let key = row.normalizedKey.isEmpty ? MemoryNormalization.key(for: row.text) : row.normalizedKey
            guard !key.isEmpty else {
                if seen.insert(row.text).inserted { out.append(row.text) }
                continue
            }
            guard seen.insert(key).inserted else { continue }
            out.append(row.text)
        }
        return out
    }

    private mutating func replaceManualScalar(kind: MemoryItemKind, text: String, bucket: MemoryItemBucket) {
        items.removeAll { $0.bucket == bucket && $0.kind == kind }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(MemoryItem(bucket: bucket, scope: .user, kind: kind, text: trimmed, source: .manual))
    }

    private mutating func replaceManualList(kind: MemoryItemKind, values: [String], bucket: MemoryItemBucket) {
        items.removeAll { $0.bucket == bucket && $0.kind == kind }
        for raw in values {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            items.append(MemoryItem(bucket: bucket, scope: .user, kind: kind, text: t, source: .manual))
        }
    }

    private func mergedSingleLine(
        kind: MemoryItemKind,
        manualBucket: MemoryItemBucket,
        derivedBuckets: [MemoryItemBucket]
    ) -> String {
        let rows = items.filter { !$0.suppressed && $0.kind == kind }
        if let manual = rows.first(where: { $0.bucket == manualBucket })?.text, !manual.isEmpty {
            return manual
        }
        let derived = rows.filter { derivedBuckets.contains($0.bucket) }
        return derived.sorted { $0.updatedAt > $1.updatedAt }.first?.text ?? ""
    }

    private func mergedList(
        kind: MemoryItemKind,
        manualBucket: MemoryItemBucket,
        derivedBuckets: [MemoryItemBucket]
    ) -> [String] {
        let rows = items.filter { !$0.suppressed && $0.kind == kind }
        var order = [manualBucket]
        order.append(contentsOf: derivedBuckets)
        var out: [String] = []
        var seen = Set<String>()
        for bucket in order {
            let slice = rows.filter { $0.bucket == bucket }.sorted { $0.updatedAt > $1.updatedAt }
            for row in slice {
                guard seen.insert(row.normalizedKey).inserted else { continue }
                out.append(row.text)
            }
        }
        return out
    }

    /// Engine use: target a specific storage bucket (avoid writing derived data into `manualUser` via property setters).
    mutating func replaceBucketScalar(
        kind: MemoryItemKind,
        bucket: MemoryItemBucket,
        memoryKey: String?,
        text merged: String,
        source: MemorySyncSource,
        supersedesItemID: UUID? = nil
    ) {
        items.removeAll { $0.bucket == bucket && $0.kind == kind && !$0.suppressed }
        let t = merged.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(
            MemoryItem(
                bucket: bucket,
                scope: .user,
                memoryKey: memoryKey,
                kind: kind,
                text: t,
                source: source,
                supersedesItemID: supersedesItemID
            )
        )
    }

    mutating func replaceBucketList(
        kind: MemoryItemKind,
        bucket: MemoryItemBucket,
        memoryKey: String?,
        values: [String],
        source: MemorySyncSource
    ) {
        items.removeAll { $0.bucket == bucket && $0.kind == kind && !$0.suppressed }
        for raw in values {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            items.append(
                MemoryItem(
                    bucket: bucket,
                    scope: .user,
                    memoryKey: memoryKey,
                    kind: kind,
                    text: t,
                    source: source
                )
            )
        }
    }

    func strings(kind: MemoryItemKind, bucket: MemoryItemBucket) -> [String] {
        items.filter { $0.bucket == bucket && $0.kind == kind && !$0.suppressed }.map(\.text)
    }

    func singleLine(kind: MemoryItemKind, bucket: MemoryItemBucket) -> String {
        items.filter { $0.bucket == bucket && $0.kind == kind && !$0.suppressed }.sorted { $0.updatedAt > $1.updatedAt }.first?.text ?? ""
    }
}

struct ContactMemory: Hashable, Codable, Sendable {
    let memoryKey: String
    var items: [MemoryItem]

    static func empty(memoryKey: String) -> ContactMemory {
        ContactMemory(memoryKey: memoryKey, items: [])
    }

    init(
        memoryKey: String,
        relationshipSummary: String,
        preferences: [String],
        recurringTopics: [String],
        boundaries: [String],
        notes: [String]
    ) {
        self.memoryKey = memoryKey
        items = Self.migrateLegacyContact(
            memoryKey: memoryKey,
            relationshipSummary: relationshipSummary,
            preferences: preferences,
            recurringTopics: recurringTopics,
            boundaries: boundaries,
            notes: notes
        )
    }

    var relationshipSummary: String {
        get {
            mergedSingleLine(kind: .relationshipSummary, manualBucket: .manualContact, derivedBuckets: [.derivedContact])
        }
        set { replaceManualScalar(kind: .relationshipSummary, text: newValue, conversationID: nil) }
    }

    var preferences: [String] {
        get {
            mergedList(kind: .preference, manualBucket: .manualContact, derivedBuckets: [.derivedContact])
        }
        set { replaceManualList(kind: .preference, values: newValue, conversationID: nil) }
    }

    var recurringTopics: [String] {
        get {
            mergedList(kind: .recurringTopic, manualBucket: .manualContact, derivedBuckets: [.derivedContact])
        }
        set { replaceManualList(kind: .recurringTopic, values: newValue, conversationID: nil) }
    }

    var boundaries: [String] {
        get {
            mergedList(kind: .boundary, manualBucket: .manualContact, derivedBuckets: [.derivedContact])
        }
        set { replaceManualList(kind: .boundary, values: newValue, conversationID: nil) }
    }

    var notes: [String] {
        get {
            mergedList(kind: .note, manualBucket: .manualContact, derivedBuckets: [.derivedContact])
        }
        set { replaceManualList(kind: .note, values: newValue, conversationID: nil) }
    }

    func asSnapshot() -> MemorySnapshot {
        var entries: [String] = []
        let rel = relationshipSummary
        if !rel.isEmpty { entries.append("Relationship: \(rel)") }
        let prefs = preferences
        if !prefs.isEmpty { entries.append("Preferences: \(prefs.joined(separator: ", "))") }
        let topics = recurringTopics
        if !topics.isEmpty { entries.append("Topics: \(topics.joined(separator: ", "))") }
        let bounds = boundaries
        if !bounds.isEmpty { entries.append("Boundaries: \(bounds.joined(separator: ", "))") }
        let noteLines = notes
        if !noteLines.isEmpty { entries.append("Notes: \(noteLines.joined(separator: ", "))") }
        return MemorySnapshot(title: "Contact Memory", entries: entries)
    }

    func asSnapshot(forPromptItems selection: [MemoryItem]) -> MemorySnapshot {
        Self.snapshotFromItems(selection, title: "Contact Memory")
    }

    private enum CodingKeys: String, CodingKey {
        case memoryKey
        case items
        case schemaVersion
        case relationshipSummary
        case preferences
        case recurringTopics
        case boundaries
        case notes
    }

    init(memoryKey: String, items: [MemoryItem]) {
        self.memoryKey = memoryKey
        self.items = items
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memoryKey = try c.decode(String.self, forKey: .memoryKey)
        if c.contains(.items) {
            items = try c.decode([MemoryItem].self, forKey: .items)
            return
        }
        let relationshipSummary = try c.decodeIfPresent(String.self, forKey: .relationshipSummary) ?? ""
        let preferences = try c.decodeIfPresent([String].self, forKey: .preferences) ?? []
        let recurringTopics = try c.decodeIfPresent([String].self, forKey: .recurringTopics) ?? []
        let boundaries = try c.decodeIfPresent([String].self, forKey: .boundaries) ?? []
        let notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        items = Self.migrateLegacyContact(memoryKey: memoryKey, relationshipSummary: relationshipSummary, preferences: preferences, recurringTopics: recurringTopics, boundaries: boundaries, notes: notes)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(memoryKey, forKey: .memoryKey)
        try c.encode(2, forKey: .schemaVersion)
        try c.encode(items, forKey: .items)
    }

    private static func migrateLegacyContact(
        memoryKey: String,
        relationshipSummary: String,
        preferences: [String],
        recurringTopics: [String],
        boundaries: [String],
        notes: [String]
    ) -> [MemoryItem] {
        var out: [MemoryItem] = []
        let now = Date.now
        if !relationshipSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(
                MemoryItem(
                    bucket: .manualContact,
                    scope: .contact,
                    memoryKey: memoryKey,
                    kind: .relationshipSummary,
                    text: relationshipSummary,
                    source: .manual,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }
        func append(_ values: [String], kind: MemoryItemKind) {
            for raw in values {
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                out.append(
                    MemoryItem(
                        bucket: .manualContact,
                        scope: .contact,
                        memoryKey: memoryKey,
                        kind: kind,
                        text: t,
                        source: .manual,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }
        }
        append(preferences, kind: .preference)
        append(recurringTopics, kind: .recurringTopic)
        append(boundaries, kind: .boundary)
        append(notes, kind: .note)
        return out
    }

    private static func snapshotFromItems(_ items: [MemoryItem], title: String) -> MemorySnapshot {
        UserProfileMemory.snapshotFromItems(items, title: title)
    }

    private mutating func replaceManualScalar(kind: MemoryItemKind, text: String, conversationID: String?) {
        items.removeAll { $0.bucket == .manualContact && $0.kind == kind }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(
            MemoryItem(
                bucket: .manualContact,
                scope: .contact,
                memoryKey: memoryKey,
                conversationID: conversationID,
                kind: kind,
                text: trimmed,
                source: .manual
            )
        )
    }

    private mutating func replaceManualList(kind: MemoryItemKind, values: [String], conversationID: String?) {
        items.removeAll { $0.bucket == .manualContact && $0.kind == kind }
        for raw in values {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            items.append(
                MemoryItem(
                    bucket: .manualContact,
                    scope: .contact,
                    memoryKey: memoryKey,
                    conversationID: conversationID,
                    kind: kind,
                    text: t,
                    source: .manual
                )
            )
        }
    }

    private func mergedSingleLine(kind: MemoryItemKind, manualBucket: MemoryItemBucket, derivedBuckets: [MemoryItemBucket]) -> String {
        let rows = items.filter { !$0.suppressed && $0.kind == kind }
        if let manual = rows.first(where: { $0.bucket == manualBucket })?.text, !manual.isEmpty {
            return manual
        }
        let derived = rows.filter { derivedBuckets.contains($0.bucket) }
        return derived.sorted { $0.updatedAt > $1.updatedAt }.first?.text ?? ""
    }

    private func mergedList(
        kind: MemoryItemKind,
        manualBucket: MemoryItemBucket,
        derivedBuckets: [MemoryItemBucket]
    ) -> [String] {
        let rows = items.filter { !$0.suppressed && $0.kind == kind }
        var order = [manualBucket]
        order.append(contentsOf: derivedBuckets)
        var out: [String] = []
        var seen = Set<String>()
        for bucket in order {
            let slice = rows.filter { $0.bucket == bucket }.sorted { $0.updatedAt > $1.updatedAt }
            for row in slice {
                guard seen.insert(row.normalizedKey).inserted else { continue }
                out.append(row.text)
            }
        }
        return out
    }

    mutating func replaceBucketScalar(
        kind: MemoryItemKind,
        bucket: MemoryItemBucket,
        text merged: String,
        source: MemorySyncSource,
        supersedesItemID: UUID? = nil
    ) {
        items.removeAll { $0.bucket == bucket && $0.kind == kind && !$0.suppressed }
        let t = merged.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(
            MemoryItem(
                bucket: bucket,
                scope: .contact,
                memoryKey: memoryKey,
                kind: kind,
                text: t,
                source: source,
                supersedesItemID: supersedesItemID
            )
        )
    }

    mutating func replaceBucketList(
        kind: MemoryItemKind,
        bucket: MemoryItemBucket,
        values: [String],
        source: MemorySyncSource
    ) {
        items.removeAll { $0.bucket == bucket && $0.kind == kind && !$0.suppressed }
        for raw in values {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            items.append(
                MemoryItem(
                    bucket: bucket,
                    scope: .contact,
                    memoryKey: memoryKey,
                    kind: kind,
                    text: t,
                    source: source
                )
            )
        }
    }

    func strings(kind: MemoryItemKind, bucket: MemoryItemBucket) -> [String] {
        items.filter { $0.bucket == bucket && $0.kind == kind && !$0.suppressed }.map(\.text)
    }
}

struct SummarySnapshot: Hashable, Codable, Sendable {
    let conversationID: String
    var text: String
    var updatedAt: Date

    static func empty(conversationID: String) -> SummarySnapshot {
        SummarySnapshot(conversationID: conversationID, text: "", updatedAt: .distantPast)
    }
}

struct MemoryCandidates: Hashable, Codable, Sendable {
    var user: [String]
    var contact: [String]

    static let empty = MemoryCandidates(user: [], contact: [])
}

struct ReplyDraft: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let conversationID: String
    var text: String
    let confidence: Double
    let intent: String
    let riskFlags: [String]
    let memoryCandidates: MemoryCandidates
    let createdAt: Date
    let modelName: String

    static func empty(conversationID: String, modelName: String) -> ReplyDraft {
        ReplyDraft(id: UUID(), conversationID: conversationID, text: "", confidence: 0, intent: "", riskFlags: [], memoryCandidates: .empty, createdAt: .now, modelName: modelName)
    }
}

enum PolicyAction: String, Codable, Sendable {
    case allow
    case draftOnly
    case block
}

struct PolicyDecision: Hashable, Codable, Sendable {
    let action: PolicyAction
    let confidence: Double
    let reasons: [String]
    let riskFlags: [String]

    static let allow = PolicyDecision(action: .allow, confidence: 1, reasons: [], riskFlags: [])
}

struct AutonomyContactConfig: Hashable, Codable, Sendable {
    let conversationID: String
    let memoryKey: String
    var monitoringEnabled: Bool
    var simulationMode: Bool
    var autoSendEnabled: Bool
    var confidenceThreshold: Double
    var quietHoursStartHour: Int
    var quietHoursEndHour: Int
    var minimumSecondsBetweenSends: Int
    var dailySendLimit: Int
    var requiresCompletedSimulation: Bool
    var lastSimulationPassedAt: Date?

    static func `default`(conversationID: String, memoryKey: String) -> AutonomyContactConfig {
        AutonomyContactConfig(
            conversationID: conversationID,
            memoryKey: memoryKey,
            monitoringEnabled: false,
            simulationMode: true,
            autoSendEnabled: false,
            confidenceThreshold: 0.88,
            quietHoursStartHour: 22,
            quietHoursEndHour: 7,
            minimumSecondsBetweenSends: 30,
            dailySendLimit: 5,
            requiresCompletedSimulation: true,
            lastSimulationPassedAt: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID
        case memoryKey
        case monitoringEnabled
        case simulationMode
        case autoSendEnabled
        case confidenceThreshold
        case quietHoursStartHour
        case quietHoursEndHour
        case minimumSecondsBetweenSends
        case minimumMinutesBetweenSends
        case dailySendLimit
        case requiresCompletedSimulation
        case lastSimulationPassedAt
    }

    init(
        conversationID: String,
        memoryKey: String,
        monitoringEnabled: Bool,
        simulationMode: Bool,
        autoSendEnabled: Bool,
        confidenceThreshold: Double,
        quietHoursStartHour: Int,
        quietHoursEndHour: Int,
        minimumSecondsBetweenSends: Int,
        dailySendLimit: Int,
        requiresCompletedSimulation: Bool,
        lastSimulationPassedAt: Date?
    ) {
        self.conversationID = conversationID
        self.memoryKey = memoryKey
        self.monitoringEnabled = monitoringEnabled
        self.simulationMode = simulationMode
        self.autoSendEnabled = autoSendEnabled
        self.confidenceThreshold = confidenceThreshold
        self.quietHoursStartHour = quietHoursStartHour
        self.quietHoursEndHour = quietHoursEndHour
        self.minimumSecondsBetweenSends = minimumSecondsBetweenSends
        self.dailySendLimit = dailySendLimit
        self.requiresCompletedSimulation = requiresCompletedSimulation
        self.lastSimulationPassedAt = lastSimulationPassedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try container.decode(String.self, forKey: .conversationID)
        memoryKey = try container.decode(String.self, forKey: .memoryKey)
        monitoringEnabled = try container.decode(Bool.self, forKey: .monitoringEnabled)
        simulationMode = try container.decode(Bool.self, forKey: .simulationMode)
        autoSendEnabled = try container.decode(Bool.self, forKey: .autoSendEnabled)
        confidenceThreshold = try container.decode(Double.self, forKey: .confidenceThreshold)
        quietHoursStartHour = try container.decode(Int.self, forKey: .quietHoursStartHour)
        quietHoursEndHour = try container.decode(Int.self, forKey: .quietHoursEndHour)
        if let seconds = try container.decodeIfPresent(Int.self, forKey: .minimumSecondsBetweenSends) {
            minimumSecondsBetweenSends = seconds
        } else if let legacyMinutes = try container.decodeIfPresent(Int.self, forKey: .minimumMinutesBetweenSends) {
            minimumSecondsBetweenSends = legacyMinutes * 60
        } else {
            minimumSecondsBetweenSends = 30
        }
        dailySendLimit = try container.decode(Int.self, forKey: .dailySendLimit)
        requiresCompletedSimulation = try container.decode(Bool.self, forKey: .requiresCompletedSimulation)
        lastSimulationPassedAt = try container.decodeIfPresent(Date.self, forKey: .lastSimulationPassedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(memoryKey, forKey: .memoryKey)
        try container.encode(monitoringEnabled, forKey: .monitoringEnabled)
        try container.encode(simulationMode, forKey: .simulationMode)
        try container.encode(autoSendEnabled, forKey: .autoSendEnabled)
        try container.encode(confidenceThreshold, forKey: .confidenceThreshold)
        try container.encode(quietHoursStartHour, forKey: .quietHoursStartHour)
        try container.encode(quietHoursEndHour, forKey: .quietHoursEndHour)
        try container.encode(minimumSecondsBetweenSends, forKey: .minimumSecondsBetweenSends)
        try container.encode(dailySendLimit, forKey: .dailySendLimit)
        try container.encode(requiresCompletedSimulation, forKey: .requiresCompletedSimulation)
        try container.encodeIfPresent(lastSimulationPassedAt, forKey: .lastSimulationPassedAt)
    }
}

struct GlobalAutonomySettings: Hashable, Codable, Sendable {
    var autonomyEnabled: Bool
    var emergencyStopEnabled: Bool
    var defaultQuietHoursStartHour: Int
    var defaultQuietHoursEndHour: Int
    var defaultConfidenceThreshold: Double
    var defaultMinimumSecondsBetweenSends: Int
    var defaultDailySendLimit: Int
    var monitorPollIntervalSeconds: Int

    static let `default` = GlobalAutonomySettings(
        autonomyEnabled: false,
        emergencyStopEnabled: false,
        defaultQuietHoursStartHour: 22,
        defaultQuietHoursEndHour: 7,
        defaultConfidenceThreshold: 0.88,
        defaultMinimumSecondsBetweenSends: 30,
        defaultDailySendLimit: 5,
        monitorPollIntervalSeconds: 15
    )

    private enum CodingKeys: String, CodingKey {
        case autonomyEnabled
        case emergencyStopEnabled
        case defaultQuietHoursStartHour
        case defaultQuietHoursEndHour
        case defaultConfidenceThreshold
        case defaultMinimumSecondsBetweenSends
        case defaultMinimumMinutesBetweenSends
        case defaultDailySendLimit
        case monitorPollIntervalSeconds
    }

    init(
        autonomyEnabled: Bool,
        emergencyStopEnabled: Bool,
        defaultQuietHoursStartHour: Int,
        defaultQuietHoursEndHour: Int,
        defaultConfidenceThreshold: Double,
        defaultMinimumSecondsBetweenSends: Int,
        defaultDailySendLimit: Int,
        monitorPollIntervalSeconds: Int
    ) {
        self.autonomyEnabled = autonomyEnabled
        self.emergencyStopEnabled = emergencyStopEnabled
        self.defaultQuietHoursStartHour = defaultQuietHoursStartHour
        self.defaultQuietHoursEndHour = defaultQuietHoursEndHour
        self.defaultConfidenceThreshold = defaultConfidenceThreshold
        self.defaultMinimumSecondsBetweenSends = defaultMinimumSecondsBetweenSends
        self.defaultDailySendLimit = defaultDailySendLimit
        self.monitorPollIntervalSeconds = monitorPollIntervalSeconds
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autonomyEnabled = try container.decodeIfPresent(Bool.self, forKey: .autonomyEnabled) ?? false
        emergencyStopEnabled = try container.decodeIfPresent(Bool.self, forKey: .emergencyStopEnabled) ?? false
        defaultQuietHoursStartHour = try container.decodeIfPresent(Int.self, forKey: .defaultQuietHoursStartHour) ?? 22
        defaultQuietHoursEndHour = try container.decodeIfPresent(Int.self, forKey: .defaultQuietHoursEndHour) ?? 7
        defaultConfidenceThreshold = try container.decodeIfPresent(Double.self, forKey: .defaultConfidenceThreshold) ?? 0.88
        if let seconds = try container.decodeIfPresent(Int.self, forKey: .defaultMinimumSecondsBetweenSends) {
            defaultMinimumSecondsBetweenSends = seconds
        } else if let legacyMinutes = try container.decodeIfPresent(Int.self, forKey: .defaultMinimumMinutesBetweenSends) {
            defaultMinimumSecondsBetweenSends = legacyMinutes * 60
        } else {
            defaultMinimumSecondsBetweenSends = 30
        }
        defaultDailySendLimit = try container.decodeIfPresent(Int.self, forKey: .defaultDailySendLimit) ?? 5
        monitorPollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .monitorPollIntervalSeconds) ?? 15
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autonomyEnabled, forKey: .autonomyEnabled)
        try container.encode(emergencyStopEnabled, forKey: .emergencyStopEnabled)
        try container.encode(defaultQuietHoursStartHour, forKey: .defaultQuietHoursStartHour)
        try container.encode(defaultQuietHoursEndHour, forKey: .defaultQuietHoursEndHour)
        try container.encode(defaultConfidenceThreshold, forKey: .defaultConfidenceThreshold)
        try container.encode(defaultMinimumSecondsBetweenSends, forKey: .defaultMinimumSecondsBetweenSends)
        try container.encode(defaultDailySendLimit, forKey: .defaultDailySendLimit)
        try container.encode(monitorPollIntervalSeconds, forKey: .monitorPollIntervalSeconds)
    }
}

enum OnboardingStep: String, Codable, Sendable, CaseIterable {
    case welcome
    case privacy
    case model
    case voice
    case autonomy
    case finish
}

struct OnboardingState: Hashable, Codable, Sendable {
    var hasEnteredSetupFlow: Bool
    var currentStep: OnboardingStep
    var privacyReviewed: Bool
    var modelReviewed: Bool
    var voiceSeeded: Bool
    var autonomyReviewed: Bool
    var isCompleted: Bool
    var completedAt: Date?

    static let `default` = OnboardingState(
        hasEnteredSetupFlow: false,
        currentStep: .welcome,
        privacyReviewed: false,
        modelReviewed: false,
        voiceSeeded: false,
        autonomyReviewed: false,
        isCompleted: false,
        completedAt: nil
    )

    private enum CodingKeys: String, CodingKey {
        case hasEnteredSetupFlow
        case currentStep
        case privacyReviewed
        case modelReviewed
        case voiceSeeded
        case autonomyReviewed
        case isCompleted
        case completedAt
    }

    init(
        hasEnteredSetupFlow: Bool,
        currentStep: OnboardingStep,
        privacyReviewed: Bool,
        modelReviewed: Bool,
        voiceSeeded: Bool,
        autonomyReviewed: Bool,
        isCompleted: Bool,
        completedAt: Date?
    ) {
        self.hasEnteredSetupFlow = hasEnteredSetupFlow
        self.currentStep = currentStep
        self.privacyReviewed = privacyReviewed
        self.modelReviewed = modelReviewed
        self.voiceSeeded = voiceSeeded
        self.autonomyReviewed = autonomyReviewed
        self.isCompleted = isCompleted
        self.completedAt = completedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasEnteredSetupFlow = try container.decodeIfPresent(Bool.self, forKey: .hasEnteredSetupFlow) ?? false
        currentStep = try container.decodeIfPresent(OnboardingStep.self, forKey: .currentStep) ?? .welcome
        privacyReviewed = try container.decodeIfPresent(Bool.self, forKey: .privacyReviewed) ?? false
        modelReviewed = try container.decodeIfPresent(Bool.self, forKey: .modelReviewed) ?? false
        voiceSeeded = try container.decodeIfPresent(Bool.self, forKey: .voiceSeeded) ?? false
        autonomyReviewed = try container.decodeIfPresent(Bool.self, forKey: .autonomyReviewed) ?? false
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hasEnteredSetupFlow, forKey: .hasEnteredSetupFlow)
        try container.encode(currentStep, forKey: .currentStep)
        try container.encode(privacyReviewed, forKey: .privacyReviewed)
        try container.encode(modelReviewed, forKey: .modelReviewed)
        try container.encode(voiceSeeded, forKey: .voiceSeeded)
        try container.encode(autonomyReviewed, forKey: .autonomyReviewed)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

struct ActivityLogEntry: Identifiable, Hashable, Codable, Sendable {
    enum Category: String, Codable, Sendable, CaseIterable {
        case startup
        case generation
        case summarization
        case policy
        case simulation
        case send
        case autonomy
        case memory
        case error
    }

    enum Severity: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    let id: UUID
    let timestamp: Date
    let category: Category
    let severity: Severity
    let conversationID: String?
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        category: Category,
        severity: Severity = .info,
        conversationID: String? = nil,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.severity = severity
        self.conversationID = conversationID
        self.message = message
        self.metadata = metadata
    }
}

struct SimulationRunRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let conversationID: String
    let createdAt: Date
    let draftText: String
    let decision: PolicyAction
    let confidence: Double
}

struct MonitorCursor: Hashable, Codable, Sendable {
    let conversationID: String
    let lastMessageID: String
    let lastMessageDateValue: Int64
}

enum ReplyOperationMode: String, Codable, Sendable {
    case draftSuggestion
    case simulation
    case autonomousSend
    case manualSend
}

struct DraftGenerationResult: Hashable, Sendable {
    let conversation: ConversationRef
    let messages: [ChatMessage]
    let promptPacket: PromptPacket
    let draft: ReplyDraft
    let policyDecision: PolicyDecision
    let summarySnapshot: SummarySnapshot
    let userMemory: UserProfileMemory
    let contactMemory: ContactMemory
}

enum ResponderError: LocalizedError, Sendable {
    case missingModelSelection
    case ollamaUnavailable
    case openRouterUnavailable
    case openRouterMissingAPIKey
    case invalidResponse(String)
    case contextLimitExceeded
    case conversationUnavailable
    case sendBlocked(String)

    var errorDescription: String? {
        switch self {
        case .missingModelSelection:
            return "Select a model first."
        case .ollamaUnavailable:
            return "Ollama is unavailable on http://127.0.0.1:11434."
        case .openRouterUnavailable:
            return "OpenRouter is unavailable or returned an unexpected response."
        case .openRouterMissingAPIKey:
            return "Enter an OpenRouter API key in Settings before using the OpenRouter provider."
        case .invalidResponse(let details):
            return "The model response could not be parsed. \(details)"
        case .contextLimitExceeded:
            return "The conversation still exceeds the selected model context limit after compaction."
        case .conversationUnavailable:
            return "The selected conversation is no longer available."
        case .sendBlocked(let reason):
            return reason
        }
    }
}

struct SystemPrompt {
    static let base = """
    You are drafting an iMessage reply as the local user.
    Requirements:
    - Stay faithful to the user's voice and relationship context.
    - Prefer the most privacy-preserving behavior available for the configured provider.
    - Never mention prompts, memory, policies, or internal reasoning.
    - Prefer concise, natural iMessage tone unless the conversation clearly calls for more detail.
    - When uncertain or risky, produce a conservative draft and lower confidence.
    Output strict JSON with keys: draft, confidence, intent, riskFlags, memoryCandidates.
    memoryCandidates must be an object with exactly two array fields: "user" and "contact".
    """
}

extension Date {
    static let appleReferenceDate = Date(timeIntervalSinceReferenceDate: 0)
}

extension Notification.Name {
    /// Posted when the user grants Contacts access so the app can refetch names from Messages data.
    static let responderContactsAccessGranted = Notification.Name("com.ash.responder.contactsAccessGranted")
}
