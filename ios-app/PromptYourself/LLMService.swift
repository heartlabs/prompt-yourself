import Foundation

/// Errors that can occur during LLM API calls.
enum LLMError: LocalizedError {
    case invalidURL
    case noAPIKey
    case httpError(Int)
    case decodingError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL configured."
        case .noAPIKey:
            return "No API key found."
        case .httpError(let code):
            return "Server error (HTTP \(code)). Check your API key and base URL."
        case .decodingError(let detail):
            return "Failed to parse response: \(detail)"
        case .networkError(let detail):
            return "Network error: \(detail)"
        }
    }
}

/// Configuration for an OpenAI-compatible chat completion service.
struct LLMConfiguration {
    let apiKey: String
    let baseURL: String  // e.g. "https://api.deepseek.com"
    let model: String
    /// Human-readable diagnostics — where the config came from.
    let source: String

    static let deepseekDefault = LLMConfiguration(
        apiKey: "",
        baseURL: "https://api.deepseek.com",
        model: "deepseek-chat",
        source: "hardcoded default"
    )

    /// Reads configuration from the bundled `llm-config.plist` resource file.
    ///
    /// The plist is gitignored — copy `llm-config.plist.template` and fill in your API key.
    static func fromPlist() -> LLMConfiguration {
        guard let url = Bundle.main.url(forResource: "llm-config", withExtension: "plist") else {
            return LLMConfiguration(
                apiKey: "",
                baseURL: "https://api.deepseek.com",
                model: "deepseek-chat",
                source: "plist NOT FOUND in bundle"
            )
        }

        guard let data = try? Data(contentsOf: url) else {
            return LLMConfiguration(
                apiKey: "",
                baseURL: "https://api.deepseek.com",
                model: "deepseek-chat",
                source: "plist found but unreadable: \(url.path)"
            )
        }

        guard let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return LLMConfiguration(
                apiKey: "",
                baseURL: "https://api.deepseek.com",
                model: "deepseek-chat",
                source: "plist found but not a valid dict"
            )
        }

        return LLMConfiguration(
            apiKey: (dict["LLMApiKey"] as? String) ?? "",
            baseURL: (dict["LLMBaseURL"] as? String) ?? "https://api.deepseek.com",
            model: (dict["LLMModel"] as? String) ?? "deepseek-chat",
            source: "llm-config.plist"
        )
    }

    var diagnostics: String {
        let keyPreview = apiKey.isEmpty ? "(empty)" : "\(apiKey.prefix(8))..."
        return "[src:\(source) | url:\(baseURL) | model:\(model) | key:\(keyPreview)]"
    }
}

/// An OpenAI-compatible chat completion service.
///
/// Configure via `LLMConfiguration`:
/// ```swift
/// let service = LLMService(configuration: LLMConfiguration.fromPlist())
/// ```
final class LLMService {
    private let session: URLSession
    /// The configuration in use — exposed for diagnostics.
    let configuration: LLMConfiguration

    // MARK: - Init

    init(configuration: LLMConfiguration = .fromPlist(),
         session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: - Public API

    /// Sends a conversation history (including system prompt) to the LLM
    /// and returns the assistant's response text.
    func sendMessages(_ messages: ChatHistory) async throws -> String {
        guard !configuration.apiKey.isEmpty else {
            throw LLMError.noAPIKey
        }

        let urlString = "\(configuration.baseURL)/chat/completions"

        guard let url = URL(string: urlString) else {
            throw LLMError.invalidURL
        }

        print("[LLMService] \(configuration.diagnostics) → GET \(url.absoluteString)")

        // Build the request body per the OpenAI spec.
        let payload: [String: Any] = [
            "model": configuration.model,
            "messages": messages.map { msg in
                [
                    "role": msg.role.rawValue,
                    "content": msg.content,
                ]
            },
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 60

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError("Invalid response")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw LLMError.httpError(httpResponse.statusCode)
        }

        return try parseResponse(data)
    }

    // MARK: - Response Parsing

    /// Parses the standard OpenAI-compatible response body.
    /// Expected shape:
    /// ```json
    /// {
    ///   "choices": [{
    ///     "message": { "role": "assistant", "content": "..." }
    ///   }]
    /// }
    /// ```
    private func parseResponse(_ data: Data) throws -> String {
        struct ResponseBody: Decodable {
            let choices: [Choice]
        }
        struct Choice: Decodable {
            let message: Message
        }
        struct Message: Decodable {
            let content: String?
        }

        do {
            let body = try JSONDecoder().decode(ResponseBody.self, from: data)
            guard let content = body.choices.first?.message.content else {
                throw LLMError.decodingError("No content in response")
            }
            return content
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.decodingError(error.localizedDescription)
        }
    }
}
