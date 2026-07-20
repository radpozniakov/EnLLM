import AppKit
import Combine
import EnLLMCore
import EnLLMPlatform
import Foundation

@MainActor
protocol PanelPresenting: AnyObject {
    func show(_ state: ActionCoordinator.PanelState)
    func hide()
    func stopMonitoring()
    var onDismiss: ((OperationID) -> Void)? { get set }
    var onCopy: ((OperationID, String) -> Void)? { get set }
    var onRecoveryAction: ((OperationID, ErrorRecoveryAction) -> Void)? { get set }
}

/// Injectable seam for opening the app's Settings scene from a non-View context.
///
/// The coordinator has no SwiftUI environment, so provider-setup recovery routes
/// through this protocol. Production activates the app and drives the standard
/// Settings selector; tests substitute a recording double.
@MainActor
protocol AppSettingsOpening: AnyObject {
    func openAppSettings()
}

final class SystemAppSettingsOpener: AppSettingsOpening {
    func openAppSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        // The SwiftUI Settings scene is opened through the standard AppKit
        // selector on macOS 14+; the app targets macOS 26.
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

@MainActor
final class ActionCoordinator: ObservableObject {
    enum PanelState: Equatable {
        case hidden
        case loading(OperationID)
        case result(OperationID, String)
        case error(OperationID, String, recoveryAction: ErrorRecoveryAction)

        var operationID: OperationID? {
            switch self {
            case .hidden: nil
            case .loading(let id), .result(let id, _), .error(let id, _, _): id
            }
        }
    }

    @Published private(set) var isActive = false
    @Published private(set) var isTerminating = false
    @Published private(set) var lastError: String?
    @Published private(set) var panelState: PanelState = .hidden

    private let actionHandler: any ActionHandling
    private let clipboard: any ClipboardCoordinating
    private let permissionService: AccessibilityPermissionService
    private let notificationService: any CorrectionFailureNotifying
    private let panel: any PanelPresenting
    private let appSettingsOpener: any AppSettingsOpening
    private let diagnostics: any DiagnosticRecording
    private var activeTask: Task<Void, Never>?
    private var copyTask: Task<Void, Never>?
    private var notificationDeliveryTask: Task<Void, Never>?
    private var notificationDeliveryOperationID: OperationID?
    private var deliveredNotificationOperationID: OperationID?
    private var notificationAuthorizationTask: Task<Void, Never>?
    private var notificationAuthorizationSequencingStarted = false
    private var notificationAuthorizationRequested = false
    private var terminationTask: Task<ClipboardTerminalResult, Never>?
    private var generation = 0

    init(
        actionHandler: any ActionHandling,
        clipboard: any ClipboardCoordinating,
        permissionService: AccessibilityPermissionService,
        notificationService: any CorrectionFailureNotifying,
        panel: any PanelPresenting,
        hotkeyRegistrar: DefaultHotkeyRegistrar,
        appSettingsOpener: any AppSettingsOpening = SystemAppSettingsOpener(),
        diagnostics: any DiagnosticRecording = NoOpDiagnosticRecorder()
    ) {
        self.actionHandler = actionHandler
        self.clipboard = clipboard
        self.permissionService = permissionService
        self.notificationService = notificationService
        self.panel = panel
        self.appSettingsOpener = appSettingsOpener
        self.diagnostics = diagnostics
        _ = hotkeyRegistrar // Settings is the sole production owner; retained for test/source compatibility.

        panel.onDismiss = { [weak self] operationID in
            self?.dismissPanel(operationID: operationID)
        }
        panel.onCopy = { [weak self] operationID, text in
            self?.copyResult(operationID: operationID, text: text)
        }
        panel.onRecoveryAction = { [weak self] operationID, recoveryAction in
            self?.handleRecoveryAction(operationID: operationID, recoveryAction: recoveryAction)
        }
    }

    func start() {
        // Hotkeys are bootstrapped and transactionally swapped by ProviderSettingsModel.
    }

