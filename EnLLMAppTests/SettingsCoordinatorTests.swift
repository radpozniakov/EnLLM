import EnLLMCore
import Foundation
import Testing
@testable import EnLLMApp

private actor TransactionCredentialStore: CredentialStoring {
    var values: [LLMProvider: String]
    var operations: [String] = []
    private var failureCalls: [String: Set<Int>] = [:]
    private var operationCounts: [String: Int] = [:]
    private var loadCounts: [LLMProvider: Int] = [:]
    private var failingLoadCalls: [LLMProvider: Set<Int>] = [:]
    init(_ values: [LLMProvider: String] = [:]) { self.values = values }
    func setFailure(_ operation: String?, call: Int = 1) {
        guard let operation else { failureCalls.removeAll(); return }
        failureCalls[operation, default: []].insert(call)
    }
    func setLoadFailure(_ provider: LLMProvider, call: Int) { failingLoadCalls[provider, default: []].insert(call) }
    func loadCredential(for provider: LLMProvider) async throws -> String? {
        loadCounts[provider, default: 0] += 1
        if failingLoadCalls[provider, default: []].contains(loadCounts[provider, default: 0]) {
            throw EnLLMError.credentialStoreFailure
        }
        return values[provider]
    }
    func saveCredential(_ credential: String, for provider: LLMProvider) async throws {
        let operation = "save-\(provider.rawValue)"; operations.append(operation)
        if shouldFail(operation) { throw EnLLMError.credentialStoreFailure }
        values[provider] = credential
    }
    func deleteCredential(for provider: LLMProvider) async throws {
        let operation = "delete-\(provider.rawValue)"; operations.append(operation)
        if shouldFail(operation) { throw EnLLMError.credentialStoreFailure }
        values.removeValue(forKey: provider)
    }
    private func shouldFail(_ operation: String) -> Bool {
        operationCounts[operation, default: 0] += 1
        return failureCalls[operation, default: []].contains(operationCounts[operation, default: 0])
    }
}

private actor TransactionRepository: SettingsPersisting {
    var value: NonSecretConfiguration
    var failSave = false
    var failRestore = false
    var saveError: (any Error)?
    var saveCount = 0
    private var suspendLoad = false
    private var suspendSave = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var saveContinuation: CheckedContinuation<Void, Never>?
    init(_ value: NonSecretConfiguration = BuiltInDefaults.configuration) { self.value = value }
    func load() async -> SettingsLoadResult {
        if suspendLoad {
            await withCheckedContinuation { loadContinuation = $0 }
            suspendLoad = false
        }
        return SettingsLoadResult(configuration: value)
    }
    func snapshot() async throws -> SettingsStoreSnapshot { .contents(Data("old".utf8)) }
    func save(_ configuration: NonSecretConfiguration) async throws {
        saveCount += 1
        if suspendSave {
            await withCheckedContinuation { saveContinuation = $0 }
            suspendSave = false
        }
        if let saveError { throw saveError }
        if failSave { throw EnLLMError.settingsPersistenceFailed }
        value = configuration
    }
    func restore(_ snapshot: SettingsStoreSnapshot) async throws {
        if failRestore { throw EnLLMError.settingsPersistenceFailed }
        value = BuiltInDefaults.configuration
    }
    func setFailSave() { failSave = true }
    func setSaveError(_ error: any Error) { saveError = error }
    func setFailRestore() { failRestore = true }
    func suspendNextLoad() { suspendLoad = true }
    func suspendNextSave() { suspendSave = true }
    func isLoadSuspended() -> Bool { loadContinuation != nil }
    func isSaveSuspended() -> Bool { saveContinuation != nil }
    func resumeLoad() { loadContinuation?.resume(); loadContinuation = nil }
    func resumeSave() { saveContinuation?.resume(); saveContinuation = nil }
}

@MainActor
private final class TransactionHotkeys: HotkeyRegistering {
    var activeDefinitions: [AppAction: HotkeyDefinition] = [:]
    var lastRollbackResult: HotkeyRollbackResult = .restored
    var pending: [AppAction: HotkeyDefinition]?
    var prepareCount = 0
    var recording: AppAction?
    var failPrepare = false
    var failUnregisterAction: AppAction?
    func prepare(correct: HotkeyDefinition, translate: HotkeyDefinition, action: @escaping @MainActor @Sendable (AppAction) -> Void) throws {
        prepareCount += 1
        let unregisterWouldFail =
            (failUnregisterAction == .correctSelection && activeDefinitions[.correctSelection] != correct) ||
            (failUnregisterAction == .translateSelectionToUkrainian && activeDefinitions[.translateSelectionToUkrainian] != translate)
        if failPrepare || unregisterWouldFail { lastRollbackResult = .restored; throw EnLLMError.hotkeyRegistrationFailed }
        pending = [.correctSelection: correct, .translateSelectionToUkrainian: translate]
    }
    func activate() { if let pending { activeDefinitions = pending }; pending = nil }
    func rollback() -> HotkeyRollbackResult { pending = nil; return .restored }
    func setRecordingAction(_ action: AppAction?) { recording = action }
    func unregister() { activeDefinitions.removeAll() }
}

private actor DraftClient: LLMProviderClient {
    nonisolated let provider: LLMProvider
    var requests: [LLMCompletionRequest] = []
    var credentials: [String] = []
    init(_ provider: LLMProvider) { self.provider = provider }
    func complete(_ request: LLMCompletionRequest, credential: String) async throws -> String { requests.append(request); credentials.append(credential); return "OK" }
}

