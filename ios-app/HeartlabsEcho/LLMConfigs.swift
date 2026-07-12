// ❗ This file is COMMITTED and contains NO secrets.
//    API keys are injected at build time via Secrets.xcconfig → Info.plist.
//    To change providers (base URL / model), edit the static properties below.
//    To set API keys locally, copy Secrets.xcconfig.template → Secrets.xcconfig.

import Foundation

// MARK: - Model Tier Definitions

/// Which model tier to use for a given operation.
enum ModelTier: CustomStringConvertible {
    /// Low-cost model for non-chat tasks (summaries, scoring, etc.).
    case cheap
    /// High-performance model for interactive chat.
    case performant

    var description: String {
        switch self {
        case .cheap: "cheap"
        case .performant: "performant"
        }
    }
}

extension LLMConfiguration {

    /// Cheap tier — DeepSeek.
    static let cheap = LLMConfiguration(
        apiKey: Bundle.main.infoDictionary?["DeepSeekAPIKey"] as? String ?? "",
        baseURL: "https://api.deepseek.com",
        model: "deepseek-chat",
        supportsImages: false,
        source: "LLMConfigs.cheap"
    )

    /// Performant tier — Mistral. This model supports image inputs.
    static let performant = LLMConfiguration(
        apiKey: Bundle.main.infoDictionary?["MistralAPIKey"] as? String ?? "",
        baseURL: "https://api.mistral.ai/v1",
        model: "mistral-large-latest",
        supportsImages: true,
        source: "LLMConfigs.performant"
    )
}
