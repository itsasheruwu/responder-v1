import Foundation

// MARK: - Normalization (dedup / suppression keys)

enum MemoryNormalization: Sendable {
    static func key(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let folded = trimmed.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let collapsed = folded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed
    }
}

// MARK: - Item model

enum MemoryScope: String, Codable, Sendable, Hashable {
    case user
    case contact
}

enum MemoryItemBucket: String, Codable, Sendable, Hashable {
    case manualUser
    case derivedUserGlobal
    case derivedUserOpenRouter
    case manualContact
    case derivedContact
}

enum MemoryItemKind: String, Codable, Sendable, Hashable, CaseIterable {
    case profileSummary
    case styleTrait
    case bannedPhrase
    case backgroundFact
    case replyHabit
    case relationshipSummary
    case preference
    case recurringTopic
    case boundary
    case note
}

struct MemoryItem: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var bucket: MemoryItemBucket
    var scope: MemoryScope
    var memoryKey: String?
    var conversationID: String?
    var kind: MemoryItemKind
    var text: String
    var normalizedKey: String
    var source: MemorySyncSource
    var createdAt: Date
    var updatedAt: Date
    var supersedesItemID: UUID?
    var pinned: Bool
    var userVerified: Bool
    var suppressed: Bool

    init(
        id: UUID = UUID(),
        bucket: MemoryItemBucket,
        scope: MemoryScope,
        memoryKey: String? = nil,
        conversationID: String? = nil,
        kind: MemoryItemKind,
        text: String,
        source: MemorySyncSource,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        supersedesItemID: UUID? = nil,
        pinned: Bool = false,
        userVerified: Bool = false,
        suppressed: Bool = false,
        normalizedKeyOverride: String? = nil
    ) {
        self.id = id
        self.bucket = bucket
        self.scope = scope
        self.memoryKey = memoryKey
        self.conversationID = conversationID
        self.kind = kind
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = trimmed
        self.normalizedKey = normalizedKeyOverride ?? MemoryNormalization.key(for: trimmed)
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.supersedesItemID = supersedesItemID
        self.pinned = pinned
        self.userVerified = userVerified
        self.suppressed = suppressed
    }

    enum CodingKeys: String, CodingKey {
        case id
        case bucket
        case scope
        case memoryKey
        case conversationID
        case kind
        case text
        case normalizedKey
        case source
        case createdAt
        case updatedAt
        case supersedesItemID
        case pinned
        case userVerified
        case suppressed
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        bucket = try c.decode(MemoryItemBucket.self, forKey: .bucket)
        scope = try c.decode(MemoryScope.self, forKey: .scope)
        memoryKey = try c.decodeIfPresent(String.self, forKey: .memoryKey)
        conversationID = try c.decodeIfPresent(String.self, forKey: .conversationID)
        kind = try c.decode(MemoryItemKind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        if let key = try c.decodeIfPresent(String.self, forKey: .normalizedKey), !key.isEmpty {
            normalizedKey = key
        } else {
            normalizedKey = MemoryNormalization.key(for: text)
        }
        source = try c.decode(MemorySyncSource.self, forKey: .source)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        supersedesItemID = try c.decodeIfPresent(UUID.self, forKey: .supersedesItemID)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        userVerified = try c.decodeIfPresent(Bool.self, forKey: .userVerified) ?? false
        suppressed = try c.decodeIfPresent(Bool.self, forKey: .suppressed) ?? false
    }

    mutating func refreshNormalization() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = trimmed
        normalizedKey = MemoryNormalization.key(for: trimmed)
    }
}

// MARK: - Active / superseded item sets

enum MemoryItemVisibility: Sendable {
    /// Items whose `id` appears as `supersedesItemID` on another item are hidden by default.
    static func activeItems(_ items: [MemoryItem]) -> [MemoryItem] {
        let supersededRootIds = Set(items.compactMap(\.supersedesItemID))
        return items.filter { item in
            !item.suppressed && !item.normalizedKey.isEmpty && !supersededRootIds.contains(item.id)
        }
    }
}

// MARK: - Duplicate rows (same text / normalization)

enum MemoryItemDeduper: Sendable {
    /// Collapses rows that are the same memory: same placement (`scope`, `bucket`, keys, `conversationID`, `kind`, `suppressed`) and same normalized text (or exact trimmed text when no norm).
    ///
    /// Winner: pinned over unpinned, then newest `updatedAt`, then user-verified, then source (`manual` beats cloud/heuristics), then stable `id`.
    static func deduplicate(_ items: [MemoryItem]) -> [MemoryItem] {
        guard items.count > 1 else { return items }
        struct Key: Hashable {
            let scope: MemoryScope
            let bucket: MemoryItemBucket
            let memoryKey: String
            let conversationID: String
            let kind: MemoryItemKind
            let suppressed: Bool
            let fingerprint: String
        }
        func fingerprint(for item: MemoryItem) -> String {
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.normalizedKey.isEmpty { return item.normalizedKey }
            let n = MemoryNormalization.key(for: trimmed)
            if !n.isEmpty { return n }
            return trimmed
        }
        func key(for item: MemoryItem) -> Key {
            Key(
                scope: item.scope,
                bucket: item.bucket,
                memoryKey: item.memoryKey ?? "",
                conversationID: item.conversationID ?? "",
                kind: item.kind,
                suppressed: item.suppressed,
                fingerprint: fingerprint(for: item)
            )
        }
        var winners: [Key: MemoryItem] = [:]
        winners.reserveCapacity(items.count)
        for item in items {
            let k = key(for: item)
            if let existing = winners[k] {
                winners[k] = pickBetter(item, existing)
            } else {
                winners[k] = item
            }
        }
        var seen = Set<Key>()
        seen.reserveCapacity(winners.count)
        var out: [MemoryItem] = []
        out.reserveCapacity(winners.count)
        for item in items {
            let k = key(for: item)
            guard !seen.contains(k) else { continue }
            seen.insert(k)
            if let winner = winners[k] {
                out.append(winner)
            }
        }
        return out
    }

