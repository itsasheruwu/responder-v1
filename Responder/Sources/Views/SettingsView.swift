import SwiftUI

struct SettingsSceneView: View {
    @Bindable var model: AppModel
    @State private var draftGlobalSettings: GlobalAutonomySettings = .default

    var body: some View {
        TabView {
            SettingsPage(
                title: "General",
                subtitle: "Choose the active conversation, provider, and local runtime access."
            ) {
                SettingsHeroPanel(
                    title: "Responder Setup",
                    message: providerSummary,
                    badges: [
                        model.selectedProvider.displayName,
                        model.selectedConversation?.title ?? "No Conversation",
                        model.selectedModelName.isEmpty ? "No Model" : model.selectedModelName
                    ]
                )

                SettingsCard(title: "Conversation Context", subtitle: "Responder stays scoped to one conversation at a time.") {
                    if model.conversations.isEmpty {
                        Text("No conversations are currently loaded.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(
                            "Active Conversation",
                            selection: Binding(
                                get: { model.selectedConversationID ?? model.conversations.first?.id ?? "" },
                                set: { newValue in
                                    guard !newValue.isEmpty else { return }
                                    Task { await model.activateConversation(newValue) }
                                }
                            )
                        ) {
                            ForEach(model.conversations) { conversation in
                                Text(conversation.title).tag(conversation.id)
                            }
                        }
                        .pickerStyle(.menu)

                        Toggle(
                            "Reopen selected conversation on launch",
                            isOn: Binding(
                                get: { model.persistConversationSelectionAcrossLaunches },
                                set: { newValue in
                                    Task { await model.updateConversationLaunchPersistence(newValue) }
                                }
                            )
                        )

                        Text("When disabled, Responder asks you to choose a conversation each time it starts.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsCard(title: "Provider", subtitle: "Switch between local-only Ollama and cloud-backed OpenRouter.") {
                    Picker("Active Provider", selection: $model.providerConfiguration.selectedProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.providerConfiguration.selectedProvider) {
                        Task { await model.saveProviderConfiguration() }
                    }

                    if model.providerConfiguration.selectedProvider == .openRouter {
                        SecureField("OpenRouter API Key", text: $model.providerConfiguration.openRouterAPIKey)
                            .textFieldStyle(.roundedBorder)
                        TextField("OpenRouter Base URL", text: $model.providerConfiguration.openRouterBaseURL)
                            .textFieldStyle(.roundedBorder)
                        Text("OpenRouter sends chat context to a routed cloud model. Built-in presets include `openrouter/free` and `nvidia/nemotron-3-super-120b-a12b:free`.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Save OpenRouter Settings") {
                            Task { await model.saveProviderConfiguration() }
                        }
                    } else {
                        SettingsCallout(
                            title: "Local-Only Mode",
                            message: "Ollama keeps draft generation on this Mac and remains the privacy-first default.",
                            tint: .green
                        )
                    }
                }

                SettingsCard(title: "Runtime Access", subtitle: "Messages history is read locally and sending still relies on Messages automation.") {
                    SettingsKeyValueRow(label: "Messages Folder", value: model.messagesDirectoryAccessPath ?? "Using Full Disk Access")
                    SettingsKeyValueRow(
                        label: "Provider Endpoint",
                        value: model.providerConfiguration.selectedProvider == .ollama
                            ? "http://127.0.0.1:11434"
                            : model.providerConfiguration.openRouterBaseURL
                    )
                    Text("If Full Disk Access is unreliable, save direct access to the Messages folder here. Sending still requires Automation permission for Messages.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button(model.messagesDirectoryAccessPath == nil ? "Choose Messages Folder" : "Choose Messages Folder Again") {
                            Task { await model.chooseMessagesFolder() }
                        }
                        if model.messagesDirectoryAccessPath != nil {
                            Button("Clear Saved Access") {
                                Task { await model.clearMessagesFolderAccess() }
                            }
                        }
                        Spacer()
                        Button("Reopen Setup") {
                            Task { await model.reopenOnboarding() }
                        }
                    }
                }

                SettingsCard(title: "Model", subtitle: "Pick the active model for the selected provider and refresh availability.") {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Active Model")
                                .font(.subheadline.weight(.semibold))
                            Menu {
                                if model.availableModels.isEmpty {
                                    Text("No models available")
                                } else {
                                    ForEach(model.availableModels) { item in
                                        Button {
                                            model.selectedModelName = item.name
                                            Task { await model.persistSelectedModel() }
                                        } label: {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(item.name)
                                                    Text("\(item.contextLimit) context")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                if item.name == model.selectedModelName {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.selectedModelName.isEmpty ? "Select Model" : model.selectedModelName)
                                            .font(.body.weight(.semibold))
                                            .lineLimit(1)
                                        Text(model.selectedModel.map { "\($0.contextLimit) context window" } ?? "\(model.availableModels.count) model options")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .menuStyle(.borderlessButton)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Status")
                                .font(.subheadline.weight(.semibold))
                            SettingsCallout(
                                title: model.availableModels.isEmpty ? "No Models Available" : "\(model.availableModels.count) Models Loaded",
                                message: model.selectedProvider == .ollama
                                    ? "Refresh after starting Ollama or pulling a new local model."
                                    : "Refresh after changing your OpenRouter key or provider access.",
                                tint: model.availableModels.isEmpty ? .orange : .green
                            )
                        }
                    }

                    Button("Refresh Models") {
                        Task { await model.refreshModels() }
                    }
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            SettingsPage(
                title: "Privacy",
                subtitle: "Understand what stays local and what leaves the Mac."
            ) {
                SettingsHeroPanel(
                    title: model.selectedProvider == .ollama ? "Local Privacy Active" : "Cloud Provider Active",
                    message: model.selectedProvider == .ollama
                        ? "Conversation context, memory, summaries, and drafts remain on this Mac when you stay on Ollama."
                        : "OpenRouter mode sends prompt content and recent context to a cloud provider. Use it only when that tradeoff is acceptable.",
                    badges: [
                        model.selectedProvider.supportsLocalPrivacy ? "Local" : "Cloud",
                        "Messages: Local DB",
                        "Send: Automation"
                    ]
                )

                SettingsCard(title: "Data Handling", subtitle: "Responder stores app state locally even when generation uses a cloud provider.") {
                    SettingsCallout(
                        title: "Stored on This Mac",
                        message: "Memory, drafts, summaries, activity logs, and contact autonomy settings are persisted locally.",
                        tint: .blue
                    )
                    SettingsCallout(
                        title: model.selectedProvider == .ollama ? "No Remote Uploads" : "Remote Prompt Routing",
                        message: model.selectedProvider == .ollama
                            ? "Ollama mode does not upload conversation data."
                            : "OpenRouter mode sends prompt payloads and chat context to OpenRouter and the selected routed model provider.",
                        tint: model.selectedProvider == .ollama ? .green : .orange
                    )
                }

                SettingsCard(title: "Permissions", subtitle: "Responder depends on macOS privacy permissions to function reliably.") {
                    SettingsChecklistRow(title: "Full Disk Access", detail: "Required to read the Messages database unless a direct folder bookmark is saved.")
                    SettingsChecklistRow(title: "Automation", detail: "Required to control Messages when sending a draft.")
                    SettingsChecklistRow(title: "Messages Folder Override", detail: "Optional fallback when Full Disk Access alone is insufficient.")
                }
            }
            .tabItem { Label("Privacy", systemImage: "lock.shield") }

            SettingsPage(
                title: "Autonomy",
                subtitle: "Tune the monitoring engine and global guardrails."
            ) {
                SettingsHeroPanel(
                    title: draftGlobalSettings.autonomyEnabled ? "Monitoring Enabled" : "Monitoring Disabled",
                    message: draftGlobalSettings.autonomyEnabled
                        ? "Responder can monitor the active conversation and prepare or send replies within the configured guardrails."
                        : "Responder stays in manual draft mode until monitoring is enabled.",
                    badges: [
                        draftGlobalSettings.emergencyStopEnabled ? "Emergency Stop On" : "Emergency Stop Off",
                        "Poll \(draftGlobalSettings.monitorPollIntervalSeconds)s",
                        "Quiet Hours \(draftGlobalSettings.defaultQuietHoursStartHour):00-\(draftGlobalSettings.defaultQuietHoursEndHour):00"
                    ]
                )

                SettingsCard(title: "Global Guardrails", subtitle: "These defaults shape monitoring behavior before any per-contact override.") {
                    Toggle("Enable monitoring engine", isOn: $draftGlobalSettings.autonomyEnabled)
                    Toggle("Emergency stop", isOn: $draftGlobalSettings.emergencyStopEnabled)
                    Stepper(
                        "Default quiet hours start: \(draftGlobalSettings.defaultQuietHoursStartHour):00",
                        value: $draftGlobalSettings.defaultQuietHoursStartHour,
                        in: 0...23
                    )
                    Stepper(
                        "Default quiet hours end: \(draftGlobalSettings.defaultQuietHoursEndHour):00",
                        value: $draftGlobalSettings.defaultQuietHoursEndHour,
                        in: 0...23
                    )
                    Stepper(
                        "Monitor poll interval: \(draftGlobalSettings.monitorPollIntervalSeconds)s",
                        value: $draftGlobalSettings.monitorPollIntervalSeconds,
                        in: 5...120,
                        step: 5
                    )
                    Button("Save Global Settings") {
                        let updatedSettings = draftGlobalSettings
                        Task { await model.updateGlobalSettings(updatedSettings) }
                    }
                }
            }
            .tabItem { Label("Autonomy", systemImage: "bolt.shield") }

            SettingsPage(
                title: "Models",
                subtitle: "Inspect the selected model and how context is managed."
            ) {
                SettingsHeroPanel(
                    title: model.selectedModelName.isEmpty ? "No Model Selected" : model.selectedModelName,
                    message: "Older messages are compacted into the rolling summary when the prompt nears the model's context limit.",
                    badges: [
                        model.selectedProvider.displayName,
                        model.selectedModel?.contextLimit.description ?? "Unknown Limit"
                    ]
                )

                SettingsCard(title: "Current Model", subtitle: "The active model controls generation, summarization, and policy evaluation.") {
                    if let selected = model.selectedModel {
                        SettingsKeyValueRow(label: "Provider", value: model.selectedProvider.displayName)
                        SettingsKeyValueRow(label: "Context Limit", value: "\(selected.contextLimit)")
                        SettingsKeyValueRow(label: "Name", value: selected.name)
                    } else {
                        Text("Select a model to inspect its effective context limit.")
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsCard(title: "Available Models", subtitle: "Refresh the provider catalog when local or remote availability changes.") {
                    if model.availableModels.isEmpty {
                        Text("No models are currently available.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.availableModels.prefix(8).map { $0 }) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.body.weight(.medium))
                                    Text("Context limit \(item.contextLimit)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.name == model.selectedModelName {
                                    Text("Active")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                    }

                    Button("Refresh Models") {
                        Task { await model.refreshModels() }
                    }
                }
            }
            .tabItem { Label("Models", systemImage: "cpu") }
        }
        .frame(width: 860, height: 620)
        .task {
            draftGlobalSettings = model.globalSettings
        }
        .onChange(of: model.globalSettings) { _, newValue in
            draftGlobalSettings = newValue
        }
    }

    private var providerSummary: String {
        if model.selectedProvider == .ollama {
            return "Ollama is active, so generation stays local unless you explicitly switch to OpenRouter."
        }
        return "OpenRouter is active. Recent chat context may be sent to the configured cloud endpoint during generation and memory updates."
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.largeTitle.weight(.semibold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsHeroPanel: View {
    let title: String
    let message: String
    let badges: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(badges.filter { !$0.isEmpty }, id: \.self) { badge in
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .foregroundStyle(.white)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

private struct SettingsCallout: View {
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SettingsKeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct SettingsChecklistRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
