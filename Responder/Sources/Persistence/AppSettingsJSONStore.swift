import Foundation

/// Human-readable export of app-wide settings (SQLite in `AppDatabase` remains the source of truth).
///
/// Written to `Application Support/Responder/app-settings.json` alongside `responder.sqlite`.
struct ExportedAppSettings: Codable, Sendable {
    var schemaVersion: Int
    var exportedAt: Date
    var providerConfiguration: ProviderConfiguration
    var globalAutonomySettings: GlobalAutonomySettings
    var conversationLaunchPreference: ConversationLaunchPreference
    var onboardingState: OnboardingState
    var selectedModel: SelectedModelState?
}

enum AppSettingsJSONStore {
    private static let fileName = "app-settings.json"

    static func settingsFileURL() throws -> URL {
        try AppDatabase.makeSupportDirectory().appendingPathComponent(fileName, isDirectory: false)
    }

    static func write(_ settings: ExportedAppSettings) throws {
        let url = try settingsFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: temporaryURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }
}
