import Foundation

// MARK: - LLM Tool Types

/// A tool that the LLM can request to call.
struct LLMTool {
    let name: String
    let description: String
    /// JSON Schema describing the parameters.
    let parameters: [String: Any]

    init(name: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// Converts this tool to a dictionary suitable for the OpenAI-compatible API payload.
    func toDictionary() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ],
        ]
    }
}

/// The response from the LLM, which may be text or a request to call tools.
enum LLMResponse {
    /// The model generated a text response.
    case text(String)
    /// The model requested one or more tool calls.
    case toolCalls(toolCalls: [ToolCallPayload])
}

// MARK: - Errors

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

// MARK: - Configuration

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

// MARK: - LLMService

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

    init(configuration: LLMConfiguration = .cheap,
         session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: - Public API

    /// Sends a conversation history (including system prompt) to the LLM
    /// and returns the response, which may be text or a tool call request.
    ///
    /// - Parameters:
    ///   - messages: The full conversation history including system prompt.
    ///   - tools: Optional tool definitions the LLM may use.
    ///   - jsonMode: When `true`, requests an OpenAI-compatible JSON object
    ///     response (`response_format: {"type": "json_object"}`). Supported by
    ///     DeepSeek and most OpenAI-compatible providers. Callers should still
    ///     parse defensively, since not every provider honors it.
    /// - Returns: An `LLMResponse` — either `.text(String)` or `.toolCalls([ToolCallPayload])`.
    func sendMessages(_ messages: ChatHistory, tools: [LLMTool]? = nil, jsonMode: Bool = false) async throws -> LLMResponse {
        guard !configuration.apiKey.isEmpty else {
            throw LLMError.noAPIKey
        }

        let urlString = "\(configuration.baseURL)/chat/completions"

        guard let url = URL(string: urlString) else {
            throw LLMError.invalidURL
        }

        print("[LLMService] \(configuration.diagnostics) → GET \(url.absoluteString)")

        // Build the request body per the OpenAI spec.
        var payload: [String: Any] = [
            "model": configuration.model,
            "messages": messages.map(encodeMessage),
        ]

        if let tools, !tools.isEmpty {
            payload["tools"] = tools.map { $0.toDictionary() }
        }

        if jsonMode {
            payload["response_format"] = ["type": "json_object"]
        }

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

    // MARK: - Message Encoding

    /// Encodes a single `ChatMessage` into a JSON-compatible dictionary for the API payload.
    ///
    /// Different roles produce different shapes:
    /// - `.system`, `.user`: `{"role": "...", "content": "..."}`
    /// - `.assistant` with tool calls: `{"role": "assistant", "content": null, "tool_calls": [...]}`
    /// - `.assistant` without: `{"role": "assistant", "content": "..."}`
    /// - `.tool`: `{"role": "tool", "content": "...", "tool_call_id": "..."}`
    private func encodeMessage(_ msg: ChatMessage) -> [String: Any] {
        var dict: [String: Any] = ["role": msg.role.rawValue]

        switch msg.role {
        case .tool:
            dict["content"] = msg.content
            if let toolCallId = msg.toolCallId {
                dict["tool_call_id"] = toolCallId
            }

        case .assistant:
            if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                dict["content"] = NSNull()
                dict["tool_calls"] = toolCalls.map { tc in
                    [
                        "id": tc.id,
                        "type": tc.type,
                        "function": [
                            "name": tc.function.name,
                            "arguments": tc.function.arguments,
                        ],
                    ]
                }
            } else {
                dict["content"] = msg.content
            }

        default:
            dict["content"] = msg.content
        }

        return dict
    }

    // MARK: - Response Parsing

    /// Parses the standard OpenAI-compatible response body.
    ///
    /// Expected shapes:
    /// ```json
    /// { "choices": [{ "finish_reason": "stop", "message": { "content": "..." } }] }
    /// { "choices": [{ "finish_reason": "tool_calls", "message": { "tool_calls": [...] } }] }
    /// ```
    private func parseResponse(_ data: Data) throws -> LLMResponse {
        struct ResponseBody: Decodable {
            let choices: [Choice]
        }
        struct Choice: Decodable {
            let finishReason: String?
            let message: Message

            enum CodingKeys: String, CodingKey {
                case finishReason = "finish_reason"
                case message
            }
        }
        struct Message: Decodable {
            let content: String?
            let toolCalls: [ToolCallPayload]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }

        do {
            let body = try JSONDecoder().decode(ResponseBody.self, from: data)
            guard let choice = body.choices.first else {
                throw LLMError.decodingError("No choices in response")
            }

            if choice.finishReason == "tool_calls",
               let toolCalls = choice.message.toolCalls,
               !toolCalls.isEmpty {
                return .toolCalls(toolCalls: toolCalls)
            }

            if let content = choice.message.content {
                return .text(content)
            }

            throw LLMError.decodingError("No content or tool calls in response")
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.decodingError(error.localizedDescription)
        }
    }
}