    func perform(_ action: AppAction) {
        guard !isTerminating else { return }
        activeTask?.cancel()
        copyTask?.cancel()
        cancelNotificationDelivery()
        generation += 1
        let operationGeneration = generation
        let operationID = OperationID()

        isActive = true
        lastError = nil

        if action == .translateSelectionToUkrainian {
            present(.loading(operationID))
        } else {
            hidePanel()
        }

        diagnostics.record(DiagnosticEvent(
            operationID: operationID,
            action: action,
            phase: .actionStarted
        ))
        let clock = ContinuousClock()
        let startedAt = clock.now

        activeTask = Task { [weak self, actionHandler, diagnostics] in
            func recordCompleted(_ outcome: DiagnosticOutcome) {
                diagnostics.record(DiagnosticEvent(
                    operationID: operationID,
                    action: action,
                    phase: .actionCompleted,
                    outcome: outcome,
                    duration: startedAt.duration(to: clock.now)
                ))
            }
            do {
                let output = try await actionHandler.perform(action, operationID: operationID)
                recordCompleted(.success)
                self?.finish(
                    action: action,
                    output: output,
                    generation: operationGeneration,
                    operationID: operationID,
                    error: nil,
                    shouldSequenceNotificationAuthorization: true
                )
            } catch is CancellationError {
                recordCompleted(.cancelled)
                self?.finish(
                    action: action,
                    output: .none,
                    generation: operationGeneration,
                    operationID: operationID,
                    error: nil,
                    shouldSequenceNotificationAuthorization: false
                )
            } catch {
                recordCompleted(.failure(ErrorPresentation.present(error).category))
                self?.finish(
                    action: action,
                    output: .none,
                    generation: operationGeneration,
                    operationID: operationID,
                    error: error,
                    shouldSequenceNotificationAuthorization: true
                )
            }
        }
    }

    func cancel() {
        invalidateActiveOperation(hidePanel: true)
    }

    func prepareForTermination() -> Task<ClipboardTerminalResult, Never> {
        if let terminationTask {
            return terminationTask
        }

        isTerminating = true
        notificationAuthorizationTask?.cancel()
        cancelNotificationDelivery()
        invalidateActiveOperation(hidePanel: true)
        panel.stopMonitoring()

        // Do not await cancelled action or notification tasks: third-party task
        // doubles may ignore cancellation. Clipboard ownership remains the only
        // teardown that can hold application termination.
        let task = Task { [clipboard] in
            await clipboard.awaitQuiescence()
        }
        terminationTask = task
        return task
    }

    private func finish(
        action: AppAction,
        output: ActionOutput,
        generation operationGeneration: Int,
        operationID: OperationID,
        error: Error?,
        shouldSequenceNotificationAuthorization: Bool
    ) {
        guard !isTerminating, generation == operationGeneration else { return }
        activeTask = nil
        isActive = false

        if let error {
            presentError(
                error,
                for: action,
                generation: operationGeneration,
                operationID: operationID
            )
        } else {
            switch output {
            case .none:
                if action == .translateSelectionToUkrainian {
                    hidePanel()
                }
            case .panelText(let text):
                present(.result(operationID, text))
            }
        }

        if action == .correctSelection, shouldSequenceNotificationAuthorization {
            scheduleFirstCorrectionNotificationAuthorization()
        }
    }

    private func presentError(
        _ error: Error,
        for action: AppAction,
        generation operationGeneration: Int,
        operationID: OperationID
    ) {
        let presentation = ErrorPresentation.present(error)
        lastError = presentation.message

        guard action == .correctSelection,
              presentation.category != .accessibilityPermission else {
            presentErrorPanel(operationID: operationID, presentation: presentation)
            return
        }

        notificationDeliveryOperationID = operationID
        notificationDeliveryTask = Task { [weak self, notificationService] in
            let authorizationStatus = await notificationService.authorizationStatus()
            guard let self,
                  self.isCurrent(operationGeneration),
                  !self.isActive else { return }

            guard authorizationStatus == .authorized else {
                self.notificationDeliveryTask = nil
                self.notificationDeliveryOperationID = nil
                self.presentErrorPanel(operationID: operationID, presentation: presentation)
                return
            }

            do {
                try Task.checkCancellation()
                try await notificationService.deliver(CorrectionFailureNotification(
                    operationID: operationID,
                    presentation: presentation
                ))
                guard self.isCurrent(operationGeneration), !self.isActive else { return }
                self.notificationDeliveryTask = nil
                self.notificationDeliveryOperationID = nil
                self.deliveredNotificationOperationID = operationID
            } catch is CancellationError {
                // A newer operation or termination owns presentation now.
            } catch {
                guard self.isCurrent(operationGeneration), !self.isActive else { return }
                self.notificationDeliveryTask = nil
                self.notificationDeliveryOperationID = nil
                self.presentErrorPanel(operationID: operationID, presentation: presentation)
            }
        }
    }

