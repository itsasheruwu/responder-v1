import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var container: AppContainer

    var providerConfiguration: ProviderConfiguration = .default
    var availableModels: [OllamaModelInfo] = []
    var selectedModelName: String = ""
    var conversations: [ConversationRef] = []
    var selectedConversationID: String?
    var conversationLaunchPreference: ConversationLaunchPreference = .default
    var messages: [ChatMessage] = []
    var currentDraft: ReplyDraft?
    var currentPrompt: PromptPacket?
    var currentPolicyDecision: PolicyDecision?
    var userMemory: UserProfileMemory = .empty
    var manualUserMemory: UserProfileMemory = .empty
    var derivedUserMemory: UserProfileMemory = .empty
    var userMemoryMetadata: MemorySyncMetadata?
    var contactMemory: ContactMemory = .empty(memoryKey: "preview")
    var manualContactMemory: ContactMemory = .empty(memoryKey: "preview")
    var derivedContactMemory: ContactMemory = .empty(memoryKey: "preview")
    var contactMemoryMetadata: MemorySyncMetadata?
    var summary: SummarySnapshot = .empty(conversationID: "preview")
    var contactAutonomyConfig: AutonomyContactConfig = .default(conversationID: "preview", memoryKey: "preview")
    var globalSettings: GlobalAutonomySettings = .default
    var activityLog: [ActivityLogEntry] = []
    var onboardingState: OnboardingState = .default
    var statusMessage: String = "Loading…"
    var errorMessage: String?
    var startupIssues: [String] = []
    var messagesDirectoryAccess: MessagesDirectoryAccess?
    var isLoading = false
    var isGenerating = false
    var isSending = false
    var isUpdatingMemory = false
    var memoryUpdateStatus: String?

    private var hasStarted = false
    private var hasLoadedPersistentState = false
    private var hasResolvedConversationSelection = false
    private var monitorTask: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var conversationLoadTask: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
    }

    static func live() -> AppModel {
        do {
            let container = try AppContainer.live()
            let model = AppModel(container: container)
            model.startupIssues = container.startupIssues
            model.messagesDirectoryAccess = container.messagesDirectoryAccess
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
        async let modelsRefresh: Void = refreshModels()
        async let conversationsRefresh: Void = refreshConversations()
        async let activityRefresh: Void = refreshActivityLog()
        _ = await (modelsRefresh, conversationsRefresh, activityRefresh)
        if let issue = startupIssues.first {
            statusMessage = issue
        }
        restartMonitoring()
    }

    var selectedConversation: ConversationRef? {
        conversations.first(where: { $0.id == selectedConversationID })
    }

    var persistConversationSelectionAcrossLaunches: Bool {
        conversationLaunchPreference.persistSelectionAcrossLaunches
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

    var messagesDirectoryAccessPath: String? {
        messagesDirectoryAccess?.directoryPath
    }

    var showsConversationChooser: Bool {
        hasLoadedPersistentState &&
        hasResolvedConversationSelection &&
        !messagesAccessRestricted &&
        !conversations.isEmpty &&
        selectedConversationID == nil
    }

    func refreshModels() async {
        do {
            let models = try await container.llm.listModels()
            if models.isEmpty {
                availableModels = []
                selectedModelName = ""
                statusMessage = selectedProvider == .ollama ? "No local Ollama models found." : "No OpenRouter models available."
            } else {
                availableModels = models
                if !models.contains(where: { $0.name == selectedModelName }) {
                    selectedModelName = models.first?.name ?? ""
                }
                if let selected = models.first(where: { $0.name == selectedModelName }) {
                    try await container.database.saveSelectedModel(SelectedModelState(provider: selectedProvider, model: selected))
                    refreshSelectedModelMetadataIfNeeded(selected)
                }
                statusMessage = "Loaded \(models.count) \(selectedProvider.displayName) model(s)."
            }
        } catch {
            availableModels = []
            selectedModelName = ""
            errorMessage = error.localizedDescription
            statusMessage = selectedProvider == .ollama
                ? "Ollama unavailable. Generation is disabled until it is reachable."
                : "OpenRouter unavailable. Check your API key and network connection."
        }
    }

    func refreshConversations() async {
        hasResolvedConversationSelection = false
        do {
            conversations = try await container.messagesStore.fetchConversations(limit: 80)
            if conversations.isEmpty {
                if let issue = startupIssues.first {
                    statusMessage = issue
                } else {
                    statusMessage = "No conversations available."
                }
                selectedConversationID = nil
                conversationLaunchPreference.conversationID = nil
                messages = []
                currentDraft = nil
                currentPrompt = nil
                currentPolicyDecision = nil
                hasResolvedConversationSelection = true
                return
            }

            if let preferredConversationID = await resolvePreferredConversationID() {
                selectedConversationID = preferredConversationID
                conversationLaunchPreference.conversationID = preferredConversationID
                hasResolvedConversationSelection = true
                scheduleConversationLoad(id: preferredConversationID)
                return
            }

            if conversationLaunchPreference.persistSelectionAcrossLaunches,
               conversationLaunchPreference.conversationID != nil {
                conversationLaunchPreference = .default
                await persistConversationLaunchPreference()
                statusMessage = "Saved conversation is no longer available. Pick a conversation to continue."
            } else if statusMessage.isEmpty || statusMessage == "Loading…" {
                statusMessage = "Choose a conversation to continue."
            }

            clearConversationContext()
            hasResolvedConversationSelection = true
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Unable to load Messages history."
            do {
                try await container.database.appendActivityLog(
                    ActivityLogEntry(
                        category: .error,
                        severity: .error,
                        conversationID: selectedConversationID,
                        message: "Messages history refresh failed.",
                        metadata: ["details": error.localizedDescription]
                    )
                )
                await refreshActivityLog()
            } catch {
                errorMessage = error.localizedDescription
            }
            hasResolvedConversationSelection = true
        }
    }

    func loadConversation(id: String) async {
        guard !Task.isCancelled else { return }
        selectedConversationID = id
        conversationLaunchPreference.conversationID = id
        let conversation: ConversationRef
        if let existingConversation = conversations.first(where: { $0.id == id }) {
            conversation = existingConversation
        } else if let fetchedConversation = try? await container.messagesStore.fetchConversation(id: id) {
            conversations.removeAll { $0.id == fetchedConversation.id }
            conversations.insert(fetchedConversation, at: 0)
            conversation = fetchedConversation
        } else {
            return
        }

        do {
            statusMessage = "Loading context for \(conversation.title)…"
            async let fetchedMessages = container.messagesStore.fetchMessages(conversationID: id, limit: 80)
            async let loadedSummary = container.memory.loadSummary(conversationID: conversation.id)
            async let loadedAutonomyConfig = container.database.loadAutonomyConfig(conversationID: conversation.id, memoryKey: conversation.memoryKey)
            async let loadedDraft = container.memory.loadDraft(conversationID: conversation.id, modelName: selectedModelName)

            let loadedMessages = try await fetchedMessages
            guard !Task.isCancelled, selectedConversationID == id else { return }
            try await synchronizeMemoriesForUI(
                conversation: conversation,
                messages: loadedMessages,
                status: "Updating memory for \(conversation.title)…"
            )
            self.messages = loadedMessages
            try await reloadUserMemoryState()
            try await reloadContactMemoryState(for: conversation)
            summary = try await loadedSummary
            contactAutonomyConfig = try await loadedAutonomyConfig
            currentDraft = try await loadedDraft
            statusMessage = "Loaded context for \(conversation.title)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func activateConversation(_ id: String, persistAcrossLaunches: Bool? = nil) async {
        if let persistAcrossLaunches {
            conversationLaunchPreference.persistSelectionAcrossLaunches = persistAcrossLaunches
        }
        conversationLaunchPreference.conversationID = id
        await persistConversationLaunchPreference()
        await loadConversation(id: id)
        restartMonitoring()
    }

    func updateConversationLaunchPersistence(_ persistAcrossLaunches: Bool) async {
        conversationLaunchPreference.persistSelectionAcrossLaunches = persistAcrossLaunches
        if persistAcrossLaunches {
            conversationLaunchPreference.conversationID = selectedConversationID
        }
        await persistConversationLaunchPreference()
        statusMessage = persistAcrossLaunches
            ? "Responder will reopen the selected conversation on launch."
            : "Responder will ask which conversation to use on launch."
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
            if selectedConversation != nil {
                startMemoryUpdate(status: "Updating memory from recent chat context…")
            }
            let result = try await container.autonomy.generateReply(
                conversationID: selectedConversationID,
                modelName: selectedModelName,
                mode: mode,
                conversation: selectedConversation,
                messages: messages,
                contextLimit: selectedModel?.contextLimit
            )
            finishMemoryUpdate()
            messages = result.messages
            currentDraft = result.draft
            currentPrompt = result.promptPacket
            currentPolicyDecision = result.policyDecision
            summary = result.summarySnapshot
            userMemory = result.userMemory
            contactMemory = result.contactMemory
            try await reloadUserMemoryState()
            try await reloadContactMemoryState(for: result.conversation)
            contactAutonomyConfig = try await container.database.loadAutonomyConfig(conversationID: result.conversation.id, memoryKey: result.conversation.memoryKey)
            statusMessage = "Draft ready."
            await refreshActivityLog()
        } catch {
            finishMemoryUpdate()
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
            try await container.memory.saveUserProfileMemory(manualUserMemory)
            try await reloadUserMemoryState()
            statusMessage = "User memory saved."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveContactMemory() async {
        guard let selectedConversation else { return }
        do {
            try await container.memory.saveContactMemory(manualContactMemory, conversationID: selectedConversation.id)
            try await reloadContactMemoryState(for: selectedConversation)
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

    func refreshMemoryFromCurrentConversation() async {
        guard let conversation = selectedConversation else { return }
        do {
            try await synchronizeMemoriesForUI(
                conversation: conversation,
                messages: messages,
                status: "Updating memory from recent chat context…"
            )
            try await reloadUserMemoryState()
            try await reloadContactMemoryState(for: conversation)
            statusMessage = "Memory updated from conversation context."
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
        draftSaveTask?.cancel()
        guard var draft = currentDraft else { return }
        draft.text = text
        currentDraft = draft
        do {
            try await container.memory.saveDraft(draft)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scheduleDraftSave(_ text: String) {
        draftSaveTask?.cancel()
        guard currentDraft != nil else { return }

        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveCurrentDraftText(text)
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

    func updateGlobalSettings(_ settings: GlobalAutonomySettings) async {
        globalSettings = settings
        await saveGlobalSettings()
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

    func chooseMessagesFolder() async {
        let panel = NSOpenPanel()
        panel.title = "Choose Your Messages Folder"
        panel.message = "Select the Messages folder inside your Library so Responder can read chat.db directly."
        panel.prompt = "Allow Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library", directoryHint: .isDirectory)

        guard panel.runModal() == .OK, let directoryURL = panel.url else {
            return
        }

        let databaseURL = directoryURL.appending(path: "chat.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            errorMessage = "Choose the Messages folder that contains chat.db."
            return
        }

        do {
            let access = try MessagesDirectoryAccessStore.save(directoryURL: directoryURL)
            messagesDirectoryAccess = access
            await reloadLiveContainer(status: "Saved Messages folder access.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearMessagesFolderAccess() async {
        MessagesDirectoryAccessStore.clear()
        messagesDirectoryAccess = nil
        await reloadLiveContainer(status: "Cleared saved Messages folder access.")
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
        manualUserMemory = userMemory

        do {
            try await container.memory.saveUserProfileMemory(manualUserMemory)
            try await reloadUserMemoryState()
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
            async let globalSettingsTask = container.database.loadGlobalSettings()
            async let onboardingStateTask = container.database.loadOnboardingState()
            async let providerConfigurationTask = container.database.loadProviderConfiguration()
            async let launchPreferenceTask = container.database.loadConversationLaunchPreference()
            async let selectedModelTask = container.database.loadSelectedModel()

            globalSettings = try await globalSettingsTask
            onboardingState = try await onboardingStateTask
            providerConfiguration = try await providerConfigurationTask
            conversationLaunchPreference = try await launchPreferenceTask
            messagesDirectoryAccess = container.messagesDirectoryAccess
            if let selected = try await selectedModelTask,
               selected.provider == providerConfiguration.selectedProvider {
                selectedModelName = selected.model.name
            }
            try await reloadUserMemoryState()
            hasLoadedPersistentState = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restartMonitoring() {
        monitorTask?.cancel()
        guard globalSettings.autonomyEnabled,
              !selectedModelName.isEmpty,
              let selectedConversationID
        else { return }

        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    _ = try await self.container.autonomy.monitorCycle(
                        modelName: self.selectedModelName,
                        activeConversationID: selectedConversationID
                    )
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

    private func persistConversationLaunchPreference() async {
        do {
            try await container.database.saveConversationLaunchPreference(conversationLaunchPreference)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearConversationContext() {
        conversationLoadTask?.cancel()
        selectedConversationID = nil
        messages = []
        currentDraft = nil
        currentPrompt = nil
        currentPolicyDecision = nil
        contactMemory = .empty(memoryKey: "preview")
        manualContactMemory = .empty(memoryKey: "preview")
        derivedContactMemory = .empty(memoryKey: "preview")
        contactMemoryMetadata = nil
        summary = .empty(conversationID: "preview")
        contactAutonomyConfig = .default(conversationID: "preview", memoryKey: "preview")
    }

    private func reloadLiveContainer(status: String? = nil) async {
        do {
            let refreshedContainer = try AppContainer.live(database: container.database)
            container = refreshedContainer
            startupIssues = refreshedContainer.startupIssues
            messagesDirectoryAccess = refreshedContainer.messagesDirectoryAccess
            await refreshConversations()
            if let status, startupIssues.isEmpty {
                statusMessage = status
            } else if let issue = startupIssues.first {
                statusMessage = issue
            }
            restartMonitoring()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolvePreferredConversationID() async -> String? {
        if let currentID = selectedConversationID,
           conversations.contains(where: { $0.id == currentID }) {
            return currentID
        }

        guard conversationLaunchPreference.persistSelectionAcrossLaunches,
              let persistedID = conversationLaunchPreference.conversationID
        else {
            return nil
        }

        if conversations.contains(where: { $0.id == persistedID }) {
            return persistedID
        }

        guard let fetchedConversation = try? await container.messagesStore.fetchConversation(id: persistedID) else {
            return nil
        }

        conversations.removeAll { $0.id == fetchedConversation.id }
        conversations.insert(fetchedConversation, at: 0)
        return fetchedConversation.id
    }

    private func refreshSelectedModelMetadataIfNeeded(_ selected: OllamaModelInfo) {
        guard selectedProvider == .ollama, selected.contextLimit <= 4096 else { return }

        Task { [weak self] in
            guard let self else { return }
            guard let details = try? await self.container.llm.modelDetails(for: selected.name) else { return }
            await self.applySelectedModelMetadata(details)
        }
    }

    private func applySelectedModelMetadata(_ details: OllamaModelInfo) async {
        guard let index = availableModels.firstIndex(where: { $0.name == details.name }) else { return }
        guard availableModels[index].contextLimit != details.contextLimit else { return }

        availableModels[index] = OllamaModelInfo(
            name: availableModels[index].name,
            digest: availableModels[index].digest ?? details.digest,
            sizeBytes: availableModels[index].sizeBytes ?? details.sizeBytes,
            modifiedAt: availableModels[index].modifiedAt ?? details.modifiedAt,
            contextLimit: details.contextLimit
        )

        if selectedModelName == details.name {
            try? await container.database.saveSelectedModel(
                SelectedModelState(provider: selectedProvider, model: availableModels[index])
            )
        }
    }

    private func scheduleConversationLoad(id: String) {
        conversationLoadTask?.cancel()
        conversationLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadConversation(id: id)
        }
    }

    private func synchronizeMemoriesForUI(
        conversation: ConversationRef,
        messages: [ChatMessage],
        status: String
    ) async throws {
        startMemoryUpdate(status: status)
        do {
            try await container.memory.synchronizeMemories(conversation: conversation, messages: messages)
            finishMemoryUpdate()
        } catch {
            finishMemoryUpdate()
            throw error
        }
    }

    private func reloadUserMemoryState() async throws {
        async let loadedMerged = container.memory.loadUserProfileMemory()
        async let loadedManual = container.database.loadUserProfileMemory()
        async let loadedDerived = container.database.loadDerivedUserProfileMemory()
        async let loadedMetadata = container.database.loadDerivedUserProfileMemoryMetadata()

        userMemory = try await loadedMerged
        manualUserMemory = try await loadedManual
        derivedUserMemory = try await loadedDerived
        userMemoryMetadata = try await loadedMetadata
    }

    private func reloadContactMemoryState(for conversation: ConversationRef) async throws {
        async let loadedMerged = container.memory.loadContactMemory(memoryKey: conversation.memoryKey, conversationID: conversation.id)
        async let loadedManual = container.database.loadContactMemory(memoryKey: conversation.memoryKey, conversationID: conversation.id)
        async let loadedDerived = container.database.loadDerivedContactMemory(memoryKey: conversation.memoryKey)
        async let loadedMetadata = container.database.loadDerivedContactMemoryMetadata(memoryKey: conversation.memoryKey)

        contactMemory = try await loadedMerged
        manualContactMemory = try await loadedManual
        derivedContactMemory = try await loadedDerived
        contactMemoryMetadata = try await loadedMetadata
    }

    private func startMemoryUpdate(status: String) {
        isUpdatingMemory = true
        memoryUpdateStatus = status
    }

    private func finishMemoryUpdate() {
        isUpdatingMemory = false
        memoryUpdateStatus = nil
    }
}
