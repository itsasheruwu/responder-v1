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

    static let `default` = ProviderConfiguration(
        selectedProvider: .ollama,
        openRouterAPIKey: "",
        openRouterBaseURL: "https://openrouter.ai/api/v1"
    )
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
}

struct UserProfileMemory: Hashable, Codable, Sendable {
    var profileSummary: String
    var styleTraits: [String]
    var bannedPhrases: [String]
    var backgroundFacts: [String]
    var replyHabits: [String]

    static let empty = UserProfileMemory(profileSummary: "", styleTraits: [], bannedPhrases: [], backgroundFacts: [], replyHabits: [])

    func asSnapshot() -> MemorySnapshot {
        var entries: [String] = []
        if !profileSummary.isEmpty {
            entries.append("Profile: \(profileSummary)")
        }
        if !styleTraits.isEmpty {
            entries.append("Style traits: \(styleTraits.joined(separator: ", "))")
        }
        if !bannedPhrases.isEmpty {
            entries.append("Avoid: \(bannedPhrases.joined(separator: ", "))")
        }
        if !backgroundFacts.isEmpty {
            entries.append("Facts: \(backgroundFacts.joined(separator: ", "))")
        }
        if !replyHabits.isEmpty {
            entries.append("Habits: \(replyHabits.joined(separator: ", "))")
        }
        return MemorySnapshot(title: "User Memory", entries: entries)
    }
}

struct ContactMemory: Hashable, Codable, Sendable {
    let memoryKey: String
    var relationshipSummary: String
    var preferences: [String]
    var recurringTopics: [String]
    var boundaries: [String]
    var notes: [String]

    static func empty(memoryKey: String) -> ContactMemory {
        ContactMemory(memoryKey: memoryKey, relationshipSummary: "", preferences: [], recurringTopics: [], boundaries: [], notes: [])
    }

    func asSnapshot() -> MemorySnapshot {
        var entries: [String] = []
        if !relationshipSummary.isEmpty {
            entries.append("Relationship: \(relationshipSummary)")
        }
        if !preferences.isEmpty {
            entries.append("Preferences: \(preferences.joined(separator: ", "))")
        }
        if !recurringTopics.isEmpty {
            entries.append("Topics: \(recurringTopics.joined(separator: ", "))")
        }
        if !boundaries.isEmpty {
            entries.append("Boundaries: \(boundaries.joined(separator: ", "))")
        }
        if !notes.isEmpty {
            entries.append("Notes: \(notes.joined(separator: ", "))")
        }
        return MemorySnapshot(title: "Contact Memory", entries: entries)
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
