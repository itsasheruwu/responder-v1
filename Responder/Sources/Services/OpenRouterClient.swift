import Foundation

actor OpenRouterClient {
    static let builtInModels: [OllamaModelInfo] = [
        OllamaModelInfo(
            name: "openrouter/free",
            digest: nil,
            sizeBytes: nil,
            modifiedAt: nil,
            contextLimit: 200_000
        ),
        OllamaModelInfo(
            name: "nvidia/nemotron-3-super-120b-a12b:free",
            digest: nil,
            sizeBytes: nil,
            modifiedAt: nil,
            contextLimit: 262_144
        )
    ]

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
        decoder.dateDecodingStrategy = .secondsSince1970
        encoder.dateEncodingStrategy = .iso8601
    }

    func listModels(configuration: ProviderConfiguration) async throws -> [OllamaModelInfo] {
        let request = try makeRequest(path: "/models", configuration: configuration, method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)

        let payload = try decoder.decode(OpenRouterModelsResponse.self, from: data)
        var models = payload.data.map { item in
            OllamaModelInfo(
                name: item.id,
                digest: nil,
                sizeBytes: nil,
                modifiedAt: item.createdAt.map(Date.init(timeIntervalSince1970:)),
                contextLimit: item.contextLength ?? item.topProvider?.contextLength ?? 32_768
            )
        }
        for builtInModel in Self.builtInModels where !models.contains(where: { $0.name == builtInModel.name }) {
            models.append(builtInModel)
        }
        return models.sorted { lhs, rhs in
            let leftBuiltInIndex = Self.builtInModels.firstIndex(where: { $0.name == lhs.name })
            let rightBuiltInIndex = Self.builtInModels.firstIndex(where: { $0.name == rhs.name })
            if let leftBuiltInIndex, let rightBuiltInIndex {
                return leftBuiltInIndex < rightBuiltInIndex
            }
            if leftBuiltInIndex != nil { return true }
            if rightBuiltInIndex != nil { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func modelDetails(for modelName: String, configuration: ProviderConfiguration) async throws -> OllamaModelInfo {
        if let builtInModel = Self.builtInModels.first(where: { $0.name == modelName }) {
            return builtInModel
        }
        let models = try await listModels(configuration: configuration)
        return models.first(where: { $0.name == modelName }) ?? OllamaModelInfo(
            name: modelName,
            digest: nil,
            sizeBytes: nil,
            modifiedAt: nil,
            contextLimit: 32_768
        )
    }

    func generateReplyJSON(modelName: String, prompt: PromptPacket, configuration: ProviderConfiguration) async throws -> ReplyDraft {
        let request = try makeChatCompletionRequest(
            configuration: configuration,
            modelName: modelName,
            systemPrompt: prompt.systemInstructions,
            userPrompt: prompt.layers.map { "## \($0.title)\n\($0.content)" }.joined(separator: "\n\n"),
            maxTokens: max(64, prompt.contextUsage.reservedOutputTokens),
            requireJSON: true
        )

        let payload = try await performChatCompletion(request: request)
        let jsonText = Self.extractJSONObject(from: payload) ?? payload
        let draftPayload: ModelDraftResponse
        do {
            draftPayload = try Self.decodeDraftResponse(from: jsonText, decoder: decoder)
        } catch {
            let snippet = Self.compactSnippet(from: payload)
            throw ResponderError.invalidResponse("Raw output: \(snippet)")
        }

        return ReplyDraft(
            id: UUID(),
            conversationID: "",
            text: draftPayload.draft.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: draftPayload.confidence,
            intent: draftPayload.intent,
            riskFlags: draftPayload.riskFlags,
            memoryCandidates: draftPayload.memoryCandidates,
            createdAt: .now,
            modelName: modelName
        )
    }

    func summarize(
        modelName: String,
        conversation: ConversationRef,
        transcript: String,
        existingSummary: String,
        configuration: ProviderConfiguration
    ) async throws -> String {
        let prompt = """
        Summarize the older portion of this conversation for future reply drafting.
        Keep it factual, short, and useful for iMessage tone continuity.
        Existing summary:
        \(existingSummary.isEmpty ? "None" : existingSummary)

        Transcript:
        \(transcript)
        """

        let request = try makeChatCompletionRequest(
            configuration: configuration,
            modelName: modelName,
            systemPrompt: "Return a concise plain-text rolling summary only.",
            userPrompt: prompt,
            maxTokens: 220,
            requireJSON: false
        )

        let text = try await performChatCompletion(request: request)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func classifyRisk(
        modelName: String,
        conversation: ConversationRef,
        messages: [ChatMessage],
        draft: ReplyDraft,
        configuration: ProviderConfiguration
    ) async throws -> PolicyDecision? {
        let transcript = messages.suffix(8).map {
            "[\($0.direction.rawValue)] \($0.senderName): \($0.text)"
        }.joined(separator: "\n")

        let prompt = """
        Review this reply candidate for auto-send safety.
        Return strict JSON with keys: action, confidence, reasons, riskFlags.

        Conversation: \(conversation.title)
        Recent messages:
        \(transcript)

        Draft:
        \(draft.text)
        """

        let request = try makeChatCompletionRequest(
            configuration: configuration,
            modelName: modelName,
            systemPrompt: "You are a conservative safety classifier for local message autonomy.",
            userPrompt: prompt,
            maxTokens: 120,
            requireJSON: true
        )

        let payload = try await performChatCompletion(request: request)
        let jsonText = Self.extractJSONObject(from: payload) ?? payload
        guard let value = try? decoder.decode(ModelPolicyResponse.self, from: Data(jsonText.utf8)) else {
            return nil
        }

        return PolicyDecision(
            action: PolicyAction(rawValue: value.action) ?? .draftOnly,
            confidence: value.confidence,
            reasons: value.reasons,
            riskFlags: value.riskFlags
        )
    }

    private func makeRequest(path: String, configuration: ProviderConfiguration, method: String) throws -> URLRequest {
        guard !configuration.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResponderError.openRouterMissingAPIKey
        }
        guard let baseURL = URL(string: configuration.openRouterBaseURL) else {
            throw ResponderError.openRouterUnavailable
        }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(configuration.openRouterAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Responder", forHTTPHeaderField: "X-OpenRouter-Title")
        return request
    }

    private func makeChatCompletionRequest(
        configuration: ProviderConfiguration,
        modelName: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        requireJSON: Bool
    ) throws -> URLRequest {
        var request = try makeRequest(path: "/chat/completions", configuration: configuration, method: "POST")
        let body = OpenRouterChatCompletionRequest(
            model: modelName,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            responseFormat: requireJSON ? .jsonObject : nil,
            maxTokens: maxTokens
        )
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func performChatCompletion(request: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let payload = try decoder.decode(OpenRouterChatCompletionResponse.self, from: data)
        guard let content = payload.choices.first?.message.flattenedContent, !content.isEmpty else {
            throw ResponderError.openRouterUnavailable
        }
        return content
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ResponderError.openRouterUnavailable
        }
    }

    private static func decodeDraftResponse(from text: String, decoder: JSONDecoder) throws -> ModelDraftResponse {
        if let direct = try? decoder.decode(ModelDraftResponse.self, from: Data(text.utf8)) {
            return direct
        }

        let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8))
        guard var object = decoded as? [String: Any], !object.isEmpty else {
            throw ResponderError.invalidResponse("The model did not return valid JSON.")
        }

        if object["riskFlags"] == nil { object["riskFlags"] = [] }
        if object["memoryCandidates"] == nil { object["memoryCandidates"] = ["user": [], "contact": []] }

        if let riskFlags = object["riskFlags"] as? String {
            object["riskFlags"] = splitListString(riskFlags)
        }

        if let memoryList = object["memoryCandidates"] as? [String] {
            object["memoryCandidates"] = normalizeFlatMemoryCandidates(memoryList)
        } else if let memoryString = object["memoryCandidates"] as? String {
            object["memoryCandidates"] = normalizeFlatMemoryCandidates(splitListString(memoryString))
        } else if let memoryArray = object["memoryCandidates"] as? [Any] {
            let normalizedItems = memoryArray.compactMap { value -> String? in
                if let string = value as? String {
                    return string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let dictionary = value as? [String: Any],
                   let text = dictionary["text"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil
            }.filter { !$0.isEmpty }
            object["memoryCandidates"] = normalizeFlatMemoryCandidates(normalizedItems)
        }

        if var memory = object["memoryCandidates"] as? [String: Any] {
            if let user = memory["user"] as? String { memory["user"] = splitListString(user) }
            if let contact = memory["contact"] as? String { memory["contact"] = splitListString(contact) }
            if memory["user"] == nil { memory["user"] = [] }
            if memory["contact"] == nil { memory["contact"] = [] }
            object["memoryCandidates"] = memory
        }

        if let confidence = object["confidence"] as? String, let value = Double(confidence) {
            object["confidence"] = value
        }

        let normalized = try JSONSerialization.data(withJSONObject: object, options: [])
        return try decoder.decode(ModelDraftResponse.self, from: normalized)
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return nil
        }
        return String(text[start...end])
    }

    private static func splitListString(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeFlatMemoryCandidates(_ values: [String]) -> [String: [String]] {
        [
            "user": [],
            "contact": values.filter { !$0.isEmpty }
        ]
    }

    private static func compactSnippet(from text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(220)
            .description
    }
}

private struct OpenRouterModelsResponse: Decodable {
    let data: [OpenRouterModel]
}

private struct OpenRouterModel: Decodable {
    struct TopProvider: Decodable {
        let contextLength: Int?

        enum CodingKeys: String, CodingKey {
            case contextLength = "context_length"
        }
    }

    let id: String
    let createdAt: TimeInterval?
    let contextLength: Int?
    let topProvider: TopProvider?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created"
        case contextLength = "context_length"
        case topProvider = "top_provider"
    }
}

private struct OpenRouterChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String

        static let jsonObject = ResponseFormat(type: "json_object")
    }

    let model: String
    let messages: [Message]
    let responseFormat: ResponseFormat?
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
    }
}

private struct OpenRouterChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            struct ContentPart: Decodable {
                let type: String?
                let text: String?
            }

            let contentString: String?
            let contentParts: [ContentPart]?

            var flattenedContent: String? {
                if let contentString, !contentString.isEmpty {
                    return contentString
                }
                let joined = contentParts?
                    .compactMap(\.text)
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return joined?.isEmpty == false ? joined : nil
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let string = try? container.decode(String.self, forKey: .content) {
                    contentString = string
                    contentParts = nil
                } else if let parts = try? container.decode([ContentPart].self, forKey: .content) {
                    contentString = nil
                    contentParts = parts
                } else {
                    contentString = nil
                    contentParts = nil
                }
            }

            private enum CodingKeys: String, CodingKey {
                case content
            }
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct ModelDraftResponse: Decodable {
    let draft: String
    let confidence: Double
    let intent: String
    let riskFlags: [String]
    let memoryCandidates: MemoryCandidates
}

private struct ModelPolicyResponse: Decodable {
    let action: String
    let confidence: Double
    let reasons: [String]
    let riskFlags: [String]
}
