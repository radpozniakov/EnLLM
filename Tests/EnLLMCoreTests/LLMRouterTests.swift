import Foundation
import Testing
@testable import EnLLMCore

private actor RouterCredentialStore: CredentialStoring {
    var credentials: [LLMProvider: String?]
    private var loadErrors: [LLMProvider: EnLLMError] = [:]
    private(set) var loadOrder: [LLMProvider] = []

    init(credentials: [LLMProvider: String?]) {
        self.credentials = credentials
    }

    func setLoadError(_ error: EnLLMError, for provider: LLMProvider) {
        loadErrors[provider] = error
    }

    func loadCredential(for provider: LLMProvider) async throws -> String? {
        loadOrder.append(provider)
        if let error = loadErrors[provider] {
            throw error
        }
        return credentials[provider] ?? nil
    }

    func saveCredential(_ credential: String, for provider: LLMProvider) async throws {
        credentials[provider] = credential
    }

    func deleteCredential(for provider: LLMProvider) async throws {
        credentials[provider] = nil
    }
}

@MainActor
private final class RouterSettings: LLMRoutingConfigProviding {
    var primaryProvider: LLMProvider
    var fallbackEnabled: Bool

    init(primaryProvider: LLMProvider, fallbackEnabled: Bool) {
        self.primaryProvider = primaryProvider
        self.fallbackEnabled = fallbackEnabled
    }

    var routingConfiguration: LLMRoutingConfiguration {
        LLMRoutingConfiguration(
            primaryProvider: primaryProvider,
            fallbackEnabled: fallbackEnabled
        )
    }
}

private actor AttemptRecorder {
    private(set) var order: [LLMProvider] = []

    func record(_ provider: LLMProvider) {
        order.append(provider)
    }
}

private actor RouterClient: LLMProviderClient {
    enum Behavior: Sendable {
        case success(String)
        case error(EnLLMError)
        case cancellation
    }

    nonisolated let provider: LLMProvider
    private let recorder: AttemptRecorder
    private(set) var requests: [LLMCompletionRequest] = []
    private(set) var credentials: [String] = []
    private var behaviors: [Behavior]

    init(provider: LLMProvider, recorder: AttemptRecorder, behaviors: [Behavior]) {
        self.provider = provider
        self.recorder = recorder
        self.behaviors = behaviors
    }

    func complete(
        _ request: LLMCompletionRequest,
        credential: String
    ) async throws -> String {
        await recorder.record(provider)
        requests.append(request)
        credentials.append(credential)
        let behavior = behaviors.isEmpty ? .success("unused") : behaviors.removeFirst()
        switch behavior {
        case .success(let output):
            return output
        case .error(let error):
            throw error
        case .cancellation:
            throw CancellationError()
        }
    }
}

@MainActor
private func makeRouter(
    instruction: String = BuiltInDefaults.correctionInstruction,
    settings: RouterSettings,
    store: RouterCredentialStore,
    anthropicClient: RouterClient,
    openAIClient: RouterClient
) -> LLMRouter {
    LLMRouter(
        instruction: instruction,
        routingConfigurationProvider: settings,
        credentialStore: store,
        anthropicClient: anthropicClient,
        openAIClient: openAIClient
    )
}

@MainActor
@Test func routerUsesConfiguredPrimaryProviderWithoutCallingAlternateOnSuccess() async throws {
    let anthropicRecorder = AttemptRecorder()
    let openAIRecorder = AttemptRecorder()
    let settings = RouterSettings(primaryProvider: .anthropic, fallbackEnabled: true)
    let store = RouterCredentialStore(credentials: [.anthropic: "anthropic-key", .openAI: "openai-key"])
    let anthropicClient = RouterClient(
        provider: .anthropic,
        recorder: anthropicRecorder,
        behaviors: [.success("anthropic result")]
    )
    let openAIClient = RouterClient(
        provider: .openAI,
        recorder: openAIRecorder,
        behaviors: [.success("openai result")]
    )
    let router = makeRouter(
        settings: settings,
        store: store,
        anthropicClient: anthropicClient,
        openAIClient: openAIClient
    )

    let output = try await router.transform("selected text")

    #expect(output == "anthropic result")
    #expect(await anthropicRecorder.order == [.anthropic])
    #expect(await openAIRecorder.order.isEmpty)
    #expect(await store.loadOrder == [.anthropic])
    #expect(await anthropicClient.requests == [LLMCompletionRequest(
        instruction: BuiltInDefaults.correctionInstruction,
        userText: "selected text",
        model: BuiltInDefaults.anthropicModel
    )])
}