private actor SuspendingDraftClient: LLMProviderClient {
    nonisolated let provider: LLMProvider
    private var continuation: CheckedContinuation<String, any Error>?
    init(_ provider: LLMProvider) { self.provider = provider }
    func complete(_ request: LLMCompletionRequest, credential: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    var isSuspended: Bool { continuation != nil }
    func succeed() {
        continuation?.resume(returning: "OK")
        continuation = nil
    }
}

/// Stands in for selected text / API key / response body content that must never reach the UI.
private let leakSentinel = "selected text / API key / response body sentinel"

/// A non-`EnLLMError` error whose `localizedDescription` carries the sentinel. Routing it through
/// `ErrorPresentation.present` must collapse it to the generic message, never surfacing the sentinel.
private struct UnsafeSettingsError: LocalizedError {
    let errorDescription: String?
}

private actor ThrowingDraftClient: LLMProviderClient {
    nonisolated let provider: LLMProvider
    private let error: any Error
    init(_ provider: LLMProvider, error: any Error) { self.provider = provider; self.error = error }
    func complete(_ request: LLMCompletionRequest, credential: String) async throws -> String { throw error }
}

/// Succeeds for every model except the named one, which throws — used to prove
/// Test Connection identifies exactly which selected model failed.
private actor ModelFailingClient: LLMProviderClient {
    nonisolated let provider: LLMProvider
    private let failingModel: String
    private let error: any Error
    private(set) var requests: [LLMCompletionRequest] = []
    init(_ provider: LLMProvider, failingModel: String, error: any Error) {
        self.provider = provider; self.failingModel = failingModel; self.error = error
    }
    func complete(_ request: LLMCompletionRequest, credential: String) async throws -> String {
        requests.append(request)
        if request.model == failingModel { throw error }
        return "OK"
    }
}

@MainActor
private func transactionModel(
    credentials: TransactionCredentialStore,
    repository: TransactionRepository,
    hotkeys: TransactionHotkeys,
    runtime: RuntimeConfigurationStore,
    anthropic: any LLMProviderClient = DraftClient(.anthropic),
    openAI: any LLMProviderClient = DraftClient(.openAI),
    autosaveDelay: Duration = .milliseconds(600)
) -> ProviderSettingsModel {
    ProviderSettingsModel(
        credentialStore: credentials,
        anthropicClient: anthropic,
        openAIClient: openAI,
        settingsRepository: repository,
        hotkeyRegistrar: hotkeys,
        runtimeStore: runtime,
        autosaveDelay: autosaveDelay
    )
}

@MainActor
@Test func bootstrapShowsStoredKeysSecurelyAndPublishesOneSnapshot() async {
    let credentials = TransactionCredentialStore([.anthropic: "secret-a"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)

    await model.bootstrapAndWait()

    #expect(model.draftAPIKey(for: .anthropic) == "secret-a")
    #expect(!model.hasCredentialEdit(.anthropic))
    #expect(model.credentialAvailability(for: .anthropic) == .present)
    #expect(runtime.runtimeConfiguration.anthropicCredential == .available("secret-a"))
    #expect(hotkeys.activeDefinitions[.correctSelection] == BuiltInDefaults.correctHotkey)
}

@MainActor
@Test func applyIsRejectedUntilSuspendedBootstrapPublishesItsSingleLoadedSnapshot() async {
    let loaded = NonSecretConfiguration(
        primaryProvider: .openAI,
        fallbackEnabled: false,
        openAICorrectionModel: "gpt-5.6-luna",
        openAITranslationModel: "gpt-5.4-mini",
        anthropicCorrectionModel: "claude-haiku-4-5",
        anthropicTranslationModel: "claude-sonnet-5",
        correctionInstruction: "loaded correction",
        translationInstruction: "loaded translation",
        correctHotkey: BuiltInDefaults.correctHotkey,
        translateHotkey: BuiltInDefaults.translateHotkey
    )
    let credentials = TransactionCredentialStore()
    let repository = TransactionRepository(loaded)
    await repository.suspendNextLoad()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)

    model.bootstrap()
    while !(await repository.isLoadSuspended()) { await Task.yield() }
    model.anthropicTranslationModel = "claude-haiku-4-5"
    model.apply()
    #expect(!model.isBootstrapped)
    #expect(!model.isApplying)
    await repository.resumeLoad()
    await model.bootstrapAndWait()

    #expect(model.isBootstrapped)
    #expect(model.anthropicTranslationModel == "claude-sonnet-5")
    #expect(runtime.runtimeConfiguration.settings == loaded)
    #expect(await repository.saveCount == 0)
}

@MainActor
@Test func terminationWaitsForSuspendedBootstrapAndPreventsLateRegistrationOrPublication() async {
    let loaded = NonSecretConfiguration(
        primaryProvider: .anthropic,
        fallbackEnabled: true,
        openAICorrectionModel: "gpt-5.4-mini",
        openAITranslationModel: "gpt-5.6-luna",
        anthropicCorrectionModel: "claude-haiku-4-5",
        anthropicTranslationModel: "claude-sonnet-5",
        correctionInstruction: "correct",
        translationInstruction: "translate",
        correctHotkey: BuiltInDefaults.correctHotkey,
        translateHotkey: BuiltInDefaults.translateHotkey
    )
    let credentials = TransactionCredentialStore([.anthropic: "must-not-publish"])
    let repository = TransactionRepository(loaded)
    await repository.suspendNextLoad()
    let hotkeys = TransactionHotkeys()
    let initialRuntime = RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing)
    let runtime = RuntimeConfigurationStore(initialRuntime)
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)

    model.bootstrap()
    while !(await repository.isLoadSuspended()) { await Task.yield() }
    let termination = Task { await model.prepareForTermination() }
    while !model.isTerminating { await Task.yield() }
    await repository.resumeLoad()
    await termination.value

    #expect(!model.isBootstrapped)
    #expect(hotkeys.prepareCount == 0)
    #expect(hotkeys.activeDefinitions.isEmpty)
    #expect(runtime.runtimeConfiguration == initialRuntime)
}

