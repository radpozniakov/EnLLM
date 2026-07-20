import Foundation

public struct HotkeyDefinition: Codable, Equatable, Hashable, Sendable {
    public static let commandModifier: UInt32 = 1 << 8
    public static let shiftModifier: UInt32 = 1 << 9
    public static let optionModifier: UInt32 = 1 << 11
    public static let controlModifier: UInt32 = 1 << 12
    public static let supportedModifierMask = commandModifier | shiftModifier | optionModifier | controlModifier

    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isValid: Bool {
        modifiers != 0 && modifiers & ~Self.supportedModifierMask == 0 && Self.supportedKeyCodes.contains(keyCode)
    }

    // Explicit Carbon physical-key whitelist: ANSI keys, editing/navigation, keypad, arrows, and function keys.
    // Media keys and undefined gaps are intentionally excluded.
    public static let supportedKeyCodes: Set<UInt32> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
        18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33,
        34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49,
        50, 51, 53, 64, 65, 67, 69, 71, 75, 76, 78, 79, 80, 81, 82, 83,
        84, 85, 86, 87, 88, 89, 90, 91, 92, 96, 97, 98, 99, 100, 101,
        103, 105, 106, 107, 109, 111, 113, 114, 115, 116, 117, 118, 119,
        120, 121, 122, 123, 124, 125, 126
    ]
}

public struct NonSecretConfiguration: Equatable, Sendable {
    public let primaryProvider: LLMProvider
    public let fallbackEnabled: Bool
    public let openAICorrectionModel: String
    public let openAITranslationModel: String
    public let anthropicCorrectionModel: String
    public let anthropicTranslationModel: String
    public let correctionInstruction: String
    public let translationInstruction: String
    public let correctHotkey: HotkeyDefinition
    public let translateHotkey: HotkeyDefinition

    public init(
        primaryProvider: LLMProvider,
        fallbackEnabled: Bool,
        openAICorrectionModel: String,
        openAITranslationModel: String,
        anthropicCorrectionModel: String,
        anthropicTranslationModel: String,
        correctionInstruction: String,
        translationInstruction: String,
        correctHotkey: HotkeyDefinition,
        translateHotkey: HotkeyDefinition
    ) {
        self.primaryProvider = primaryProvider
        self.fallbackEnabled = fallbackEnabled
        self.openAICorrectionModel = openAICorrectionModel
        self.openAITranslationModel = openAITranslationModel
        self.anthropicCorrectionModel = anthropicCorrectionModel
        self.anthropicTranslationModel = anthropicTranslationModel
        self.correctionInstruction = correctionInstruction
        self.translationInstruction = translationInstruction
        self.correctHotkey = correctHotkey
        self.translateHotkey = translateHotkey
    }

    /// The model selected for a specific provider *and* app action. Correction and
    /// translation carry independent selections, so routing must always pass both.
    public func model(for provider: LLMProvider, action: AppAction) -> String {
        switch (provider, action) {
        case (.openAI, .correctSelection): openAICorrectionModel
        case (.openAI, .translateSelectionToUkrainian): openAITranslationModel
        case (.anthropic, .correctSelection): anthropicCorrectionModel
        case (.anthropic, .translateSelectionToUkrainian): anthropicTranslationModel
        }
    }

    public func instruction(for action: AppAction) -> String {
        action == .correctSelection ? correctionInstruction : translationInstruction
    }

    /// A copy with every model selection normalized to an allowed choice for its
    /// (provider, action) combination, defaulting any disallowed value.
    public func normalizingModels() -> NonSecretConfiguration {
        NonSecretConfiguration(
            primaryProvider: primaryProvider,
            fallbackEnabled: fallbackEnabled,
            openAICorrectionModel: LLMModelCatalog.normalized(openAICorrectionModel, for: .openAI, action: .correctSelection),
            openAITranslationModel: LLMModelCatalog.normalized(openAITranslationModel, for: .openAI, action: .translateSelectionToUkrainian),
            anthropicCorrectionModel: LLMModelCatalog.normalized(anthropicCorrectionModel, for: .anthropic, action: .correctSelection),
            anthropicTranslationModel: LLMModelCatalog.normalized(anthropicTranslationModel, for: .anthropic, action: .translateSelectionToUkrainian),
            correctionInstruction: correctionInstruction,
            translationInstruction: translationInstruction,
            correctHotkey: correctHotkey,
            translateHotkey: translateHotkey
        )
    }

