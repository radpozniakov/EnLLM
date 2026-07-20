import Combine
import EnLLMCore
import EnLLMPlatform
import Foundation

@MainActor
final class ProviderSettingsModel: ObservableObject {
    enum Status: Equatable { case idle, saving, saved, success(String), failure(String) }
    enum CredentialAvailability: Equatable { case unknown, absent, present }

    @Published var primaryProvider: LLMProvider { didSet { if primaryProvider != oldValue { draftDidChange() } } }
    @Published var fallbackEnabled: Bool { didSet { if fallbackEnabled != oldValue { draftDidChange() } } }
    @Published var openAICorrectionModel: String {
        didSet { if openAICorrectionModel != oldValue { invalidateTest(for: .openAI); draftDidChange() } }
    }
    @Published var openAITranslationModel: String {
        didSet { if openAITranslationModel != oldValue { invalidateTest(for: .openAI); draftDidChange() } }
    }
    @Published var anthropicCorrectionModel: String {
        didSet { if anthropicCorrectionModel != oldValue { invalidateTest(for: .anthropic); draftDidChange() } }
    }
    @Published var anthropicTranslationModel: String {
        didSet { if anthropicTranslationModel != oldValue { invalidateTest(for: .anthropic); draftDidChange() } }
    }
    @Published var correctionInstruction: String { didSet { if correctionInstruction != oldValue { draftDidChange() } } }
    @Published var translationInstruction: String { didSet { if translationInstruction != oldValue { draftDidChange() } } }
    @Published var correctHotkey: HotkeyDefinition { didSet { if correctHotkey != oldValue { draftDidChange() } } }
    @Published var translateHotkey: HotkeyDefinition { didSet { if translateHotkey != oldValue { draftDidChange() } } }
    @Published private(set) var isApplying = false
    @Published private(set) var isBootstrapped = false
    @Published private(set) var applyStatus: Status = .idle
    @Published private(set) var recoveryMessage: String?
    // Shortcut recording UX state (BL-021), exposed for the recorder view and VoiceOver.
    @Published private(set) var activeRecordingAction: AppAction?
    @Published private(set) var recordingFeedback: [AppAction: String] = [:]
    @Published private var providerStates: [LLMProvider: ProviderState]

    private let credentialStore: any CredentialStoring
    private let settingsRepository: any SettingsPersisting
    private let hotkeyRegistrar: any HotkeyRegistering
    private let runtimeStore: any RuntimeConfigurationPublishing
    private let anthropicClient: any LLMProviderClient
    private let openAIClient: any LLMProviderClient
    private var activeCredentials: [LLMProvider: RuntimeCredential] = [.anthropic: .missing, .openAI: .missing]
    private var editedCredentialProviders: Set<LLMProvider> = []
    // Confirmed deletion intents (BL-018). A pending deletion is a draft-only intent;
    // Keychain/runtime are mutated only by the whole-snapshot commit.
    private var pendingDeletionProviders: Set<LLMProvider> = []
    private var bootstrapTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var testTasks: [LLMProvider: Task<Void, Never>] = [:]
    private var actionDispatch: (@MainActor @Sendable (AppAction) -> Void) = { _ in }
    private(set) var isTerminating = false
    // Debounced transactional autosave (BL-020).
    private let autosaveDelay: Duration
    private var autosaveTask: Task<Void, Never>?
    private var pendingRecommit = false
    private var blockedByRecovery = false
    private var suppressDraftObservation = false
    private var editGeneration = 0
    private var safeDiscardConfirmed = false
    /// True when the last completed commit ended in incomplete rollback/recovery and
    /// the user has not resolved it; termination stays blocked until a safe discard.
    private(set) var needsSafeDiscardConfirmation = false