@MainActor
@Test func successfulApplyPublishesModelsPromptsCredentialsAndBothHotkeysTogether() async {
    let credentials = TransactionCredentialStore([.anthropic: "old"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .available("old"), openAICredential: .missing))
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)
    await model.bootstrapAndWait()

    model.primaryProvider = .openAI
    model.anthropicTranslationModel = "claude-sonnet-5"
    model.openAITranslationModel = "gpt-5.6-luna"
    model.correctionInstruction = "custom correction"
    model.translationInstruction = "custom translation"
    model.correctHotkey = HotkeyDefinition(keyCode: 0, modifiers: HotkeyDefinition.commandModifier)
    model.translateHotkey = HotkeyDefinition(keyCode: 1, modifiers: HotkeyDefinition.optionModifier)
    model.setDraftAPIKey("new-a", for: .anthropic)
    model.setDraftAPIKey("new-o", for: .openAI)
    await model.applyAndWait()

    #expect(model.applyStatus == .saved)
    #expect(runtime.runtimeConfiguration.settings.openAITranslationModel == "gpt-5.6-luna")
    #expect(runtime.runtimeConfiguration.settings.anthropicTranslationModel == "claude-sonnet-5")
    #expect(runtime.runtimeConfiguration.openAICredential == .available("new-o"))
    #expect(hotkeys.activeDefinitions[.correctSelection] == model.correctHotkey)
    #expect(model.draftAPIKey(for: .anthropic) == "new-a")
    #expect(!model.hasCredentialEdit(.anthropic))
    #expect(await repository.saveCount == 1)
}

@MainActor
@Test func editsDuringAnInFlightCommitCoalesceIntoASerializedRecommit() async {
    let credentials = TransactionCredentialStore([.anthropic: "old-a", .openAI: "old-o"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)
    await model.bootstrapAndWait()
    await repository.suspendNextSave()
    model.setDraftAPIKey("captured-a", for: .anthropic)
    model.setDraftAPIKey("captured-o", for: .openAI)

    model.apply()
    while !(await repository.isSaveSuspended()) { await Task.yield() }
    // Edits arriving during the in-flight commit are coalesced into a serialized recommit.
    model.setDraftAPIKey("later-a", for: .anthropic)
    model.setDraftAPIKey("later-o", for: .openAI)
    await repository.resumeSave()
    await model.applyAndWait()

    // The newest complete snapshot wins; the first commit persisted captured-*, then the
    // coalesced recommit persisted later-*.
    #expect(await credentials.values[.anthropic] == "later-a")
    #expect(await credentials.values[.openAI] == "later-o")
    #expect(runtime.runtimeConfiguration.anthropicCredential == .available("later-a"))
    #expect(runtime.runtimeConfiguration.openAICredential == .available("later-o"))
    #expect(model.draftAPIKey(for: .anthropic) == "later-a")
    #expect(model.draftAPIKey(for: .openAI) == "later-o")
    #expect(!model.hasCredentialEdit(.anthropic))
    #expect(!model.hasCredentialEdit(.openAI))
    #expect(await repository.saveCount == 2)
}

@MainActor
@Test func confirmedDeletionDeletesOnlyThatProviderOnApply() async {
    let credentials = TransactionCredentialStore([.anthropic: "old-a", .openAI: "old-o"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)
    await model.bootstrapAndWait()
    model.confirmCredentialDeletion(.anthropic)
    await model.applyAndWait()
    #expect(await credentials.values[.anthropic] == nil)
    #expect(await credentials.values[.openAI] == "old-o")
    #expect(runtime.runtimeConfiguration.anthropicCredential == .missing)
    #expect(runtime.runtimeConfiguration.openAICredential == .available("old-o"))
}

@MainActor
@Test func editedEmptyFieldWithoutConfirmationDoesNotDelete() async {
    let credentials = TransactionCredentialStore([.anthropic: "old-a", .openAI: "old-o"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .available("old-a"), openAICredential: .available("old-o")))
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)
    await model.bootstrapAndWait()
    // Clearing the secure field is allowed but is NOT an implicit deletion.
    model.setDraftAPIKey("  \n", for: .anthropic)
    await model.applyAndWait()
    #expect(await credentials.values[.anthropic] == "old-a")
    #expect(runtime.runtimeConfiguration.anthropicCredential == .available("old-a"))
}

@MainActor
@Test func deleteAndUndoVisibilityRequireConfirmedSavedCredential() async {
    // anthropic present, openAI absent, and an unknown route via a load failure.
    let credentials = TransactionCredentialStore([.anthropic: "saved-a"])
    await credentials.setLoadFailure(.openAI, call: 1)
    let model = transactionModel(
        credentials: credentials,
        repository: TransactionRepository(),
        hotkeys: TransactionHotkeys(),
        runtime: RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    )
    await model.bootstrapAndWait()

    // Present credential: Delete shown, Undo hidden until an edit/deletion.
    #expect(model.credentialAvailability(for: .anthropic) == .present)
    #expect(model.canDeleteCredential(.anthropic))
    #expect(!model.canUndoCredential(.anthropic))

    // Unknown credential (load failed): neither action.
    #expect(model.credentialAvailability(for: .openAI) == .unknown)
    #expect(!model.canDeleteCredential(.openAI))
    #expect(!model.canUndoCredential(.openAI))

    // Editing a present credential exposes Undo.
    model.setDraftAPIKey("new-a", for: .anthropic)
    #expect(model.canUndoCredential(.anthropic))
    #expect(model.canDeleteCredential(.anthropic)) // still a saved credential, not pending deletion
    model.undoCredentialEdit(.anthropic)
    #expect(!model.canUndoCredential(.anthropic))

    // Confirming deletion hides Delete, shows Undo, and marks the intent.
    model.confirmCredentialDeletion(.anthropic)
    #expect(model.isPendingCredentialDeletion(.anthropic))
    #expect(!model.canDeleteCredential(.anthropic))
    #expect(model.canUndoCredential(.anthropic))
    #expect(model.draftAPIKey(for: .anthropic) == "")
}

@MainActor
@Test func typingWhenNoCredentialSavedNeverRevealsDeleteOrUndo() async {
    let model = transactionModel(
        credentials: TransactionCredentialStore(),
        repository: TransactionRepository(),
        hotkeys: TransactionHotkeys(),
        runtime: RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    )
    await model.bootstrapAndWait()
    #expect(model.credentialAvailability(for: .anthropic) == .absent)
    model.setDraftAPIKey("typed-new-key", for: .anthropic)
    #expect(!model.canDeleteCredential(.anthropic))
    #expect(!model.canUndoCredential(.anthropic))
}

@MainActor
@Test func confirmedDeletionIsDraftOnlyAndCancelSuppressesIntentAcrossLaterEdits() async {
    let credentials = TransactionCredentialStore([.anthropic: "saved-a"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .available("saved-a"), openAICredential: .missing))
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)
    await model.bootstrapAndWait()

    model.confirmCredentialDeletion(.anthropic)
    // Draft-only: nothing mutated in Keychain or runtime before apply.
    #expect(await credentials.values[.anthropic] == "saved-a")
    #expect(runtime.runtimeConfiguration.anthropicCredential == .available("saved-a"))

    // Cancel restores the saved draft and suppresses the intent.
    model.undoCredentialEdit(.anthropic)
    #expect(!model.isPendingCredentialDeletion(.anthropic))
    #expect(model.draftAPIKey(for: .anthropic) == "saved-a")

    // A later unrelated edit must not revive the deletion.
    model.anthropicTranslationModel = "claude-sonnet-5"
    await model.applyAndWait()
    #expect(await credentials.values[.anthropic] == "saved-a")
    #expect(runtime.runtimeConfiguration.anthropicCredential == .available("saved-a"))
}

