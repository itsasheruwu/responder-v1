import Foundation
import GRDB

actor AppDatabase {
    private let dbQueue: DatabaseQueue
    let databaseURL: URL

    init(inMemory: Bool = false) throws {
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
    }

    func loadUserProfileMemory() throws -> UserProfileMemory {
        try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT memory_json FROM user_profile_memory WHERE id = 1") {
                return try decode(UserProfileMemory.self, from: row["memory_json"])
            }
            return .empty
        }
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
        }
    }

    func loadContactMemory(memoryKey: String, conversationID: String) throws -> ContactMemory {
        try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT memory_json FROM contact_memory WHERE memory_key = ?", arguments: [memoryKey]) {
                return try decode(ContactMemory.self, from: row["memory_json"])
            }
            return .empty(memoryKey: memoryKey)
        }
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
}