    init(
        credentialStore: any CredentialStoring,
        anthropicClient: any LLMProviderClient,
        openAIClient: any LLMProviderClient,
        settingsRepository: (any SettingsPersisting)? = nil,
        hotkeyRegistrar: (any HotkeyRegistering)? = nil,
        runtimeStore: (any RuntimeConfigurationPublishing)? = nil,
        autosaveDelay: Duration = .milliseconds(600)
    ) {
        precondition(anthropicClient.provider == .anthropic && openAIClient.provider == .openAI)
        self.autosaveDelay = autosaveDelay
        let defaults = BuiltInDefaults.configuration
        primaryProvider = defaults.primaryProvider
        fallbackEnabled = defaults.fallbackEnabled
        openAICorrectionModel = defaults.openAICorrectionModel
        openAITranslationModel = defaults.openAITranslationModel
        anthropicCorrectionModel = defaults.anthropicCorrectionModel
        anthropicTranslationModel = defaults.anthropicTranslationModel
        correctionInstruction = defaults.correctionInstruction
        translationInstruction = defaults.translationInstruction
        correctHotkey = defaults.correctHotkey
        translateHotkey = defaults.translateHotkey
        self.credentialStore = credentialStore
        self.anthropicClient = anthropicClient
        self.openAIClient = openAIClient
        self.settingsRepository = settingsRepository ?? EphemeralSettingsRepository()
        self.hotkeyRegistrar = hotkeyRegistrar ?? DefaultHotkeyRegistrar()
        self.runtimeStore = runtimeStore ?? RuntimeConfigurationStore(RuntimeConfiguration(
            settings: defaults,
            anthropicCredential: .missing,
            openAICredential: .missing
        ))
        providerStates = Dictionary(uniqueKeysWithValues: LLMProvider.allCases.map { ($0, ProviderState()) })
    }

    var draftConfiguration: NonSecretConfiguration {
        NonSecretConfiguration(
            primaryProvider: primaryProvider,
            fallbackEnabled: fallbackEnabled,
            openAICorrectionModel: openAICorrectionModel,
            openAITranslationModel: openAITranslationModel,
            anthropicCorrectionModel: anthropicCorrectionModel,
            anthropicTranslationModel: anthropicTranslationModel,
            correctionInstruction: correctionInstruction,
            translationInstruction: translationInstruction,
            correctHotkey: correctHotkey,
            translateHotkey: translateHotkey
        )
    }

    /// The current draft model selection for a provider/action, and its binding setter.
    func selectedModel(for provider: LLMProvider, action: AppAction) -> String {
        draftConfiguration.model(for: provider, action: action)
    }

    func setSelectedModel(_ model: String, for provider: LLMProvider, action: AppAction) {
        switch (provider, action) {
        case (.openAI, .correctSelection): openAICorrectionModel = model
        case (.openAI, .translateSelectionToUkrainian): openAITranslationModel = model
        case (.anthropic, .correctSelection): anthropicCorrectionModel = model
        case (.anthropic, .translateSelectionToUkrainian): anthropicTranslationModel = model
        }
    }

    /// The provider's distinct selected models in action order (correction first),
    /// collapsing a duplicate so an equal correction/translation choice tests once.
    func distinctSelectedModels(for provider: LLMProvider) -> [(action: AppAction, model: String)] {
        let correction = selectedModel(for: provider, action: .correctSelection)
        let translation = selectedModel(for: provider, action: .translateSelectionToUkrainian)
        var result: [(action: AppAction, model: String)] = [(.correctSelection, correction)]
        if translation != correction { result.append((.translateSelectionToUkrainian, translation)) }
        return result
    }

    var validationIssues: [SettingsValidationIssue] { draftConfiguration.validationIssues }

    func configureActionDispatch(_ action: @escaping @MainActor @Sendable (AppAction) -> Void) {
        actionDispatch = action
    }

    func bootstrap() {
        guard bootstrapTask == nil, !isBootstrapped, !isTerminating else { return }
        bootstrapTask = Task { [weak self] in
            await self?.performBootstrap()
            self?.bootstrapTask = nil
        }
    }

    func bootstrapAndWait() async {
        bootstrap()
        await bootstrapTask?.value
    }