@MainActor
@Test func failedPersistenceRollsBackCredentialsAndNeverPublishesDraft() async {
    let credentials = TransactionCredentialStore([.anthropic: "old"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .available("old"), openAICredential: .missing))
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)
    await model.bootstrapAndWait()
    await repository.setFailSave()
    model.anthropicTranslationModel = "claude-sonnet-5"
    model.setDraftAPIKey("staged", for: .anthropic)

    await model.applyAndWait()

    #expect(runtime.runtimeConfiguration.settings.anthropicTranslationModel == BuiltInDefaults.anthropicTranslationModel)
    #expect(await credentials.values[.anthropic] == "old")
    if case .failure = model.applyStatus {} else { Issue.record("Apply must report failure") }
}

@MainActor
@Test func everyForwardCommitBoundaryKeepsThePreviousRuntimeOnFailure() async {
    enum Failure { case anthropicCredential, openAICredential, settings, hotkeys }
    for failure in [Failure.anthropicCredential, .openAICredential, .settings, .hotkeys] {
        let credentials = TransactionCredentialStore([.anthropic: "old-a", .openAI: "old-o"])
        let repository = TransactionRepository()
        let hotkeys = TransactionHotkeys()
        let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .available("old-a"), openAICredential: .available("old-o")))
        let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)
        await model.bootstrapAndWait()
        switch failure {
        case .anthropicCredential: await credentials.setFailure("save-anthropic")
        case .openAICredential: await credentials.setFailure("save-openAI")
        case .settings: await repository.setFailSave()
        case .hotkeys: hotkeys.failPrepare = true
        }
        model.anthropicTranslationModel = "claude-sonnet-5"
        model.setDraftAPIKey("new-a", for: .anthropic)
        model.setDraftAPIKey("new-o", for: .openAI)
        await model.applyAndWait()
        #expect(runtime.runtimeConfiguration.settings == BuiltInDefaults.configuration)
        if case .failure = model.applyStatus {} else { Issue.record("Failure boundary reported success") }
    }
}

@MainActor
@Test func unregisterFailureForEachSupersededActionNeverPublishesOrReportsSuccess() async {
    for appAction in AppAction.allCases {
        let credentials = TransactionCredentialStore()
        let repository = TransactionRepository()
        let hotkeys = TransactionHotkeys()
        let previous = RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing)
        let runtime = RuntimeConfigurationStore(previous)
        let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)
        await model.bootstrapAndWait()
        hotkeys.failUnregisterAction = appAction
        if appAction == .correctSelection {
            model.correctHotkey = HotkeyDefinition(keyCode: 0, modifiers: HotkeyDefinition.commandModifier)
        } else {
            model.translateHotkey = HotkeyDefinition(keyCode: 1, modifiers: HotkeyDefinition.optionModifier)
        }

        await model.applyAndWait()

        #expect(runtime.runtimeConfiguration == previous)
        let expected = appAction == .correctSelection ? BuiltInDefaults.correctHotkey : BuiltInDefaults.translateHotkey
        #expect(hotkeys.activeDefinitions[appAction] == expected)
        if case .failure = model.applyStatus {} else { Issue.record("Unregister failure reported success for \(appAction)") }
    }
}

@MainActor
@Test func incompleteDurableRollbackReloadsActualStateAndReportsRecovery() async {
    let credentials = TransactionCredentialStore([.anthropic: "old-a"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .available("old-a"), openAICredential: .missing))
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)
    await model.bootstrapAndWait()
    model.anthropicTranslationModel = "claude-sonnet-5"
    hotkeys.failPrepare = true
    await repository.setFailRestore()
    await model.applyAndWait()
    #expect(model.anthropicTranslationModel == "claude-sonnet-5")
    #expect(runtime.runtimeConfiguration.settings == BuiltInDefaults.configuration)
    #expect(model.recoveryMessage?.contains("settings file") == true)
    #expect(model.applyStatus == .failure(EnLLMError.settingsRecoveryRequired.localizedDescription))
}

@MainActor
@Test func credentialRollbackFailureNeverActivatesDraftKeyAndReloadsDurablePresence() async {
    let credentials = TransactionCredentialStore([.anthropic: "old-a", .openAI: "old-o"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let previous = RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .available("old-a"), openAICredential: .available("old-o"))
    let runtime = RuntimeConfigurationStore(previous)
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)
    await model.bootstrapAndWait()
    hotkeys.failPrepare = true
    await credentials.setFailure("save-anthropic", call: 2)
    model.setDraftAPIKey("draft-a", for: .anthropic)

    await model.applyAndWait()

    #expect(await credentials.values[.anthropic] == "draft-a")
    #expect(runtime.runtimeConfiguration.anthropicCredential == .disabledUncertain)
    #expect(runtime.runtimeConfiguration.openAICredential == .available("old-o"))
    #expect(runtime.runtimeConfiguration.anthropicCredential != .available("draft-a"))
    #expect(model.credentialAvailability(for: .anthropic) == .present)
    #expect(model.credentialAvailability(for: .openAI) == .present)
    #expect(model.applyStatus == .failure(EnLLMError.settingsRecoveryRequired.localizedDescription))
}

