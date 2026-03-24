import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let container: AppContainer

    var providerConfiguration: ProviderConfiguration = .default
    var availableModels: [OllamaModelInfo] = []
    var selectedModelName: String = ""
    var conversations: [ConversationRef] = []
    var selectedConversationID: String?
    var messages: [ChatMessage] = []
    var currentDraft: ReplyDraft?
    var currentPrompt: PromptPacket?
    var currentPolicyDecision: PolicyDecision?
    var userMemory: UserProfileMemory = .empty
    var contactMemory: ContactMemory = .empty(memoryKey: "preview")
    var summary: SummarySnapshot = .empty(conversationID: "preview")
    var contactAutonomyConfig: AutonomyContactConfig = .default(conversationID: "preview", memoryKey: "preview")
    var globalSettings: GlobalAutonomySettings = .default
    var activityLog: [ActivityLogEntry] = []
    var onboardingState: OnboardingState = .default
    var statusMessage: String = "Loading…"
    var errorMessage: String?
    var startupIssues: [String] = []
    var isLoading = false
    var isGenerating = false
    var isSending = false

    private var hasStarted = false
    private var hasLoadedPersistentState = false
    private var monitorTask: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
    }

    static func live() -> AppModel {
        do {
            let container = try AppContainer.live()
            let model = AppModel(container: container)
            model.startupIssues = container.startupIssues
            return model
        } catch {
            let model = AppModel(container: .preview())
            model.errorMessage = "Live services failed to initialize. Running in preview mode: \(error.localizedDescription)"
            return model
        }
    }

    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        isLoading = true
        defer { isLoading = false }

        await loadPersistedState()
        await refreshModels()
        await refreshConversations()
        await refreshActivityLog()
        if let issue = startupIssues.first {
            statusMessage = issue
        }
        restartMonitoring()
    }

    var selectedConversation: ConversationRef? {
        conversations.first(where: { $0.id == selectedConversationID })
    }

    var showsPermissionGate: Bool {
        hasLoadedPersistentState && !onboardingState.isCompleted && !onboardingState.hasEnteredSetupFlow
    }

    var showsOnboarding: Bool {
        hasLoadedPersistentState && !onboardingState.isCompleted && onboardingState.hasEnteredSetupFlow
    }

    var selectedModel: OllamaModelInfo? {
        availableModels.first(where: { $0.name == selectedModelName })
    }

    var selectedProvider: AIProvider {
        providerConfiguration.selectedProvider
    }

    var messagesAccessRestricted: Bool {
        !startupIssues.isEmpty
    }

    func refreshModels() async {
        do {
            var models = try await container.llm.listModels()
            if models.isEmpty {
                statusMessage = selectedProvider == .ollama ? "No local Ollama models found." : "No OpenRouter models available."
            } else {
                for index in models.indices {
                    if let context = try? await container.llm.modelDetails(for: models[index].name).contextLimit {
                        models[index] = OllamaModelInfo(
                            name: models[index].name,
                            digest: models[index].digest,
                            sizeBytes: models[index].sizeBytes,
                            modifiedAt: models[index].modifiedAt,
                            contextLimit: context
                        )
                    }
                }
                availableModels = models
                if selectedModelName.isEmpty {
                    selectedModelName = models.first?.name ?? ""
                }
                if let selected = models.first(where: { $0.name == selectedModelName }) {
                    try await container.database.saveSelectedModel(SelectedModelState(provider: selectedProvider, model: selected))
                }
                statusMessage = "Loaded \(models.count) \(selectedProvider.displayName) model(s)."
            }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = selectedProvider == .ollama
                ? "Ollama unavailable. Generation is disabled until it is reachable."
                : "OpenRouter unavailable. Check your API key and network connection."
        }
    }

    func refreshConversations() async {
        do {
            conversations = try await container.messagesStore.fetchConversations(limit: 150)
            if conversations.isEmpty {
                if let issue = startupIssues.first {
                    statusMessage = issue
                } else {
                    statusMessage = "No conversations available."
                }
                selectedConversationID = nil
                messages = []
                currentDraft = nil
                currentPrompt = nil
                currentPolicyDecision = nil
                return
            }
            if selectedConversationID == nil {
                selectedConversationID = conversations.first?.id
            }
            if let selectedConversationID {
                await loadConversation(id: selectedConversationID)
            }
        } catch {
            errorMessage = error.localizedDescription
            do {
                try await container.database.appendActivityLog(
                    ActivityLogEntry(
                        category: .error,
                        severity: .error,
                        conversationID: selectedConversationID,
                        message: "Draft generation failed.",
                        metadata: ["details": error.localizedDescription]
                    )
                )
                await refreshActivityLog()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadConversation(id: String) async {
        selectedConversationID = id
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }

        do {
            messages = try await container.messagesStore.fetchMessages(conversationID: id, limit: 80)
            try await container.memory.synchronizeMemories(conversation: conversation, messages: messages)
            userMemory = try await container.memory.loadUserProfileMemory()
            contactMemory = try await container.memory.loadContactMemory(memoryKey: conversation.memoryKey, conversationID: conversation.id)
            summary = try await container.memory.loadSummary(conversationID: conversation.id)
            contactAutonomyConfig = try await container.database.loadAutonomyConfig(conversationID: conversation.id, memoryKey: conversation.memoryKey)
            currentDraft = try await container.memory.loadDraft(conversationID: conversation.id, modelName: selectedModelName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generateDraft(mode: ReplyOperationMode = .draftSuggestion) async {
        guard let selectedConversationID else {
            errorMessage = startupIssues.first ?? ResponderError.conversationUnavailable.localizedDescription
            return
        }
        guard !selectedModelName.isEmpty else {
            errorMessage = ResponderError.missingModelSelection.localizedDescription
            return
        }

        isGenerating = true
        defer { isGenerating = false }

        do {
            let result = try await container.autonomy.generateReply(
                conversationID: selectedConversationID,
                modelName: selectedModelName,
                mode: mode
            )
            messages = result.messages
            currentDraft = result.draft
            currentPrompt = result.promptPacket
            currentPolicyDecision = result.policyDecision
            summary = result.summarySnapshot
            userMemory = result.userMemory
            contactMemory = result.contactMemory
            contactAutonomyConfig = try await container.database.loadAutonomyConfig(conversationID: result.conversation.id, memoryKey: result.conversation.memoryKey)
            statusMessage = "Draft ready."
            await refreshActivityLog()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendCurrentDraft(auto: Bool = false) async {
        guard let draft = currentDraft, let selectedConversationID else { return }
        isSending = true
        defer { isSending = false }

        do {
            try await container.autonomy.sendDraft(draft, conversationID: selectedConversationID, mode: auto ? .autonomousSend : .manualSend)
            statusMessage = auto ? "Auto-send completed." : "Message sent through Messages."
            await refreshActivityLog()
            await refreshConversations()
            await loadConversation(id: selectedConversationID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshActivityLog() async {
        do {
            activityLog = try await container.database.fetchActivityLog(limit: 200)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func persistSelectedModel() async {
        guard let selected = availableModels.first(where: { $0.name == selectedModelName }) else { return }
        do {
            try await container.database.saveSelectedModel(SelectedModelState(provider: selectedProvider, model: selected))
            statusMessage = "Selected \(selectedProvider.displayName) model: \(selected.name)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveProviderConfiguration(refreshModels shouldRefreshModels: Bool = true) async {
        do {
            try await container.database.saveProviderConfiguration(providerConfiguration)
            availableModels = []
            selectedModelName = providerConfiguration.selectedProvider == .openRouter ? OpenRouterClient.builtInModels.first?.name ?? "" : ""
            statusMessage = providerConfiguration.selectedProvider == .ollama
                ? "Provider set to Ollama."
                : "Provider set to OpenRouter."
            if shouldRefreshModels {
                await refreshModels()
            }
            restartMonitoring()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveUserMemory() async {
        do {
            try await container.memory.saveUserProfileMemory(userMemory)
            statusMessage = "User memory saved."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveContactMemory() async {
        guard let selectedConversation else { return }
        do {
            try await container.memory.saveContactMemory(contactMemory, conversationID: selectedConversation.id)
            statusMessage = "Contact memory saved."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveSummary() async {
        do {
            try await container.memory.saveSummary(summary)
            statusMessage = "Rolling summary saved."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveAutonomyConfig() async {
        do {
            try await container.database.saveAutonomyConfig(contactAutonomyConfig)
            statusMessage = "Autonomy settings saved for this contact."
            restartMonitoring()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveCurrentDraftText(_ text: String) async {
        guard var draft = currentDraft else { return }
        draft.text = text
        currentDraft = draft
        do {
            try await container.memory.saveDraft(draft)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateGlobalEmergencyStop(_ enabled: Bool) async {
        globalSettings.emergencyStopEnabled = enabled
        await saveGlobalSettings()
    }

    func saveGlobalSettings() async {
        do {
            try await container.database.saveGlobalSettings(globalSettings)
            restartMonitoring()
            statusMessage = globalSettings.emergencyStopEnabled ? "Emergency stop enabled." : "Global settings saved."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func reopenOnboarding() async {
        onboardingState.hasEnteredSetupFlow = true
        onboardingState.isCompleted = false
        if onboardingState.currentStep == .finish {
            onboardingState.currentStep = .welcome
        }
        onboardingState.completedAt = nil
        await persistOnboardingState(status: "Setup reopened.")
    }

    func enterOnboardingFlow() async {
        onboardingState.hasEnteredSetupFlow = true
        if onboardingState.currentStep == .finish {
            onboardingState.currentStep = .welcome
        }
        await persistOnboardingState(status: "Setup started.")
    }

    func deferOnboardingForPermissions() async {
        onboardingState.hasEnteredSetupFlow = false
        await persistOnboardingState(status: "Grant permissions, restart the app, then start setup when ready.")
    }

    func goBackOnboarding() async {
        switch onboardingState.currentStep {
        case .welcome:
            break
        case .privacy:
            onboardingState.currentStep = .welcome
        case .model:
            onboardingState.currentStep = .privacy
        case .voice:
            onboardingState.currentStep = .model
        case .autonomy:
            onboardingState.currentStep = .voice
        case .finish:
            onboardingState.currentStep = .autonomy
        }
        await persistOnboardingState()
    }

    func advanceOnboarding() async {
        switch onboardingState.currentStep {
        case .welcome:
            onboardingState.currentStep = .privacy
        case .privacy:
            onboardingState.privacyReviewed = true
            onboardingState.currentStep = .model
        case .model:
            onboardingState.modelReviewed = true
            if let selectedModel {
                do {
                    try await container.database.saveSelectedModel(SelectedModelState(provider: selectedProvider, model: selectedModel))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            onboardingState.currentStep = .voice
        case .voice:
            onboardingState.voiceSeeded = true
            onboardingState.currentStep = .autonomy
        case .autonomy:
            onboardingState.autonomyReviewed = true
            onboardingState.currentStep = .finish
        case .finish:
            break
        }
        await persistOnboardingState()
    }

    func saveOnboardingVoiceProfile(
        profileSummary: String,
        styleTraits: [String],
        bannedPhrases: [String],
        backgroundFacts: [String],
        replyHabits: [String]
    ) async {
        userMemory = UserProfileMemory(
            profileSummary: profileSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            styleTraits: styleTraits,
            bannedPhrases: bannedPhrases,
            backgroundFacts: backgroundFacts,
            replyHabits: replyHabits
        )

        do {
            try await container.memory.saveUserProfileMemory(userMemory)
            statusMessage = "Voice profile saved locally."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyOnboardingAutonomyDefaults(enableMonitoring: Bool) async {
        globalSettings.autonomyEnabled = enableMonitoring
        globalSettings.emergencyStopEnabled = false
        do {
            try await container.database.saveGlobalSettings(globalSettings)
            restartMonitoring()
            statusMessage = enableMonitoring ? "Monitoring enabled. Auto-send still stays off until you opt in per contact." : "Draft suggestion mode remains the default."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeOnboarding() async {
        onboardingState.isCompleted = true
        onboardingState.hasEnteredSetupFlow = true
        onboardingState.currentStep = .finish
        onboardingState.completedAt = .now
        await persistOnboardingState(status: "Setup complete.")
    }

    private func loadPersistedState() async {
        do {
            globalSettings = try await container.database.loadGlobalSettings()
            onboardingState = try await container.database.loadOnboardingState()
            providerConfiguration = try await container.database.loadProviderConfiguration()
            if let selected = try await container.database.loadSelectedModel(),
               selected.provider == providerConfiguration.selectedProvider {
                selectedModelName = selected.model.name
            }
            userMemory = try await container.memory.loadUserProfileMemory()
            hasLoadedPersistentState = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restartMonitoring() {
        monitorTask?.cancel()
        guard globalSettings.autonomyEnabled, !selectedModelName.isEmpty else { return }

        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    _ = try await self.container.autonomy.monitorCycle(modelName: self.selectedModelName)
                    await self.refreshActivityLog()
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                    }
                }

                let interval = UInt64(max(5, self.globalSettings.monitorPollIntervalSeconds)) * 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func persistOnboardingState(status: String? = nil) async {
        do {
            try await container.database.saveOnboardingState(onboardingState)
            if let status {
                statusMessage = status
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