    private static func pickBetter(_ a: MemoryItem, _ b: MemoryItem) -> MemoryItem {
        prefers(a, over: b) ? a : b
    }

    private static func prefers(_ a: MemoryItem, over b: MemoryItem) -> Bool {
        if a.pinned != b.pinned { return a.pinned && !b.pinned }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if a.userVerified != b.userVerified { return a.userVerified && !b.userVerified }
        let ra = sourceRank(a.source)
        let rb = sourceRank(b.source)
        if ra != rb { return ra < rb }
        return a.id.uuidString < b.id.uuidString
    }

    private static func sourceRank(_ s: MemorySyncSource) -> Int {
        switch s {
        case .manual: return 0
        case .openRouter: return 1
        case .heuristic: return 2
        case .acceptedDraft: return 3
        }
    }
}

// MARK: - Retrieval

struct MemoryRetrievalConfig: Hashable, Sendable {
    var maxUserItems: Int
    var maxContactItems: Int
    var recentMessageCount: Int

    static let `default` = MemoryRetrievalConfig(maxUserItems: 24, maxContactItems: 24, recentMessageCount: 12)
}

/// Caps derived `memory_item` rows (non-pinned, non-suppressed) per slice; tombstones trimmed separately by age/count.
enum MemoryStorageLimits: Sendable {
    static let maxDerivedRowsUserGlobal = 400
    static let maxDerivedRowsOpenRouterSlice = 400
    static let maxDerivedRowsContact = 400
    /// Drop oldest suppressed rows after this many per `(scope, memory_key)` fingerprint.
    static let maxSuppressedTombstonesPerKey = 200
    /// Suppressed rows older than this are deleted on maintenance passes.
    static let suppressedRetentionSeconds: TimeInterval = 90 * 24 * 3600
}

/// Abstracts scoring (keyword vs embedding). Async for network-backed embedders.
protocol MemoryRetrieving: Sendable {
    func rankItems(_ items: [MemoryItem], against recentMessages: [ChatMessage]) async throws -> [MemoryItem]
}

struct KeywordOverlapMemoryRetriever: MemoryRetrieving {
    func rankItems(_ items: [MemoryItem], against recentMessages: [ChatMessage]) async throws -> [MemoryItem] {
        let window = MemoryTranscriptWindow.recentMessagesForDerivation(
            recentMessages,
            maxCount: MemoryTranscriptWindow.defaultMaxMessageCount,
            maxAge: nil
        )
        let suffix = Array(window.suffix(12))
        let corpus = suffix.map(\.text).joined(separator: " ")
        let queryTokens = tokenize(corpus)
        guard !queryTokens.isEmpty else {
            return items.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
        return items.sorted { lhs, rhs in
            let sl = score(lhs, queryTokens: queryTokens)
            let sr = score(rhs, queryTokens: queryTokens)
            if sl != sr { return sl > sr }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func score(_ item: MemoryItem, queryTokens: Set<String>) -> Int {
        let tokens = tokenize(item.text)
        return tokens.intersection(queryTokens).count
    }

    private func tokenize(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let parts = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
        return Set(parts)
    }
}

enum MemoryPromptAssembly: Sendable {
    /// Pinned + all manual bucket items, plus top non-manual by retriever until `maxCount`.
    static func selectPromptItems(
        mergedItems: [MemoryItem],
        manualBuckets: Set<MemoryItemBucket>,
        recentMessages: [ChatMessage],
        maxCount: Int,
        retriever: any MemoryRetrieving
    ) async throws -> [MemoryItem] {
        let active = MemoryItemVisibility.activeItems(mergedItems)
        let manual = active.filter { manualBuckets.contains($0.bucket) }
        let nonManual = active.filter { !manualBuckets.contains($0.bucket) }
        let pinnedNonManual = nonManual.filter(\.pinned)
        let unpinnedNonManual = nonManual.filter { !$0.pinned }

        var picked: [MemoryItem] = []
        var seen = Set<String>()

        func appendUnique(_ item: MemoryItem) {
            let sig = "\(item.id.uuidString)"
            guard seen.insert(sig).inserted else { return }
            picked.append(item)
        }

        for item in manual.sorted(by: tieBreak) {
            appendUnique(item)
            if picked.count >= maxCount { return picked }
        }
        for item in pinnedNonManual.sorted(by: tieBreak) {
            appendUnique(item)
            if picked.count >= maxCount { return picked }
        }

        let ranked = try await retriever.rankItems(unpinnedNonManual, against: recentMessages)
        for item in ranked {
            if picked.count >= maxCount { break }
            appendUnique(item)
        }
        return picked
    }

    private static func tieBreak(lhs: MemoryItem, rhs: MemoryItem) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