@MainActor
@Test func unreadableCredentialDuringIncompleteRecoveryDisablesOnlyThatRoute() async {
    let credentials = TransactionCredentialStore([.anthropic: "old-a", .openAI: "old-o"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let previous = RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .available("old-a"), openAICredential: .available("old-o"))
    let runtime = RuntimeConfigurationStore(previous)
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)
    await model.bootstrapAndWait()
    hotkeys.failPrepare = true
    await repository.setFailRestore()
    await credentials.setLoadFailure(.openAI, call: 3)
    model.anthropicTranslationModel = "claude-sonnet-5"

    await model.applyAndWait()

    #expect(runtime.runtimeConfiguration.anthropicCredential == .available("old-a"))
    #expect(runtime.runtimeConfiguration.openAICredential == .disabledUncertain)
    #expect(model.credentialAvailability(for: .anthropic) == .present)
    #expect(model.credentialAvailability(for: .openAI) == .unknown)
    #expect(runtime.runtimeConfiguration.settings == previous.settings)
}

@MainActor
@Test func fallbackDisclosureExplicitlyIncludesMissingPrimaryCredential() {
    let model = transactionModel(
        credentials: TransactionCredentialStore(),
        repository: TransactionRepository(),
        hotkeys: TransactionHotkeys(),
        runtime: RuntimeConfigurationStore(RuntimeConfiguration(
            settings: BuiltInDefaults.configuration,
            anthropicCredential: .missing,
            openAICredential: .missing
        ))
    )

    #expect(model.fallbackEffectDescription == "If the primary provider is missing a key or fails with an approved provider error, the same selected text may be sent to OpenAI once.")
}

@MainActor
@Test func keyEditSuppressesSuspendedTestConnectionCompletion() async {
    let client = SuspendingDraftClient(.anthropic)
    let model = transactionModel(
        credentials: TransactionCredentialStore([.anthropic: "tested-key"]),
        repository: TransactionRepository(),
        hotkeys: TransactionHotkeys(),
        runtime: RuntimeConfigurationStore(RuntimeConfiguration(
            settings: BuiltInDefaults.configuration,
            anthropicCredential: .missing,
            openAICredential: .missing
        )),
        anthropic: client
    )
    await model.bootstrapAndWait()

    model.startTestConnection(for: .anthropic)
    while !(await client.isSuspended) { await Task.yield() }
    model.setDraftAPIKey("edited-key", for: .anthropic)
    #expect(!model.isTesting(.anthropic))
    #expect(model.status(for: .anthropic) == .idle)

    await client.succeed()
    await Task.yield()
    #expect(model.status(for: .anthropic) == .idle)
}

@MainActor
@Test func modelEditSuppressesSuspendedTestConnectionCompletion() async {
    let client = SuspendingDraftClient(.anthropic)
    let model = transactionModel(
        credentials: TransactionCredentialStore([.anthropic: "tested-key"]),
        repository: TransactionRepository(),
        hotkeys: TransactionHotkeys(),
        runtime: RuntimeConfigurationStore(RuntimeConfiguration(
            settings: BuiltInDefaults.configuration,
            anthropicCredential: .missing,
            openAICredential: .missing
        )),
        anthropic: client
    )
    await model.bootstrapAndWait()
    model.anthropicTranslationModel = "claude-sonnet-5"

    model.startTestConnection(for: .anthropic)
    while !(await client.isSuspended) { await Task.yield() }
    model.anthropicTranslationModel = "claude-haiku-4-5"
    #expect(!model.isTesting(.anthropic))
    #expect(model.status(for: .anthropic) == .idle)

    await client.succeed()
    await Task.yield()
    #expect(model.status(for: .anthropic) == .idle)
}

@MainActor
@Test func autosaveDoesNotCancelInFlightTestConnection() async {
    let client = SuspendingDraftClient(.anthropic)
    let model = transactionModel(
        credentials: TransactionCredentialStore([.anthropic: "tested-key"]),
        repository: TransactionRepository(),
        hotkeys: TransactionHotkeys(),
        runtime: RuntimeConfigurationStore(RuntimeConfiguration(
            settings: BuiltInDefaults.configuration,
            anthropicCredential: .available("tested-key"),
            openAICredential: .missing
        )),
        anthropic: client
    )
    await model.bootstrapAndWait()

    model.startTestConnection(for: .anthropic)
    while !(await client.isSuspended) { await Task.yield() }
    // An unrelated valid edit + autosave commit must NOT cancel the in-flight test.
    model.correctionInstruction = "unrelated valid edit"
    await model.applyAndWait()
    #expect(model.isTesting(.anthropic))

    await client.succeed()
    while model.isTesting(.anthropic) { await Task.yield() }
    #expect(model.status(for: .anthropic) == .success("Anthropic connection succeeded."))
}

@MainActor
@Test func testConnectionTestsBothDistinctDraftModelsWithFixedContent() async {
    let credentials = TransactionCredentialStore([.anthropic: "stored"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .available("stored"), openAICredential: .missing))
    let client = DraftClient(.anthropic)
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime, anthropic: client)
    await model.bootstrapAndWait()
    // Correction stays claude-haiku-4-5 (default); translation becomes claude-sonnet-5 -> two distinct models.
    model.anthropicTranslationModel = "claude-sonnet-5"
    model.startTestConnection(for: .anthropic)
    while model.isTesting(.anthropic) { await Task.yield() }
    let requests = await client.requests
    #expect(Set(requests.map(\.model)) == ["claude-haiku-4-5", "claude-sonnet-5"])
    #expect(requests.allSatisfy { $0.instruction == BuiltInDefaults.connectionTestInstruction })
    #expect(requests.allSatisfy { $0.userText == BuiltInDefaults.connectionTestUserText })
    #expect(model.status(for: .anthropic) == .success("Anthropic connection succeeded."))
    // Test Connection flushes the pending valid snapshot, so the tested selection is now durable.
    #expect(runtime.runtimeConfiguration.settings.anthropicTranslationModel == "claude-sonnet-5")
}

