import Testing
@testable import EnLLMCore

@Test func recoveryDefaultsMatchTheSpecification() {
    #expect(BuiltInDefaults.bundleIdentifier == "com.radpozniakov.enllm")
    #expect(BuiltInDefaults.maximumInputLength == 10_000)
    #expect(BuiltInDefaults.maximumOutputTokens == 4_096)
    #expect(BuiltInDefaults.requestTimeoutSeconds == 15)
    #expect(BuiltInDefaults.primaryProvider == .anthropic)
    #expect(BuiltInDefaults.fallbackEnabled)
    #expect(BuiltInDefaults.anthropicModel == "claude-haiku-4-5")
    #expect(BuiltInDefaults.openAIModel == "gpt-5.4-mini")
}