    public var validationIssues: [SettingsValidationIssue] {
        var issues: [SettingsValidationIssue] = []
        if !LLMModelCatalog.isAllowed(openAICorrectionModel, for: .openAI, action: .correctSelection) { issues.append(.disallowedOpenAICorrectionModel) }
        if !LLMModelCatalog.isAllowed(openAITranslationModel, for: .openAI, action: .translateSelectionToUkrainian) { issues.append(.disallowedOpenAITranslationModel) }
        if !LLMModelCatalog.isAllowed(anthropicCorrectionModel, for: .anthropic, action: .correctSelection) { issues.append(.disallowedAnthropicCorrectionModel) }
        if !LLMModelCatalog.isAllowed(anthropicTranslationModel, for: .anthropic, action: .translateSelectionToUkrainian) { issues.append(.disallowedAnthropicTranslationModel) }
        if correctionInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.blankCorrectionInstruction) }
        if translationInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.blankTranslationInstruction) }
        if !correctHotkey.isValid { issues.append(.invalidCorrectHotkey) }
        if !translateHotkey.isValid { issues.append(.invalidTranslateHotkey) }
        if correctHotkey == translateHotkey { issues.append(.duplicateHotkeys) }
        return issues
    }

    public var isValid: Bool { validationIssues.isEmpty }
}

public enum CredentialDraft: Equatable, Sendable {
    case unchanged
    case replace(String)
    case delete
}

public struct SettingsDraft: Equatable, Sendable {
    public var configuration: NonSecretConfiguration
    public var anthropicCredential: CredentialDraft
    public var openAICredential: CredentialDraft

    public init(
        configuration: NonSecretConfiguration,
        anthropicCredential: CredentialDraft = .unchanged,
        openAICredential: CredentialDraft = .unchanged
    ) {
        self.configuration = configuration
        self.anthropicCredential = anthropicCredential
        self.openAICredential = openAICredential
    }

    public func credential(for provider: LLMProvider) -> CredentialDraft {
        provider == .anthropic ? anthropicCredential : openAICredential
    }
}

public enum SettingsValidationIssue: String, Equatable, Hashable, Sendable {
    case disallowedOpenAICorrectionModel
    case disallowedOpenAITranslationModel
    case disallowedAnthropicCorrectionModel
    case disallowedAnthropicTranslationModel
    case blankCorrectionInstruction
    case blankTranslationInstruction
    case invalidCorrectHotkey
    case invalidTranslateHotkey
    case duplicateHotkeys

    public var message: String {
        switch self {
        case .disallowedOpenAICorrectionModel: "Select a supported OpenAI correction model."
        case .disallowedOpenAITranslationModel: "Select a supported OpenAI translation model."
        case .disallowedAnthropicCorrectionModel: "Select a supported Anthropic correction model."
        case .disallowedAnthropicTranslationModel: "Select a supported Anthropic translation model."
        case .blankCorrectionInstruction: "Correction instructions cannot be empty."
        case .blankTranslationInstruction: "Translation instructions cannot be empty."
        case .invalidCorrectHotkey: "Correct shortcut must contain a supported key and at least one modifier."
        case .invalidTranslateHotkey: "Translate shortcut must contain a supported key and at least one modifier."
        case .duplicateHotkeys: "Correct and Translate shortcuts must be different."
        }
    }
}

public enum SettingsLoadRecovery: Equatable, Sendable {
    case none
    case recoveredDefaults(String)
}

public struct SettingsLoadResult: Equatable, Sendable {
    public let configuration: NonSecretConfiguration
    public let recovery: SettingsLoadRecovery

    public init(configuration: NonSecretConfiguration, recovery: SettingsLoadRecovery = .none) {
        self.configuration = configuration
        self.recovery = recovery
    }
}

public enum SettingsStoreSnapshot: Equatable, Sendable {
    case absent
    case contents(Data)
}

public protocol SettingsPersisting: Sendable {
    func load() async -> SettingsLoadResult
    func snapshot() async throws -> SettingsStoreSnapshot
    func save(_ configuration: NonSecretConfiguration) async throws
    func restore(_ snapshot: SettingsStoreSnapshot) async throws
}

public enum HotkeyRollbackResult: Equatable, Sendable {
    case restored
    case uncertain(Set<AppAction>)
}

@MainActor
public protocol HotkeyRegistering: AnyObject {
    var activeDefinitions: [AppAction: HotkeyDefinition] { get }
    var lastRollbackResult: HotkeyRollbackResult { get }
    func prepare(
        correct: HotkeyDefinition,
        translate: HotkeyDefinition,
        action: @escaping @MainActor @Sendable (AppAction) -> Void
    ) throws
    func activate()
    func rollback() -> HotkeyRollbackResult
    func setRecordingAction(_ action: AppAction?)
    func unregister()
}
