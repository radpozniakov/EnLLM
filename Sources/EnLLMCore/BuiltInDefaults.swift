public enum BuiltInDefaults {
    public static let bundleIdentifier = "com.radpozniakov.enllm"
    public static let maximumInputLength = 10_000
    public static let maximumOutputTokens = 4_096
    public static let requestTimeoutSeconds = 15
    public static let primaryProvider: LLMProvider = .anthropic
    public static let fallbackEnabled = true
    // Legacy single-model defaults retained for the compatibility router path and
    // provider.defaultModel; they equal the catalog defaults for each provider.
    public static let anthropicModel = "claude-haiku-4-5"
    public static let openAIModel = "gpt-5.4-mini"
    public static let openAICorrectionModel = LLMModelCatalog.defaultModel(for: .openAI, action: .correctSelection)
    public static let openAITranslationModel = LLMModelCatalog.defaultModel(for: .openAI, action: .translateSelectionToUkrainian)
    public static let anthropicCorrectionModel = LLMModelCatalog.defaultModel(for: .anthropic, action: .correctSelection)
    public static let anthropicTranslationModel = LLMModelCatalog.defaultModel(for: .anthropic, action: .translateSelectionToUkrainian)
    public static let correctHotkey = HotkeyDefinition(
        keyCode: 17, // kVK_ANSI_T
        modifiers: HotkeyDefinition.controlModifier | HotkeyDefinition.shiftModifier
    )
    public static let translateHotkey = HotkeyDefinition(
        keyCode: 17, // kVK_ANSI_T
        modifiers: HotkeyDefinition.optionModifier
    )

    public static let correctionInstruction = """
    Correct grammar, spelling, punctuation, and obvious wording mistakes with the smallest necessary changes.
    Preserve the original meaning, tone, language, line breaks, plain-text formatting, Markdown, code and code blocks, commands, paths, API names, product names, and identifiers.
    Return only the corrected text. Do not add explanations, labels, or commentary.
    """

    public static let ukrainianTranslationInstruction = """
    Auto-detect the source language and translate the provided text into Ukrainian.
    If the text is already Ukrainian, return it unchanged.
    Preserve line breaks, plain-text formatting, Markdown, code and code blocks, commands, paths, API names, product names, identifiers, and other technical tokens.
    Return only the resulting text. Do not add explanations, labels, or commentary.
    """

    public static let connectionTestInstruction =
        "Return exactly OK to confirm that this model can complete a request."
    public static let connectionTestUserText = "Connection test."

    public static let configuration = NonSecretConfiguration(
        primaryProvider: primaryProvider,
        fallbackEnabled: fallbackEnabled,
        openAICorrectionModel: openAICorrectionModel,
        openAITranslationModel: openAITranslationModel,
        anthropicCorrectionModel: anthropicCorrectionModel,
        anthropicTranslationModel: anthropicTranslationModel,
        correctionInstruction: correctionInstruction,
        translationInstruction: ukrainianTranslationInstruction,
        correctHotkey: correctHotkey,
        translateHotkey: translateHotkey
    )
}
