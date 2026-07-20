import Testing
@testable import EnLLMCore

@Test func phase5DefaultsAreCompleteAndValid() {
    let value = BuiltInDefaults.configuration
    #expect(value.primaryProvider == .anthropic)
    #expect(value.fallbackEnabled)
    #expect(value.openAICorrectionModel == "gpt-5.4-mini")
    #expect(value.openAITranslationModel == "gpt-5.4-mini")
    #expect(value.anthropicCorrectionModel == "claude-haiku-4-5")
    #expect(value.anthropicTranslationModel == "claude-haiku-4-5")
    #expect(value.model(for: .openAI, action: .correctSelection) == "gpt-5.4-mini")
    #expect(value.model(for: .anthropic, action: .translateSelectionToUkrainian) == "claude-haiku-4-5")
    #expect(value.correctionInstruction == BuiltInDefaults.correctionInstruction)
    #expect(value.translationInstruction == BuiltInDefaults.ukrainianTranslationInstruction)
    #expect(value.correctHotkey == HotkeyDefinition(keyCode: 17, modifiers: HotkeyDefinition.controlModifier | HotkeyDefinition.shiftModifier))
    #expect(value.translateHotkey == HotkeyDefinition(keyCode: 17, modifiers: HotkeyDefinition.optionModifier))
    #expect(value.validationIssues.isEmpty)
}

@Test func settingsValidationRejectsDisallowedModelsBlankInstructionsAndBadOrDuplicateHotkeys() {
    let invalid = NonSecretConfiguration(
        primaryProvider: .openAI,
        fallbackEnabled: false,
        openAICorrectionModel: "not-a-model",
        openAITranslationModel: " ",
        anthropicCorrectionModel: "",
        anthropicTranslationModel: "claude-nope",
        correctionInstruction: "\n",
        translationInstruction: " ",
        correctHotkey: HotkeyDefinition(keyCode: 17, modifiers: 0),
        translateHotkey: HotkeyDefinition(keyCode: 17, modifiers: 0)
    )
    #expect(Set(invalid.validationIssues) == Set(SettingsValidationIssue.allInvalidCases))

    let duplicate = NonSecretConfiguration(
        primaryProvider: .anthropic,
        fallbackEnabled: true,
        openAICorrectionModel: "gpt-5.4-mini",
        openAITranslationModel: "gpt-5.4-mini",
        anthropicCorrectionModel: "claude-haiku-4-5",
        anthropicTranslationModel: "claude-haiku-4-5",
        correctionInstruction: "c",
        translationInstruction: "t",
        correctHotkey: BuiltInDefaults.correctHotkey,
        translateHotkey: BuiltInDefaults.correctHotkey
    )
    #expect(duplicate.validationIssues == [.duplicateHotkeys])
}

@Test func modelSelectionResolvesPerProviderAndAction() {
    let value = NonSecretConfiguration(
        primaryProvider: .openAI,
        fallbackEnabled: true,
        openAICorrectionModel: "gpt-5.4-mini",
        openAITranslationModel: "gpt-5.6-luna",
        anthropicCorrectionModel: "claude-haiku-4-5",
        anthropicTranslationModel: "claude-sonnet-5",
        correctionInstruction: "c",
        translationInstruction: "t",
        correctHotkey: BuiltInDefaults.correctHotkey,
        translateHotkey: BuiltInDefaults.translateHotkey
    )
    #expect(value.model(for: .openAI, action: .correctSelection) == "gpt-5.4-mini")
    #expect(value.model(for: .openAI, action: .translateSelectionToUkrainian) == "gpt-5.6-luna")
    #expect(value.model(for: .anthropic, action: .correctSelection) == "claude-haiku-4-5")
    #expect(value.model(for: .anthropic, action: .translateSelectionToUkrainian) == "claude-sonnet-5")
    #expect(value.validationIssues.isEmpty)
}

@Test func modelCatalogExposesAllowedChoicesDefaultsAndNormalization() {
    #expect(LLMModelCatalog.allowedModels(for: .openAI, action: .correctSelection) == ["gpt-5.4-mini", "gpt-5.6-luna"])
    #expect(LLMModelCatalog.allowedModels(for: .openAI, action: .translateSelectionToUkrainian) == ["gpt-5.4-mini", "gpt-5.6-luna"])
    #expect(LLMModelCatalog.allowedModels(for: .anthropic, action: .correctSelection) == ["claude-haiku-4-5"])
    #expect(LLMModelCatalog.allowedModels(for: .anthropic, action: .translateSelectionToUkrainian) == ["claude-haiku-4-5", "claude-sonnet-5"])
    #expect(LLMModelCatalog.defaultModel(for: .openAI, action: .correctSelection) == "gpt-5.4-mini")
    #expect(LLMModelCatalog.defaultModel(for: .anthropic, action: .translateSelectionToUkrainian) == "claude-haiku-4-5")
    #expect(LLMModelCatalog.isAllowed("claude-sonnet-5", for: .anthropic, action: .translateSelectionToUkrainian))
    #expect(!LLMModelCatalog.isAllowed("claude-sonnet-5", for: .anthropic, action: .correctSelection))
    #expect(LLMModelCatalog.normalized("claude-sonnet-5", for: .anthropic, action: .correctSelection) == "claude-haiku-4-5")
    #expect(LLMModelCatalog.normalized("gpt-5.6-luna", for: .openAI, action: .translateSelectionToUkrainian) == "gpt-5.6-luna")
}

private extension SettingsValidationIssue {
    static let allInvalidCases: [Self] = [
        .disallowedOpenAICorrectionModel, .disallowedOpenAITranslationModel,
        .disallowedAnthropicCorrectionModel, .disallowedAnthropicTranslationModel,
        .blankCorrectionInstruction, .blankTranslationInstruction,
        .invalidCorrectHotkey, .invalidTranslateHotkey, .duplicateHotkeys
    ]
}

@Test func hotkeysRejectUnsupportedBitsAndKeys() {
    #expect(!HotkeyDefinition(keyCode: 17, modifiers: 1).isValid)
    #expect(!HotkeyDefinition(keyCode: 255, modifiers: HotkeyDefinition.commandModifier).isValid)
    #expect(HotkeyDefinition(keyCode: 0, modifiers: HotkeyDefinition.commandModifier).isValid)
}

@Test func hotkeyWhitelistRejectsMediaModifierAndEveryUndefinedGap() {
    let rejectedCodes: [UInt32] = [
        52, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 66, 68, 70,
        72, 73, 74, 77, 93, 94, 95, 102, 104, 108, 110, 112
    ]
    for code in rejectedCodes {
        #expect(!HotkeyDefinition(keyCode: code, modifiers: HotkeyDefinition.commandModifier).isValid)
    }
    for code in HotkeyDefinition.supportedKeyCodes {
        #expect(HotkeyDefinition(keyCode: code, modifiers: HotkeyDefinition.controlModifier).isValid)
    }
}
