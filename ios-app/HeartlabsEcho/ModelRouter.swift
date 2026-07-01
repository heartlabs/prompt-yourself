import Foundation

// MARK: - ModelRouter

/// Routes chat completion requests to the appropriate model tier with automatic
/// fallback: if the primary tier fails with a retryable error (network, HTTP,
/// invalid URL), it falls back to the other tier.
///
/// Usage:
/// ```swift
/// let router = ModelRouter()
/// let chatResponse = try await router.sendMessages(history, tier: .performant)
/// let summary      = try await router.sendMessages(history, tier: .cheap)
/// ```
final class ModelRouter {
    private let cheapService: LLMService
    private let performantService: LLMService

    // MARK: - Init

    init(cheapConfig: LLMConfiguration = .cheap,
         performantConfig: LLMConfiguration = .performant,
         session: URLSession = .shared) {
        self.cheapService = LLMService(configuration: cheapConfig, session: session)
        self.performantService = LLMService(configuration: performantConfig, session: session)
    }

    // MARK: - Public API

    /// Sends messages to the specified model tier.
    ///
    /// On retryable errors (network, HTTP, invalid URL) the request is
    /// retried once using the opposite tier. Decoding errors and missing
    /// API keys are **not** retried — they indicate a provider-side issue
    /// that another model won't fix.
    ///
    /// - Parameters:
    ///   - messages: The full conversation history including system prompt.
    ///   - tier: Which model tier to use first (`.cheap` or `.performant`).
    ///   - tools: Optional tool definitions the LLM may use.
    ///   - jsonMode: Requests an OpenAI-compatible JSON object response.
    /// - Returns: An `LLMResponse`.
    func sendMessages(_ messages: ChatHistory,
                      tier: ModelTier,
                      tools: [LLMTool]? = nil,
                      jsonMode: Bool = false) async throws -> LLMResponse {
        let primary = service(for: tier)

        do {
            return try await primary.sendMessages(messages, tools: tools, jsonMode: jsonMode)
        } catch let error as LLMError {
            guard shouldFallBack(error) else { throw error }
            print("[ModelRouter] \(tier) failed: \(error.localizedDescription) → falling back to \(fallbackTier(for: tier))")
            let backup = service(for: fallbackTier(for: tier))
            return try await backup.sendMessages(messages, tools: tools, jsonMode: jsonMode)
        }
    }

    // MARK: - Diagnostics

    /// Returns a diagnostic string for a given tier.
    func diagnostics(for tier: ModelTier) -> String {
        service(for: tier).configuration.diagnostics
    }

    // MARK: - Private Helpers

    private func service(for tier: ModelTier) -> LLMService {
        switch tier {
        case .cheap:       return cheapService
        case .performant:  return performantService
        }
    }

    private func fallbackTier(for tier: ModelTier) -> ModelTier {
        switch tier {
        case .cheap:       return .performant
        case .performant:  return .cheap
        }
    }

    /// Returns `true` for errors where retrying with a different model
    /// might succeed: network errors, HTTP errors, and invalid URLs.
    /// Decoding errors and missing API keys are not retried.
    private func shouldFallBack(_ error: LLMError) -> Bool {
        switch error {
        case .networkError, .httpError, .invalidURL:
            return true
        case .decodingError, .noAPIKey:
            return false
        }
    }
}
