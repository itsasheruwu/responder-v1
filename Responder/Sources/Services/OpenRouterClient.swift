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
        let windowed = MemoryTranscriptWindow.recentMessagesForDerivation(messages, maxCount: 8, maxAge: nil)
        let transcript = windowed.map {
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

    func summarizeRelationship(
        conversation: ConversationRef,
        messages: [ChatMessage],
        existingSummary: String,
        configuration: ProviderConfiguration,
        modelName: String = "openrouter/free"
    ) async throws -> String {
        let windowed = MemoryTranscriptWindow.recentMessagesForDerivation(messages, maxCount: 24, maxAge: nil)
        let transcript = windowed.map {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let renderedText = text.isEmpty ? "[no text]" : text
            return "[\($0.direction.rawValue)] \($0.senderName): \(renderedText)"
        }.joined(separator: "\n")

        let participantLine: String
        if conversation.participants.isEmpty {
            participantLine = conversation.title
        } else {
            participantLine = conversation.participants.map(\.displayName).joined(separator: ", ")
        }

        let prompt = """
        Write a short relationship summary for contact memory in plain English.
        Keep it to 1 or 2 sentences.
        Focus on what relationship the user appears to have with this contact and the communication dynamic that matters for future replies.
        If the relationship is uncertain, say "seems" or "appears" instead of overstating it.
        Do not use bullet points, labels, or JSON.
        Do not mention models, prompts, or internal analysis.

        Conversation title: \(conversation.title)
        Participants: \(participantLine)
        Existing relationship summary: \(existingSummary.isEmpty ? "None" : existingSummary)

        Recent transcript:
        \(transcript.isEmpty ? "No recent transcript." : transcript)
        """

        let request = try makeChatCompletionRequest(
            configuration: configuration,
            modelName: modelName,
            systemPrompt: "Return only a concise relationship summary in plain English.",
            userPrompt: prompt,
            maxTokens: 120,
            requireJSON: false
        )

        let text = try await performChatCompletion(request: request)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Batched OpenAI-style embeddings (`POST /embeddings`). Vectors are ordered to match `texts`.
    func embeddingVectors(for texts: [String], configuration: ProviderConfiguration, modelName: String) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var combined: [[Float]] = []
        combined.reserveCapacity(texts.count)
        let batchSize = 32
        var offset = 0
        while offset < texts.count {
            let end = min(offset + batchSize, texts.count)
            let chunk = Array(texts[offset..<end])
            let batch = try await embeddingBatch(texts: chunk, configuration: configuration, modelName: modelName)
            guard batch.count == chunk.count else {
                throw ResponderError.openRouterUnavailable
            }
            combined.append(contentsOf: batch)
            offset = end
        }
        return combined
    }

    func deriveMemories(
        conversation: ConversationRef,
        messages: [ChatMessage],
        userMemory: UserProfileMemory,
        contactMemory: ContactMemory,
        configuration: ProviderConfiguration,
        modelName: String = "openrouter/free"
    ) async throws -> DerivedMemoryResponse {
        // Caller passes an already windowed transcript; keep order as given (chronological).
        let transcript = messages.map {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let renderedText = text.isEmpty ? "[no text]" : text
            return "[\($0.direction.rawValue)] \($0.senderName): \(renderedText)"
        }.joined(separator: "\n")

        let participantLine: String
        if conversation.participants.isEmpty {
            participantLine = conversation.title
        } else {
            participantLine = conversation.participants.map(\.displayName).joined(separator: ", ")
        }

        let prompt = """
        Update the memory state for a messaging assistant from conversation context.
        Return strict JSON only.

        Rules:
        - Use plain English.
        - Keep summaries concise and factual.
        - Prefer durable patterns over one-off moments.
        - Leave fields empty when there is not enough evidence.
        - Do not invent sensitive facts.
        - Arrays should contain short items, not paragraphs.
        - Keep no more than 6 items per array.

        Conversation title: \(conversation.title)
        Participants: \(participantLine)

        Existing user memory:
        \(serializeUserMemory(userMemory))

        Existing contact memory:
        \(serializeContactMemory(contactMemory))

        Recent transcript:
        \(transcript.isEmpty ? "No recent transcript." : transcript)
        """

        let request = try makeChatCompletionRequest(
            configuration: configuration,
            modelName: modelName,
            systemPrompt: """
            Return JSON with exactly these keys:
            userProfileSummary, userStyleTraits, userBannedPhrases, userBackgroundFacts, userReplyHabits,
            contactRelationshipSummary, contactPreferences, contactRecurringTopics, contactBoundaries, contactNotes.
            """,
            userPrompt: prompt,
            maxTokens: 320,
            requireJSON: true
        )

        let payload = try await performChatCompletion(request: request)
        let jsonText = Self.extractJSONObject(from: payload) ?? payload
        return try decodeDerivedMemoryResponse(from: jsonText, decoder: decoder)
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

    private func embeddingBatch(texts: [String], configuration: ProviderConfiguration, modelName: String) async throws -> [[Float]] {
        var request = try makeRequest(path: "/embeddings", configuration: configuration, method: "POST")
        let body = OpenRouterEmbeddingsRequest(model: modelName, input: texts)
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let payload = try decoder.decode(OpenRouterEmbeddingsResponse.self, from: data)
        guard payload.data.count == texts.count else {
            throw ResponderError.openRouterUnavailable
        }
        if payload.data.allSatisfy({ $0.index != nil }) {
            return payload.data
                .map { (idx: $0.index!, vec: $0.embeddingFloats) }
                .sorted { $0.idx < $1.idx }
                .map(\.vec)
        }
        return payload.data.map(\.embeddingFloats)
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

    private func decodeDerivedMemoryResponse(from text: String, decoder: JSONDecoder) throws -> DerivedMemoryResponse {
        if let direct = try? decoder.decode(DerivedMemoryResponse.self, from: Data(text.utf8)) {
            return direct
        }

        let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8))
        guard var object = decoded as? [String: Any], !object.isEmpty else {
            throw ResponderError.invalidResponse("The memory model did not return valid JSON.")
        }

        let keys = [
            "userProfileSummary",
            "userStyleTraits",
            "userBannedPhrases",
            "userBackgroundFacts",
            "userReplyHabits",
            "contactRelationshipSummary",
            "contactPreferences",
            "contactRecurringTopics",
            "contactBoundaries",
            "contactNotes"
        ]

        for key in keys {
            if object[key] == nil {
                object[key] = key.hasSuffix("Summary") ? "" : []
            } else if let string = object[key] as? String {
                object[key] = key.hasSuffix("Summary") ? string : Self.splitListString(string)
            }
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return try decoder.decode(DerivedMemoryResponse.self, from: data)
    }

    private func serializeUserMemory(_ memory: UserProfileMemory) -> String {
        """
        Profile summary: \(memory.profileSummary.isEmpty ? "None" : memory.profileSummary)
        Style traits: \(memory.styleTraits.isEmpty ? "None" : memory.styleTraits.joined(separator: ", "))
        Banned phrases: \(memory.bannedPhrases.isEmpty ? "None" : memory.bannedPhrases.joined(separator: ", "))
        Background facts: \(memory.backgroundFacts.isEmpty ? "None" : memory.backgroundFacts.joined(separator: ", "))
        Reply habits: \(memory.replyHabits.isEmpty ? "None" : memory.replyHabits.joined(separator: ", "))
        """
    }

    private func serializeContactMemory(_ memory: ContactMemory) -> String {
        """
        Relationship summary: \(memory.relationshipSummary.isEmpty ? "None" : memory.relationshipSummary)
        Preferences: \(memory.preferences.isEmpty ? "None" : memory.preferences.joined(separator: ", "))
        Recurring topics: \(memory.recurringTopics.isEmpty ? "None" : memory.recurringTopics.joined(separator: ", "))
        Boundaries: \(memory.boundaries.isEmpty ? "None" : memory.boundaries.joined(separator: ", "))
        Notes: \(memory.notes.isEmpty ? "None" : memory.notes.joined(separator: ", "))
        """
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

enum EmbeddingVectorMath: Sendable {
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}

struct OpenRouterEmbeddingMemoryRetriever: MemoryRetrieving {
    private let client: OpenRouterClient
    private let configuration: ProviderConfiguration
    private let embeddingModel: String

    init(client: OpenRouterClient, configuration: ProviderConfiguration, embeddingModel: String) {
        self.client = client
        self.configuration = configuration
        self.embeddingModel = embeddingModel
    }

    func rankItems(_ items: [MemoryItem], against recentMessages: [ChatMessage]) async throws -> [MemoryItem] {
        guard !items.isEmpty else { return [] }
        do {
            return try await rankWithEmbeddings(items, recentMessages: recentMessages)
        } catch {
            return try await KeywordOverlapMemoryRetriever().rankItems(items, against: recentMessages)
        }
    }

    private func rankWithEmbeddings(_ items: [MemoryItem], recentMessages: [ChatMessage]) async throws -> [MemoryItem] {
        let window = MemoryTranscriptWindow.recentMessagesForDerivation(
            recentMessages,
            maxCount: MemoryTranscriptWindow.defaultMaxMessageCount,
            maxAge: nil
        )
        let suffix = Array(window.suffix(12))
        let queryText = suffix.map { "\($0.senderName): \($0.text)" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if queryText.isEmpty {
            return try await KeywordOverlapMemoryRetriever().rankItems(items, against: recentMessages)
        }
        let inputs = [queryText] + items.map(\.text)
        let vectors = try await client.embeddingVectors(for: inputs, configuration: configuration, modelName: embeddingModel)
        guard vectors.count == inputs.count, let queryVec = vectors.first, !queryVec.isEmpty else {
            return try await KeywordOverlapMemoryRetriever().rankItems(items, against: recentMessages)
        }
        let itemVectors = Array(vectors.dropFirst())
        guard itemVectors.count == items.count else {
            return try await KeywordOverlapMemoryRetriever().rankItems(items, against: recentMessages)
        }
        let scored = zip(items, itemVectors).map { pair -> (MemoryItem, Float) in
            let sim = pair.1.isEmpty ? Float(0) : EmbeddingVectorMath.cosineSimilarity(queryVec, pair.1)
            return (pair.0, sim)
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.updatedAt != rhs.0.updatedAt { return lhs.0.updatedAt > rhs.0.updatedAt }
            return lhs.0.id.uuidString < rhs.0.id.uuidString
        }.map(\.0)
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

private struct OpenRouterEmbeddingsRequest: Encodable {
    let model: String
    let input: [String]
}

private struct OpenRouterEmbeddingsResponse: Decodable {
    struct Item: Decodable {
        let embedding: [Double]
        let index: Int?

        var embeddingFloats: [Float] {
            embedding.map { Float($0) }
        }
    }

    let data: [Item]
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

struct DerivedMemoryResponse: Decodable, Sendable {
    let userProfileSummary: String
    let userStyleTraits: [String]
    let userBannedPhrases: [String]
    let userBackgroundFacts: [String]
    let userReplyHabits: [String]
    let contactRelationshipSummary: String
    let contactPreferences: [String]
    let contactRecurringTopics: [String]
    let contactBoundaries: [String]
    let contactNotes: [String]
}
