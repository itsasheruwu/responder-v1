import SwiftUI

struct MemoryInspectorView: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MemoryColumnHeader(
                        title: "User Memory",
                        subtitle: "Manual edits stay local and override derived context when both exist. OpenRouter-derived user refinements are stored per contact key and merged here when a conversation is active."
                    )

                    if let syncIssue = model.memorySyncLastError ?? model.userMemoryMetadata?.lastError {
                        Text(syncIssue)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }

                    MemoryCard(title: "Effective Memory", badge: "Merged", tint: .accentColor) {
                        UserMemoryReadOnlyFields(memory: model.userMemory)
                        MemoryItemsQuickActions(
                            items: MemoryItemVisibility.activeItems(model.userMemory.items),
                            model: model
                        )
                    }

                    MemoryCard(title: "Manual Memory", badge: "Manual", tint: .blue) {
                        UserMemoryEditor(memory: $model.manualUserMemory)
                        Button("Save User Memory") {
                            Task { await model.saveUserMemory() }
                        }
                    }

                    MemoryCard(
                        title: "Derived From Context",
                        badge: model.userMemoryMetadata?.source.displayName ?? "Derived",
                        tint: .orange
                    ) {
                        MemoryMetadataView(metadata: model.userMemoryMetadata)
                        UserMemoryReadOnlyFields(memory: model.derivedUserMemory)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 420)
            .background(Color(nsColor: .windowBackgroundColor))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MemoryColumnHeader(
                        title: "Contact Memory",
                        subtitle: "Derived contact memory is refreshed from the active conversation and kept separate from your manual notes."
                    ) {
                        Button(model.isUpdatingMemory ? "Updating Memory…" : "Refresh From Context") {
                            Task { await model.refreshMemoryFromCurrentConversation() }
                        }
                        .disabled(model.isUpdatingMemory || model.selectedConversation == nil)
                    }

                    MemoryCard(title: "Effective Memory", badge: "Merged", tint: .accentColor) {
                        ContactMemoryReadOnlyFields(memory: model.contactMemory)
                        MemoryItemsQuickActions(
                            items: MemoryItemVisibility.activeItems(model.contactMemory.items),
                            model: model
                        )
                    }

                    MemoryCard(title: "Manual Memory", badge: "Manual", tint: .blue) {
                        ContactMemoryEditor(memory: $model.manualContactMemory)
                        Button("Save Contact Memory") {
                            Task { await model.saveContactMemory() }
                        }
                        .disabled(model.selectedConversation == nil)
                    }

                    MemoryCard(
                        title: "Derived From Context",
                        badge: model.contactMemoryMetadata?.source.displayName ?? "Derived",
                        tint: .orange
                    ) {
                        MemoryMetadataView(metadata: model.contactMemoryMetadata)
                        ContactMemoryReadOnlyFields(memory: model.derivedContactMemory)
                    }

                    MemoryCard(title: "Rolling Summary", badge: "Summary", tint: .purple) {
                        TextEditor(text: $model.summary.text)
                            .font(.body)
                            .frame(minHeight: 180)
                            .padding(10)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        Button("Save Summary") {
                            Task { await model.saveSummary() }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 460)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
        }
        .navigationTitle("Memory Inspector")
    }
}

private struct MemoryColumnHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

private struct MemoryCard<Content: View>: View {
    let title: String
    let badge: String
    let tint: Color
    let content: Content

    init(
        title: String,
        badge: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.badge = badge
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.headline)
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.12), in: Capsule())
                Spacer()
            }

            content
        }
        .padding(16)
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

private struct MemoryItemsQuickActions: View {
    let items: [MemoryItem]
    @Bindable var model: AppModel

