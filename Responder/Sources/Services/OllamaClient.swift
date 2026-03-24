import Foundation

actor OllamaClient: OllamaClientProtocol {
    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    func listModels() async throws -> [OllamaModelInfo] {
        let request = URLRequest(url: baseURL.appending(path: "/api/tags"))
        let (data, response) = try await session.data(for: request)
        try validate(response: response)

        let payload = try decoder.decode(TagsResponse.self, from: data)
        return payload.models.map {
            OllamaModelInfo(
                name: $0.name,
                digest: $0.digest,
                sizeBytes: $0.size,
                modifiedAt: $0.modifiedAt,
                contextLimit: 4096
            )
        }.sorted { $0.name < $1.name }
    }

    func modelDetails(for modelName: String) async throws -> OllamaModelInfo {
        var request = URLRequest(url: baseURL.appending(path: "/api/show"))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(["model": modelName])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        try validate(response: response)

        let payload = try decoder.decode(ModelShowResponse.self, from: data)
        let parsedContext = Self.parseContextLimit(from: payload.parameters) ?? Self.parseContextLimit(from: payload.template) ?? 4096

        return OllamaModelInfo(
            name: payload.model,
            digest: payload.digest,
            sizeBytes: nil,
            modifiedAt: nil,
            contextLimit: parsedContext
        )
    }

    func generateReplyJSON(modelName: String, prompt: PromptPacket) async throws -> ReplyDraft {
        var request = URLRequest(url: baseURL.appending(path: "/api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = GenerateRequest(
            model: modelName,
            system: prompt.systemInstructions,
            prompt: prompt.layers.map { "## \($0.title)\n\($0.content)" }.joined(separator: "\n\n"),
            stream: false,
            format: "json",
            options: GenerateOptions(numPredict: max(64, prompt.contextUsage.reservedOutputTokens))
        )
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try validate(response: response)

        let payload = try decoder.decode(GenerateResponse.self, from: data)
        let jsonText = Self.extractJSONObject(from: payload.response) ?? payload.response
        let draftPayload: ModelDraftResponse
        do {
            draftPayload = try Self.decodeDraftResponse(from: jsonText, decoder: decoder)
        } catch {
            let snippet = Self.compactSnippet(from: payload.response)
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

    func summarize(modelName: String, conversation: ConversationRef, transcript: String, existingSummary: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "/api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = """
        Summarize the older portion of this conversation for future reply drafting.
        Keep it factual, short, and useful for iMessage tone continuity.
        Existing summary:
        \(existingSummary.isEmpty ? "None" : existingSummary)

        Transcript:
        \(transcript)
        """

        request.httpBody = try encoder.encode(GenerateRequest(
            model: modelName,
            system: "Return a concise plain-text rolling summary only.",
            prompt: prompt,
            stream: false,
            format: nil,
            options: GenerateOptions(numPredict: 220)
        ))

        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let payload = try decoder.decode(GenerateResponse.self, from: data)
        return payload.response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func classifyRisk(modelName: String, conversation: ConversationRef, messages: [ChatMessage], draft: ReplyDraft) async throws -> PolicyDecision? {
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

        var request = URLRequest(url: baseURL.appending(path: "/api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(GenerateRequest(
            model: modelName,
            system: "You are a conservative safety classifier for local message autonomy.",
            prompt: prompt,
            stream: false,
            format: "json",
            options: GenerateOptions(numPredict: 120)
        ))

        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let payload = try decoder.decode(GenerateResponse.self, from: data)
        let jsonText = Self.extractJSONObject(from: payload.response) ?? payload.response
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

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ResponderError.ollamaUnavailable
        }
    }

    private static func parseContextLimit(from text: String?) -> Int? {
        guard let text else { return nil }
        let pattern = #"num_ctx\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[valueRange])
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return nil
        }
        return String(text[start...end])
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

private struct TagsResponse: Decodable {
    struct TagModel: Decodable {
        let name: String
        let digest: String?
        let size: Int64?
        let modifiedAt: Date?

        enum CodingKeys: String, CodingKey {
            case name
            case digest
            case size
            case modifiedAt = "modified_at"
        }
    }

    let models: [TagModel]
}

private struct ModelShowResponse: Decodable {
    let model: String
    let digest: String?
    let parameters: String?
    let template: String?
}

private struct GenerateRequest: Encodable {
    let model: String
    let system: String?
    let prompt: String
    let stream: Bool
    let format: String?
    let options: GenerateOptions
}

private struct GenerateOptions: Encodable {
    let numPredict: Int

    enum CodingKeys: String, CodingKey {
        case numPredict = "num_predict"
    }
}

private struct GenerateResponse: Decodable {
    let response: String
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