@MainActor
@Test func testConnectionIssuesOneRequestWhenBothActionsSelectTheSameModel() async {
    let credentials = TransactionCredentialStore([.openAI: "stored"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let client = DraftClient(.openAI)
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime, openAI: client)
    await model.bootstrapAndWait()
    // Both OpenAI actions default to gpt-5.4-mini -> a single deduplicated request.
    model.startTestConnection(for: .openAI)
    while model.isTesting(.openAI) { await Task.yield() }
    let requests = await client.requests
    #expect(requests.count == 1)
    #expect(requests.first?.model == "gpt-5.4-mini")
    #expect(model.status(for: .openAI) == .success("OpenAI connection succeeded."))
}

@MainActor
@Test func testConnectionIdentifiesWhichSelectedModelFailed() async {
    let credentials = TransactionCredentialStore([.openAI: "stored"])
    let client = ModelFailingClient(.openAI, failingModel: "gpt-5.6-luna", error: EnLLMError.providerRateLimited(.openAI))
    let model = transactionModel(
        credentials: credentials,
        repository: TransactionRepository(),
        hotkeys: TransactionHotkeys(),
        runtime: RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing)),
        openAI: client
    )
    await model.bootstrapAndWait()
    // Correction gpt-5.4-mini succeeds; translation gpt-5.6-luna fails.
    model.openAITranslationModel = "gpt-5.6-luna"
    model.startTestConnection(for: .openAI)
    while model.isTesting(.openAI) { await Task.yield() }
    let message = model.statusMessage(for: .openAI)
    #expect(message?.contains("translation model (gpt-5.6-luna)") == true)
    if case .failure = model.status(for: .openAI) {} else { Issue.record("Expected a failure status") }
}

@MainActor
@Test func applyCleanRollbackSanitizesUnknownPersistenceError() async {
    let credentials = TransactionCredentialStore([.anthropic: "old"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .available("old"), openAICredential: .missing))
    let model = transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime)
    await model.bootstrapAndWait()
    await repository.setSaveError(UnsafeSettingsError(errorDescription: leakSentinel))
    model.anthropicTranslationModel = "claude-sonnet-5"

    await model.applyAndWait()

    #expect(model.applyStatus == .failure("Something went wrong. Please try again."))
    if case .failure(let message) = model.applyStatus {
        #expect(!message.contains(leakSentinel))
    } else {
        Issue.record("Apply must report failure")
    }
}

@MainActor
@Test func testConnectionSanitizesUnknownProviderError() async {
    let client = ThrowingDraftClient(.anthropic, error: UnsafeSettingsError(errorDescription: leakSentinel))
    let model = transactionModel(
        credentials: TransactionCredentialStore([.anthropic: "stored"]),
        repository: TransactionRepository(),
        hotkeys: TransactionHotkeys(),
        runtime: RuntimeConfigurationStore(RuntimeConfiguration(
            settings: BuiltInDefaults.configuration,
            anthropicCredential: .missing,
            openAICredential: .missing
        )),
        anthropic: client
    )
    await model.bootstrapAndWait()

    model.startTestConnection(for: .anthropic)
    while model.isTesting(.anthropic) { await Task.yield() }

    // The per-model wrapper adds only safe identifiers; the sanitized error must still appear and the sentinel must not.
    let message = model.statusMessage(for: .anthropic)
    #expect(message?.contains("Something went wrong. Please try again.") == true)
    #expect(message?.contains(leakSentinel) == false)
    if case .failure = model.status(for: .anthropic) {} else { Issue.record("Expected a failure status") }
}

@MainActor
@Test func testConnectionMissingKeyKeepsActionableMessage() async {
    let model = transactionModel(
        credentials: TransactionCredentialStore(),
        repository: TransactionRepository(),
        hotkeys: TransactionHotkeys(),
        runtime: RuntimeConfigurationStore(RuntimeConfiguration(
            settings: BuiltInDefaults.configuration,
            anthropicCredential: .missing,
            openAICredential: .missing
        ))
    )
    await model.bootstrapAndWait()

    model.startTestConnection(for: .anthropic)

    #expect(model.status(for: .anthropic) == .failure("Add an API key for Anthropic in Settings."))
}

@MainActor
@Test func resetRestoresTheFourCatalogModelDefaults() async {
    let model = transactionModel(
        credentials: TransactionCredentialStore(),
        repository: TransactionRepository(),
        hotkeys: TransactionHotkeys(),
        runtime: RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    )
    await model.bootstrapAndWait()
    model.openAICorrectionModel = "gpt-5.6-luna"
    model.openAITranslationModel = "gpt-5.6-luna"
    model.anthropicTranslationModel = "claude-sonnet-5"

    model.resetModelsAndPrompts()

    #expect(model.openAICorrectionModel == "gpt-5.4-mini")
    #expect(model.openAITranslationModel == "gpt-5.4-mini")
    #expect(model.anthropicCorrectionModel == "claude-haiku-4-5")
    #expect(model.anthropicTranslationModel == "claude-haiku-4-5")
    #expect(model.draftConfiguration.validationIssues.isEmpty)
}

@MainActor
@Test func bootstrapNormalizesDisallowedLoadedModelSelectionToDefault() async {
    // A persisted-but-now-disallowed selection (e.g. sonnet for correction) must be
    // normalized so the UI never presents an invalid choice.
    let loaded = NonSecretConfiguration(
        primaryProvider: .anthropic,
        fallbackEnabled: true,
        openAICorrectionModel: "gpt-5.4-mini",
        openAITranslationModel: "gpt-5.6-luna",
        anthropicCorrectionModel: "claude-sonnet-5",
        anthropicTranslationModel: "claude-sonnet-5",
        correctionInstruction: "c",
        translationInstruction: "t",
        correctHotkey: BuiltInDefaults.correctHotkey,
        translateHotkey: BuiltInDefaults.translateHotkey
    )
    let model = transactionModel(
        credentials: TransactionCredentialStore(),
        repository: TransactionRepository(loaded),
        hotkeys: TransactionHotkeys(),
        runtime: RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    )
    await model.bootstrapAndWait()
    #expect(model.anthropicCorrectionModel == "claude-haiku-4-5") // normalized
    #expect(model.anthropicTranslationModel == "claude-sonnet-5") // still allowed
    #expect(model.draftConfiguration.validationIssues.isEmpty)
}