@MainActor
@Test func routerUsesOpenAIAsPrimaryWhenConfigured() async throws {
    let recorder = AttemptRecorder()
    let settings = RouterSettings(primaryProvider: .openAI, fallbackEnabled: true)
    let store = RouterCredentialStore(credentials: [.anthropic: "anthropic-key", .openAI: "openai-key"])
    let anthropicClient = RouterClient(provider: .anthropic, recorder: recorder, behaviors: [.success("anthropic")])
    let openAIClient = RouterClient(provider: .openAI, recorder: recorder, behaviors: [.success("openai")])
    let router = makeRouter(
        settings: settings,
        store: store,
        anthropicClient: anthropicClient,
        openAIClient: openAIClient
    )

    let output = try await router.transform("selected text")

    #expect(output == "openai")
    #expect(await recorder.order == [.openAI])
    #expect(await store.loadOrder == [.openAI])
    #expect(await openAIClient.requests == [LLMCompletionRequest(
        instruction: BuiltInDefaults.correctionInstruction,
        userText: "selected text",
        model: BuiltInDefaults.openAIModel
    )])
    #expect(await anthropicClient.requests.isEmpty)
}

@MainActor
@Test func routerDoesNotFallbackWhenFallbackIsDisabledEvenForMissingPrimaryCredential() async {
    let recorder = AttemptRecorder()
    let settings = RouterSettings(primaryProvider: .anthropic, fallbackEnabled: false)
    let store = RouterCredentialStore(credentials: [.anthropic: nil, .openAI: "openai-key"])
    let router = makeRouter(
        settings: settings,
        store: store,
        anthropicClient: RouterClient(provider: .anthropic, recorder: recorder, behaviors: []),
        openAIClient: RouterClient(provider: .openAI, recorder: recorder, behaviors: [.success("openai")])
    )

    await #expect(throws: EnLLMError.providerCredentialMissing(.anthropic)) {
        try await router.transform("selected text")
    }
    #expect(await recorder.order.isEmpty)
    #expect(await store.loadOrder == [.anthropic])
}

@MainActor
@Test func routerFallsBackOnceWhenPrimaryCredentialIsMissingAndAlternateCredentialExists() async throws {
    let recorder = AttemptRecorder()
    let settings = RouterSettings(primaryProvider: .anthropic, fallbackEnabled: true)
    let store = RouterCredentialStore(credentials: [.anthropic: nil, .openAI: "  openai-key  "])
    let anthropicClient = RouterClient(provider: .anthropic, recorder: recorder, behaviors: [])
    let openAIClient = RouterClient(
        provider: .openAI,
        recorder: recorder,
        behaviors: [.success("fallback result")]
    )
    let router = makeRouter(
        instruction: BuiltInDefaults.ukrainianTranslationInstruction,
        settings: settings,
        store: store,
        anthropicClient: anthropicClient,
        openAIClient: openAIClient
    )

    let output = try await router.transform("selected text")

    #expect(output == "fallback result")
    #expect(await recorder.order == [.openAI])
    #expect(await anthropicClient.requests.isEmpty)
    #expect(await store.loadOrder == [.anthropic, .openAI])
    #expect(await openAIClient.credentials == ["openai-key"])
    #expect(await openAIClient.requests == [LLMCompletionRequest(
        instruction: BuiltInDefaults.ukrainianTranslationInstruction,
        userText: "selected text",
        model: BuiltInDefaults.openAIModel
    )])
}

@MainActor
@Test func routerReturnsPrimaryFailureWhenAlternateCredentialIsMissing() async {
    let recorder = AttemptRecorder()
    let settings = RouterSettings(primaryProvider: .openAI, fallbackEnabled: true)
    let store = RouterCredentialStore(credentials: [.anthropic: nil, .openAI: "openai-key"])
    let anthropicClient = RouterClient(provider: .anthropic, recorder: recorder, behaviors: [])
    let openAIClient = RouterClient(
        provider: .openAI,
        recorder: recorder,
        behaviors: [.error(.providerRateLimited(.openAI))]
    )
    let router = makeRouter(
        settings: settings,
        store: store,
        anthropicClient: anthropicClient,
        openAIClient: openAIClient
    )

    await #expect(throws: EnLLMError.providerRateLimited(.openAI)) {
        try await router.transform("selected text")
    }
    #expect(await recorder.order == [.openAI])
    #expect(await store.loadOrder == [.openAI, .anthropic])
    #expect(await anthropicClient.requests.isEmpty)
}