    var body: some View {
        if items.isEmpty {
            Text("No atomic memory rows (legacy data is shown above).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Items")
                    .font(.subheadline.weight(.medium))
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text.isEmpty ? "—" : item.text)
                                .font(.callout)
                                .textSelection(.enabled)
                            HStack(spacing: 8) {
                                Text(item.kind.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(item.bucket.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(item.source.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if item.pinned {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(.orange)
                                .help("Pinned for prompts")
                        }
                        Menu {
                            Button("Pin") {
                                Task { await model.pinMemoryItem(id: item.id, pinned: true) }
                            }
                            Button("Unpin") {
                                Task { await model.pinMemoryItem(id: item.id, pinned: false) }
                            }
                            Button("Wrong / forget (block re-add)", role: .destructive) {
                                Task { await model.forgetMemoryItem(id: item.id) }
                            }
                            Button("Delete…", role: .destructive) {
                                Task { await model.deleteMemoryItem(id: item.id) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .accessibilityLabel("Item actions")
                        }
                        .menuStyle(.borderlessButton)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

private struct MemoryMetadataView: View {
    let metadata: MemorySyncMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(metadata?.source.displayName ?? "Not synced yet", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let syncedAt = metadata?.syncedAt {
                    Text("Last sync \(syncedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let err = metadata?.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct UserMemoryEditor: View {
    @Binding var memory: UserProfileMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MemoryTextArea(title: "Profile Summary", text: $memory.profileSummary)
            MemoryCommaListEditor(title: "Style Traits", values: Binding(
                get: { memory.styleTraits },
                set: { memory.styleTraits = $0 }
            ))
            MemoryCommaListEditor(title: "Banned Phrases", values: Binding(
                get: { memory.bannedPhrases },
                set: { memory.bannedPhrases = $0 }
            ))
            MemoryCommaListEditor(title: "Background Facts", values: Binding(
                get: { memory.backgroundFacts },
                set: { memory.backgroundFacts = $0 }
            ))
            MemoryCommaListEditor(title: "Reply Habits", values: Binding(
                get: { memory.replyHabits },
                set: { memory.replyHabits = $0 }
            ))
        }
    }
}

private struct ContactMemoryEditor: View {
    @Binding var memory: ContactMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MemoryTextArea(title: "Relationship Summary", text: $memory.relationshipSummary)
            MemoryCommaListEditor(title: "Preferences", values: Binding(
                get: { memory.preferences },
                set: { memory.preferences = $0 }
            ))
            MemoryCommaListEditor(title: "Recurring Topics", values: Binding(
                get: { memory.recurringTopics },
                set: { memory.recurringTopics = $0 }
            ))
            MemoryCommaListEditor(title: "Boundaries", values: Binding(
                get: { memory.boundaries },
                set: { memory.boundaries = $0 }
            ))
            MemoryCommaListEditor(title: "Notes", values: Binding(
                get: { memory.notes },
                set: { memory.notes = $0 }
            ))
        }
    }
}

private struct UserMemoryReadOnlyFields: View {
    let memory: UserProfileMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReadOnlyMemoryField(title: "Profile Summary", value: memory.profileSummary)
            ReadOnlyMemoryField(title: "Style Traits", values: memory.styleTraits)
            ReadOnlyMemoryField(title: "Banned Phrases", values: memory.bannedPhrases)
            ReadOnlyMemoryField(title: "Background Facts", values: memory.backgroundFacts)
            ReadOnlyMemoryField(title: "Reply Habits", values: memory.replyHabits)
        }
    }
}

private struct ContactMemoryReadOnlyFields: View {
    let memory: ContactMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReadOnlyMemoryField(title: "Relationship Summary", value: memory.relationshipSummary)
            ReadOnlyMemoryField(title: "Preferences", values: memory.preferences)
            ReadOnlyMemoryField(title: "Recurring Topics", values: memory.recurringTopics)
            ReadOnlyMemoryField(title: "Boundaries", values: memory.boundaries)
            ReadOnlyMemoryField(title: "Notes", values: memory.notes)
        }
    }
}

private struct MemoryTextArea: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            TextField(title, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct MemoryCommaListEditor: View {
    let title: String
    @Binding var values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            TextField(title, text: Binding(
                get: { values.joined(separator: ", ") },
                set: { values = Self.parse($0) }
            ))
            .textFieldStyle(.plain)
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private static func parse(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct ReadOnlyMemoryField: View {
    let title: String
    let value: String
    let values: [String]

    init(title: String, value: String) {
        self.title = title
        self.value = value
        self.values = []
    }

    init(title: String, values: [String]) {
        self.title = title
        self.value = ""
        self.values = values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))

            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            } else if !values.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(values, id: \.self) { entry in
                        Text(entry)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
            } else {
                Text("None yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var cursor = CGPoint.zero
        var lineHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x + size.width > maxWidth, cursor.x > 0 {
                measuredWidth = max(measuredWidth, cursor.x - spacing)
                cursor.x = 0
                cursor.y += lineHeight + spacing
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            cursor.x += size.width + spacing
        }

        measuredWidth = max(measuredWidth, max(0, cursor.x - spacing))
        return CGSize(width: measuredWidth, height: cursor.y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var cursor = CGPoint(x: bounds.minX, y: bounds.minY)
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x + size.width > bounds.maxX, cursor.x > bounds.minX {
                cursor.x = bounds.minX
                cursor.y += lineHeight + spacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: cursor.x, y: cursor.y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            cursor.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
