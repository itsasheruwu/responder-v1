import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            NavigationSplitView {
                ConversationContextView(model: model)
            } content: {
                ConversationDetailView(model: model)
            } detail: {
                ReplyInspectorView(model: model)
            }
            .blur(radius: overlayActive ? 8 : 0)
            .allowsHitTesting(!overlayActive)

            if overlayActive {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                if model.showsPermissionGate {
                    PermissionGateView(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if model.showsOnboarding {
                    OnboardingView(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if model.showsConversationChooser {
                    StartupConversationPickerView(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
        .navigationTitle("Responder")
        .toolbar {
            ToolbarItemGroup {
                ModelToolbarSelector(model: model)

                Button("Memory Inspector") {
                    openWindow(id: "memory-inspector")
                }

                Button("Activity Log") {
                    openWindow(id: "activity-log")
                }

                Button("Setup") {
                    Task { await model.reopenOnboarding() }
                }

                Button("Settings") {
                    openSettings()
                }

                Toggle(isOn: Binding(
                    get: { model.globalSettings.emergencyStopEnabled },
                    set: { newValue in Task { await model.updateGlobalEmergencyStop(newValue) } }
                )) {
                    Text("Emergency Stop")
                }
                .toggleStyle(.switch)

                if model.isUpdatingMemory {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating Memory")
                            .font(.caption)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if model.isUpdatingMemory, let memoryUpdateStatus = model.memoryUpdateStatus {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(memoryUpdateStatus)
                    }
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                }

                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .padding()
        }
        .task {
            await model.startIfNeeded()
        }
        .alert("Responder", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("OK", role: .cancel) {
                model.clearError()
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var overlayActive: Bool {
        model.showsPermissionGate || model.showsOnboarding || model.showsConversationChooser
    }
}

private struct ModelToolbarSelector: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.selectedProvider.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.selectedModelName.isEmpty ? "Select Model" : model.selectedModelName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(model.selectedModel.map { "\($0.contextLimit) context" } ?? "\(model.availableModels.count) available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(width: 260, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .menuStyle(.borderlessButton)
            }

            Button {
                Task {
                    await model.refreshModels()
                    await model.refreshConversations()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh models and conversations")
            .disabled(model.isGenerating || model.isLoading)
        }
    }
}

struct ConversationContextView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let conversation = model.selectedConversation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Active Context")
                                .font(.title3.weight(.semibold))
                            Text("Responder stays scoped to one conversation at a time.")
                                .foregroundStyle(.secondary)
                        }

                        GroupBox("Conversation") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(conversation.title)
                                    .font(.headline)
                                Text(conversation.subtitle)
                                    .foregroundStyle(.secondary)
                                Text("Service: \(conversation.service.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if conversation.unreadCount > 0 {
                                    Text("\(conversation.unreadCount) unread message(s)")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                }
                                if let date = conversation.lastMessageDate {
                                    Text("Last activity: \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GroupBox("Launch Behavior") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(model.persistConversationSelectionAcrossLaunches
                                     ? "Responder will reopen this conversation automatically on launch."
                                     : "Responder will ask you to choose a conversation each time it launches.")
                                Button("Change Conversation in Settings") {
                                    openSettings()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GroupBox("Recent Preview") {
                            Text(conversation.lastMessagePreview)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "message",
                    description: Text("Choose a conversation on launch or open Settings to change the active context.")
                )
            }
        }
    }
}

struct ConversationDetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let conversation = model.selectedConversation {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conversation.title)
                                .font(.title2.weight(.semibold))
                            Text(conversation.subtitle)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Generate Draft") {
                            Task { await model.generateDraft() }
                        }
                        .disabled(model.isGenerating || model.selectedModelName.isEmpty)
                    }

                    ScrollViewReader { proxy in
                        Group {
                            if model.messages.isEmpty {
                                ContentUnavailableView(
                                    model.isLoading || model.isUpdatingMemory ? "Loading Messages" : "No Messages Loaded",
                                    systemImage: model.isLoading || model.isUpdatingMemory ? "ellipsis.message" : "message.badge",
                                    description: Text(model.statusMessage)
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 10) {
                                        ForEach(model.messages) { message in
                                            HStack {
                                                if message.direction == .outgoing {
                                                    Spacer(minLength: 60)
                                                }
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(message.senderName)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                    Text(message.text)
                                                        .textSelection(.enabled)
                                                }
                                                .padding(10)
                                                .frame(maxWidth: 420, alignment: .leading)
                                                .background(message.direction == .outgoing ? Color.accentColor.opacity(0.16) : Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                                                if message.direction == .incoming {
                                                    Spacer(minLength: 60)
                                                }
                                            }
                                            .id(message.id)
                                        }
                                    }
                                }
                                .onChange(of: model.messages.count) {
                                    if let last = model.messages.last?.id {
                                        proxy.scrollTo(last, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "message",
                    description: Text("Responder needs one conversation selected before it can load history and generate replies.")
                )
            }
        }
    }
}

struct ReplyInspectorView: View {
    @Bindable var model: AppModel
    @State private var draftText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.currentDraft == nil {
                    ContentUnavailableView("No Draft Yet", systemImage: "square.and.pencil", description: Text("Generate a draft from the selected conversation."))
                } else {
                    GroupBox("Draft") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $draftText)
                            .frame(minHeight: 180)

                            HStack {
                                Button(model.isGenerating ? "Generating…" : "Regenerate") {
                                    Task { await model.generateDraft() }
                                }
                                .disabled(model.isGenerating)

                                Button("Simulation Run") {
                                    Task { await model.generateDraft(mode: .simulation) }
                                }
                                .disabled(model.isGenerating)

                                Button(model.isSending ? "Sending…" : "Send") {
                                    Task { await model.sendCurrentDraft() }
                                }
                                .disabled(model.isSending || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }

                    if let usage = model.currentPrompt?.contextUsage {
                        GroupBox("Context Usage") {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView(value: usage.utilization)
                                Text("Estimated input: \(usage.estimatedInputTokens) tokens")
                                Text("Reserved output: \(usage.reservedOutputTokens) tokens")
                                Text("Reserved headroom: \(usage.reservedHeadroomTokens) tokens")
                                Text("Context limit: \(usage.contextLimit) tokens")
                                Text(usage.compacted ? "Older messages were compacted before generation." : "No compaction was needed.")
                                    .foregroundStyle(usage.compacted ? .secondary : .secondary)
                            }
                            .font(.caption)
                        }
                    }

                    if let decision = model.currentPolicyDecision {
                        GroupBox("Policy") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Decision: \(decision.action.rawValue)")
                                    .font(.headline)
                                Text("Confidence: \(decision.confidence, format: .number.precision(.fractionLength(2)))")
                                if !decision.reasons.isEmpty {
                                    Text(decision.reasons.joined(separator: "\n"))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                        }
                    }

                    GroupBox("Applied Memory") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("User")
                                .font(.headline)
                            Text(model.userMemory.asSnapshot().promptText)
                                .textSelection(.enabled)
                            Divider()
                            Text("Contact")
                                .font(.headline)
                            Text(model.contactMemory.asSnapshot().promptText)
                                .textSelection(.enabled)
                            Divider()
                            Text("Rolling Summary")
                                .font(.headline)
                            Text(model.summary.text.isEmpty ? "No rolling summary yet." : model.summary.text)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                    }

                    GroupBox("Autonomy") {
                        AutonomySettingsForm(model: model, compact: true)
                    }
                }
            }
            .padding()
        }
        .onChange(of: model.currentDraft?.id, initial: true) {
            draftText = model.currentDraft?.text ?? ""
        }
        .onChange(of: model.currentDraft?.text) {
            let latest = model.currentDraft?.text ?? ""
            if latest != draftText {
                draftText = latest
            }
        }
        .onChange(of: draftText) { _, newValue in
            model.scheduleDraftSave(newValue)
        }
    }
}

