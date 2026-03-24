import Contacts
import Foundation
import GRDB

actor MessagesStoreReader: MessagesStoreProtocol {
    private let dbQueue: DatabaseQueue
    private let contactResolver = ContactNameResolver()

    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Messages/chat.db")) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "MessagesStoreReader"
        dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    }

    func fetchConversations(limit: Int) async throws -> [ConversationRef] {
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

            return rows.map { row in
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
        }

        var conversations: [ConversationRef] = []
        conversations.reserveCapacity(rows.count)

        for row in rows {
            let participants = try await loadParticipants(chatRowID: row.chatRowID, service: row.service)
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

            conversations.append(
                ConversationRef(
                    id: row.guid,
                    title: title,
                    service: row.service,
                    participants: participants,
                    isGroup: Self.isGroupConversation(participants: participants, style: row.style),
                    lastMessagePreview: normalized.text,
                    lastMessageDate: Self.appleDate(rawValue: row.lastDateRaw),
                    unreadCount: row.unreadCount
                )
            )
        }

        return conversations
    }

    func fetchConversation(id: String) async throws -> ConversationRef? {
        try await fetchConversations(limit: 250).first(where: { $0.id == id })
    }

    func fetchMessages(conversationID: String, limit: Int) async throws -> [ChatMessage] {
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
                senderName = await contactResolver.displayName(for: handleID) ?? row.fallbackSenderLabel
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

        return messages
    }

    func latestCursor(conversationID: String) async throws -> MonitorCursor? {
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

    private func loadParticipants(chatRowID: Int64, service: ConversationService) async throws -> [Participant] {
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

actor ContactNameResolver {
    private let store = CNContactStore()
    private var cache: [String: String?] = [:]
    private var accessAttempted = false
    private var canAccessContacts = false

    func displayName(for rawHandle: String) async -> String? {
        let key = normalize(handle: rawHandle)
        if let cached = cache[key] {
            return cached
        }

        await ensureAccess()
        guard canAccessContacts else {
            cache[key] = nil
            return nil
        }

        let name = lookupContactName(for: key)
        cache[key] = name
        return name
    }

    private func ensureAccess() async {
        guard !accessAttempted else { return }
        accessAttempted = true

        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized, .limited:
            canAccessContacts = true
        case .notDetermined:
            canAccessContacts = (try? await store.requestAccess(for: .contacts)) ?? false
        case .denied, .restricted:
            canAccessContacts = false
        @unknown default:
            canAccessContacts = false
        }
    }

    private func lookupContactName(for normalizedHandle: String) -> String? {
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey] as [CNKeyDescriptor]

        if normalizedHandle.contains("@"),
           let contact = try? store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingEmailAddress: normalizedHandle),
                keysToFetch: keys
           ).first,
           let name = formattedName(from: contact) {
            return name
        }

        let phoneVariants = phoneLookupVariants(for: normalizedHandle)
        for variant in phoneVariants {
            let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: variant))
            if let contact = try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first,
               let name = formattedName(from: contact) {
                return name
            }
        }

        return nil
    }

    private func formattedName(from contact: CNContact) -> String? {
        let given = contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let family = contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)

        let fullName = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        if !fullName.isEmpty { return fullName }
        if !nickname.isEmpty { return nickname }
        return nil
    }

    private func phoneLookupVariants(for normalizedHandle: String) -> [String] {
        let digits = normalizedHandle.filter(\.isNumber)
        guard !digits.isEmpty else { return [normalizedHandle] }

        var variants = [normalizedHandle, digits]
        if let lastTen = digits.suffixIfLonger(than: 10) {
            variants.append(String(lastTen))
        }
        return Array(NSOrderedSet(array: variants)) as? [String] ?? variants
    }

    private func normalize(handle: String) -> String {
        handle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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