// MARK: - BL-021 shortcut recording UX

@MainActor
private func recordingModel(_ hotkeys: TransactionHotkeys = TransactionHotkeys()) -> ProviderSettingsModel {
    transactionModel(
        credentials: TransactionCredentialStore(),
        repository: TransactionRepository(),
        hotkeys: hotkeys,
        runtime: RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    )
}

@MainActor
@Test func recordingCapturesValidModifiedShortcutOnceAndEndsRecording() async {
    let hotkeys = TransactionHotkeys()
    let model = recordingModel(hotkeys)
    await model.bootstrapAndWait()
    model.beginRecording(.correctSelection)
    #expect(model.isRecording(.correctSelection))
    #expect(hotkeys.recording == .correctSelection)

    let outcome = model.handleRecordedKey(keyCode: 0, modifiers: HotkeyDefinition.commandModifier, for: .correctSelection)

    #expect(outcome == .recorded(HotkeyDefinition(keyCode: 0, modifiers: HotkeyDefinition.commandModifier)))
    #expect(model.correctHotkey == HotkeyDefinition(keyCode: 0, modifiers: HotkeyDefinition.commandModifier))
    #expect(!model.isRecording(.correctSelection))
    #expect(hotkeys.recording == nil)
    #expect(model.recordingMessage(for: .correctSelection) == nil)
}

@MainActor
@Test func recordingRejectsModifierOnlyAndUnsupportedKeysInlineWithoutChange() async {
    let model = recordingModel()
    await model.bootstrapAndWait()
    let original = model.correctHotkey
    model.beginRecording(.correctSelection)

    #expect(model.handleRecordedKey(keyCode: 0, modifiers: 0, for: .correctSelection) == .rejectedInvalid)
    #expect(model.handleRecordedKey(keyCode: 255, modifiers: HotkeyDefinition.commandModifier, for: .correctSelection) == .rejectedInvalid)
    #expect(model.correctHotkey == original)
    #expect(model.isRecording(.correctSelection)) // still recording after a rejection
    #expect(model.recordingMessage(for: .correctSelection) != nil)
}

@MainActor
@Test func recordingRejectsDuplicateOfOtherActionInlineWithoutChange() async {
    let model = recordingModel()
    await model.bootstrapAndWait()
    let original = model.correctHotkey
    model.beginRecording(.correctSelection)

    // The default translate shortcut is ⌥T (keyCode 17, option); recording it for correct duplicates it.
    let outcome = model.handleRecordedKey(keyCode: 17, modifiers: HotkeyDefinition.optionModifier, for: .correctSelection)

    #expect(outcome == .rejectedDuplicate)
    #expect(model.correctHotkey == original)
    #expect(model.translateHotkey == BuiltInDefaults.translateHotkey)
    #expect(model.recordingMessage(for: .correctSelection) != nil)
}

@MainActor
@Test func escapeCancelRecordingLeavesShortcutUnchangedAndClearsState() async {
    let hotkeys = TransactionHotkeys()
    let model = recordingModel(hotkeys)
    await model.bootstrapAndWait()
    let original = model.correctHotkey
    model.beginRecording(.correctSelection)
    // Seed inline feedback with a rejection so we can prove cancel clears it.
    _ = model.handleRecordedKey(keyCode: 0, modifiers: 0, for: .correctSelection)
    #expect(model.recordingMessage(for: .correctSelection) != nil)

    model.cancelRecording(for: .correctSelection)

    #expect(model.correctHotkey == original)
    #expect(!model.isRecording(.correctSelection))
    #expect(hotkeys.recording == nil)
    #expect(model.recordingMessage(for: .correctSelection) == nil)
}

@MainActor
@Test func terminationClearsActiveRecordingState() async {
    let hotkeys = TransactionHotkeys()
    let model = recordingModel(hotkeys)
    await model.bootstrapAndWait()
    model.beginRecording(.translateSelectionToUkrainian)
    #expect(hotkeys.recording == .translateSelectionToUkrainian)

    await model.prepareForTermination()

    #expect(model.activeRecordingAction == nil)
    #expect(hotkeys.recording == nil)
}

// MARK: - BL-020 debounced transactional autosave