@MainActor
@Test func routerFallsBackForIncompleteAndEmptyProviderResponsesOnlyOnce() async throws {
    for (primaryProvider, primaryError, expectedModel) in [
        (LLMProvider.openAI, EnLLMError.providerIncompleteResponse(.openAI), BuiltInDefaults.anthropicModel),
        (LLMProvider.anthropic, EnLLMError.emptyOutput, BuiltInDefaults.openAIModel)
    ] {
        let recorder = AttemptRecorder()
        let settings = RouterSettings(primaryProvider: primaryProvider, fallbackEnabled: true)
        let store = RouterCredentialStore(credentials: [.anthropic: "anthropic-key", .openAI: "openai-key"])
        let anthropicClient = RouterClient(
            provider: .anthropic,
            recorder: recorder,
            behaviors: primaryProvider == .anthropic ? [.error(primaryError)] : [.success("anthropic fallback")]
        )
        let openAIClient = RouterClient(
            provider: .openAI,
            recorder: recorder,
            behaviors: primaryProvider == .openAI ? [.error(primaryError)] : [.success("openai fallback")]
        )
        let router = makeRouter(
            settings: settings,
            store: store,
            anthropicClient: anthropicClient,
            openAIClient: openAIClient
        )

        let output = try await router.transform("selected text")

        #expect(await recorder.order == [primaryProvider, primaryProvider.alternateProvider])
        let anthropicRequests = await anthropicClient.requests
        let openAIRequests = await openAIClient.requests
        #expect(anthropicRequests.count + openAIRequests.count == 2)
        let fallbackRequest = primaryProvider == .openAI
            ? try #require(anthropicRequests.first)
            : try #require(openAIRequests.first)
        #expect(fallbackRequest.model == expectedModel)
        #expect(!output.isEmpty)
    }
}

@MainActor
@Test func routerDoesNotFallbackForLocalOrCredentialStoreFailuresAndPropagatesCancellation() async {
    let localRecorder = AttemptRecorder()
    let localSettings = RouterSettings(primaryProvider: .anthropic, fallbackEnabled: true)
    let localStore = RouterCredentialStore(credentials: [.anthropic: "anthropic-key", .openAI: "openai-key"])
    let localRouter = makeRouter(
        settings: localSettings,
        store: localStore,
        anthropicClient: RouterClient(
            provider: .anthropic,
            recorder: localRecorder,
            behaviors: [.error(.clipboardUnavailable)]
        ),
        openAIClient: RouterClient(
            provider: .openAI,
            recorder: localRecorder,
            behaviors: [.success("fallback")]
        )
    )

    await #expect(throws: EnLLMError.clipboardUnavailable) {
        try await localRouter.transform("selected text")
    }
    #expect(await localRecorder.order == [.anthropic])

    let storeFailureRecorder = AttemptRecorder()
    let storeFailureSettings = RouterSettings(primaryProvider: .anthropic, fallbackEnabled: true)
    let storeFailureStore = RouterCredentialStore(credentials: [.anthropic: "anthropic-key", .openAI: "openai-key"])
    await storeFailureStore.setLoadError(.credentialStoreFailure, for: .anthropic)
    let storeFailureRouter = makeRouter(
        settings: storeFailureSettings,
        store: storeFailureStore,
        anthropicClient: RouterClient(provider: .anthropic, recorder: storeFailureRecorder, behaviors: []),
        openAIClient: RouterClient(provider: .openAI, recorder: storeFailureRecorder, behaviors: [.success("fallback")])
    )

    await #expect(throws: EnLLMError.credentialStoreFailure) {
        try await storeFailureRouter.transform("selected text")
    }
    #expect(await storeFailureRecorder.order.isEmpty)

    let cancellationRecorder = AttemptRecorder()
    let cancellationSettings = RouterSettings(primaryProvider: .openAI, fallbackEnabled: true)
    let cancellationStore = RouterCredentialStore(credentials: [.anthropic: "anthropic-key", .openAI: "openai-key"])
    let cancellationRouter = makeRouter(
        settings: cancellationSettings,
        store: cancellationStore,
        anthropicClient: RouterClient(provider: .anthropic, recorder: cancellationRecorder, behaviors: [.success("fallback")]),
        openAIClient: RouterClient(provider: .openAI, recorder: cancellationRecorder, behaviors: [.cancellation])
    )

    await #expect(throws: CancellationError.self) {
        try await cancellationRouter.transform("selected text")
    }
    #expect(await cancellationRecorder.order == [.openAI])
}

