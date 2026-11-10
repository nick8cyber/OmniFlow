import Foundation

/// Fetches `GET {baseURL}/models` from the provider's OpenAI-compatible
/// endpoint so settings dropdowns can offer the provider's real catalog
/// instead of only the hardcoded list. Failures resolve to an empty list —
/// dropdowns then show their predefined entries.
enum ModelListService {
    private struct ModelsResponse: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    /// Model families a `/models` catalog may list that cannot serve
    /// `chat/completions` (embeddings, image/audio generation, transcribe).
    private static let nonLLMMarkers = [
        "embed", "aqa", "imagen", "image", "tts", "transcribe", "veo", "lyria", "robotics",
    ]

    static func fetchLLMModels(baseURL: String, apiKey: String) async -> [String] {
        let ids = await fetchModelIDs(baseURL: baseURL, apiKey: apiKey)
        return filterLLMModels(ids)
    }

    /// `GET {baseURL}/models` → model ids in catalog order, deduplicated.
    static func fetchModelIDs(baseURL: String, apiKey: String) async -> [String] {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return []
        }
        var path = components.path
        if path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        components.path = path + "/models"
        guard let url = components.url else {
            return []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await LLMAPITransport.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return []
        }
        return decodeModelIDs(data)
    }

    static func decodeModelIDs(_ data: Data) -> [String] {
        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return decoded.data.map(\.id)
            .map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
            .filter { seen.insert($0).inserted }
    }

    static func filterLLMModels(_ ids: [String]) -> [String] {
        ids.filter { id in
            let lowered = id.lowercased()
            return !nonLLMMarkers.contains { lowered.contains($0) }
        }
    }
}