private func waitForSave(_ repository: TransactionRepository, atLeast count: Int) async {
    for _ in 0..<400 {
        if await repository.saveCount >= count { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func autosaveModel(
    _ repository: TransactionRepository,
    runtime: RuntimeConfigurationStore,
    credentials: TransactionCredentialStore = TransactionCredentialStore(),
    hotkeys: TransactionHotkeys = TransactionHotkeys(),
    delay: Duration = .milliseconds(20)
) -> ProviderSettingsModel {
    transactionModel(credentials: credentials, repository: repository, hotkeys: hotkeys, runtime: runtime, autosaveDelay: delay)
}

@MainActor
@Test func debouncedValidEditAutosavesExactlyOnce() async {
    let repository = TransactionRepository()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let model = autosaveModel(repository, runtime: runtime)
    await model.bootstrapAndWait()

    model.correctionInstruction = "edited once"
    await waitForSave(repository, atLeast: 1)
    try? await Task.sleep(for: .milliseconds(40))

    #expect(await repository.saveCount == 1)
    #expect(runtime.runtimeConfiguration.settings.correctionInstruction == "edited once")
    #expect(model.applyStatus == .saved)
}

@MainActor
@Test func rapidEditsCoalesceIntoASingleCommit() async {
    let repository = TransactionRepository()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let model = autosaveModel(repository, runtime: runtime, delay: .milliseconds(40))
    await model.bootstrapAndWait()

    model.correctionInstruction = "a"
    model.correctionInstruction = "b"
    model.correctionInstruction = "c"
    await waitForSave(repository, atLeast: 1)
    try? await Task.sleep(for: .milliseconds(60))

    #expect(await repository.saveCount == 1)
    #expect(runtime.runtimeConfiguration.settings.correctionInstruction == "c")
}

@MainActor
@Test func invalidDraftIsNotAutosavedAndKeepsLastGoodRuntime() async {
    let repository = TransactionRepository()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let model = autosaveModel(repository, runtime: runtime)
    await model.bootstrapAndWait()

    model.correctionInstruction = "" // invalid (blank)
    try? await Task.sleep(for: .milliseconds(60))

    #expect(await repository.saveCount == 0)
    #expect(!model.draftConfiguration.validationIssues.isEmpty)
    #expect(runtime.runtimeConfiguration.settings.correctionInstruction == BuiltInDefaults.correctionInstruction)
    #expect(model.correctionInstruction == "") // editable value preserved for correction
}

@MainActor
@Test func editDuringCommitCoalescesToNewestValidSnapshot() async {
    let repository = TransactionRepository()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let model = autosaveModel(repository, runtime: runtime)
    await model.bootstrapAndWait()
    await repository.suspendNextSave()

    model.correctionInstruction = "first"
    model.apply()
    while !(await repository.isSaveSuspended()) { await Task.yield() }
    model.correctionInstruction = "second" // valid edit during the in-flight commit
    await repository.resumeSave()
    await waitForSave(repository, atLeast: 2)
    try? await Task.sleep(for: .milliseconds(40))

    #expect(await repository.saveCount == 2)
    #expect(runtime.runtimeConfiguration.settings.correctionInstruction == "second")
}

@MainActor
@Test func staleSuccessIsSuppressedWhenANewerInvalidEditArrives() async {
    let repository = TransactionRepository()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let model = autosaveModel(repository, runtime: runtime)
    await model.bootstrapAndWait()
    await repository.suspendNextSave()

    model.correctionInstruction = "first"
    model.apply()
    while !(await repository.isSaveSuspended()) { await Task.yield() }
    model.correctionInstruction = "" // newer INVALID edit
    await repository.resumeSave()
    while model.isApplying { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))

    // The committed "first" is durable, but the stale Saved status must not show over an invalid draft.
    #expect(runtime.runtimeConfiguration.settings.correctionInstruction == "first")
    #expect(model.applyStatus != .saved)
    #expect(!model.draftConfiguration.validationIssues.isEmpty)
}

@MainActor
@Test func settingsCloseFlushesPendingValidEdit() async {
    let repository = TransactionRepository()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let model = autosaveModel(repository, runtime: runtime, delay: .milliseconds(600))
    await model.bootstrapAndWait()

    model.correctionInstruction = "closing edit"
    model.settingsDidDisappear() // flushes into an immediate commit
    await waitForSave(repository, atLeast: 1)

    #expect(await repository.saveCount == 1)
    #expect(runtime.runtimeConfiguration.settings.correctionInstruction == "closing edit")
}

@MainActor
@Test func quitIsBlockedByAnUncommittableInvalidEditUntilSafeDiscard() async {
    let repository = TransactionRepository()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let model = autosaveModel(repository, runtime: runtime, delay: .milliseconds(600))
    await model.bootstrapAndWait()

    model.correctionInstruction = "" // invalid, uncommittable

    let firstAttempt = await model.prepareForTermination()
    #expect(!firstAttempt)
    #expect(model.needsSafeDiscardConfirmation)
    #expect(!model.isTerminating)

    model.confirmSafeDiscard()
    let secondAttempt = await model.prepareForTermination()
    #expect(secondAttempt)
    #expect(model.isTerminating)
}

@MainActor
@Test func incompleteRecoveryBlocksQuitAndRemainsVisible() async {
    let credentials = TransactionCredentialStore([.anthropic: "old-a"])
    let repository = TransactionRepository()
    let hotkeys = TransactionHotkeys()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .available("old-a"), openAICredential: .missing))
    let model = autosaveModel(repository, runtime: runtime, credentials: credentials, hotkeys: hotkeys, delay: .milliseconds(600))
    await model.bootstrapAndWait()

    hotkeys.failPrepare = true
    await repository.setFailRestore()
    model.correctionInstruction = "triggers recovery"
    await model.applyAndWait()

    #expect(model.applyStatus == .failure(EnLLMError.settingsRecoveryRequired.localizedDescription))
    #expect(model.needsSafeDiscardConfirmation)

    let blocked = await model.prepareForTermination()
    #expect(!blocked)
    // The recovery error is not cleared by the blocked quit attempt.
    #expect(model.applyStatus == .failure(EnLLMError.settingsRecoveryRequired.localizedDescription))

    model.confirmSafeDiscard()
    #expect(await model.prepareForTermination())
}

@MainActor
@Test func confirmedDeletionAutosavesThroughTheTransaction() async {
    let credentials = TransactionCredentialStore([.anthropic: "saved-a", .openAI: "saved-o"])
    let repository = TransactionRepository()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .available("saved-a"), openAICredential: .available("saved-o")))
    let model = autosaveModel(repository, runtime: runtime, credentials: credentials)
    await model.bootstrapAndWait()

    model.confirmCredentialDeletion(.anthropic)
    await waitForSave(repository, atLeast: 1)

    #expect(await credentials.values[.anthropic] == nil)
    #expect(await credentials.values[.openAI] == "saved-o")
    #expect(runtime.runtimeConfiguration.anthropicCredential == .missing)
}

@MainActor
@Test func recordedShortcutAutosavesThroughTheTransaction() async {
    let hotkeys = TransactionHotkeys()
    let repository = TransactionRepository()
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(settings: BuiltInDefaults.configuration, anthropicCredential: .missing, openAICredential: .missing))
    let model = autosaveModel(repository, runtime: runtime, hotkeys: hotkeys)
    await model.bootstrapAndWait()

    model.beginRecording(.correctSelection)
    let recorded = HotkeyDefinition(keyCode: 0, modifiers: HotkeyDefinition.commandModifier)
    _ = model.handleRecordedKey(keyCode: 0, modifiers: HotkeyDefinition.commandModifier, for: .correctSelection)
    await waitForSave(repository, atLeast: 1)

    #expect(runtime.runtimeConfiguration.settings.correctHotkey == recorded)
    #expect(hotkeys.activeDefinitions[.correctSelection] == recorded)
}