@MainActor
@Test func routerThrowsSanitizedCombinedFailureAfterTwoDistinctProviderAttempts() async {
    let recorder = AttemptRecorder()
    let settings = RouterSettings(primaryProvider: .anthropic, fallbackEnabled: true)
    let store = RouterCredentialStore(credentials: [.anthropic: "anthropic-secret", .openAI: "openai-secret"])
    let router = makeRouter(
        settings: settings,
        store: store,
        anthropicClient: RouterClient(
            provider: .anthropic,
            recorder: recorder,
            behaviors: [.error(.providerFailure(.anthropic))]
        ),
        openAIClient: RouterClient(
            provider: .openAI,
            recorder: recorder,
            behaviors: [.error(.providerAuthenticationFailed(.openAI))]
        )
    )

    do {
        _ = try await router.transform("private selected text")
        Issue.record("Expected combined failure")
    } catch let error as EnLLMError {
        #expect(error == .bothProvidersFailed(primary: .anthropic, secondary: .openAI))
        #expect(error.localizedDescription == "Anthropic and then OpenAI could not complete the request.")
        #expect(!error.localizedDescription.contains("private selected text"))
        #expect(!error.localizedDescription.contains("anthropic-secret"))
        #expect(!error.localizedDescription.contains("openai-secret"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(await recorder.order == [.anthropic, .openAI])
}

@MainActor
@Test func atomicRuntimeRouterUsesCustomActionInstructionModelAndMemoryCredential() async throws {
    let anthropicRecorder = AttemptRecorder()
    let openAIRecorder = AttemptRecorder()
    let anthropicClient = RouterClient(provider: .anthropic, recorder: anthropicRecorder, behaviors: [.success("custom result")])
    let openAIClient = RouterClient(provider: .openAI, recorder: openAIRecorder, behaviors: [])
    let settings = NonSecretConfiguration(
        primaryProvider: .anthropic,
        fallbackEnabled: false,
        openAICorrectionModel: "gpt-5.4-mini",
        openAITranslationModel: "gpt-5.6-luna",
        anthropicCorrectionModel: "claude-haiku-4-5",
        anthropicTranslationModel: "claude-sonnet-5",
        correctionInstruction: "custom-correction",
        translationInstruction: "custom-translation",
        correctHotkey: BuiltInDefaults.correctHotkey,
        translateHotkey: BuiltInDefaults.translateHotkey
    )
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(
        settings: settings,
        anthropicCredential: .available("memory-key"),
        openAICredential: .missing
    ))
    let router = LLMRouter(
        action: .translateSelectionToUkrainian,
        runtimeConfigurationProvider: runtime,
        anthropicClient: anthropicClient,
        openAIClient: openAIClient
    )

    #expect(try await router.transform("selected text") == "custom result")
    #expect(await anthropicClient.requests == [LLMCompletionRequest(
        instruction: "custom-translation",
        userText: "selected text",
        model: "claude-sonnet-5"
    )])
    #expect(await anthropicClient.credentials == ["memory-key"])
}