    private func performBootstrap() async {
        let loaded = await settingsRepository.load()
        guard !isTerminating else { return }
        let configuration = loaded.configuration
        var credentials: [LLMProvider: RuntimeCredential] = [:]
        var availability: [LLMProvider: CredentialAvailability] = [:]
        var credentialRecoveryMessage: String?
        for provider in LLMProvider.allCases {
            do {
                let credential = try await credentialStore.loadCredential(for: provider)
                credentials[provider] = runtimeCredential(credential)
                availability[provider] = credential == nil ? .absent : .present
            } catch {
                credentials[provider] = .disabledUncertain
                availability[provider] = .unknown
                credentialRecoveryMessage = "A stored \(provider.displayName) credential could not be verified. That route is disabled until Settings is applied."
            }
            guard !isTerminating else { return }
        }

        do {
            try hotkeyRegistrar.prepare(
                correct: configuration.correctHotkey,
                translate: configuration.translateHotkey,
                action: actionDispatch
            )
            hotkeyRegistrar.activate()
        } catch {
            applyStatus = .failure("Saved shortcuts could not be registered. Menu actions remain available.")
        }
        guard !isTerminating else {
            _ = hotkeyRegistrar.rollback()
            return
        }

        // Publish the same normalized configuration the draft shows, so the runtime
        // (and LLMRouter) can never operate on a disallowed persisted model selection
        // and the draft is not spuriously dirty right after bootstrap.
        let normalized = configuration.normalizingModels()
        applyDraft(normalized)
        activeCredentials = credentials
        for provider in LLMProvider.allCases {
            updateState(for: provider) { $0.credentialAvailability = availability[provider, default: .unknown] }
        }
        if case .recoveredDefaults(let message) = loaded.recovery { recoveryMessage = message }
        if let credentialRecoveryMessage { recoveryMessage = credentialRecoveryMessage }
        runtimeStore.publish(makeRuntime(configuration: normalized, credentials: credentials))
        isBootstrapped = true
    }

    /// True when the draft or credential intents differ from the active runtime.
    private var isDirty: Bool {
        draftConfiguration != runtimeStore.runtimeConfiguration.settings
            || !editedCredentialProviders.isEmpty
            || !pendingDeletionProviders.isEmpty
    }

    // MARK: - Debounced transactional autosave

