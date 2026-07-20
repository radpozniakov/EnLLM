import Foundation

public struct LLMRoutingConfiguration: Equatable, Sendable {
    public let primaryProvider: LLMProvider
    public let fallbackEnabled: Bool

    public init(primaryProvider: LLMProvider, fallbackEnabled: Bool) {
        self.primaryProvider = primaryProvider
        self.fallbackEnabled = fallbackEnabled
    }
}

@MainActor
public protocol LLMRoutingConfigProviding: Sendable {
    var routingConfiguration: LLMRoutingConfiguration { get }
}

@MainActor
public struct LLMRouter: TranslationTransforming, CorrectionTransforming {
    private let action: AppAction
    private let runtimeProvider: (any RuntimeConfigurationProviding)?
    private let legacyInstruction: String?
    private let legacyRoutingProvider: (any LLMRoutingConfigProviding)?
    private let legacyCredentialStore: (any CredentialStoring)?
    private let anthropicClient: any LLMProviderClient
    private let openAIClient: any LLMProviderClient
    private let diagnostics: any DiagnosticRecording

    public init(
        action: AppAction,
        runtimeConfigurationProvider: any RuntimeConfigurationProviding,
        anthropicClient: any LLMProviderClient,
        openAIClient: any LLMProviderClient,
        diagnostics: any DiagnosticRecording = NoOpDiagnosticRecorder()
    ) {
        precondition(anthropicClient.provider == .anthropic)
        precondition(openAIClient.provider == .openAI)
        self.action = action
        runtimeProvider = runtimeConfigurationProvider
        legacyInstruction = nil
        legacyRoutingProvider = nil
        legacyCredentialStore = nil
        self.anthropicClient = anthropicClient
        self.openAIClient = openAIClient
        self.diagnostics = diagnostics
    }

    // Compatibility initializer retained for package clients; app composition uses atomic runtime snapshots.
    public init(
        instruction: String,
        routingConfigurationProvider: any LLMRoutingConfigProviding,
        credentialStore: any CredentialStoring,
        anthropicClient: any LLMProviderClient,
        openAIClient: any LLMProviderClient
    ) {
        precondition(anthropicClient.provider == .anthropic)
        precondition(openAIClient.provider == .openAI)
        action = .correctSelection
        runtimeProvider = nil
        legacyInstruction = instruction
        legacyRoutingProvider = routingConfigurationProvider
        legacyCredentialStore = credentialStore
        self.anthropicClient = anthropicClient
        self.openAIClient = openAIClient
        diagnostics = NoOpDiagnosticRecorder()
    }

    public func transform(_ text: String) async throws -> String {
        try Task.checkCancellation()
        if legacyRoutingProvider != nil {
            return try await legacyTransform(text)
        }
        let snapshot = try await operationSnapshot()
        let primary = snapshot.settings.primaryProvider
        let first = try await attempt(provider: primary, text: text, snapshot: snapshot)
        if case .success(let output) = first { return output }
        let firstFailure = first.failure
        guard snapshot.settings.fallbackEnabled,
              firstFailure.isFallbackableProviderFailure(for: primary) else {
            throw firstFailure
        }

        let secondary = primary.alternateProvider
        switch snapshot.credential(for: secondary) {
        case .missing:
            throw firstFailure
        case .disabledUncertain:
            throw EnLLMError.runtimeCredentialUncertain(secondary)
        case .available:
            let second = try await attempt(provider: secondary, text: text, snapshot: snapshot)
            switch second {
            case .success(let output):
                return output
            case .failure:
                throw EnLLMError.bothProvidersFailed(primary: primary, secondary: secondary)
            }
        }
    }