@MainActor
@Test func routerUsesActionSpecificModelForPrimaryAndFallbackAttempts() async throws {
    // Each action must route through its own (provider, action) model selection,
    // on both the primary attempt and the single fallback attempt.
    let settings = NonSecretConfiguration(
        primaryProvider: .openAI,
        fallbackEnabled: true,
        openAICorrectionModel: "gpt-5.4-mini",
        openAITranslationModel: "gpt-5.6-luna",
        anthropicCorrectionModel: "claude-haiku-4-5",
        anthropicTranslationModel: "claude-sonnet-5",
        correctionInstruction: "correction-instruction",
        translationInstruction: "translation-instruction",
        correctHotkey: BuiltInDefaults.correctHotkey,
        translateHotkey: BuiltInDefaults.translateHotkey
    )
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(
        settings: settings,
        anthropicCredential: .available("anthropic-key"),
        openAICredential: .available("openai-key")
    ))

    // Translation: OpenAI primary fails (fallbackable) -> Anthropic fallback.
    let translateRecorder = AttemptRecorder()
    let openAITranslate = RouterClient(provider: .openAI, recorder: translateRecorder, behaviors: [.error(.providerFailure(.openAI))])
    let anthropicTranslate = RouterClient(provider: .anthropic, recorder: translateRecorder, behaviors: [.success("translated")])
    let translateRouter = LLMRouter(
        action: .translateSelectionToUkrainian,
        runtimeConfigurationProvider: runtime,
        anthropicClient: anthropicTranslate,
        openAIClient: openAITranslate
    )
    #expect(try await translateRouter.transform("text") == "translated")
    #expect(await openAITranslate.requests.first?.model == "gpt-5.6-luna")
    #expect(await anthropicTranslate.requests.first?.model == "claude-sonnet-5")

    // Correction: OpenAI primary fails -> Anthropic fallback, distinct models.
    let correctRecorder = AttemptRecorder()
    let openAICorrect = RouterClient(provider: .openAI, recorder: correctRecorder, behaviors: [.error(.providerFailure(.openAI))])
    let anthropicCorrect = RouterClient(provider: .anthropic, recorder: correctRecorder, behaviors: [.success("corrected")])
    let correctRouter = LLMRouter(
        action: .correctSelection,
        runtimeConfigurationProvider: runtime,
        anthropicClient: anthropicCorrect,
        openAIClient: openAICorrect
    )
    #expect(try await correctRouter.transform("text") == "corrected")
    #expect(await openAICorrect.requests.first?.model == "gpt-5.4-mini")
    #expect(await anthropicCorrect.requests.first?.model == "claude-haiku-4-5")
}

// MARK: - BL-004 provider-attempt lifecycle diagnostics (production init)

private final class DiagnosticSpy: DiagnosticRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        lock.lock(); storage.append(event); lock.unlock()
    }

    var events: [DiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

@MainActor
private func makeDiagnosticRouter(
    primary: LLMProvider = .anthropic,
    fallbackEnabled: Bool = true,
    anthropicCredential: RuntimeCredential = .available("anthropic-key"),
    openAICredential: RuntimeCredential = .available("openai-key"),
    anthropicBehaviors: [RouterClient.Behavior] = [],
    openAIBehaviors: [RouterClient.Behavior] = [],
    diagnostics: any DiagnosticRecording
) -> LLMRouter {
    let settings = NonSecretConfiguration(
        primaryProvider: primary,
        fallbackEnabled: fallbackEnabled,
        openAICorrectionModel: BuiltInDefaults.openAICorrectionModel,
        openAITranslationModel: BuiltInDefaults.openAITranslationModel,
        anthropicCorrectionModel: BuiltInDefaults.anthropicCorrectionModel,
        anthropicTranslationModel: BuiltInDefaults.anthropicTranslationModel,
        correctionInstruction: BuiltInDefaults.correctionInstruction,
        translationInstruction: BuiltInDefaults.ukrainianTranslationInstruction,
        correctHotkey: BuiltInDefaults.correctHotkey,
        translateHotkey: BuiltInDefaults.translateHotkey
    )
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(
        settings: settings,
        anthropicCredential: anthropicCredential,
        openAICredential: openAICredential
    ))
    let recorder = AttemptRecorder()
    return LLMRouter(
        action: .correctSelection,
        runtimeConfigurationProvider: runtime,
        anthropicClient: RouterClient(provider: .anthropic, recorder: recorder, behaviors: anthropicBehaviors),
        openAIClient: RouterClient(provider: .openAI, recorder: recorder, behaviors: openAIBehaviors),
        diagnostics: diagnostics
    )
}

@MainActor
@Test func routerRecordsExactlyOneProviderAttemptOnPrimarySuccess() async throws {
    let spy = DiagnosticSpy()
    let operationID = OperationID()
    let router = makeDiagnosticRouter(anthropicBehaviors: [.success("ok")], diagnostics: spy)

    let output = try await DiagnosticContext.$operationID.withValue(operationID) {
        try await router.transform("private selected text")
    }

    #expect(output == "ok")
    let events = spy.events
    #expect(events.count == 2)
    #expect(events.allSatisfy { $0.operationID == operationID })
    #expect(events.allSatisfy { $0.provider == .anthropic })
    #expect(events[0].phase == .providerAttemptStarted)
    #expect(events[1].phase == .providerAttemptCompleted)
    #expect(events[1].outcome == .success)
    #expect(events[1].duration != nil)
    #expect(!events.contains { $0.provider == .openAI })
}

