import Foundation

public enum LLMProvider: String, Sendable, Equatable, CaseIterable {
    case anthropic
    case openAI

    public var displayName: String {
        switch self {
        case .anthropic:
            "Anthropic"
        case .openAI:
            "OpenAI"
        }
    }

    public var defaultModel: String {
        switch self {
        case .anthropic:
            BuiltInDefaults.anthropicModel
        case .openAI:
            BuiltInDefaults.openAIModel
        }
    }

    public var alternateProvider: LLMProvider {
        switch self {
        case .anthropic:
            .openAI
        case .openAI:
            .anthropic
        }
    }
}

public struct LLMCompletionRequest: Sendable, Equatable {
    public let instruction: String
    public let userText: String
    public let model: String
    public let maxOutputTokens: Int
    public let timeout: Duration

    public init(
        instruction: String,
        userText: String,
        model: String,
        maxOutputTokens: Int = BuiltInDefaults.maximumOutputTokens,
        timeout: Duration = .seconds(BuiltInDefaults.requestTimeoutSeconds)
    ) {
        self.instruction = instruction
        self.userText = userText
        self.model = model
        self.maxOutputTokens = maxOutputTokens
        self.timeout = timeout
    }
}

public protocol LLMProviderClient: Sendable {
    var provider: LLMProvider { get }

    func complete(
        _ request: LLMCompletionRequest,
        credential: String
    ) async throws -> String
}

public protocol CredentialStoring: Sendable {
    func loadCredential(for provider: LLMProvider) async throws -> String?
    func saveCredential(_ credential: String, for provider: LLMProvider) async throws
    func deleteCredential(for provider: LLMProvider) async throws
}

@MainActor
public struct CredentialBackedTextTransformer: TranslationTransforming, CorrectionTransforming {
    private let instruction: String
    private let model: String
    private let providerClient: any LLMProviderClient
    private let credentialStore: any CredentialStoring

    public init(
        instruction: String,
        model: String,
        providerClient: any LLMProviderClient,
        credentialStore: any CredentialStoring
    ) {
        self.instruction = instruction
        self.model = model
        self.providerClient = providerClient
        self.credentialStore = credentialStore
    }

    public func transform(_ text: String) async throws -> String {
        try Task.checkCancellation()
        guard let credential = try await credentialStore.loadCredential(for: providerClient.provider),
              !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnLLMError.providerCredentialMissing(providerClient.provider)
        }
        try Task.checkCancellation()
        return try await providerClient.complete(
            LLMCompletionRequest(
                instruction: instruction,
                userText: text,
                model: model
            ),
            credential: credential
        )
    }
}
