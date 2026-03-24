import SwiftUI

struct MemoryInspectorView: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            Form {
                Section("User Profile Memory") {
                    TextField("Profile summary", text: $model.userMemory.profileSummary, axis: .vertical)
                    TextField("Style traits", text: Binding(
                        get: { model.userMemory.styleTraits.joined(separator: ", ") },
                        set: { model.userMemory.styleTraits = Self.parse($0) }
                    ))
                    TextField("Banned phrases", text: Binding(
                        get: { model.userMemory.bannedPhrases.joined(separator: ", ") },
                        set: { model.userMemory.bannedPhrases = Self.parse($0) }
                    ))
                    TextField("Background facts", text: Binding(
                        get: { model.userMemory.backgroundFacts.joined(separator: ", ") },
                        set: { model.userMemory.backgroundFacts = Self.parse($0) }
                    ))
                    TextField("Reply habits", text: Binding(
                        get: { model.userMemory.replyHabits.joined(separator: ", ") },
                        set: { model.userMemory.replyHabits = Self.parse($0) }
                    ))

                    Button("Save User Memory") {
                        Task { await model.saveUserMemory() }
                    }
                }
            }
            .frame(minWidth: 320)

            Form {
                Section("Selected Contact Memory") {
                    TextField("Relationship summary", text: $model.contactMemory.relationshipSummary, axis: .vertical)
                    TextField("Preferences", text: Binding(
                        get: { model.contactMemory.preferences.joined(separator: ", ") },
                        set: { model.contactMemory.preferences = Self.parse($0) }
                    ))
                    TextField("Recurring topics", text: Binding(
                        get: { model.contactMemory.recurringTopics.joined(separator: ", ") },
                        set: { model.contactMemory.recurringTopics = Self.parse($0) }
                    ))
                    TextField("Boundaries", text: Binding(
                        get: { model.contactMemory.boundaries.joined(separator: ", ") },
                        set: { model.contactMemory.boundaries = Self.parse($0) }
                    ))
                    TextField("Notes", text: Binding(
                        get: { model.contactMemory.notes.joined(separator: ", ") },
                        set: { model.contactMemory.notes = Self.parse($0) }
                    ))

                    Button("Save Contact Memory") {
                        Task { await model.saveContactMemory() }
                    }
                }

                Section("Rolling Summary") {
                    TextEditor(text: $model.summary.text)
                        .frame(minHeight: 180)
                    Button("Save Summary") {
                        Task { await model.saveSummary() }
                    }
                }
            }
            .frame(minWidth: 360)
        }
        .padding()
        .navigationTitle("Memory Inspector")
    }

    private static func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