struct StartupConversationPickerView: View {
    @Bindable var model: AppModel

    @State private var pendingConversationID: String?
    @State private var persistAcrossLaunches = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose Conversation Context")
                    .font(.largeTitle.weight(.semibold))
                Text("Responder now works with one conversation at a time. Pick the conversation you want it to use for history, memory, and draft generation.")
                    .foregroundStyle(.secondary)
            }

            List(model.conversations, selection: $pendingConversationID) { conversation in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(conversation.title)
                            .font(.headline)
                        Spacer()
                        Text(conversation.service.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(conversation.lastMessagePreview)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    Text(conversation.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(conversation.id)
            }
            .frame(minHeight: 320)

            Toggle("Always reopen this conversation on launch", isOn: $persistAcrossLaunches)

            HStack {
                Text("You can change the active conversation later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Use Conversation") {
                    guard let pendingConversationID else { return }
                    Task {
                        await model.activateConversation(
                            pendingConversationID,
                            persistAcrossLaunches: persistAcrossLaunches
                        )
                    }
                }
                .disabled(pendingConversationID == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 780, height: 620, alignment: .topLeading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(radius: 30)
        .task {
            if pendingConversationID == nil {
                pendingConversationID = model.conversationLaunchPreference.conversationID ?? model.conversations.first?.id
            }
            persistAcrossLaunches = model.persistConversationSelectionAcrossLaunches
        }
    }
}

struct AutonomySettingsForm: View {
    @Bindable var model: AppModel
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Toggle("Monitor this conversation", isOn: $model.contactAutonomyConfig.monitoringEnabled)
            Toggle("Simulation mode", isOn: $model.contactAutonomyConfig.simulationMode)
            Toggle("Allow auto-send without review", isOn: $model.contactAutonomyConfig.autoSendEnabled)
            LabeledContent("Confidence threshold") {
                Text(model.contactAutonomyConfig.confidenceThreshold, format: .number.precision(.fractionLength(2)))
            }
            Slider(value: $model.contactAutonomyConfig.confidenceThreshold, in: 0.5...0.99, step: 0.01)
            Stepper("Quiet hours start: \(model.contactAutonomyConfig.quietHoursStartHour):00", value: $model.contactAutonomyConfig.quietHoursStartHour, in: 0...23)
            Stepper("Quiet hours end: \(model.contactAutonomyConfig.quietHoursEndHour):00", value: $model.contactAutonomyConfig.quietHoursEndHour, in: 0...23)
            Stepper("Min seconds between auto-sends: \(model.contactAutonomyConfig.minimumSecondsBetweenSends)", value: $model.contactAutonomyConfig.minimumSecondsBetweenSends, in: 5...300, step: 5)
            Stepper("Daily auto-send limit: \(model.contactAutonomyConfig.dailySendLimit)", value: $model.contactAutonomyConfig.dailySendLimit, in: 1...20)
            Toggle("Require simulation pass first", isOn: $model.contactAutonomyConfig.requiresCompletedSimulation)
            Button("Save Contact Autonomy Settings") {
                Task { await model.saveAutonomyConfig() }
            }
        }
        .font(compact ? .caption : .body)
    }
}