    private func cancelNotificationDelivery() {
        notificationDeliveryTask?.cancel()
        notificationDeliveryTask = nil
        let operationIDs = [notificationDeliveryOperationID, deliveredNotificationOperationID]
        notificationDeliveryOperationID = nil
        deliveredNotificationOperationID = nil
        for operationID in Set(operationIDs.compactMap { $0 }) {
            notificationService.cancelDelivery(for: operationID)
        }
    }

    private func scheduleFirstCorrectionNotificationAuthorization() {
        guard !notificationAuthorizationSequencingStarted, !isTerminating else { return }
        notificationAuthorizationSequencingStarted = true

        notificationAuthorizationTask = Task { [weak self, clipboard, notificationService] in
            _ = await clipboard.awaitQuiescence()
            guard let self else { return }

            while self.isActive && !self.isTerminating && !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(25))
                } catch {
                    return
                }
            }
            guard !self.isTerminating, !Task.isCancelled, !self.isActive else { return }

            let status = await notificationService.authorizationStatus()
            guard !self.isTerminating, !Task.isCancelled, !self.isActive,
                  status == .notDetermined, !self.notificationAuthorizationRequested else { return }

            self.notificationAuthorizationRequested = true
            await notificationService.requestAuthorization()
        }
    }

    private func isCurrent(_ operationGeneration: Int) -> Bool {
        !isTerminating && generation == operationGeneration
    }

    private func presentErrorPanel(
        operationID: OperationID,
        presentation: UserFacingErrorPresentation
    ) {
        present(
            .error(
                operationID,
                presentation.message,
                recoveryAction: presentation.recoveryAction
            )
        )
    }

    private func dismissPanel(operationID: OperationID) {
        guard panelState.operationID == operationID else { return }
        invalidateActiveOperation(hidePanel: true)
    }

    private func copyResult(operationID: OperationID, text: String) {
        guard !isTerminating, panelState == .result(operationID, text) else { return }
        copyTask?.cancel()
        let operationGeneration = generation
        copyTask = Task { [weak self, clipboard] in
            do {
                try await clipboard.writeUserCopy(text)
                guard let self, self.generation == operationGeneration,
                      self.panelState == .result(operationID, text) else { return }
                self.copyTask = nil
                self.hidePanel()
            } catch is CancellationError {
                // A newer invocation or termination owns the UI now.
            } catch {
                guard let self, self.generation == operationGeneration else { return }
                self.copyTask = nil
                let presentation = ErrorPresentation.present(error)
                self.presentErrorPanel(operationID: operationID, presentation: presentation)
            }
        }
    }

    private func handleRecoveryAction(
        operationID: OperationID,
        recoveryAction: ErrorRecoveryAction
    ) {
        // A recovery button belongs to a specific error panel. Ignore it once the
        // app is terminating or a newer operation has replaced that panel so a
        // stale click cannot open Settings behind the current operation.
        guard !isTerminating, panelState.operationID == operationID else { return }
        switch recoveryAction {
        case .none:
            break
        case .openAccessibilitySettings:
            permissionService.requestAccessPrompt()
            _ = permissionService.openSettings()
        case .openAppSettings:
            appSettingsOpener.openAppSettings()
        }
    }

    private func invalidateActiveOperation(hidePanel shouldHide: Bool) {
        activeTask?.cancel()
        copyTask?.cancel()
        cancelNotificationDelivery()
        generation += 1
        activeTask = nil
        copyTask = nil
        isActive = false
        if shouldHide {
            hidePanel()
        }
    }

    private func present(_ state: PanelState) {
        guard !isTerminating else { return }
        panelState = state
        panel.show(state)
    }

    private func hidePanel() {
        panelState = .hidden
        panel.hide()
    }
}
