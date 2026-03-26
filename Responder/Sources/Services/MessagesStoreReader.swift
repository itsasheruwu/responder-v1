import Contacts
import Foundation
import GRDB
import OSLog

actor MessagesStoreReader: MessagesStoreProtocol {
    private let sourceDatabaseURL: URL
    private let securityScopedMessagesDirectoryURL: URL?
    private let snapshotRootURL: URL
    private let fileManager: FileManager
    private let contactResolver = ContactNameResolver()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Responder", category: "MessagesStoreReader")
    private var cachedSnapshot: SnapshotContext?
    private var cachedSnapshotSignature: SnapshotSignature?
    private var cachedConversationLists: [Int: [ConversationRef]] = [:]
    private var cachedConversationByID: [String: ConversationRef] = [:]
    private var cachedMessageLists: [MessageCacheKey: [ChatMessage]] = [:]

    init(messagesDirectoryAccess: MessagesDirectoryAccess? = nil) throws {
        fileManager = .default
        snapshotRootURL = fileManager.temporaryDirectory.appending(path: "ResponderMessagesSnapshots", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: snapshotRootURL, withIntermediateDirectories: true)
        Self.cleanupSnapshots(at: snapshotRootURL, fileManager: fileManager)

        let defaultMessagesDirectoryURL = fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Messages", directoryHint: .isDirectory)
        let defaultDatabaseURL = defaultMessagesDirectoryURL.appending(path: "chat.db")

        if fileManager.fileExists(atPath: defaultDatabaseURL.path) {
            sourceDatabaseURL = defaultDatabaseURL
            securityScopedMessagesDirectoryURL = nil
            return
        }

        guard let messagesDirectoryAccess else {
            throw Self.makeMessagesAccessError()
        }

        let resolvedDirectoryURL = try Self.resolveMessagesDirectoryURL(from: messagesDirectoryAccess)
        let bookmarkedDatabaseURL = resolvedDirectoryURL.appending(path: "chat.db")
        // `resolveMessagesDirectoryURL` ends security-scoped access before returning; visibility of
        // `chat.db` for a user-picked folder must be checked while the scope is active.
        try Self.withMessagesDirectoryAccess(url: resolvedDirectoryURL) {
            guard FileManager.default.fileExists(atPath: bookmarkedDatabaseURL.path) else {
                throw Self.makeMessagesAccessError()
            }
        }

        sourceDatabaseURL = bookmarkedDatabaseURL
        securityScopedMessagesDirectoryURL = resolvedDirectoryURL
    }

    func fetchConversations(limit: Int) async throws -> [ConversationRef] {
        if let cached = try cachedConversations(limit: limit) {
            return cached
        }

        return try await withSnapshotQueue { [self] dbQueue in
            let rows: [ConversationRow] = try await dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT c.ROWID AS rowid,
                           c.guid,
                           c.display_name,
                           c.chat_identifier,
                           c.service_name,
                           c.style,
                           m.text AS preview_text,
                           m.attributedBody AS preview_attributed_body,
                           m.cache_has_attachments AS preview_has_attachments,
                           m.item_type AS preview_item_type,
                           m.associated_message_guid AS preview_associated_guid,
                           m.date AS last_date,
                           (
                             SELECT COUNT(*)
                             FROM chat_message_join cmj2
                             JOIN message unread ON unread.ROWID = cmj2.message_id
                             WHERE cmj2.chat_id = c.ROWID
                               AND unread.is_from_me = 0
                               AND unread.is_read = 0
                               AND unread.is_finished = 1
                               AND unread.is_system_message = 0
                           ) AS unread_count
                    FROM chat c
                    LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    LEFT JOIN message m ON m.ROWID = cmj.message_id
                    WHERE c.is_archived = 0
                      AND (
                        m.ROWID IS NULL OR (
                            m.is_system_message = 0
                            AND m.ROWID = (
                                SELECT latest.ROWID
                                FROM chat_message_join latest_cmj
                                JOIN message latest ON latest.ROWID = latest_cmj.message_id
                                WHERE latest_cmj.chat_id = c.ROWID
                                  AND latest.is_system_message = 0
                                ORDER BY latest.date DESC, latest.ROWID DESC
                                LIMIT 1
                            )
                        )
                      )
                    ORDER BY last_date DESC
                    LIMIT ?
                    """,
                    arguments: [limit]
                )

                return rows.map(Self.makeConversationRow(from:))
            }

            let conversations = rows.map(Self.makeConversationPreview(from:))
            self.cachedConversationLists[limit] = conversations
            return conversations
        }
    }

    func fetchConversation(id: String) async throws -> ConversationRef? {
        if let cached = try cachedConversation(id: id) {
            return cached
        }

        return try await withSnapshotQueue { [self] dbQueue in
            guard let row = try dbQueue.read({ db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT c.ROWID AS rowid,
                           c.guid,
                           c.display_name,
                           c.chat_identifier,
                           c.service_name,
                           c.style,
                           m.text AS preview_text,
                           m.attributedBody AS preview_attributed_body,
                           m.cache_has_attachments AS preview_has_attachments,
                           m.item_type AS preview_item_type,
                           m.associated_message_guid AS preview_associated_guid,
                           m.date AS last_date,
                           (
                             SELECT COUNT(*)
                             FROM chat_message_join cmj2
                             JOIN message unread ON unread.ROWID = cmj2.message_id
                             WHERE cmj2.chat_id = c.ROWID
                               AND unread.is_from_me = 0
                               AND unread.is_read = 0
                               AND unread.is_finished = 1
                               AND unread.is_system_message = 0
                           ) AS unread_count
                    FROM chat c
                    LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    LEFT JOIN message m ON m.ROWID = cmj.message_id
                    WHERE c.guid = ?
                      AND (
                        m.ROWID IS NULL OR (
                            m.is_system_message = 0
                            AND m.ROWID = (
                                SELECT latest.ROWID
                                FROM chat_message_join latest_cmj
                                JOIN message latest ON latest.ROWID = latest_cmj.message_id
                                WHERE latest_cmj.chat_id = c.ROWID
                                  AND latest.is_system_message = 0
                                ORDER BY latest.date DESC, latest.ROWID DESC
                                LIMIT 1
                            )
                        )
                      )
                    ORDER BY last_date DESC
                    LIMIT 1
                    """,
                    arguments: [id]
                )
            }) else {
                return nil
            }

            let conversation = try await self.hydrateConversation(from: Self.makeConversationRow(from: row), dbQueue: dbQueue)
            self.cachedConversationByID[conversation.id] = conversation
            return conversation
        }
    }

    func fetchMessages(conversationID: String, limit: Int) async throws -> [ChatMessage] {
        if let cached = try cachedMessages(conversationID: conversationID, limit: limit) {
            return cached
        }

        return try await withSnapshotQueue { [self] dbQueue in
            let rows: [MessageRow] = try await dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT m.guid,
                           m.text,
                           m.attributedBody,
                           m.date,
                           m.is_from_me,
                           m.cache_has_attachments,
                           m.item_type,
                           m.associated_message_guid,
                           m.is_system_message,
                           h.id AS handle_id,
                           COALESCE(NULLIF(h.id, ''), 'Me') AS sender_label
                    FROM chat_message_join cmj
                    JOIN chat c ON c.ROWID = cmj.chat_id
                    JOIN message m ON m.ROWID = cmj.message_id
                    LEFT JOIN handle h ON h.ROWID = CASE
                        WHEN m.handle_id != 0 THEN m.handle_id
                        ELSE m.other_handle
                    END
                    WHERE c.guid = ?
                      AND m.is_system_message = 0
                    ORDER BY m.date DESC, m.ROWID DESC
                    LIMIT ?
                    """,
                    arguments: [conversationID, limit]
                )

                return rows.map { row in
                    MessageRow(
                        guid: row["guid"],
                        text: row["text"],
                        attributedBody: row["attributedBody"],
                        dateRaw: row["date"],
                        isFromMe: (row["is_from_me"] ?? 0) == 1,
                        hasAttachments: (row["cache_has_attachments"] ?? 0) == 1,
                        itemType: row["item_type"] ?? 0,
                        associatedGuid: row["associated_message_guid"],
                        handleID: row["handle_id"],
                        fallbackSenderLabel: row["sender_label"] ?? "Contact"
                    )
                }
            }

            var messages: [ChatMessage] = []
            messages.reserveCapacity(rows.count)

            for row in rows.reversed() {
                guard let date = Self.appleDate(rawValue: row.dateRaw) else { continue }
                let senderName: String
                if row.isFromMe {
                    senderName = "Me"
                } else if let handleID = row.handleID {
                    senderName = await self.contactResolver.displayName(for: handleID) ?? row.fallbackSenderLabel
                } else {
                    senderName = row.fallbackSenderLabel
                }

                let normalized = Self.normalizeMessageText(
                    rawText: row.text,
                    attributedBody: row.attributedBody,
                    hasAttachment: row.hasAttachments,
                    itemType: row.itemType,
                    hasAssociatedContent: row.associatedGuid != nil
                )

                messages.append(
                    ChatMessage(
                        id: row.guid,
                        text: normalized.text,
                        senderName: senderName,
                        senderHandle: row.handleID,
                        date: date,
                        direction: row.isFromMe ? .outgoing : .incoming,
                        containsAttachmentPlaceholder: normalized.containsAttachmentPlaceholder,
                        isUnsupportedContent: normalized.isUnsupportedContent
                    )
                )
            }

            self.cachedMessageLists[MessageCacheKey(conversationID: conversationID, limit: limit)] = messages
            return messages
        }
    }

    func invalidateContactLabelCaches() {
        cachedConversationLists.removeAll()
        cachedConversationByID.removeAll()
        cachedMessageLists.removeAll()
    }

    func latestCursor(conversationID: String) async throws -> MonitorCursor? {
        try await withSnapshotQueue { dbQueue in
            try await dbQueue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT m.guid, m.date
                    FROM chat c
                    JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE c.guid = ?
                      AND m.is_system_message = 0
                      AND m.is_from_me = 0
                    ORDER BY m.date DESC, m.ROWID DESC
                    LIMIT 1
                    """,
                    arguments: [conversationID]
                ) else {
                    return nil
                }

                return MonitorCursor(
                    conversationID: conversationID,
                    lastMessageID: row["guid"],
                    lastMessageDateValue: row["date"] ?? 0
                )
            }
        }
    }

    private func loadParticipants(chatRowID: Int64, service: ConversationService, dbQueue: DatabaseQueue) async throws -> [Participant] {
        let handles: [(handle: String, fallbackName: String)] = try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT h.id, COALESCE(NULLIF(h.uncanonicalized_id, ''), h.id) AS display_name
                FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id = ?
                ORDER BY h.id
                """,
                arguments: [chatRowID]
            )

            return rows.map { (($0["id"] as String? ?? ""), ($0["display_name"] as String? ?? "")) }
        }

        var participants: [Participant] = []
        participants.reserveCapacity(handles.count)

        for item in handles {
            let resolvedName = await contactResolver.displayName(for: item.handle)
            participants.append(
                Participant(
                    handle: item.handle,
                    displayName: resolvedName ?? item.fallbackName.nonEmpty ?? item.handle,
                    service: service
                )
            )
        }

        return participants
    }

    private func hydrateConversation(from row: ConversationRow, dbQueue: DatabaseQueue) async throws -> ConversationRef {
        let participants = try await loadParticipants(chatRowID: row.chatRowID, service: row.service, dbQueue: dbQueue)
        let title = row.displayName?.nonEmpty ?? Self.defaultTitle(
            chatIdentifier: row.chatIdentifier,
            participants: participants
        )
        let normalized = Self.normalizeMessageText(
            rawText: row.previewText,
            attributedBody: row.previewAttributedBody,
            hasAttachment: row.previewHasAttachments,
            itemType: row.previewItemType,
            hasAssociatedContent: row.previewAssociatedGuid != nil
        )

        return ConversationRef(
            id: row.guid,
            title: title,
            service: row.service,
            participants: participants,
            isGroup: Self.isGroupConversation(participants: participants, style: row.style),
            lastMessagePreview: normalized.text,
            lastMessageDate: Self.appleDate(rawValue: row.lastDateRaw),
            unreadCount: row.unreadCount
        )
    }

    private func withSnapshotQueue<T>(_ operation: @escaping (DatabaseQueue) async throws -> T) async throws -> T {
        let snapshot = try snapshotContext()
        return try await operation(snapshot.dbQueue)
    }

    private func snapshotContext() throws -> SnapshotContext {
        let signature = try Self.makeSnapshotSignature(
            sourceDatabaseURL: sourceDatabaseURL,
            securityScopedMessagesDirectoryURL: securityScopedMessagesDirectoryURL,
            fileManager: fileManager
        )

        if let cachedSnapshot,
           let cachedSnapshotSignature,
           cachedSnapshotSignature == signature,
           cachedSnapshot.snapshotFilesAreValid(fileManager: fileManager) {
            return cachedSnapshot
        }

        if let cachedSnapshot {
            cachedSnapshot.cleanupDirectoryIfNeeded(fileManager: fileManager)
        }
        cachedConversationLists.removeAll()
        cachedConversationByID.removeAll()
        cachedMessageLists.removeAll()

        let snapshot = try Self.makeSnapshotContext(
            sourceDatabaseURL: sourceDatabaseURL,
            securityScopedMessagesDirectoryURL: securityScopedMessagesDirectoryURL,
            log: log
        )
        cachedSnapshot = snapshot
        cachedSnapshotSignature = signature
        return snapshot
    }

    private func cachedConversations(limit: Int) throws -> [ConversationRef]? {
        guard try snapshotIsCurrent() else { return nil }
        return cachedConversationLists[limit]
    }

    private func cachedConversation(id: String) throws -> ConversationRef? {
        guard try snapshotIsCurrent() else { return nil }
        return cachedConversationByID[id]
    }

    private func cachedMessages(conversationID: String, limit: Int) throws -> [ChatMessage]? {
        guard try snapshotIsCurrent() else { return nil }
        return cachedMessageLists[MessageCacheKey(conversationID: conversationID, limit: limit)]
    }

    private func snapshotIsCurrent() throws -> Bool {
        guard let cachedSnapshot, let cachedSnapshotSignature else {
            return false
        }

        let currentSignature = try Self.makeSnapshotSignature(
            sourceDatabaseURL: sourceDatabaseURL,
            securityScopedMessagesDirectoryURL: securityScopedMessagesDirectoryURL,
            fileManager: fileManager
        )
        guard currentSignature == cachedSnapshotSignature,
              cachedSnapshot.snapshotFilesAreValid(fileManager: fileManager) else {
            cachedSnapshot.cleanupDirectoryIfNeeded(fileManager: fileManager)
            self.cachedSnapshot = nil
            self.cachedSnapshotSignature = nil
            cachedConversationLists.removeAll()
            cachedConversationByID.removeAll()
            cachedMessageLists.removeAll()
            return false
        }

        return true
    }

    private static func makeSnapshotContext(
        sourceDatabaseURL: URL,
        securityScopedMessagesDirectoryURL: URL?,
        log: Logger
    ) throws -> SnapshotContext {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "MessagesStoreReaderSnapshot"

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let dbQueue: DatabaseQueue = try withMessagesDirectoryAccess(url: securityScopedMessagesDirectoryURL) {
                    try DatabaseQueue.temporaryCopy(fromPath: sourceDatabaseURL.path, configuration: configuration)
                }
                return SnapshotContext(directoryURL: nil, dbQueue: dbQueue)
            } catch {
                lastError = error
                log.error("Messages DB snapshot failed (attempt \(attempt + 1)/3): \(error.localizedDescription)")
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }
        throw lastError ?? makeMessagesAccessError(detail: "Could not create a consistent copy of chat.db (SQLite backup failed).")
    }

    private static func makeSnapshotSignature(
        sourceDatabaseURL: URL,
        securityScopedMessagesDirectoryURL: URL?,
        fileManager: FileManager
    ) throws -> SnapshotSignature {
        try withMessagesDirectoryAccess(url: securityScopedMessagesDirectoryURL) {
            SnapshotSignature(
                database: try fileSignature(for: sourceDatabaseURL, fileManager: fileManager),
                wal: try optionalFileSignature(for: URL(fileURLWithPath: sourceDatabaseURL.path + "-wal"), fileManager: fileManager),
                shm: try optionalFileSignature(for: URL(fileURLWithPath: sourceDatabaseURL.path + "-shm"), fileManager: fileManager)
            )
        }
    }

    private static func fileSignature(for url: URL, fileManager: FileManager) throws -> FileSignature {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return FileSignature(
            modificationDate: attributes[.modificationDate] as? Date,
            fileSize: (attributes[.size] as? NSNumber)?.int64Value
        )
    }

    private static func optionalFileSignature(for url: URL, fileManager: FileManager) throws -> FileSignature? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try fileSignature(for: url, fileManager: fileManager)
    }

    private static func resolveMessagesDirectoryURL(from access: MessagesDirectoryAccess) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: access.bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard url.startAccessingSecurityScopedResource() else {
            throw makeMessagesAccessError(detail: "Responder could not reopen the saved Messages folder permission.")
        }
        defer { url.stopAccessingSecurityScopedResource() }

        if isStale {
            _ = try? MessagesDirectoryAccessStore.save(directoryURL: url)
        }

        return url
    }

    private static func withMessagesDirectoryAccess<T>(url: URL?, operation: () throws -> T) throws -> T {
        guard let url else {
            return try operation()
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw makeMessagesAccessError(detail: "Responder could not reopen the saved Messages folder permission.")
        }
        defer { url.stopAccessingSecurityScopedResource() }

        return try operation()
    }

    private static func makeMessagesAccessError(detail: String? = nil) -> NSError {
        let message = detail ?? "Responder does not currently have permission to read ~/Library/Messages/chat.db."
        return NSError(
            domain: "MessagesStoreReader",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func cleanupSnapshots(at snapshotRootURL: URL, fileManager: FileManager) {
        guard let snapshotURLs = try? fileManager.contentsOfDirectory(
            at: snapshotRootURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for snapshotURL in snapshotURLs {
            cleanupSnapshot(at: snapshotURL, fileManager: fileManager)
        }
    }

    private static func cleanupSnapshot(at directoryURL: URL, fileManager: FileManager) {
        try? fileManager.removeItem(at: directoryURL)
    }

    private static func makeConversationRow(from row: Row) -> ConversationRow {
        ConversationRow(
            chatRowID: row["rowid"],
            guid: row["guid"],
            displayName: row["display_name"],
            chatIdentifier: row["chat_identifier"],
            service: ConversationService(rawService: row["service_name"]),
            style: row["style"] ?? 0,
            previewText: row["preview_text"],
            previewAttributedBody: row["preview_attributed_body"],
            previewHasAttachments: (row["preview_has_attachments"] ?? 0) == 1,
            previewItemType: row["preview_item_type"] ?? 0,
            previewAssociatedGuid: row["preview_associated_guid"],
            lastDateRaw: row["last_date"],
            unreadCount: row["unread_count"] ?? 0
        )
    }

    private static func makeConversationPreview(from row: ConversationRow) -> ConversationRef {
        let participants = previewParticipants(from: row)
        let title = row.displayName?.nonEmpty ?? defaultTitle(
            chatIdentifier: row.chatIdentifier,
            participants: participants
        )
        let normalized = normalizeMessageText(
            rawText: row.previewText,
            attributedBody: row.previewAttributedBody,
            hasAttachment: row.previewHasAttachments,
            itemType: row.previewItemType,
            hasAssociatedContent: row.previewAssociatedGuid != nil
        )

        return ConversationRef(
            id: row.guid,
            title: title,
            service: row.service,
            participants: participants,
            isGroup: isGroupConversation(participants: participants, style: row.style),
            lastMessagePreview: normalized.text,
            lastMessageDate: appleDate(rawValue: row.lastDateRaw),
            unreadCount: row.unreadCount
        )
    }

    private static func previewParticipants(from row: ConversationRow) -> [Participant] {
        guard row.style == 45,
              let handle = row.chatIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !handle.isEmpty
        else {
            return []
        }

        let displayName = row.displayName?.nonEmpty ?? handle
        return [Participant(handle: handle, displayName: displayName, service: row.service)]
    }

    private static func defaultTitle(chatIdentifier: String?, participants: [Participant]) -> String {
        if !participants.isEmpty {
            return participants.map(\.displayName).joined(separator: ", ")
        }
        if let chatIdentifier, !chatIdentifier.isEmpty {
            return chatIdentifier
        }
        return "Unknown Conversation"
    }

    private static func isGroupConversation(participants: [Participant], style: Int) -> Bool {
        participants.count > 1 || style != 45
    }

    private static func appleDate(rawValue: Int64?) -> Date? {
        guard let rawValue, rawValue != 0 else { return nil }
        let seconds: TimeInterval
        if abs(rawValue) > 10_000_000_000 {
            seconds = TimeInterval(rawValue) / 1_000_000_000
        } else {
            seconds = TimeInterval(rawValue)
        }
        return Date.appleReferenceDate.addingTimeInterval(seconds)
    }

    private static func normalizeMessageText(
        rawText: String?,
        attributedBody: Data?,
        hasAttachment: Bool,
        itemType: Int,
        hasAssociatedContent: Bool
    ) -> (text: String, containsAttachmentPlaceholder: Bool, isUnsupportedContent: Bool) {
        if let rawText = rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !rawText.isEmpty {
            return (rawText, hasAttachment, itemType != 0 || hasAssociatedContent)
        }

        if let decodedBody = extractText(from: attributedBody), !decodedBody.isEmpty, decodedBody != "\u{FFFC}" {
            return (decodedBody, hasAttachment, itemType != 0 || hasAssociatedContent)
        }

        if hasAttachment {
            return ("[Attachment omitted]", true, false)
        }
        if itemType != 0 || hasAssociatedContent {
            return ("[Unsupported message]", false, true)
        }
        return ("[Empty message]", false, false)
    }

    private static func extractText(from attributedBody: Data?) -> String? {
        guard let attributedBody, !attributedBody.isEmpty else { return nil }
        guard let markerRange = attributedBody.range(of: Data("NSString".utf8)) else { return nil }

        let markerEnd = markerRange.upperBound
        guard let plusOffset = attributedBody[markerEnd...].firstIndex(of: 0x2B) else { return nil }

        let lengthStart = attributedBody.index(after: plusOffset)
        guard lengthStart < attributedBody.endIndex else { return nil }

        let byteCount = Int(attributedBody[lengthStart])
        guard byteCount >= 0 else { return nil }

        let textStart = attributedBody.index(after: lengthStart)
        guard let textEnd = attributedBody.index(textStart, offsetBy: byteCount, limitedBy: attributedBody.endIndex) else {
            return nil
        }

        let payload = attributedBody[textStart..<textEnd]
        let string = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }
}

private struct ConversationRow: Sendable {
    let chatRowID: Int64
    let guid: String
    let displayName: String?
    let chatIdentifier: String?
    let service: ConversationService
    let style: Int
    let previewText: String?
    let previewAttributedBody: Data?
    let previewHasAttachments: Bool
    let previewItemType: Int
    let previewAssociatedGuid: String?
    let lastDateRaw: Int64?
    let unreadCount: Int
}

private struct MessageRow: Sendable {
    let guid: String
    let text: String?
    let attributedBody: Data?
    let dateRaw: Int64?
    let isFromMe: Bool
    let hasAttachments: Bool
    let itemType: Int
    let associatedGuid: String?
    let handleID: String?
    let fallbackSenderLabel: String
}

private struct SnapshotContext {
    /// Present only for legacy on-disk file-copy snapshots; GRDB ``DatabaseQueue/temporaryCopy(fromPath:configuration:)`` snapshots omit this.
    let directoryURL: URL?
    let dbQueue: DatabaseQueue

    fileprivate func snapshotFilesAreValid(fileManager: FileManager) -> Bool {
        guard let directoryURL else { return true }
        return fileManager.fileExists(atPath: directoryURL.path)
    }

    fileprivate func cleanupDirectoryIfNeeded(fileManager: FileManager) {
        guard let directoryURL else { return }
        Self.cleanupSnapshot(at: directoryURL, fileManager: fileManager)
    }

    private static func cleanupSnapshot(at directoryURL: URL, fileManager: FileManager) {
        try? fileManager.removeItem(at: directoryURL)
    }
}

private struct SnapshotSignature: Equatable {
    let database: FileSignature
    let wal: FileSignature?
    let shm: FileSignature?
}

private struct FileSignature: Equatable {
    let modificationDate: Date?
    let fileSize: Int64?
}

private struct MessageCacheKey: Hashable {
    let conversationID: String
    let limit: Int
}

actor ContactNameResolver {
    /// Empty string means a completed lookup with no matching display name (cache negative results).
    private var cache: [String: String] = [:]
    private var accessAttempted = false
    private var canAccessContacts = false
    private var permissionRequestTask: Task<Void, Never>?

    func displayName(for rawHandle: String) async -> String? {
        let key = Self.normalize(handle: rawHandle)
        if let cached = cache[key] {
            return cached.isEmpty ? nil : cached
        }

        await refreshAccessStatus()
        guard canAccessContacts else {
            requestAccessIfNeeded()
            return nil
        }

        let name = await lookupContactNameOnMainActor(normalizedHandle: key)
        cache[key] = name ?? ""
        return name
    }

    private func refreshAccessStatus() async {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized, .limited:
            accessAttempted = true
            canAccessContacts = true
        case .notDetermined:
            canAccessContacts = false
        case .denied, .restricted:
            accessAttempted = true
            canAccessContacts = false
        @unknown default:
            accessAttempted = true
            canAccessContacts = false
        }
    }

    private func requestAccessIfNeeded() {
        guard !accessAttempted else { return }
        guard permissionRequestTask == nil else { return }
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return }

        accessAttempted = true
        permissionRequestTask = Task {
            let granted = await Task { @MainActor in
                let store = CNContactStore()
                return (try? await store.requestAccess(for: .contacts)) ?? false
            }.value
            await self.completePermissionRequest(granted: granted)
        }
    }

    private func completePermissionRequest(granted: Bool) async {
        canAccessContacts = granted
        permissionRequestTask = nil
        if granted {
            cache.removeAll()
            NotificationCenter.default.post(name: .responderContactsAccessGranted, object: nil)
        }
    }

    @MainActor
    private static func contactLookupKeys() -> [CNKeyDescriptor] {
        [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactNamePrefixKey as CNKeyDescriptor,
            CNContactNameSuffixKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
        ]
    }

    private func lookupContactNameOnMainActor(normalizedHandle: String) async -> String? {
        await MainActor.run {
            let store = CNContactStore()
            let keys = Self.contactLookupKeys()

            if normalizedHandle.contains("@") {
                let predicate = CNContact.predicateForContacts(matchingEmailAddress: normalizedHandle)
                if let contact = try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first {
                    return Self.formattedName(from: contact)
                }
            }

            let phoneVariants = Self.phoneLookupVariants(for: normalizedHandle)
            for variant in phoneVariants {
                let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: variant))
                if let contact = try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first {
                    return Self.formattedName(from: contact)
                }
            }

            return nil
        }
    }

    private static func formattedName(from contact: CNContact) -> String? {
        // Avoid `CNContactFormatter` + `.fullName` here: on some unified contacts it calls into
        // `-[CNContact displayNameOrder]` and can raise an Objective‑C exception (crashing the app).
        // Assemble from the keys we fetch instead.
        var segments: [String] = []
        for piece in [
            contact.namePrefix,
            contact.givenName,
            contact.middleName,
            contact.familyName,
            contact.nameSuffix
        ] {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(trimmed) }
        }
        if !segments.isEmpty {
            return segments.joined(separator: " ")
        }

        let nickname = contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nickname.isEmpty { return nickname }

        let department = contact.departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !department.isEmpty { return department }

        let org = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !org.isEmpty { return org }

        return nil
    }

    private static func phoneLookupVariants(for normalizedHandle: String) -> [String] {
        let digits = normalizedHandle.filter(\.isNumber)
        guard !digits.isEmpty else { return dedupe([normalizedHandle]) }

        var variants = [normalizedHandle, digits]
        if normalizedHandle.hasPrefix("+") {
            variants.append(String(normalizedHandle.dropFirst()))
        }
        if let lastTen = digits.suffixIfLonger(than: 10) {
            variants.append(String(lastTen))
        }
        if let last11 = digits.suffixIfLonger(than: 11) {
            variants.append(String(last11))
        }
        return dedupe(variants)
    }

    private static func dedupe(_ variants: [String]) -> [String] {
        Array(NSOrderedSet(array: variants)) as? [String] ?? variants
    }

    private static func normalize(handle: String) -> String {
        var h = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("tel:") { h.removeFirst(4) }
        if h.hasPrefix("sms:") { h.removeFirst(4) }
        return h.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    func suffixIfLonger(than length: Int) -> Substring? {
        count > length ? suffix(length) : nil
    }
}