    /// A draft change occurred. A fresh edit clears a prior recovery block (the user
    /// may retry), bumps the edit generation for stale-status suppression, and re-arms
    /// the debounce. Programmatic draft loads (bootstrap/recovery) are suppressed.
    private func draftDidChange() {
        guard isBootstrapped, !isTerminating, !suppressDraftObservation else { return }
        editGeneration &+= 1
        blockedByRecovery = false
        needsSafeDiscardConfirmation = false
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard draftConfiguration.validationIssues.isEmpty else {
            // Invalid drafts are never autosaved: keep the last good active runtime and
            // let the view show inline validation; drop any stale routine status.
            if applyStatus == .saving || applyStatus == .saved { applyStatus = .idle }
            return
        }
        guard isDirty else {
            // The draft matches the active runtime; there is nothing to save. Clear a
            // stale routine or recovery status left over from an earlier commit.
            applyStatus = .idle
            return
        }
        autosaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self.autosaveTask = nil
            self.commit()
        }
    }

    /// Starts one whole-snapshot commit, serializing behind any in-flight commit and
    /// coalescing to the newest valid snapshot.
    private func commit() {
        guard isBootstrapped, !isTerminating, !blockedByRecovery else { return }
        guard isDirty, draftConfiguration.validationIssues.isEmpty else { return }
        guard applyTask == nil else { pendingRecommit = true; return }
        let generation = editGeneration
        let snapshot = captureApplySnapshot()
        isApplying = true
        applyStatus = .saving
        applyTask = Task { [weak self] in
            await self?.performApply(snapshot, generation: generation)
            self?.completeCommit()
        }
    }

    private func completeCommit() {
        applyTask = nil
        isApplying = false
        // An incomplete recovery remains visible and drops the coalesced recommit;
        // only a fresh user edit (which clears blockedByRecovery) may retry.
        guard !blockedByRecovery else { pendingRecommit = false; return }
        if pendingRecommit {
            pendingRecommit = false
            if isDirty, draftConfiguration.validationIssues.isEmpty { commit() }
        }
    }

    /// Flushes any pending debounce and awaits the current and any coalesced commit.
    /// Used by Test Connection, Settings close, Quit, and tests.
    func flushAndAwaitAutosave() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        if applyTask == nil, !blockedByRecovery, isDirty, draftConfiguration.validationIssues.isEmpty {
            commit()
        }
        while let task = applyTask { await task.value }
    }

    // Compatibility triggers for tests and explicit "save now" call sites: commit the
    // current valid draft immediately, bypassing the debounce.
    func apply() {
        autosaveTask?.cancel()
        autosaveTask = nil
        commit()
    }

    func applyAndWait() async {
        apply()
        while let task = applyTask { await task.value }
    }

    private func performApply(_ snapshot: ApplySnapshot, generation: Int) async {
        let candidate = snapshot.draft.configuration
        let previousRuntime = runtimeStore.runtimeConfiguration
        var settingsSnapshot: SettingsStoreSnapshot?
        var oldCredentials: [LLMProvider: String?] = [:]
        var mutatedProviders: [LLMProvider] = []
        var settingsWriteAttempted = false

        do {
            settingsSnapshot = try await settingsRepository.snapshot()
            for provider in LLMProvider.allCases {
                oldCredentials[provider] = try await credentialStore.loadCredential(for: provider)
            }
            var candidateCredentials = Dictionary(uniqueKeysWithValues: LLMProvider.allCases.map {
                ($0, runtimeCredential(oldCredentials[$0] ?? nil))
            })
            for provider in LLMProvider.allCases {
                switch snapshot.draft.credential(for: provider) {
                case .unchanged:
                    break
                case .delete:
                    mutatedProviders.append(provider)
                    try await credentialStore.deleteCredential(for: provider)
                    candidateCredentials[provider] = .missing
                case .replace(let credential):
                    mutatedProviders.append(provider)
                    try await credentialStore.saveCredential(credential, for: provider)
                    candidateCredentials[provider] = .available(credential)
                }
            }
            settingsWriteAttempted = true
            try await settingsRepository.save(candidate)
            try hotkeyRegistrar.prepare(correct: candidate.correctHotkey, translate: candidate.translateHotkey, action: actionDispatch)

            // Preparation owns every fallible Carbon operation. Activation and publication cannot fail or suspend.
            hotkeyRegistrar.activate()
            runtimeStore.publish(makeRuntime(configuration: candidate, credentials: candidateCredentials))
            activeCredentials = candidateCredentials
            for provider in LLMProvider.allCases {
                if snapshot.draft.credential(for: provider) != .unchanged,
                   state(for: provider).draftRevision == snapshot.revisions[provider, default: -1] {
                    editedCredentialProviders.remove(provider)
                    pendingDeletionProviders.remove(provider)
                    clearCredentialDraft(for: provider)
                }
                updateAvailability(for: provider)
            }
            recoveryMessage = nil
            // Suppress a stale "Saved" if a newer edit has since arrived.
            applyStatus = (generation == editGeneration) ? .saved : .idle
        } catch {
            var rollbackProblems: [String] = []
            var uncertainProviders: Set<LLMProvider> = []
            // A throwing prepare attempts restoration internally and reports uncertainty.
            if case .uncertain = hotkeyRegistrar.lastRollbackResult { rollbackProblems.append("shortcuts") }
            if settingsWriteAttempted, let settingsSnapshot {
                do { try await settingsRepository.restore(settingsSnapshot) } catch { rollbackProblems.append("settings file") }
            }
            for provider in mutatedProviders.reversed() {
                do {
                    if let old = oldCredentials[provider] ?? nil { try await credentialStore.saveCredential(old, for: provider) }
                    else { try await credentialStore.deleteCredential(for: provider) }
                } catch {
                    rollbackProblems.append("\(provider.displayName) credential")
                    uncertainProviders.insert(provider)
                }
            }
            runtimeStore.publish(previousRuntime)
            if rollbackProblems.isEmpty {
                // A routine (fully rolled-back) failure may be suppressed as stale.
                applyStatus = (generation == editGeneration) ? .failure(ErrorPresentation.present(error).message) : .idle
            } else {
                // Incomplete recovery is never suppressed and blocks further autosave.
                await recoverActualState(
                    problems: rollbackProblems,
                    uncertainProviders: uncertainProviders,
                    previousRuntime: previousRuntime
                )
            }
        }
    }

    private func recoverActualState(
        problems: [String],
        uncertainProviders: Set<LLMProvider>,
        previousRuntime: RuntimeConfiguration
    ) async {
        let loaded = await settingsRepository.load()
        applyDraft(loaded.configuration)
        var disabledProviders = uncertainProviders
        var durableAvailability: [LLMProvider: CredentialAvailability] = [:]
        for provider in LLMProvider.allCases {
            do {
                let value = try await credentialStore.loadCredential(for: provider)
                durableAvailability[provider] = runtimeCredential(value) == .missing ? .absent : .present
            } catch {
                durableAvailability[provider] = .unknown
                disabledProviders.insert(provider)
            }
        }
        let safeCredentials = Dictionary(uniqueKeysWithValues: LLMProvider.allCases.map { provider in
            (provider, disabledProviders.contains(provider) ? RuntimeCredential.disabledUncertain : previousRuntime.credential(for: provider))
        })
        activeCredentials = safeCredentials
        for provider in LLMProvider.allCases {
            updateState(for: provider) { $0.credentialAvailability = durableAvailability[provider, default: .unknown] }
        }
        runtimeStore.publish(makeRuntime(configuration: previousRuntime.settings, credentials: safeCredentials))
        recoveryMessage = "Recovery was incomplete for: \(problems.joined(separator: ", ")). Durable credential presence was reloaded; only uncertain routes or shortcuts are disabled."
        applyStatus = .failure(ErrorPresentation.present(EnLLMError.settingsRecoveryRequired).message)
        // Block queued autosave commits and termination until the user resolves this.
        blockedByRecovery = true
        needsSafeDiscardConfirmation = true
    }

    enum RecordingOutcome: Equatable { case recorded(HotkeyDefinition), rejectedInvalid, rejectedDuplicate }

    func beginRecording(_ action: AppAction) {
        activeRecordingAction = action
        recordingFeedback[action] = nil
        hotkeyRegistrar.setRecordingAction(action)
    }

    func endRecording() {
        activeRecordingAction = nil
        hotkeyRegistrar.setRecordingAction(nil)
    }

    func isRecording(_ action: AppAction) -> Bool { activeRecordingAction == action }
    func recordingMessage(for action: AppAction) -> String? { recordingFeedback[action] }

    /// Validates a captured key combination and, only when it is a supported modified
    /// shortcut distinct from the other action's, updates the draft exactly once and
    /// ends recording. Invalid or duplicate captures are rejected inline without
    /// replacing the active or drafted shortcuts.
    @discardableResult
    func handleRecordedKey(keyCode: UInt32, modifiers: UInt32, for action: AppAction) -> RecordingOutcome {
        let candidate = HotkeyDefinition(keyCode: keyCode, modifiers: modifiers)
        guard candidate.isValid else {
            recordingFeedback[action] = "Press a key together with at least one of ⌘ ⌥ ⌃ ⇧."
            return .rejectedInvalid
        }
        let other = action == .correctSelection ? translateHotkey : correctHotkey
        guard candidate != other else {
            recordingFeedback[action] = "That shortcut is already used by the other action."
            return .rejectedDuplicate
        }
        setHotkey(candidate, for: action)
        endRecording()
        return .recorded(candidate)
    }

    /// Escape/cancel: leaves the previously displayed shortcut unchanged.
    func cancelRecording(for action: AppAction) {
        recordingFeedback[action] = nil
        endRecording()
    }

    private func setHotkey(_ definition: HotkeyDefinition, for action: AppAction) {
        switch action {
        case .correctSelection: correctHotkey = definition
        case .translateSelectionToUkrainian: translateHotkey = definition
        }
    }

    func resetModelsAndPrompts() {
        openAICorrectionModel = BuiltInDefaults.openAICorrectionModel
        openAITranslationModel = BuiltInDefaults.openAITranslationModel
        anthropicCorrectionModel = BuiltInDefaults.anthropicCorrectionModel
        anthropicTranslationModel = BuiltInDefaults.anthropicTranslationModel
        correctionInstruction = BuiltInDefaults.correctionInstruction
        translationInstruction = BuiltInDefaults.ukrainianTranslationInstruction
    }

    func draftAPIKey(for provider: LLMProvider) -> String {
        if editedCredentialProviders.contains(provider) {
            return state(for: provider).draftAPIKey
        }
        guard case .available(let credential) = activeCredentials[provider, default: .missing] else {
            return ""
        }
        return credential
    }
    func setDraftAPIKey(_ value: String, for provider: LLMProvider) {
        let previousCredential = effectiveDraftCredential(for: provider)
        editedCredentialProviders.insert(provider)
        // Typing a value supersedes any pending deletion (it becomes a replacement).
        pendingDeletionProviders.remove(provider)
        updateState(for: provider) { $0.draftAPIKey = value; $0.draftRevision &+= 1 }
        if effectiveDraftCredential(for: provider) != previousCredential { invalidateTest(for: provider) }
        draftDidChange()
    }
    /// Records a confirmed deletion intent for a confirmed saved credential. It does
    /// not mutate Keychain or runtime routing; the whole-snapshot commit does.
    /// Absent/unknown credentials are never deletable, so this is a no-op for them.
    func confirmCredentialDeletion(_ provider: LLMProvider) {
        guard hasStoredCredential(for: provider) else { return }
        let previousCredential = effectiveDraftCredential(for: provider)
        pendingDeletionProviders.insert(provider)
        editedCredentialProviders.insert(provider)
        updateState(for: provider) { $0.draftAPIKey = ""; $0.draftRevision &+= 1 }
        if effectiveDraftCredential(for: provider) != previousCredential { invalidateTest(for: provider) }
        draftDidChange()
    }
    /// Cancels an edit or a pending deletion, restoring the pre-edit saved credential
    /// draft and suppressing the deletion intent so a later edit cannot revive it.
    func undoCredentialEdit(_ provider: LLMProvider) {
        let previousCredential = effectiveDraftCredential(for: provider)
        pendingDeletionProviders.remove(provider)
        editedCredentialProviders.remove(provider)
        clearCredentialDraft(for: provider)
        if effectiveDraftCredential(for: provider) != previousCredential { invalidateTest(for: provider) }
        draftDidChange()
    }
    func hasCredentialEdit(_ provider: LLMProvider) -> Bool { editedCredentialProviders.contains(provider) }
    func isPendingCredentialDeletion(_ provider: LLMProvider) -> Bool { pendingDeletionProviders.contains(provider) }
    /// Delete is offered only for a confirmed saved credential not already pending deletion.
    func canDeleteCredential(_ provider: LLMProvider) -> Bool {
        hasStoredCredential(for: provider) && !pendingDeletionProviders.contains(provider)
    }
    /// Undo is offered only for an edit to, or a pending deletion of, a confirmed saved credential.
    func canUndoCredential(_ provider: LLMProvider) -> Bool {
        hasStoredCredential(for: provider) && (hasCredentialEdit(provider) || pendingDeletionProviders.contains(provider))
    }
    func status(for provider: LLMProvider) -> Status { state(for: provider).status }
    func statusMessage(for provider: LLMProvider) -> String? {
        switch status(for: provider) {
        case .idle, .saving, .saved: nil
        case .success(let value), .failure(let value): value
        }
    }
    func isTesting(_ provider: LLMProvider) -> Bool { state(for: provider).isTesting }
    func credentialAvailability(for provider: LLMProvider) -> CredentialAvailability { state(for: provider).credentialAvailability }
    func hasStoredCredential(for provider: LLMProvider) -> Bool { credentialAvailability(for: provider) == .present }
    var fallbackAlternateProvider: LLMProvider { primaryProvider.alternateProvider }
    var isFallbackAvailable: Bool { effectiveDraftCredential(for: fallbackAlternateProvider) != nil }
    var fallbackAvailabilityMessage: String? {
        guard fallbackEnabled, !isFallbackAvailable else { return nil }
        return "Fallback is enabled but unavailable until you provide an \(fallbackAlternateProvider.displayName) API key."
    }
    var fallbackEffectDescription: String {
        fallbackEnabled
            ? "If the primary provider is missing a key or fails with an approved provider error, the same selected text may be sent to \(fallbackAlternateProvider.displayName) once."
            : "Fallback is disabled. Selected text is sent only to the primary provider."
    }
    var routingPersistenceMessage: String { "Changes save automatically a moment after you stop editing." }

    func startTestConnection(for provider: LLMProvider) {
        cancelTest(for: provider)
        // Reject inline while the draft is invalid; an invalid draft is never flushed or tested.
        guard draftConfiguration.validationIssues.isEmpty else {
            updateState(for: provider) { $0.status = .failure("Resolve the highlighted settings before testing \(provider.displayName).") }
            return
        }
        guard let credential = effectiveDraftCredential(for: provider) else {
            updateState(for: provider) { $0.status = .failure(ErrorPresentation.present(EnLLMError.providerCredentialMissing(provider)).message) }
            return
        }
        let models = distinctSelectedModels(for: provider)
        // Models come from fixed dropdowns, so they are always allowed; guard defensively anyway.
        guard models.allSatisfy({ !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            updateState(for: provider) { $0.status = .failure("Select a supported model for \(provider.displayName).") }
            return
        }
        let revision = ProviderTestRevision(credential: credential, models: models.map(\.model))
        let generation = updateState(for: provider) { $0.testGeneration &+= 1; $0.isTesting = true; $0.status = .idle; return $0.testGeneration }
        let client = provider == .anthropic ? anthropicClient : openAIClient
        testTasks[provider] = Task { [weak self, client] in
            // Flush and await a pending valid snapshot so the test reflects durable settings.
            // The captured credential/models are immutable, so autosave cannot change them midway.
            await self?.flushAndAwaitAutosave()
            guard let self, self.isCurrentTest(revision, generation: generation, for: provider) else { return }
            // Test each distinct selected model in sequence; a duplicate correction/translation
            // choice was already collapsed so it is tested only once.
            for entry in models {
                do {
                    _ = try await client.complete(LLMCompletionRequest(
                        instruction: BuiltInDefaults.connectionTestInstruction,
                        userText: BuiltInDefaults.connectionTestUserText,
                        model: entry.model
                    ), credential: credential)
                } catch is CancellationError {
                    guard self.isCurrentTest(revision, generation: generation, for: provider) else { return }
                    self.updateState(for: provider) { $0.isTesting = false }
                    self.clearTestTask(generation: generation, for: provider)
                    return
                } catch {
                    guard self.isCurrentTest(revision, generation: generation, for: provider) else { return }
                    self.updateState(for: provider) {
                        $0.isTesting = false
                        $0.status = .failure(Self.testFailureMessage(provider: provider, action: entry.action, model: entry.model, error: error))
                    }
                    self.clearTestTask(generation: generation, for: provider)
                    return
                }
            }
            guard self.isCurrentTest(revision, generation: generation, for: provider) else { return }
            self.updateState(for: provider) { $0.isTesting = false; $0.status = .success("\(provider.displayName) connection succeeded.") }
            self.clearTestTask(generation: generation, for: provider)
        }
    }

    /// Stable, content-free wording identifying which selected model failed. The
    /// provider name, action label, and fixed catalog model ID are all safe to show;
    /// the underlying error is sanitized through ErrorPresentation.
    private static func testFailureMessage(provider: LLMProvider, action: AppAction, model: String, error: any Error) -> String {
        let actionLabel = action == .correctSelection ? "correction" : "translation"
        return "\(provider.displayName) connection failed for the \(actionLabel) model (\(model)). \(ErrorPresentation.present(error).message)"
    }

    private func clearTestTask(generation: Int, for provider: LLMProvider) {
        if state(for: provider).testGeneration == generation { testTasks[provider] = nil }
    }

    func cancelTest(for provider: LLMProvider) {
        updateState(for: provider) { $0.testGeneration &+= 1; $0.isTesting = false; $0.status = .idle }
        testTasks[provider]?.cancel(); testTasks[provider] = nil
    }
    func settingsDidDisappear() {
        for provider in LLMProvider.allCases { cancelTest(for: provider) }
        endRecording()
        // Flush a pending valid edit into an immediate commit; the model outlives the window.
        apply()
    }

    /// The user explicitly accepted discarding an uncommittable/failed settings edit,
    /// unblocking a subsequent quit.
    func confirmSafeDiscard() { safeDiscardConfirmed = true }

    /// Coordinates settings teardown with quit. Returns false to cancel termination when
    /// an uncommittable invalid edit remains, or an incomplete recovery is unresolved, and
    /// the user has not confirmed a safe discard.
    @discardableResult
    func prepareForTermination() async -> Bool {
        // Flush and await any pending valid commit/rollback before blocking new work.
        await flushAndAwaitAutosave()
        if !safeDiscardConfirmed,
           needsSafeDiscardConfirmation || (isDirty && !draftConfiguration.validationIssues.isEmpty) {
            needsSafeDiscardConfirmation = true
            return false
        }
        isTerminating = true
        endRecording()
        autosaveTask?.cancel(); autosaveTask = nil
        for provider in LLMProvider.allCases { cancelTest(for: provider) }
        await applyTask?.value
        await bootstrapTask?.value
        hotkeyRegistrar.unregister()
        return true
    }

    private func captureApplySnapshot() -> ApplySnapshot {
        var revisions: [LLMProvider: Int] = [:]
        var drafts: [LLMProvider: CredentialDraft] = [:]
        for provider in LLMProvider.allCases {
            revisions[provider] = state(for: provider).draftRevision
            if pendingDeletionProviders.contains(provider) {
                drafts[provider] = .delete
                continue
            }
            guard editedCredentialProviders.contains(provider) else {
                drafts[provider] = .unchanged
                continue
            }
            let value = draftAPIKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
            // An edited-but-empty field is no longer an implicit deletion; deletion is explicit and confirmed.
            drafts[provider] = value.isEmpty ? .unchanged : .replace(value)
        }
        return ApplySnapshot(
            draft: SettingsDraft(
                configuration: draftConfiguration,
                anthropicCredential: drafts[.anthropic, default: .unchanged],
                openAICredential: drafts[.openAI, default: .unchanged]
            ),
            revisions: revisions
        )
    }

    private func invalidateTest(for provider: LLMProvider) {
        guard isTesting(provider) || status(for: provider) != .idle else { return }
        cancelTest(for: provider)
    }
    private func isCurrentTest(_ revision: ProviderTestRevision, generation: Int, for provider: LLMProvider) -> Bool {
        state(for: provider).testGeneration == generation &&
            ProviderTestRevision(
                credential: effectiveDraftCredential(for: provider),
                models: distinctSelectedModels(for: provider).map(\.model)
            ) == revision
    }
    private func effectiveDraftCredential(for provider: LLMProvider) -> String? {
        if editedCredentialProviders.contains(provider) {
            let value = draftAPIKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard case .available(let value) = activeCredentials[provider, default: .missing] else { return nil }
        return value
    }
    private func makeRuntime(configuration: NonSecretConfiguration, credentials: [LLMProvider: RuntimeCredential]) -> RuntimeConfiguration {
        RuntimeConfiguration(settings: configuration, anthropicCredential: credentials[.anthropic, default: .missing], openAICredential: credentials[.openAI, default: .missing])
    }
    private func runtimeCredential(_ value: String?) -> RuntimeCredential {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .missing }
        return .available(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private func updateAvailability(for provider: LLMProvider) {
        updateState(for: provider) { state in
            switch activeCredentials[provider, default: .missing] { case .available: state.credentialAvailability = .present; case .missing: state.credentialAvailability = .absent; case .disabledUncertain: state.credentialAvailability = .unknown }
        }
    }
    private func applyDraft(_ value: NonSecretConfiguration) {
        // Programmatic loads (bootstrap/recovery) must not schedule an autosave.
        suppressDraftObservation = true
        defer { suppressDraftObservation = false }
        // Normalize any disallowed persisted/loaded selection so the UI never shows an invalid choice.
        let normalized = value.normalizingModels()
        primaryProvider = normalized.primaryProvider; fallbackEnabled = normalized.fallbackEnabled
        openAICorrectionModel = normalized.openAICorrectionModel
        openAITranslationModel = normalized.openAITranslationModel
        anthropicCorrectionModel = normalized.anthropicCorrectionModel
        anthropicTranslationModel = normalized.anthropicTranslationModel
        correctionInstruction = normalized.correctionInstruction; translationInstruction = normalized.translationInstruction
        correctHotkey = normalized.correctHotkey; translateHotkey = normalized.translateHotkey
    }
    private func clearCredentialDraft(for provider: LLMProvider) { updateState(for: provider) { $0.draftAPIKey = ""; $0.draftRevision &+= 1 } }
    private func state(for provider: LLMProvider) -> ProviderState { providerStates[provider, default: ProviderState()] }
    @discardableResult private func updateState<T>(for provider: LLMProvider, _ body: (inout ProviderState) -> T) -> T { var state = providerStates[provider, default: ProviderState()]; let result = body(&state); providerStates[provider] = state; return result }
}

private struct ProviderTestRevision: Equatable {
    let credential: String?
    let models: [String]
}

private struct ApplySnapshot: Equatable, Sendable {
    let draft: SettingsDraft
    let revisions: [LLMProvider: Int]
}

private struct ProviderState: Equatable {
    var draftAPIKey = ""
    var status: ProviderSettingsModel.Status = .idle
    var isTesting = false
    var credentialAvailability: ProviderSettingsModel.CredentialAvailability = .unknown
    var testGeneration = 0
    var draftRevision = 0
}

private actor EphemeralSettingsRepository: SettingsPersisting {
    private var value = BuiltInDefaults.configuration
    func load() async -> SettingsLoadResult { SettingsLoadResult(configuration: value) }
    func snapshot() async throws -> SettingsStoreSnapshot { .absent }
    func save(_ configuration: NonSecretConfiguration) async throws { value = configuration }
    func restore(_ snapshot: SettingsStoreSnapshot) async throws { value = BuiltInDefaults.configuration }
}