@MainActor
@Test func routerRecordsTwoOrderedProviderAttemptsOnFallback() async throws {
    let spy = DiagnosticSpy()
    let operationID = OperationID()
    let router = makeDiagnosticRouter(
        anthropicBehaviors: [.error(.providerFailure(.anthropic))],
        openAIBehaviors: [.success("fallback")],
        diagnostics: spy
    )

    let output = try await DiagnosticContext.$operationID.withValue(operationID) {
        try await router.transform("private selected text")
    }

    #expect(output == "fallback")
    let events = spy.events
    #expect(events.map(\.provider) == [.anthropic, .anthropic, .openAI, .openAI])
    #expect(events.map(\.phase) == [
        .providerAttemptStarted, .providerAttemptCompleted,
        .providerAttemptStarted, .providerAttemptCompleted
    ])
    #expect(events[1].outcome == .failure(.provider))
    #expect(events[3].outcome == .success)
    #expect(events.allSatisfy { $0.operationID == operationID })
}

@MainActor
@Test func routerRecordsCancellationAsCancellationWithoutFallbackAttempt() async {
    let spy = DiagnosticSpy()
    let operationID = OperationID()
    let router = makeDiagnosticRouter(
        anthropicBehaviors: [.cancellation],
        openAIBehaviors: [.success("must not run")],
        diagnostics: spy
    )

    await #expect(throws: CancellationError.self) {
        try await DiagnosticContext.$operationID.withValue(operationID) {
            try await router.transform("private selected text")
        }
    }

    let events = spy.events
    #expect(events.map(\.provider) == [.anthropic, .anthropic])
    #expect(events[1].outcome == .cancelled)
    #expect(!events.contains { $0.provider == .openAI })
}

@MainActor
@Test func routerRecordsNoSecondaryAttemptForNonFallbackablePrimaryFailure() async {
    let spy = DiagnosticSpy()
    let operationID = OperationID()
    let router = makeDiagnosticRouter(
        fallbackEnabled: false,
        anthropicBehaviors: [.error(.providerFailure(.anthropic))],
        diagnostics: spy
    )

    await #expect(throws: EnLLMError.providerFailure(.anthropic)) {
        try await DiagnosticContext.$operationID.withValue(operationID) {
            try await router.transform("private selected text")
        }
    }

    let events = spy.events
    #expect(events.map(\.provider) == [.anthropic, .anthropic])
    #expect(events[1].outcome == .failure(.provider))
    #expect(!events.contains { $0.provider == .openAI })
}

@MainActor
@Test func routerRecordsNoSecondaryAttemptWhenFallbackCredentialMissing() async {
    let spy = DiagnosticSpy()
    let operationID = OperationID()
    let router = makeDiagnosticRouter(
        anthropicCredential: .missing,
        openAICredential: .missing,
        diagnostics: spy
    )

    await #expect(throws: EnLLMError.providerCredentialMissing(.anthropic)) {
        try await DiagnosticContext.$operationID.withValue(operationID) {
            try await router.transform("private selected text")
        }
    }

    let events = spy.events
    #expect(events.map(\.provider) == [.anthropic, .anthropic])
    #expect(events[1].outcome == .failure(.providerSetup))
    #expect(!events.contains { $0.provider == .openAI })
}

@MainActor
@Test func routerDiagnosticsCarryOperationIDAndNeverContainContent() async throws {
    let spy = DiagnosticSpy()
    let operationID = OperationID()
    let router = makeDiagnosticRouter(
        anthropicBehaviors: [.error(.providerFailure(.anthropic))],
        openAIBehaviors: [.success("fallback output")],
        diagnostics: spy
    )

    _ = try await DiagnosticContext.$operationID.withValue(operationID) {
        try await router.transform("private selected text")
    }

    let sentinels = [
        "private selected text",
        "fallback output",
        "anthropic-key",
        "openai-key",
        BuiltInDefaults.anthropicModel,
        BuiltInDefaults.openAIModel,
        BuiltInDefaults.correctionInstruction
    ]
    #expect(!spy.events.isEmpty)
    for event in spy.events {
        #expect(event.operationID == operationID)
        for sentinel in sentinels {
            #expect(!event.summary.contains(sentinel))
        }
    }
}
