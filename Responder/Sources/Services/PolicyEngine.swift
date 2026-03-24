import Foundation

actor PolicyEngine: PolicyEvaluating {
    private let ollama: any OllamaClientProtocol
    private let database: AppDatabase
    private let calendar: Calendar

    init(ollama: any OllamaClientProtocol, database: AppDatabase, calendar: Calendar = .current) {
        self.ollama = ollama
        self.database = database
        self.calendar = calendar
    }

    func evaluate(
        mode: ReplyOperationMode,
        conversation: ConversationRef,
        messages: [ChatMessage],
        draft: ReplyDraft,
        config: AutonomyContactConfig,
        globalSettings: GlobalAutonomySettings
    ) async throws -> PolicyDecision {
        var reasons: [String] = []
        var riskFlags = Set(draft.riskFlags)
        var action: PolicyAction = .allow

        if globalSettings.emergencyStopEnabled && mode == .autonomousSend {
            return PolicyDecision(action: .block, confidence: 1, reasons: ["Emergency stop is enabled."], riskFlags: ["emergency_stop"])
        }

        if conversation.isGroup && mode == .autonomousSend {
            return PolicyDecision(action: .block, confidence: 1, reasons: ["Group conversations are blocked for auto-send in v1."], riskFlags: ["group_chat"])
        }

        if messages.contains(where: { $0.containsAttachmentPlaceholder || $0.isUnsupportedContent }), mode == .autonomousSend {
            return PolicyDecision(action: .block, confidence: 1, reasons: ["Attachment or unsupported-content threads require manual review."], riskFlags: ["attachment_thread"])
        }

        let latestIncoming = messages.last(where: { $0.direction == .incoming })?.text.lowercased() ?? ""
        let combined = (latestIncoming + "\n" + draft.text.lowercased())

        let hardBlockPatterns = [
            ("money", ["venmo", "zelle", "$", "wire", "pay me", "invoice"]),
            ("medical", ["doctor", "hospital", "prescription", "symptom"]),
            ("legal", ["lawyer", "contract", "sue", "legal"]),
            ("safety", ["emergency", "unsafe", "dangerous"]),
            ("conflict", ["hate", "furious", "angry", "fight"]),
            ("scheduling", ["reschedule", "move to", "tomorrow at", "calendar"])
        ]

        for (flag, patterns) in hardBlockPatterns where patterns.contains(where: combined.contains) && mode == .autonomousSend {
            riskFlags.insert(flag)
            reasons.append("Detected \(flag)-sensitive content.")
            action = .block
        }

        if latestIncoming.contains("?"), mode == .autonomousSend {
            riskFlags.insert("ambiguous_question")
            reasons.append("Incoming question may need manual judgment.")
            action = max(action, .draftOnly)
        }

        if isWithinQuietHours(config: config), mode == .autonomousSend {
            riskFlags.insert("quiet_hours")
            reasons.append("Quiet hours are active.")
            action = max(action, .draftOnly)
        }

        if mode == .autonomousSend {
            if draft.confidence < config.confidenceThreshold {
                riskFlags.insert("confidence_low")
                reasons.append("Model confidence is below the contact threshold.")
                action = max(action, .draftOnly)
            }

            if config.requiresCompletedSimulation, config.lastSimulationPassedAt == nil {
                riskFlags.insert("simulation_required")
                reasons.append("Simulation must pass before enabling real auto-send.")
                action = max(action, .draftOnly)
            }

            let recentInterval = Date().addingTimeInterval(TimeInterval(-config.minimumMinutesBetweenSends * 60))
            if try await database.countAutoSends(conversationID: conversation.id, since: recentInterval) > 0 {
                riskFlags.insert("rate_limit_interval")
                reasons.append("Minimum interval between auto-sends has not elapsed.")
                action = max(action, .draftOnly)
            }

            let dayStart = calendar.startOfDay(for: .now)
            if try await database.countAutoSends(conversationID: conversation.id, since: dayStart) >= config.dailySendLimit {
                riskFlags.insert("daily_limit")
                reasons.append("Daily auto-send limit reached.")
                action = max(action, .draftOnly)
            }
        }

        if action != .block,
           let modelDecision = try? await ollama.classifyRisk(modelName: draft.modelName, conversation: conversation, messages: messages, draft: draft) {
            riskFlags.formUnion(modelDecision.riskFlags)
            reasons.append(contentsOf: modelDecision.reasons)
            action = max(action, modelDecision.action)
        }

        return PolicyDecision(
            action: action,
            confidence: draft.confidence,
            reasons: Array(Set(reasons)),
            riskFlags: Array(riskFlags).sorted()
        )
    }

    private func isWithinQuietHours(config: AutonomyContactConfig) -> Bool {
        let hour = calendar.component(.hour, from: .now)
        if config.quietHoursStartHour < config.quietHoursEndHour {
            return (config.quietHoursStartHour..<config.quietHoursEndHour).contains(hour)
        }
        return hour >= config.quietHoursStartHour || hour < config.quietHoursEndHour
    }
}

private func max(_ lhs: PolicyAction, _ rhs: PolicyAction) -> PolicyAction {
    let order: [PolicyAction] = [.allow, .draftOnly, .block]
    return order.firstIndex(of: lhs)! >= order.firstIndex(of: rhs)! ? lhs : rhs
}
