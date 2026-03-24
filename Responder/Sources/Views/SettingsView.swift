import SwiftUI

struct SettingsSceneView: View {
    @Bindable var model: AppModel
    @State private var draftGlobalSettings: GlobalAutonomySettings = .default

    var body: some View {
        TabView {
            Form {
                Section("Provider") {
                    Picker("Active Provider", selection: $model.providerConfiguration.selectedProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .onChange(of: model.providerConfiguration.selectedProvider) {
                        Task { await model.saveProviderConfiguration() }
                    }

                    if model.providerConfiguration.selectedProvider == .openRouter {
                        SecureField("OpenRouter API Key", text: $model.providerConfiguration.openRouterAPIKey)
                            .textFieldStyle(.roundedBorder)
                        TextField("OpenRouter Base URL", text: $model.providerConfiguration.openRouterBaseURL)
                            .textFieldStyle(.roundedBorder)
                        Text("Built-in OpenRouter presets include `openrouter/free` and `nvidia/nemotron-3-super-120b-a12b:free`.")
                            .foregroundStyle(.secondary)
                        Button("Save OpenRouter Settings") {
                            Task { await model.saveProviderConfiguration() }
                        }
                        Text("OpenRouter sends prompts to a cloud provider. This is not local-only or privacy-first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Ollama stays fully local on this Mac and remains the default provider.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Runtime") {
                    Text("Messages access is read-only through the local chat database.")
                    Text("Sending uses Messages automation and requires user-granted Automation access.")
                    if model.providerConfiguration.selectedProvider == .ollama {
                        Text("Ollama endpoint: http://127.0.0.1:11434")
                    } else {
                        Text("OpenRouter endpoint: \(model.providerConfiguration.openRouterBaseURL)")
                    }
                    Button("Reopen Setup") {
                        Task { await model.reopenOnboarding() }
                    }
                }

                Section("Model") {
                    Picker("Selected Model", selection: $model.selectedModelName) {
                        ForEach(model.availableModels) { item in
                            Text("\(item.name) (\(item.contextLimit))").tag(item.name)
                        }
                    }
                    Button("Refresh Models") {
                        Task { await model.refreshModels() }
                    }
                }
            }
            .tabItem { Label("General", systemImage: "gear") }
            .padding()

            Form {
                Section("Privacy") {
                    Text("All memory, drafts, logs, and summaries stay on this Mac.")
                    if model.providerConfiguration.selectedProvider == .ollama {
                        Text("Responder does not upload conversation data when using Ollama.")
                    } else {
                        Text("OpenRouter mode sends prompt content to OpenRouter and the routed model provider.")
                    }
                    Text("For full functionality, grant Full Disk Access to read Messages history and Automation permission to control Messages for sending.")
                }
            }
            .tabItem { Label("Privacy", systemImage: "lock") }
            .padding()

            Form {
                Section("Global Autonomy") {
                    Toggle("Enable monitoring engine", isOn: $draftGlobalSettings.autonomyEnabled)
                    Toggle("Emergency stop", isOn: $draftGlobalSettings.emergencyStopEnabled)
                    Stepper("Default quiet hours start: \(draftGlobalSettings.defaultQuietHoursStartHour):00", value: $draftGlobalSettings.defaultQuietHoursStartHour, in: 0...23)
                    Stepper("Default quiet hours end: \(draftGlobalSettings.defaultQuietHoursEndHour):00", value: $draftGlobalSettings.defaultQuietHoursEndHour, in: 0...23)
                    Stepper("Monitor poll interval: \(draftGlobalSettings.monitorPollIntervalSeconds)s", value: $draftGlobalSettings.monitorPollIntervalSeconds, in: 5...120, step: 5)
                    Button("Save Global Settings") {
                        let updatedSettings = draftGlobalSettings
                        Task { await model.updateGlobalSettings(updatedSettings) }
                    }
                }
            }
            .tabItem { Label("Autonomy", systemImage: "bolt.shield") }
            .padding()

            Form {
                Section("Model Limits") {
                    if let selected = model.availableModels.first(where: { $0.name == model.selectedModelName }) {
                        Text("Effective context limit: \(selected.contextLimit)")
                    } else {
                        Text("Select a model to inspect its context limit.")
                    }
                    Text("Provider: \(model.selectedProvider.displayName)")
                    Text("When nearing the context limit, older messages are compacted into a rolling summary and the recent tail is preserved.")
                }
            }
            .tabItem { Label("Models", systemImage: "cpu") }
            .padding()
        }
        .frame(width: 720, height: 480)
        .task {
            draftGlobalSettings = model.globalSettings
        }
        .onChange(of: model.globalSettings) { _, newValue in
            draftGlobalSettings = newValue
        }
    }
}
