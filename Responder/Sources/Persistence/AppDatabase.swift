import Foundation
import GRDB

actor AppDatabase {
    private let dbQueue: DatabaseQueue
    let databaseURL: URL
    /// When false (in-memory test DB), settings are not mirrored to `app-settings.json`.
    private let mirrorsSettingsJSONToFile: Bool

    init(inMemory: Bool = false) throws {
        mirrorsSettingsJSONToFile = !inMemory
        if inMemory {
            databaseURL = URL(fileURLWithPath: "/dev/null")
            dbQueue = try DatabaseQueue()
        } else {
            let support = try Self.makeSupportDirectory()
            databaseURL = support.appendingPathComponent("responder.sqlite")
            dbQueue = try DatabaseQueue(path: databaseURL.path)
        }

        try Self.migrator.migrate(dbQueue)
    }

    static func makeSupportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Responder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createCoreTables") { db in
            try db.create(table: "app_settings", ifNotExists: true) { table in
                table.column("key", .text).primaryKey()
                table.column("value_json", .text).notNull()
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: "selected_model", ifNotExists: true) { table in
                table.column("id", .integer).primaryKey()
                table.column("provider", .text).notNull().defaults(to: AIProvider.ollama.rawValue)
                table.column("model_name", .text).notNull()
                table.column("context_limit", .integer).notNull()
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: "user_profile_memory", ifNotExists: true) { table in
                table.column("id", .integer).primaryKey()
                table.column("memory_json", .text).notNull()
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: "contact_memory", ifNotExists: true) { table in
                table.column("memory_key", .text).primaryKey()
                table.column("conversation_id", .text).notNull()
                table.column("memory_json", .text).notNull()
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: "conversation_summary", ifNotExists: true) { table in
                table.column("conversation_id", .text).primaryKey()
                table.column("summary_json", .text).notNull()
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: "draft", ifNotExists: true) { table in
                table.column("conversation_id", .text).primaryKey()
                table.column("draft_json", .text).notNull()
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: "autonomy_contact_config", ifNotExists: true) { table in
                table.column("conversation_id", .text).primaryKey()
                table.column("memory_key", .text).notNull()
                table.column("config_json", .text).notNull()
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: "policy_rule_override", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("rule_json", .text).notNull()
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: "activity_log", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("created_at", .double).notNull()
                table.column("category", .text).notNull()
                table.column("severity", .text).notNull()
                table.column("conversation_id", .text)
                table.column("message", .text).notNull()
                table.column("metadata_json", .text).notNull()
            }

            try db.create(table: "simulation_run", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("conversation_id", .text).notNull()
                table.column("created_at", .double).notNull()
                table.column("draft_text", .text).notNull()
                table.column("decision", .text).notNull()
                table.column("confidence", .double).notNull()
            }

            try db.create(table: "monitor_cursor", ifNotExists: true) { table in
                table.column("conversation_id", .text).primaryKey()
                table.column("cursor_json", .text).notNull()
                table.column("updated_at", .double).notNull()
            }
        }

        migrator.registerMigration("addProviderToSelectedModel") { db in
            let columns = try db.columns(in: "selected_model").map(\.name)
            if !columns.contains("provider") {
                try db.alter(table: "selected_model") { table in
                    table.add(column: "provider", .text).notNull().defaults(to: AIProvider.ollama.rawValue)
                }
            }
        }

        migrator.registerMigration("memoryItemsV1") { db in
            try db.create(table: "memory_item", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("bucket", .text).notNull()
                table.column("scope", .text).notNull()
                table.column("memory_key", .text)
                table.column("conversation_id", .text)
                table.column("kind", .text).notNull()
                table.column("text", .text).notNull()
                table.column("normalized_key", .text).notNull()
                table.column("source", .text).notNull()
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
                table.column("supersedes_id", .text)
                table.column("pinned", .integer).notNull()
                table.column("user_verified", .integer).notNull()
                table.column("suppressed", .integer).notNull()
            }
            try db.create(
                index: "idx_memory_item_scope_key",
                on: "memory_item",
                columns: ["scope", "memory_key"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_memory_item_conversation",
                on: "memory_item",
                columns: ["conversation_id"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_memory_item_bucket_key",
                on: "memory_item",
                columns: ["bucket", "memory_key"],
                ifNotExists: true
            )
        }

        return migrator
    }

    func loadGlobalSettings() throws -> GlobalAutonomySettings {
        try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = 'global_autonomy_settings'") {
                return try decode(GlobalAutonomySettings.self, from: row["value_json"])
            }
            return .default
        }
    }

    func saveGlobalSettings(_ settings: GlobalAutonomySettings) throws {
        try upsertJSON(
            table: "app_settings",
            keyColumn: "key",
            keyValue: "global_autonomy_settings",
            jsonColumn: "value_json",
            value: settings
        )
        mirrorAppSettingsJSONFileBestEffort()
    }

    func loadOnboardingState() throws -> OnboardingState {
        try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = 'onboarding_state'") {
                return try decode(OnboardingState.self, from: row["value_json"])
            }
            return .default
        }
    }

    func saveOnboardingState(_ state: OnboardingState) throws {
        try upsertJSON(
            table: "app_settings",
            keyColumn: "key",
            keyValue: "onboarding_state",
            jsonColumn: "value_json",
            value: state
        )
        mirrorAppSettingsJSONFileBestEffort()
    }

    func loadProviderConfiguration() throws -> ProviderConfiguration {
        try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = 'provider_configuration'") {
                return try decode(ProviderConfiguration.self, from: row["value_json"])
            }
            return .default
        }
    }

    func saveProviderConfiguration(_ configuration: ProviderConfiguration) throws {
        try upsertJSON(
            table: "app_settings",
            keyColumn: "key",
            keyValue: "provider_configuration",
            jsonColumn: "value_json",
            value: configuration
        )
        mirrorAppSettingsJSONFileBestEffort()
    }

    func loadConversationLaunchPreference() throws -> ConversationLaunchPreference {
        try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = 'conversation_launch_preference'") {
                return try decode(ConversationLaunchPreference.self, from: row["value_json"])
            }
            return .default
        }
    }

    func saveConversationLaunchPreference(_ preference: ConversationLaunchPreference) throws {
        try upsertJSON(
            table: "app_settings",
            keyColumn: "key",
            keyValue: "conversation_launch_preference",
            jsonColumn: "value_json",
            value: preference
        )
        mirrorAppSettingsJSONFileBestEffort()
    }

    func loadSelectedModel() throws -> SelectedModelState? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT provider, model_name, context_limit FROM selected_model WHERE id = 1") else {
                return nil
            }
            let provider = AIProvider(rawValue: row["provider"]) ?? .ollama
            let model = OllamaModelInfo(name: row["model_name"], digest: nil, sizeBytes: nil, modifiedAt: nil, contextLimit: row["context_limit"])
            return SelectedModelState(provider: provider, model: model)
        }
    }

    func saveSelectedModel(_ selection: SelectedModelState) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO selected_model (id, provider, model_name, context_limit, updated_at)
                VALUES (1, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    provider = excluded.provider,
                    model_name = excluded.model_name,
                    context_limit = excluded.context_limit,
                    updated_at = excluded.updated_at
                """,
                arguments: [selection.provider.rawValue, selection.model.name, selection.model.contextLimit, Date().timeIntervalSince1970]
            )
        }
        mirrorAppSettingsJSONFileBestEffort()
    }

    func loadUserProfileMemory() throws -> UserProfileMemory {
        let fromTable = try dbQueue.read { db in
            try Self.fetchMemoryItems(
                db: db,
                bucket: .manualUser,
                scope: .user,
                memoryKey: nil,
                conversationID: nil
            )
        }
        if !fromTable.isEmpty {
            return UserProfileMemory(items: fromTable)
        }
        let decoded: UserProfileMemory = try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT memory_json FROM user_profile_memory WHERE id = 1") {
                return try decode(UserProfileMemory.self, from: row["memory_json"])
            }
            return .empty
        }
        if !decoded.items.isEmpty {
            try dbQueue.write { db in
                try Self.replaceMemoryItems(db: db, bucket: .manualUser, scope: .user, memoryKey: nil, conversationID: nil, items: decoded.items)
            }
        }
        return decoded
    }

    func saveUserProfileMemory(_ memory: UserProfileMemory) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO user_profile_memory (id, memory_json, updated_at)
                VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    memory_json = excluded.memory_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [try encode(memory), Date().timeIntervalSince1970]
            )
            try Self.replaceMemoryItems(db: db, bucket: .manualUser, scope: .user, memoryKey: nil, conversationID: nil, items: memory.items)
        }
    }

    func loadDerivedUserProfileMemory() throws -> UserProfileMemory {
        let fromTable = try dbQueue.read { db in
            try Self.fetchMemoryItems(
                db: db,
                bucket: .derivedUserGlobal,
                scope: .user,
                memoryKey: nil,
                conversationID: nil
            )
        }
        if !fromTable.isEmpty {
            return UserProfileMemory(items: fromTable)
        }
        let decoded: UserProfileMemory = try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = 'derived_user_profile_memory'") {
                return try decode(UserProfileMemory.self, from: row["value_json"])
            }
            return .empty
        }
        if !decoded.items.isEmpty {
            try dbQueue.write { db in
                try Self.replaceMemoryItems(db: db, bucket: .derivedUserGlobal, scope: .user, memoryKey: nil, conversationID: nil, items: decoded.items)
            }
        }
        return decoded
    }

    func saveDerivedUserProfileMemory(_ memory: UserProfileMemory) throws {
        try upsertJSON(
            table: "app_settings",
            keyColumn: "key",
            keyValue: "derived_user_profile_memory",
            jsonColumn: "value_json",
            value: memory
        )
        try dbQueue.write { db in
            try Self.replaceMemoryItems(db: db, bucket: .derivedUserGlobal, scope: .user, memoryKey: nil, conversationID: nil, items: memory.items)
        }
    }

    func loadDerivedUserProfileMemoryMetadata() throws -> MemorySyncMetadata? {
        try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = 'derived_user_profile_memory_metadata'") {
                return try decode(MemorySyncMetadata.self, from: row["value_json"])
            }
            return nil
        }
    }

    func saveDerivedUserProfileMemoryMetadata(_ metadata: MemorySyncMetadata) throws {
        try upsertJSON(
            table: "app_settings",
            keyColumn: "key",
            keyValue: "derived_user_profile_memory_metadata",
            jsonColumn: "value_json",
            value: metadata
        )
    }

    /// Per–`memoryKey` OpenRouter-derived user profile refinements. Global `derived_user_profile_memory` keeps heuristic / cross-cutting traits only.
    func loadDerivedUserOpenRouterSlice(memoryKey: String) throws -> UserProfileMemory? {
        let fromTable = try dbQueue.read { db in
            try Self.fetchMemoryItems(
                db: db,
                bucket: .derivedUserOpenRouter,
                scope: .user,
                memoryKey: memoryKey,
                conversationID: nil
            )
        }
        if !fromTable.isEmpty {
            return UserProfileMemory(items: fromTable)
        }
        let key = "derived_user_openrouter_slice:\(memoryKey)"
        let decoded: UserProfileMemory? = try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?", arguments: [key]) else {
                return nil
            }
            return try decode(UserProfileMemory.self, from: row["value_json"])
        }
        if let decoded, !decoded.items.isEmpty {
            try dbQueue.write { db in
                try Self.replaceMemoryItems(db: db, bucket: .derivedUserOpenRouter, scope: .user, memoryKey: memoryKey, conversationID: nil, items: decoded.items)
            }
        }
        return decoded
    }

    func saveDerivedUserOpenRouterSlice(_ memory: UserProfileMemory, memoryKey: String) throws {
        try upsertJSON(
            table: "app_settings",
            keyColumn: "key",
            keyValue: "derived_user_openrouter_slice:\(memoryKey)",
            jsonColumn: "value_json",
            value: memory
        )
        try dbQueue.write { db in
            try Self.replaceMemoryItems(db: db, bucket: .derivedUserOpenRouter, scope: .user, memoryKey: memoryKey, conversationID: nil, items: memory.items)
        }
    }

    func loadContactMemoryConversationID(memoryKey: String) throws -> String? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT conversation_id FROM contact_memory WHERE memory_key = ?", arguments: [memoryKey])?["conversation_id"]
        }
    }

    func loadContactMemory(memoryKey: String, conversationID: String) throws -> ContactMemory {
        let fromTable = try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT conversation_id FROM contact_memory WHERE memory_key = ?",
                arguments: [memoryKey]
            ) else {
                return [] as [MemoryItem]
            }
            let storedConversationID: String = row["conversation_id"]
            if memoryKey == conversationID, storedConversationID != conversationID {
                return [] as [MemoryItem]
            }
            return try Self.fetchMemoryItems(
                db: db,
                bucket: .manualContact,
                scope: .contact,
                memoryKey: memoryKey,
                conversationID: nil
            )
        }
        if !fromTable.isEmpty {
            return ContactMemory(memoryKey: memoryKey, items: fromTable)
        }
        let decoded: ContactMemory = try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT conversation_id, memory_json FROM contact_memory WHERE memory_key = ?",
                arguments: [memoryKey]
            ) else {
                return .empty(memoryKey: memoryKey)
            }
            let storedConversationID: String = row["conversation_id"]
            if memoryKey == conversationID, storedConversationID != conversationID {
                return .empty(memoryKey: memoryKey)
            }
            return try decode(ContactMemory.self, from: row["memory_json"])
        }
        if !decoded.items.isEmpty {
            try dbQueue.write { db in
                try Self.replaceMemoryItems(
                    db: db,
                    bucket: .manualContact,
                    scope: .contact,
                    memoryKey: memoryKey,
                    conversationID: conversationID,
                    items: decoded.items
                )
            }
        }
        return decoded
    }

    func saveContactMemory(_ memory: ContactMemory, conversationID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO contact_memory (memory_key, conversation_id, memory_json, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(memory_key) DO UPDATE SET
                    conversation_id = excluded.conversation_id,
                    memory_json = excluded.memory_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [memory.memoryKey, conversationID, try encode(memory), Date().timeIntervalSince1970]
            )
            var stamped = memory
            stamped.items = memory.items.map { item in
                var copy = item
                if copy.bucket == .manualContact, copy.conversationID == nil {
                    copy.conversationID = conversationID
                }
                return copy
            }
            try Self.replaceMemoryItems(db: db, bucket: .manualContact, scope: .contact, memoryKey: memory.memoryKey, conversationID: conversationID, items: stamped.items)
        }
    }

    func loadDerivedContactMemory(memoryKey: String) throws -> ContactMemory {
        let fromTable = try dbQueue.read { db in
            try Self.fetchMemoryItems(
                db: db,
                bucket: .derivedContact,
                scope: .contact,
                memoryKey: memoryKey,
                conversationID: nil
            )
        }
        if !fromTable.isEmpty {
            return ContactMemory(memoryKey: memoryKey, items: fromTable)
        }
        let key = "derived_contact_memory:\(memoryKey)"
        let decoded: ContactMemory = try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?", arguments: [key]) {
                return try decode(ContactMemory.self, from: row["value_json"])
            }
            return .empty(memoryKey: memoryKey)
        }
        if !decoded.items.isEmpty {
            try dbQueue.write { db in
                try Self.replaceMemoryItems(db: db, bucket: .derivedContact, scope: .contact, memoryKey: memoryKey, conversationID: nil, items: decoded.items)
            }
        }
        return decoded
    }

    func saveDerivedContactMemory(_ memory: ContactMemory) throws {
        try upsertJSON(
            table: "app_settings",
            keyColumn: "key",
            keyValue: "derived_contact_memory:\(memory.memoryKey)",
            jsonColumn: "value_json",
            value: memory
        )
        try dbQueue.write { db in
            try Self.replaceMemoryItems(db: db, bucket: .derivedContact, scope: .contact, memoryKey: memory.memoryKey, conversationID: nil, items: memory.items)
        }
    }

    func loadDerivedContactMemoryMetadata(memoryKey: String) throws -> MemorySyncMetadata? {
        try dbQueue.read { db in
            let key = "derived_contact_memory_metadata:\(memoryKey)"
            if let row = try Row.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?", arguments: [key]) {
                return try decode(MemorySyncMetadata.self, from: row["value_json"])
            }
            return nil
        }
    }

    func saveDerivedContactMemoryMetadata(_ metadata: MemorySyncMetadata, memoryKey: String) throws {
        try upsertJSON(
            table: "app_settings",
            keyColumn: "key",
            keyValue: "derived_contact_memory_metadata:\(memoryKey)",
            jsonColumn: "value_json",
            value: metadata
        )
    }

    func loadMemoryTranscriptFingerprint(conversationID: String) throws -> String? {
        try dbQueue.read { db in
            let key = "memory_transcript_fingerprint:\(conversationID)"
            return try Row.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?", arguments: [key])?["value_json"]
        }
    }

    func saveMemoryTranscriptFingerprint(_ fingerprint: String, conversationID: String) throws {
        try dbQueue.write { db in
            let key = "memory_transcript_fingerprint:\(conversationID)"
            try db.execute(
                sql: """
                INSERT INTO app_settings (key, value_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value_json = excluded.value_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [key, fingerprint, Date().timeIntervalSince1970]
            )
        }
    }

    func loadSummary(conversationID: String) throws -> SummarySnapshot {
        try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT summary_json FROM conversation_summary WHERE conversation_id = ?", arguments: [conversationID]) {
                return try decode(SummarySnapshot.self, from: row["summary_json"])
            }
            return .empty(conversationID: conversationID)
        }
    }

    func saveSummary(_ summary: SummarySnapshot) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversation_summary (conversation_id, summary_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(conversation_id) DO UPDATE SET
                    summary_json = excluded.summary_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [summary.conversationID, try encode(summary), Date().timeIntervalSince1970]
            )
        }
    }

    func loadDraft(conversationID: String, modelName: String) throws -> ReplyDraft {
        try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT draft_json FROM draft WHERE conversation_id = ?", arguments: [conversationID]) {
                return try decode(ReplyDraft.self, from: row["draft_json"])
            }
            return .empty(conversationID: conversationID, modelName: modelName)
        }
    }

    func saveDraft(_ draft: ReplyDraft) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO draft (conversation_id, draft_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(conversation_id) DO UPDATE SET
                    draft_json = excluded.draft_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [draft.conversationID, try encode(draft), Date().timeIntervalSince1970]
            )
        }
    }

    func loadAutonomyConfig(conversationID: String, memoryKey: String) throws -> AutonomyContactConfig {
        try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT config_json FROM autonomy_contact_config WHERE conversation_id = ?", arguments: [conversationID]) {
                return try decode(AutonomyContactConfig.self, from: row["config_json"])
            }
            return .default(conversationID: conversationID, memoryKey: memoryKey)
        }
    }

    func saveAutonomyConfig(_ config: AutonomyContactConfig) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO autonomy_contact_config (conversation_id, memory_key, config_json, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(conversation_id) DO UPDATE SET
                    memory_key = excluded.memory_key,
                    config_json = excluded.config_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [config.conversationID, config.memoryKey, try encode(config), Date().timeIntervalSince1970]
            )
        }
    }

    func loadAllAutonomyConfigs() throws -> [AutonomyContactConfig] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT config_json FROM autonomy_contact_config")
            return try rows.map { try decode(AutonomyContactConfig.self, from: $0["config_json"]) }
        }
    }

    func appendActivityLog(_ entry: ActivityLogEntry) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO activity_log (id, created_at, category, severity, conversation_id, message, metadata_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    entry.id.uuidString,
                    entry.timestamp.timeIntervalSince1970,
                    entry.category.rawValue,
                    entry.severity.rawValue,
                    entry.conversationID,
                    entry.message,
                    try encode(entry.metadata)
                ]
            )
        }
    }

    func fetchActivityLog(limit: Int) throws -> [ActivityLogEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, created_at, category, severity, conversation_id, message, metadata_json
                FROM activity_log
                ORDER BY created_at DESC
                LIMIT ?
                """,
                arguments: [limit]
            )

            return try rows.map { row in
                ActivityLogEntry(
                    id: UUID(uuidString: row["id"]) ?? UUID(),
                    timestamp: Date(timeIntervalSince1970: row["created_at"]),
                    category: ActivityLogEntry.Category(rawValue: row["category"]) ?? .error,
                    severity: ActivityLogEntry.Severity(rawValue: row["severity"]) ?? .info,
                    conversationID: row["conversation_id"],
                    message: row["message"],
                    metadata: try decode([String: String].self, from: row["metadata_json"])
                )
            }
        }
    }

    func appendSimulationRun(_ simulation: SimulationRunRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO simulation_run (id, conversation_id, created_at, draft_text, decision, confidence)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    simulation.id.uuidString,
                    simulation.conversationID,
                    simulation.createdAt.timeIntervalSince1970,
                    simulation.draftText,
                    simulation.decision.rawValue,
                    simulation.confidence
                ]
            )
        }
    }

    func latestSimulationRun(conversationID: String) throws -> SimulationRunRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, conversation_id, created_at, draft_text, decision, confidence
                FROM simulation_run
                WHERE conversation_id = ?
                ORDER BY created_at DESC
                LIMIT 1
                """,
                arguments: [conversationID]
            ) else {
                return nil
            }

            return SimulationRunRecord(
                id: UUID(uuidString: row["id"]) ?? UUID(),
                conversationID: row["conversation_id"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                draftText: row["draft_text"],
                decision: PolicyAction(rawValue: row["decision"]) ?? .draftOnly,
                confidence: row["confidence"]
            )
        }
    }

    func saveMonitorCursor(_ cursor: MonitorCursor) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO monitor_cursor (conversation_id, cursor_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(conversation_id) DO UPDATE SET
                    cursor_json = excluded.cursor_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [cursor.conversationID, try encode(cursor), Date().timeIntervalSince1970]
            )
        }
    }

    func loadMonitorCursor(conversationID: String) throws -> MonitorCursor? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT cursor_json FROM monitor_cursor WHERE conversation_id = ?", arguments: [conversationID]) else {
                return nil
            }
            return try decode(MonitorCursor.self, from: row["cursor_json"])
        }
    }

    func countAutoSends(conversationID: String, since date: Date) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM activity_log
                WHERE conversation_id = ?
                  AND category = 'send'
                  AND created_at >= ?
                  AND message LIKE 'Auto-sent:%'
                """,
                arguments: [conversationID, date.timeIntervalSince1970]
            ) ?? 0
        }
    }

    // MARK: - Memory items (atomic rows; JSON blobs remain for backup / migration)

    func fetchMemoryItem(id: UUID) throws -> MemoryItem? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_item WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            return Self.memoryItem(from: row)
        }
    }

    func suppressedNormalizedKeys(scope: MemoryScope, memoryKey: String?) throws -> Set<String> {
        try dbQueue.read { db in
            var sql = "SELECT normalized_key FROM memory_item WHERE suppressed = 1 AND scope = ?"
            var args: [any DatabaseValueConvertible] = [scope.rawValue]
            if let memoryKey {
                sql += " AND memory_key = ?"
                args.append(memoryKey)
            } else {
                sql += " AND memory_key IS NULL"
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return Set(rows.compactMap { row in (row["normalized_key"] as String?).flatMap { $0.isEmpty ? nil : $0 } })
        }
    }

    func setMemoryItemPinned(id: UUID, pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE memory_item SET pinned = ?, updated_at = ? WHERE id = ?",
                arguments: [pinned ? 1 : 0, Date().timeIntervalSince1970, id.uuidString]
            )
        }
    }

    func deleteMemoryItem(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memory_item WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Tombstone used to block normalized duplicates on future derivation (`forget` / wrong fact).
    func suppressMemoryItem(id: UUID) throws {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT scope, memory_key, conversation_id FROM memory_item WHERE id = ?", arguments: [id.uuidString]) else {
                return
            }
            let scopeRaw: String = row["scope"]
            let memoryKey: String? = row["memory_key"]
            let conversationID: String? = row["conversation_id"]
            guard let scope = MemoryScope(rawValue: scopeRaw) else { return }
            try db.execute(
                sql: """
                UPDATE memory_item
                SET suppressed = 1, pinned = 0, updated_at = ?
                WHERE id = ?
                """,
                arguments: [Date().timeIntervalSince1970, id.uuidString]
            )
            try Self.trimSuppressedTombstonesIfNeeded(db: db, scope: scope, memoryKey: memoryKey, conversationID: conversationID)
        }
    }

    /// Counts non-pinned, non-suppressed rows for diagnostics and tests.
    func countUnpinnedUnsuppressedMemoryItems(bucket: MemoryItemBucket, scope: MemoryScope, memoryKey: String?) throws -> Int {
        try dbQueue.read { db in
            try Self.countUnpinnedUnsuppressedMemoryItems(db: db, bucket: bucket, scope: scope, memoryKey: memoryKey, conversationID: nil)
        }
    }

    private static func fetchMemoryItems(
        db: Database,
        bucket: MemoryItemBucket,
        scope: MemoryScope,
        memoryKey: String?,
        conversationID: String?
    ) throws -> [MemoryItem] {
        var sql = "SELECT * FROM memory_item WHERE bucket = ? AND scope = ?"
        var args: [any DatabaseValueConvertible] = [bucket.rawValue, scope.rawValue]
        if let memoryKey {
            sql += " AND memory_key = ?"
            args.append(memoryKey)
        } else {
            sql += " AND memory_key IS NULL"
        }
        if let conversationID {
            sql += " AND (conversation_id IS NULL OR conversation_id = ?)"
            args.append(conversationID)
        }
        sql += " ORDER BY updated_at DESC"
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        let loaded = rows.compactMap { memoryItem(from: $0) }
        return MemoryItemDeduper.deduplicate(loaded)
    }

    private static func countUnpinnedUnsuppressedMemoryItems(
        db: Database,
        bucket: MemoryItemBucket,
        scope: MemoryScope,
        memoryKey: String?,
        conversationID: String?
    ) throws -> Int {
        var sql = """
        SELECT COUNT(*) FROM memory_item
        WHERE bucket = ? AND scope = ? AND pinned = 0 AND suppressed = 0
        """
        var args: [any DatabaseValueConvertible] = [bucket.rawValue, scope.rawValue]
        if let memoryKey {
            sql += " AND memory_key = ?"
            args.append(memoryKey)
        } else {
            sql += " AND memory_key IS NULL"
        }
        if let conversationID {
            sql += " AND (conversation_id IS NULL OR conversation_id = ?)"
            args.append(conversationID)
        }
        return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
    }

    private static func trimDerivedIfNeeded(
        db: Database,
        bucket: MemoryItemBucket,
        scope: MemoryScope,
        memoryKey: String?,
        conversationID: String?
    ) throws {
        let maxRows: Int
        switch bucket {
        case .derivedUserGlobal:
            maxRows = MemoryStorageLimits.maxDerivedRowsUserGlobal
        case .derivedUserOpenRouter:
            maxRows = MemoryStorageLimits.maxDerivedRowsOpenRouterSlice
        case .derivedContact:
            maxRows = MemoryStorageLimits.maxDerivedRowsContact
        default:
            return
        }
        let count = try countUnpinnedUnsuppressedMemoryItems(db: db, bucket: bucket, scope: scope, memoryKey: memoryKey, conversationID: conversationID)
        let excess = count - maxRows
        guard excess > 0 else { return }
        var subSQL = """
        SELECT id FROM memory_item
        WHERE bucket = ? AND scope = ? AND pinned = 0 AND suppressed = 0
        """
        var subArgs: [any DatabaseValueConvertible] = [bucket.rawValue, scope.rawValue]
        if let memoryKey {
            subSQL += " AND memory_key = ?"
            subArgs.append(memoryKey)
        } else {
            subSQL += " AND memory_key IS NULL"
        }
        if let conversationID {
            subSQL += " AND (conversation_id IS NULL OR conversation_id = ?)"
            subArgs.append(conversationID)
        }
        subSQL += " ORDER BY updated_at ASC LIMIT ?"
        subArgs.append(excess)
        try db.execute(sql: "DELETE FROM memory_item WHERE id IN (\(subSQL))", arguments: StatementArguments(subArgs))
    }

    private static func trimSuppressedTombstonesIfNeeded(
        db: Database,
        scope: MemoryScope,
        memoryKey: String?,
        conversationID: String?
    ) throws {
        let cutoff = Date().timeIntervalSince1970 - MemoryStorageLimits.suppressedRetentionSeconds
        var delOld = "DELETE FROM memory_item WHERE suppressed = 1 AND scope = ? AND updated_at < ?"
        var oldArgs: [any DatabaseValueConvertible] = [scope.rawValue, cutoff]
        if let memoryKey {
            delOld += " AND memory_key = ?"
            oldArgs.append(memoryKey)
        } else {
            delOld += " AND memory_key IS NULL"
        }
        if let conversationID {
            delOld += " AND (conversation_id IS NULL OR conversation_id = ?)"
            oldArgs.append(conversationID)
        }
        try db.execute(sql: delOld, arguments: StatementArguments(oldArgs))

        var countSQL = "SELECT COUNT(*) FROM memory_item WHERE suppressed = 1 AND scope = ?"
        var countArgs: [any DatabaseValueConvertible] = [scope.rawValue]
        if let memoryKey {
            countSQL += " AND memory_key = ?"
            countArgs.append(memoryKey)
        } else {
            countSQL += " AND memory_key IS NULL"
        }
        if let conversationID {
            countSQL += " AND (conversation_id IS NULL OR conversation_id = ?)"
            countArgs.append(conversationID)
        }
        let suppressedCount = try Int.fetchOne(db, sql: countSQL, arguments: StatementArguments(countArgs)) ?? 0
        let tombExcess = suppressedCount - MemoryStorageLimits.maxSuppressedTombstonesPerKey
        guard tombExcess > 0 else { return }
        var sub = "SELECT id FROM memory_item WHERE suppressed = 1 AND scope = ?"
        var subArgs: [any DatabaseValueConvertible] = [scope.rawValue]
        if let memoryKey {
            sub += " AND memory_key = ?"
            subArgs.append(memoryKey)
        } else {
            sub += " AND memory_key IS NULL"
        }
        if let conversationID {
            sub += " AND (conversation_id IS NULL OR conversation_id = ?)"
            subArgs.append(conversationID)
        }
        sub += " ORDER BY updated_at ASC LIMIT ?"
        subArgs.append(tombExcess)
        try db.execute(sql: "DELETE FROM memory_item WHERE id IN (\(sub))", arguments: StatementArguments(subArgs))
    }

    private static func replaceMemoryItems(
        db: Database,
        bucket: MemoryItemBucket,
        scope: MemoryScope,
        memoryKey: String?,
        conversationID: String?,
        items: [MemoryItem]
    ) throws {
        var deleteSQL = "DELETE FROM memory_item WHERE bucket = ? AND scope = ? AND suppressed = 0"
        var deleteArgs: [any DatabaseValueConvertible] = [bucket.rawValue, scope.rawValue]
        if let memoryKey {
            deleteSQL += " AND memory_key = ?"
            deleteArgs.append(memoryKey)
        } else {
            deleteSQL += " AND memory_key IS NULL"
        }
        if let conversationID {
            deleteSQL += " AND (conversation_id IS NULL OR conversation_id = ?)"
            deleteArgs.append(conversationID)
        }
        try db.execute(sql: deleteSQL, arguments: StatementArguments(deleteArgs))
        let uniqueItems = MemoryItemDeduper.deduplicate(items)
        for item in uniqueItems {
            try insertOrReplaceMemoryItem(db: db, item: item)
        }
        try trimDerivedIfNeeded(db: db, bucket: bucket, scope: scope, memoryKey: memoryKey, conversationID: conversationID)
        try trimSuppressedTombstonesIfNeeded(db: db, scope: scope, memoryKey: memoryKey, conversationID: conversationID)
    }

    private static func insertOrReplaceMemoryItem(db: Database, item: MemoryItem) throws {
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO memory_item (
                id, bucket, scope, memory_key, conversation_id, kind, text, normalized_key, source,
                created_at, updated_at, supersedes_id, pinned, user_verified, suppressed
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                item.id.uuidString,
                item.bucket.rawValue,
                item.scope.rawValue,
                item.memoryKey,
                item.conversationID,
                item.kind.rawValue,
                item.text,
                item.normalizedKey,
                item.source.rawValue,
                item.createdAt.timeIntervalSince1970,
                item.updatedAt.timeIntervalSince1970,
                item.supersedesItemID?.uuidString,
                item.pinned ? 1 : 0,
                item.userVerified ? 1 : 0,
                item.suppressed ? 1 : 0
            ]
        )
    }

    private static func memoryItem(from row: Row) -> MemoryItem? {
        let idString: String = row["id"]
        guard
            let id = UUID(uuidString: idString),
            let bucket = MemoryItemBucket(rawValue: row["bucket"]),
            let scope = MemoryScope(rawValue: row["scope"]),
            let kind = MemoryItemKind(rawValue: row["kind"]),
            let source = MemorySyncSource(rawValue: row["source"])
        else {
            return nil
        }
        let created = Date(timeIntervalSince1970: row["created_at"])
        let updated = Date(timeIntervalSince1970: row["updated_at"])
        let supers: String? = row["supersedes_id"]
        let nk: String = row["normalized_key"]
        let pinnedInt: Int64 = row["pinned"]
        let verifiedInt: Int64 = row["user_verified"]
        let suppressedInt: Int64 = row["suppressed"]
        return MemoryItem(
            id: id,
            bucket: bucket,
            scope: scope,
            memoryKey: row["memory_key"],
            conversationID: row["conversation_id"],
            kind: kind,
            text: row["text"],
            source: source,
            createdAt: created,
            updatedAt: updated,
            supersedesItemID: supers.flatMap(UUID.init(uuidString:)),
            pinned: pinnedInt != 0,
            userVerified: verifiedInt != 0,
            suppressed: suppressedInt != 0,
            normalizedKeyOverride: nk.isEmpty ? nil : nk
        )
    }

    private func upsertJSON<T: Encodable>(
        table: String,
        keyColumn: String,
        keyValue: String,
        jsonColumn: String,
        value: T
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO \(table) (\(keyColumn), \(jsonColumn), updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(\(keyColumn)) DO UPDATE SET
                    \(jsonColumn) = excluded.\(jsonColumn),
                    updated_at = excluded.updated_at
                """,
                arguments: [keyValue, try encode(value), Date().timeIntervalSince1970]
            )
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    /// Creates `app-settings.json` from the DB when missing (e.g. first run after this feature ships). Safe to call from a detached task at launch.
    func ensureAppSettingsJSONExportExists() {
        guard mirrorsSettingsJSONToFile else { return }
        do {
            let url = try AppSettingsJSONStore.settingsFileURL()
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try writeAppSettingsJSONSnapshot()
        } catch {}
    }

    private func mirrorAppSettingsJSONFileBestEffort() {
        guard mirrorsSettingsJSONToFile else { return }
        do { try writeAppSettingsJSONSnapshot() } catch {}
    }

    private func writeAppSettingsJSONSnapshot() throws {
        let snapshot = ExportedAppSettings(
            schemaVersion: 1,
            exportedAt: Date(),
            providerConfiguration: try loadProviderConfiguration(),
            globalAutonomySettings: try loadGlobalSettings(),
            conversationLaunchPreference: try loadConversationLaunchPreference(),
            onboardingState: try loadOnboardingState(),
            selectedModel: try loadSelectedModel()
        )
        try AppSettingsJSONStore.write(snapshot)
    }
}
