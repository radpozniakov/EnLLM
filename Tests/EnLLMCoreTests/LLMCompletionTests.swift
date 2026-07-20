import Foundation
import Testing
@testable import EnLLMCore

private actor RecordingProviderClient: LLMProviderClient {
    nonisolated let provider: LLMProvider
    private(set) var requests: [LLMCompletionRequest] = []
    private(set) var credentials: [String] = []
    let output: String

    init(provider: LLMProvider = .anthropic, output: String = "result") {
        self.provider = provider
        self.output = output
    }

    func complete(
        _ request: LLMCompletionRequest,
        credential: String
    ) async throws -> String {
        requests.append(request)
        credentials.append(credential)
        return output
    }
}

private actor StubCredentialStore: CredentialStoring {
    var credential: String?

    init(credential: String?) {
        self.credential = credential
    }

    func loadCredential(for provider: LLMProvider) async throws -> String? {
        credential
    }

    func saveCredential(_ credential: String, for provider: LLMProvider) async throws {
        self.credential = credential
    }

    func deleteCredential(for provider: LLMProvider) async throws {
        credential = nil
    }
}

@Test func providerMetadataExposesDisplayNamesDefaultsAndAlternates() {
    #expect(LLMProvider.allCases == [.anthropic, .openAI])
    #expect(LLMProvider.anthropic.displayName == "Anthropic")
    #expect(LLMProvider.openAI.displayName == "OpenAI")
    #expect(LLMProvider.anthropic.defaultModel == BuiltInDefaults.anthropicModel)
    #expect(LLMProvider.openAI.defaultModel == BuiltInDefaults.openAIModel)
    #expect(LLMProvider.anthropic.alternateProvider == .openAI)
    #expect(LLMProvider.openAI.alternateProvider == .anthropic)
}

@Test func completionRequestKeepsInstructionAndUserTextSeparate() {
    let request = LLMCompletionRequest(
        instruction: "instruction without selection",
        userText: "private selected text",
        model: BuiltInDefaults.anthropicModel
    )

    #expect(request.instruction == "instruction without selection")
    #expect(request.userText == "private selected text")
    #expect(!request.instruction.contains(request.userText))
    #expect(request.maxOutputTokens == 4_096)
    #expect(request.timeout == .seconds(15))
}

@MainActor
@Test func credentialBackedTransformerLoadsKeyAndBuildsConfiguredRequest() async throws {
    let client = RecordingProviderClient(output: "  preserved output\n")
    let store = StubCredentialStore(credential: "secret-key")
    let transformer = CredentialBackedTextTransformer(
        instruction: BuiltInDefaults.correctionInstruction,
        model: BuiltInDefaults.anthropicModel,
        providerClient: client,
        credentialStore: store
    )

    let output = try await transformer.transform("selected text")
    let requests = await client.requests
    let credentials = await client.credentials

    #expect(output == "  preserved output\n")
    #expect(requests == [LLMCompletionRequest(
        instruction: BuiltInDefaults.correctionInstruction,
        userText: "selected text",
        model: BuiltInDefaults.anthropicModel
    )])
    #expect(credentials == ["secret-key"])
}

@MainActor
@Test func credentialBackedTransformerFailsBeforeProviderWhenKeyIsMissing() async {
    let client = RecordingProviderClient(provider: .openAI)
    let transformer = CredentialBackedTextTransformer(
        instruction: BuiltInDefaults.ukrainianTranslationInstruction,
        model: BuiltInDefaults.openAIModel,
        providerClient: client,
        credentialStore: StubCredentialStore(credential: "  \n ")
    )

    await #expect(throws: EnLLMError.providerCredentialMissing(.openAI)) {
        try await transformer.transform("selected text")
    }
    #expect(await client.requests.isEmpty)
}

@Test func builtInPromptsAndRoutingDefaultsMatchPhase4Contract() {
    let correction = BuiltInDefaults.correctionInstruction.lowercased()
    #expect(correction.contains("grammar"))
    #expect(correction.contains("meaning"))
    #expect(correction.contains("language"))
    #expect(correction.contains("markdown"))
    #expect(correction.contains("code"))
    #expect(correction.contains("identifiers"))
    #expect(correction.contains("only the corrected text"))

    let translation = BuiltInDefaults.ukrainianTranslationInstruction.lowercased()
    #expect(translation.contains("auto-detect"))
    #expect(translation.contains("ukrainian"))
    #expect(translation.contains("already ukrainian"))
    #expect(translation.contains("line breaks"))
    #expect(translation.contains("markdown"))
    #expect(translation.contains("code"))
    #expect(translation.contains("only the resulting text"))

    #expect(BuiltInDefaults.primaryProvider == .anthropic)
    #expect(BuiltInDefaults.fallbackEnabled)
    #expect(!BuiltInDefaults.correctionInstruction.contains("{{text}}"))
    #expect(!BuiltInDefaults.ukrainianTranslationInstruction.contains("{{text}}"))
}
