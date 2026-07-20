import EnLLMCore
import EnLLMPlatform
import Foundation

@MainActor
struct AppRuntime {
    let coordinator: ActionCoordinator
    let settingsModel: ProviderSettingsModel

    func loadStoredCredentials() {
        settingsModel.bootstrap()
    }
}

@MainActor
enum AppComposition {
    static func makeRuntime(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppRuntime {
        let clipboard = SafeClipboardService()
        let permissionService = AccessibilityPermissionService()
        let notificationService = UserNotificationService()
        let panel = ResultPanelController()
        let hotkeyRegistrar = DefaultHotkeyRegistrar()
        let accessibility = AccessibilitySelectionService()
        let credentialStore = KeychainCredentialStore()
        let settingsRepository = AtomicSettingsRepository()
        let anthropicClient = AnthropicMessagesClient()
        let openAIClient = OpenAIResponsesClient()
        let diagnostics = DefaultDiagnosticRecorder.make()
        let defaults = BuiltInDefaults.configuration
        let runtimeStore = RuntimeConfigurationStore(RuntimeConfiguration(
            settings: defaults,
            anthropicCredential: .missing,
            openAICredential: .missing
        ))
        let settingsModel = ProviderSettingsModel(
            credentialStore: credentialStore,
            anthropicClient: anthropicClient,
            openAIClient: openAIClient,
            settingsRepository: settingsRepository,
            hotkeyRegistrar: hotkeyRegistrar,
            runtimeStore: runtimeStore
        )
        let selectionPolicy = SelectionCapturePolicy(
            accessibilityReader: accessibility,
            clipboardFallback: clipboard
        )
        let handler: any ActionHandling

        #if DEBUG
        if arguments.contains("--enable-phase2-local-transformer") {
            handler = Phase2LocalActionHandler(
                translationUseCase: TranslationUseCase(
                    selectionPolicy: selectionPolicy,
                    transformer: LocalTranslationTransformer()
                ),
                correctionUseCase: CorrectionUseCase(
                    selectionPolicy: selectionPolicy,
                    transformer: LocalCorrectionTransformer(),
                    applier: CorrectionApplicationService(
                        accessibility: accessibility,
                        clipboard: clipboard
                    )
                )
            )
        } else if arguments.contains("--enable-phase1-local-transformer") {
            handler = Phase1LocalActionHandler(
                translationUseCase: TranslationUseCase(
                    selectionPolicy: selectionPolicy,
                    transformer: LocalTranslationTransformer()
                )
            )
        } else {
            handler = makeProductionHandler(
                selectionPolicy: selectionPolicy,
                accessibility: accessibility,
                clipboard: clipboard,
                anthropicClient: anthropicClient,
                openAIClient: openAIClient,
                runtimeStore: runtimeStore,
                diagnostics: diagnostics
            )
        }
        #else
        handler = makeProductionHandler(
            selectionPolicy: selectionPolicy,
            accessibility: accessibility,
            clipboard: clipboard,
            anthropicClient: anthropicClient,
            openAIClient: openAIClient,
            runtimeStore: runtimeStore,
            diagnostics: diagnostics
        )
        #endif

        let coordinator = ActionCoordinator(
            actionHandler: handler,
            clipboard: clipboard,
            permissionService: permissionService,
            notificationService: notificationService,
            panel: panel,
            hotkeyRegistrar: hotkeyRegistrar,
            diagnostics: diagnostics
        )
        settingsModel.configureActionDispatch { [weak coordinator] action in
            coordinator?.perform(action)
        }
        return AppRuntime(
            coordinator: coordinator,
            settingsModel: settingsModel
        )
    }

    private static func makeProductionHandler(
        selectionPolicy: SelectionCapturePolicy,
        accessibility: AccessibilitySelectionService,
        clipboard: SafeClipboardService,
        anthropicClient: any LLMProviderClient,
        openAIClient: any LLMProviderClient,
        runtimeStore: any RuntimeConfigurationProviding,
        diagnostics: any DiagnosticRecording
    ) -> any ActionHandling {
        ProductionProviderActionHandler(
            translationUseCase: TranslationUseCase(
                selectionPolicy: selectionPolicy,
                transformer: LLMRouter(
                    action: .translateSelectionToUkrainian,
                    runtimeConfigurationProvider: runtimeStore,
                    anthropicClient: anthropicClient,
                    openAIClient: openAIClient,
                    diagnostics: diagnostics
                )
            ),
            correctionUseCase: CorrectionUseCase(
                selectionPolicy: selectionPolicy,
                transformer: LLMRouter(
                    action: .correctSelection,
                    runtimeConfigurationProvider: runtimeStore,
                    anthropicClient: anthropicClient,
                    openAIClient: openAIClient,
                    diagnostics: diagnostics
                ),
                applier: CorrectionApplicationService(
                    accessibility: accessibility,
                    clipboard: clipboard
                )
            )
        )
    }
}

private struct ProductionProviderActionHandler: ActionHandling {
    let translationUseCase: TranslationUseCase
    let correctionUseCase: CorrectionUseCase

    @MainActor
    func perform(_ action: AppAction, operationID: OperationID) async throws -> ActionOutput {
        switch action {
        case .correctSelection:
            try await correctionUseCase.run(operationID: operationID)
        case .translateSelectionToUkrainian:
            .panelText(try await translationUseCase.run(operationID: operationID))
        }
    }
}

#if DEBUG
private struct Phase1LocalActionHandler: ActionHandling {
    let translationUseCase: TranslationUseCase

    @MainActor
    func perform(_ action: AppAction, operationID: OperationID) async throws -> ActionOutput {
        guard action == .translateSelectionToUkrainian else {
            throw EnLLMError.featureUnavailable(action)
        }
        return .panelText(try await translationUseCase.run(operationID: operationID))
    }
}

private struct Phase2LocalActionHandler: ActionHandling {
    let translationUseCase: TranslationUseCase
    let correctionUseCase: CorrectionUseCase

    @MainActor
    func perform(_ action: AppAction, operationID: OperationID) async throws -> ActionOutput {
        switch action {
        case .correctSelection:
            try await correctionUseCase.run(operationID: operationID)
        case .translateSelectionToUkrainian:
            .panelText(try await translationUseCase.run(operationID: operationID))
        }
    }
}

private struct LocalTranslationTransformer: TranslationTransforming {
    @MainActor
    func transform(_ text: String) async throws -> String {
        try Task.checkCancellation()
        return "Local development translation:\n\(text)"
    }
}

private struct LocalCorrectionTransformer: CorrectionTransforming {
    @MainActor
    func transform(_ text: String) async throws -> String {
        try await Task.sleep(for: .seconds(2))
        try Task.checkCancellation()
        return text
            .replacingOccurrences(of: "teh", with: "the")
            .replacingOccurrences(of: "Teh", with: "The")
    }
}
#endif
