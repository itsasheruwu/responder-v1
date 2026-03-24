import SwiftUI

struct OnboardingView: View {
    @Bindable var model: AppModel

    @State private var profileSummary: String = ""
    @State private var styleTraitsText: String = ""
    @State private var bannedPhrasesText: String = ""
    @State private var backgroundFactsText: String = ""
    @State private var replyHabitsText: String = ""
    @State private var enableMonitoringAfterSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .padding(28)
        .frame(width: 860, height: 760, alignment: .topLeading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(radius: 30)
        .task {
            syncFromModel()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Set Up Responder")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                Text(stepLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }

            ProgressView(value: progressValue)
                .controlSize(.large)

            Text(stepDescription)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.onboardingState.currentStep {
        case .welcome:
            welcomeStep
        case .privacy:
            privacyStep
        case .model:
            modelStep
        case .voice:
            voiceStep
        case .autonomy:
            autonomyStep
        case .finish:
            finishStep
        }
    }

    private var footer: some View {
        HStack {
            if model.onboardingState.currentStep != .welcome {
                Button("Back") {
                    Task { await model.goBackOnboarding() }
                }
            }

            Spacer()

            Button(continueTitle) {
                Task { await handleContinue() }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Responder stays local by design.")
                .font(.title2.weight(.semibold))
            Text("This setup will verify your runtime, explain macOS access requirements, let you choose a generation model, seed your voice memory, and review autonomy defaults before the main workspace opens.")
                .foregroundStyle(.secondary)

            GroupBox("What you can do after setup") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Browse recent iMessage conversations from the local Messages database", systemImage: "message")
                    Label("Generate reply drafts in your own voice using your selected provider and model", systemImage: "cpu")
                    Label("Edit per-contact memory, rolling summaries, autonomy policies, and local logs", systemImage: "brain")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Privacy and local access")
                .font(.title2.weight(.semibold))

            runtimeStatusRow(
                title: "Messages history",
                message: model.messagesAccessRestricted ? model.startupIssues.first ?? "Messages history is currently unavailable." : "Read-only access looks available.",
                status: model.messagesAccessRestricted ? "Needs Full Disk Access" : "Ready",
                color: model.messagesAccessRestricted ? .orange : .green
            )

            runtimeStatusRow(
                title: model.selectedProvider == .ollama ? "Ollama runtime" : "OpenRouter runtime",
                message: model.selectedProvider == .ollama
                    ? (model.availableModels.isEmpty ? "No local models are currently available. Start Ollama and pull a model before generating drafts." : "Detected \(model.availableModels.count) local model(s) at http://127.0.0.1:11434.")
                    : (model.availableModels.isEmpty ? "No OpenRouter models are currently available. Enter your API key in Settings before generating drafts." : "Detected \(model.availableModels.count) OpenRouter model option(s), including openrouter/free and NVIDIA Nemotron 3 Super free."),
                status: model.availableModels.isEmpty ? "Not Ready" : "Ready",
                color: model.availableModels.isEmpty ? .orange : .green
            )

            runtimeStatusRow(
                title: "Messages automation",
                message: "Sending requires Automation permission for Messages. Draft suggestion mode works without it.",
                status: "Optional",
                color: .blue
            )

            HStack {
                Button("Refresh Local Checks") {
                    Task {
                        await model.refreshModels()
                        await model.refreshConversations()
                    }
                }
                Text("Responder does not upload conversations, memories, summaries, or logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.selectedProvider == .ollama ? "Choose a local Ollama model" : "Choose an OpenRouter model")
                .font(.title2.weight(.semibold))

            Picker("Active model", selection: $model.selectedModelName) {
                if model.availableModels.isEmpty {
                    Text("No models available").tag("")
                } else {
                    ForEach(model.availableModels) { item in
                        Text("\(item.name) (\(item.contextLimit))").tag(item.name)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360)

            if let selected = model.selectedModel {
                GroupBox("Selected model") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selected.name)
                            .font(.headline)
                        Text("Effective context limit: \(selected.contextLimit) tokens")
                        if let sizeBytes = selected.sizeBytes {
                            Text("Approximate size: \(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("No Model Selected", systemImage: "cpu", description: Text(model.selectedProvider == .ollama ? "You can continue setup without a model, but draft generation will stay unavailable until Ollama is ready." : "You can continue setup without a model, but draft generation will stay unavailable until OpenRouter is configured."))
            }

            HStack {
                Button("Refresh Models") {
                    Task { await model.refreshModels() }
                }
                Text("Responder will reserve output and safety headroom, then compact older context automatically when needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var voiceStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Seed your voice memory")
                    .font(.title2.weight(.semibold))
                Text("These fields stay local and become the starting user-memory layer for reply generation. Use one short line per item.")
                    .foregroundStyle(.secondary)

                TextField("Profile summary", text: $profileSummary, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                twoColumnEditorGrid
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.trailing, 6)
        }
        .scrollIndicators(.visible)
    }

    private var autonomyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Autonomy defaults")
                .font(.title2.weight(.semibold))
            Text("Responder starts in draft suggestion mode. Real auto-send stays off by default and still requires explicit per-contact opt-in, simulation, policy checks, quiet hours, confidence thresholds, rate limits, and the emergency stop.")
                .foregroundStyle(.secondary)

            GroupBox("Default safety posture") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Monitoring engine is optional and off by default", systemImage: "eye.slash")
                    Label("Per-contact auto-send remains off until you opt in", systemImage: "bolt.shield")
                    Label("Emergency stop is always available in the toolbar and settings", systemImage: "hand.raised")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("Enable monitoring engine after setup", isOn: $enableMonitoringAfterSetup)
            Text("This only enables background monitoring. It does not enable auto-send for any contact.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Ready to draft locally")
                .font(.title2.weight(.semibold))

            GroupBox("Setup summary") {
                VStack(alignment: .leading, spacing: 10) {
                    summaryRow(title: "Messages history", value: model.messagesAccessRestricted ? "Restricted until Full Disk Access is granted" : "Available")
                    summaryRow(title: "\(model.selectedProvider.displayName) model", value: model.selectedModel?.name ?? "None selected")
                    summaryRow(title: "Voice profile", value: profileSummary.isEmpty ? "Not seeded yet" : profileSummary)
                    summaryRow(title: "Monitoring engine", value: model.globalSettings.autonomyEnabled ? "Enabled" : "Off")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("You can reopen setup later from the toolbar or Settings.")
                .foregroundStyle(.secondary)
        }
    }

    private func runtimeStatusRow(title: String, message: String, status: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                }
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func listEditor(title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            TextEditor(text: text)
                .font(.body)
                .frame(height: 120)
                .padding(8)
                .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var twoColumnEditorGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                listEditor(title: "Style traits", text: $styleTraitsText, prompt: "brief\nwarm\nlow punctuation")
                listEditor(title: "Reply habits", text: $replyHabitsText, prompt: "usually responds same day\nprefers direct answers")
            }

            HStack(alignment: .top, spacing: 16) {
                listEditor(title: "Avoid", text: $bannedPhrasesText, prompt: "circle back\nper my last message")
                listEditor(title: "Background facts", text: $backgroundFactsText, prompt: "works on Eastern Time\noften unavailable after 10 PM")
            }
        }
    }

    private func summaryRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
        }
    }

    private var progressValue: Double {
        let steps = OnboardingStep.allCases
        guard let index = steps.firstIndex(of: model.onboardingState.currentStep) else { return 0 }
        return Double(index + 1) / Double(steps.count)
    }

    private var stepLabel: String {
        let steps = OnboardingStep.allCases
        let index = (steps.firstIndex(of: model.onboardingState.currentStep) ?? 0) + 1
        return "Step \(index) of \(steps.count)"
    }

    private var stepDescription: String {
        switch model.onboardingState.currentStep {
        case .welcome:
            return "A short local-first setup before the main workspace."
        case .privacy:
            return "Check local runtime access, Messages permissions, and privacy boundaries."
        case .model:
            return model.selectedProvider == .ollama
                ? "Pick the Ollama model that will generate drafts and summaries."
                : "Pick the OpenRouter model that will generate drafts and summaries."
        case .voice:
            return "Seed the user-memory layer with your writing habits and boundaries."
        case .autonomy:
            return "Review how monitoring and auto-send are kept constrained."
        case .finish:
            return "Review the final local setup summary and enter the app."
        }
    }

    private var continueTitle: String {
        model.onboardingState.currentStep == .finish ? "Open Responder" : "Continue"
    }

    private func handleContinue() async {
        switch model.onboardingState.currentStep {
        case .voice:
            await model.saveOnboardingVoiceProfile(
                profileSummary: profileSummary,
                styleTraits: parseLines(styleTraitsText),
                bannedPhrases: parseLines(bannedPhrasesText),
                backgroundFacts: parseLines(backgroundFactsText),
                replyHabits: parseLines(replyHabitsText)
            )
            await model.advanceOnboarding()
        case .autonomy:
            await model.applyOnboardingAutonomyDefaults(enableMonitoring: enableMonitoringAfterSetup)
            await model.advanceOnboarding()
        case .finish:
            await model.completeOnboarding()
        default:
            await model.advanceOnboarding()
        }
    }

    private func syncFromModel() {
        profileSummary = model.userMemory.profileSummary
        styleTraitsText = model.userMemory.styleTraits.joined(separator: "\n")
        bannedPhrasesText = model.userMemory.bannedPhrases.joined(separator: "\n")
        backgroundFactsText = model.userMemory.backgroundFacts.joined(separator: "\n")
        replyHabitsText = model.userMemory.replyHabits.joined(separator: "\n")
        enableMonitoringAfterSetup = model.globalSettings.autonomyEnabled
    }

    private func parseLines(_ value: String) -> [String] {
        value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