    private func attempt(provider: LLMProvider, text: String, snapshot: RuntimeConfiguration) async throws -> AttemptResult {
        record(.providerAttemptStarted, provider: provider)
        let clock = ContinuousClock()
        let start = clock.now
        func complete(_ outcome: DiagnosticOutcome) {
            record(.providerAttemptCompleted, provider: provider, outcome: outcome, duration: start.duration(to: clock.now))
        }

        switch snapshot.credential(for: provider) {
        case .missing:
            complete(.failure(.providerSetup))
            return .failure(.providerCredentialMissing(provider))
        case .disabledUncertain:
            complete(.failure(.providerSetup))
            return .failure(.runtimeCredentialUncertain(provider))
        case .available(let credential):
            do {
                let output = try await client(for: provider).complete(
                    request(for: provider, userText: text, snapshot: snapshot),
                    credential: credential
                )
                complete(.success)
                return .success(output)
            } catch is CancellationError {
                complete(.cancelled)
                throw CancellationError()
            } catch let error as EnLLMError {
                complete(.failure(ErrorPresentation.present(error).category))
                return .failure(error)
            } catch {
                complete(.failure(.provider))
                return .failure(.providerFailure(provider))
            }
        }
    }

    private func record(
        _ phase: DiagnosticLifecyclePhase,
        provider: LLMProvider,
        outcome: DiagnosticOutcome? = nil,
        duration: Duration? = nil
    ) {
        // Provider-attempt diagnostics depend on the caller (a use case) having
        // established DiagnosticContext.$operationID around the transform call.
        // When it is absent (legacy path, direct-transform tests) recording is
        // skipped rather than attributed to a wrong operation — fail closed.
        guard let operationID = DiagnosticContext.operationID else { return }
        diagnostics.record(DiagnosticEvent(
            operationID: operationID,
            action: action,
            phase: phase,
            provider: provider,
            outcome: outcome,
            duration: duration
        ))
    }

    private func operationSnapshot() async throws -> RuntimeConfiguration {
        guard let runtimeProvider else { throw EnLLMError.invalidSettings }
        return runtimeProvider.runtimeConfiguration
    }

    private func legacyTransform(_ text: String) async throws -> String {
        guard let routing = legacyRoutingProvider?.routingConfiguration,
              let store = legacyCredentialStore,
              let instruction = legacyInstruction else { throw EnLLMError.invalidSettings }
        let primary = routing.primaryProvider
        let primaryResult = try await legacyAttempt(primary, text: text, store: store, instruction: instruction)
        if case .success(let output) = primaryResult { return output }
        let firstFailure = primaryResult.failure
        guard routing.fallbackEnabled, firstFailure.isFallbackableProviderFailure(for: primary) else { throw firstFailure }
        let secondary = primary.alternateProvider
        guard let credential = try await store.loadCredential(for: secondary)?.trimmingCharacters(in: .whitespacesAndNewlines), !credential.isEmpty else { throw firstFailure }
        do {
            return try await client(for: secondary).complete(
                LLMCompletionRequest(instruction: instruction, userText: text, model: secondary.defaultModel),
                credential: credential
            )
        } catch is CancellationError { throw CancellationError() }
        catch { throw EnLLMError.bothProvidersFailed(primary: primary, secondary: secondary) }
    }

    private func legacyAttempt(_ provider: LLMProvider, text: String, store: any CredentialStoring, instruction: String) async throws -> AttemptResult {
        guard let credential = try await store.loadCredential(for: provider)?.trimmingCharacters(in: .whitespacesAndNewlines), !credential.isEmpty else {
            return .failure(.providerCredentialMissing(provider))
        }
        do {
            return .success(try await client(for: provider).complete(
                LLMCompletionRequest(instruction: instruction, userText: text, model: provider.defaultModel),
                credential: credential
            ))
        } catch is CancellationError { throw CancellationError() }
        catch let error as EnLLMError { return .failure(error) }
        catch { return .failure(.providerFailure(provider)) }
    }

    private func client(for provider: LLMProvider) -> any LLMProviderClient {
        provider == .anthropic ? anthropicClient : openAIClient
    }

    private func request(for provider: LLMProvider, userText: String, snapshot: RuntimeConfiguration) -> LLMCompletionRequest {
        LLMCompletionRequest(
            instruction: snapshot.settings.instruction(for: action),
            userText: userText,
            model: snapshot.settings.model(for: provider, action: action)
        )
    }
}

private enum AttemptResult {
    case success(String)
    case failure(EnLLMError)

    var failure: EnLLMError {
        guard case .failure(let error) = self else { fatalError("failure accessed for success") }
        return error
    }
}
