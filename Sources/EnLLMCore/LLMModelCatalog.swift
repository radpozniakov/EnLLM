import Foundation

/// The fixed, per-(provider, action) set of model IDs the app is allowed to select.
///
/// Model selection is a closed choice, not free-form text: the Settings UI offers
/// only these IDs as dropdown options, persistence rejects anything else, and the
/// first element of each allowed list is that combination's default. Live account
/// availability of these IDs is confirmed during manual acceptance, not here.
public enum LLMModelCatalog {
    /// Allowed model IDs for a provider/action combination, default first.
    public static func allowedModels(for provider: LLMProvider, action: AppAction) -> [String] {
        switch (provider, action) {
        case (.openAI, _):
            ["gpt-5.4-mini", "gpt-5.6-luna"]
        case (.anthropic, .correctSelection):
            ["claude-haiku-4-5"]
        case (.anthropic, .translateSelectionToUkrainian):
            ["claude-haiku-4-5", "claude-sonnet-5"]
        }
    }

    /// The default model ID for a provider/action combination (the first allowed choice).
    public static func defaultModel(for provider: LLMProvider, action: AppAction) -> String {
        // Force-unwrap is safe: every combination declares at least one allowed model.
        allowedModels(for: provider, action: action).first!
    }

    /// Whether a model ID is a permitted choice for a provider/action combination.
    public static func isAllowed(_ model: String, for provider: LLMProvider, action: AppAction) -> Bool {
        allowedModels(for: provider, action: action).contains(model)
    }

    /// Returns the model unchanged when allowed, otherwise the combination's default.
    /// Used to normalize a persisted or migrated selection that is no longer permitted.
    public static func normalized(_ model: String, for provider: LLMProvider, action: AppAction) -> String {
        isAllowed(model, for: provider, action: action) ? model : defaultModel(for: provider, action: action)
    }
}
