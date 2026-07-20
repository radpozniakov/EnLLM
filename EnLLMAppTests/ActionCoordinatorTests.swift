import AppKit
import EnLLMCore
import EnLLMPlatform
import Testing
@testable import EnLLMApp

@MainActor
private struct FailingActionHandler: ActionHandling {
    func perform(_ action: AppAction, operationID: OperationID) async throws -> ActionOutput {
        throw EnLLMError.featureUnavailable(action)
    }
}

private struct UnsafeActionError: LocalizedError {
    let errorDescription: String?
}

@MainActor
private struct UnsafeFailingActionHandler: ActionHandling {
    func perform(_ action: AppAction, operationID: OperationID) async throws -> ActionOutput {
        throw UnsafeActionError(errorDescription: "selected text / API key / response body sentinel")
    }
}

@MainActor
private struct AccessibilityFailingActionHandler: ActionHandling {
    func perform(_ action: AppAction, operationID: OperationID) async throws -> ActionOutput {
        throw EnLLMError.accessibilityPermissionMissing
    }
}

@MainActor
private struct ProviderSetupFailingActionHandler: ActionHandling {
    func perform(_ action: AppAction, operationID: OperationID) async throws -> ActionOutput {
        throw EnLLMError.providerCredentialMissing(.anthropic)
    }
}

@MainActor
private final class ControlledActionHandler: ActionHandling {
    private struct PendingOperation {
        let action: AppAction
        let continuation: CheckedContinuation<ActionOutput, any Error>
    }

    private var operations: [OperationID: PendingOperation] = [:]
    private(set) var invocationCount = 0

    func perform(_ action: AppAction, operationID: OperationID) async throws -> ActionOutput {
        invocationCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            operations[operationID] = PendingOperation(action: action, continuation: continuation)
        }
    }

    func isPending(_ operationID: OperationID) -> Bool {
        operations[operationID] != nil
    }

    func pendingOperation(for action: AppAction) -> OperationID? {
        operations.first(where: { $0.value.action == action })?.key
    }

    func complete(_ operationID: OperationID, output: ActionOutput) {
        operations.removeValue(forKey: operationID)?.continuation.resume(returning: output)
    }

    func fail(_ operationID: OperationID) {
        guard let pending = operations.removeValue(forKey: operationID) else { return }
        pending.continuation.resume(throwing: EnLLMError.featureUnavailable(pending.action))
    }
}

@MainActor
private final class CancellableActionHandler: ActionHandling {
    private struct PendingOperation {
        let action: AppAction
        let continuation: CheckedContinuation<ActionOutput, any Error>
    }

    private var operations: [OperationID: PendingOperation] = [:]

    func perform(_ action: AppAction, operationID: OperationID) async throws -> ActionOutput {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operations[operationID] = PendingOperation(action: action, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(operationID) }
        }
    }

    func isPending(_ operationID: OperationID) -> Bool { operations[operationID] != nil }

    func pendingOperation(for action: AppAction) -> OperationID? {
        operations.first(where: { $0.value.action == action })?.key
    }

    func complete(_ operationID: OperationID, output: ActionOutput) {
        operations.removeValue(forKey: operationID)?.continuation.resume(returning: output)
    }

    private func cancel(_ operationID: OperationID) {
        operations.removeValue(forKey: operationID)?.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private final class PanelSpy: PanelPresenting {
    var onDismiss: ((OperationID) -> Void)?
    var onCopy: ((OperationID, String) -> Void)?
    var onRecoveryAction: ((OperationID, ErrorRecoveryAction) -> Void)?
    var states: [ActionCoordinator.PanelState] = []
    var hideCount = 0
    var stopMonitoringCount = 0

    func show(_ state: ActionCoordinator.PanelState) { states.append(state) }
    func hide() { hideCount += 1 }
    func stopMonitoring() { stopMonitoringCount += 1 }
}

@MainActor
private final class AppSettingsOpenerSpy: AppSettingsOpening {
    var openCount = 0
    func openAppSettings() { openCount += 1 }
}

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
private final class NotificationSpy: CorrectionFailureNotifying {
    var status: NotificationAuthorizationStatus = .denied
    var authorizationStatusCallCount = 0
    var authorizationRequestCount = 0
    var cancelledOperationIDs: [OperationID] = []
    var delivered: [CorrectionFailureNotification] = []
    var deliveryError: Error?
    var shouldSuspendAuthorizationStatus = false
    var shouldSuspendDelivery = false
    private var authorizationStatusContinuations: [CheckedContinuation<NotificationAuthorizationStatus, Never>] = []
    private var deliveryContinuation: CheckedContinuation<Void, Never>?
    var isDelivering: Bool { deliveryContinuation != nil }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        authorizationStatusCallCount += 1
        guard shouldSuspendAuthorizationStatus else { return status }
        return await withCheckedContinuation { continuation in
            authorizationStatusContinuations.append(continuation)
        }
    }

    func requestAuthorization() async {
        authorizationRequestCount += 1
    }

    func deliver(_ notification: CorrectionFailureNotification) async throws {
        if shouldSuspendDelivery {
            await withCheckedContinuation { continuation in
                deliveryContinuation = continuation
            }
        }
        try Task.checkCancellation()
        if let deliveryError { throw deliveryError }
        delivered.append(notification)
    }

    func cancelDelivery(for operationID: OperationID) {
        cancelledOperationIDs.append(operationID)
    }

    func finishAuthorizationStatus() {
        let continuations = authorizationStatusContinuations
        authorizationStatusContinuations = []
        for continuation in continuations { continuation.resume(returning: status) }
    }

    func finishDelivery() {
        deliveryContinuation?.resume()
        deliveryContinuation = nil
    }
}

@MainActor
private final class ClipboardSpy: ClipboardCoordinating {
    var copiedText: String?
    var writeCount = 0
    var awaitQuiescenceCallCount = 0
    var isAwaitingQuiescence = false
    var quiescenceContinuation: CheckedContinuation<ClipboardTerminalResult, Never>?
    var shouldSuspendQuiescence = false
    var shouldSuspendWrite = false
    var isWriting = false
    private var writeContinuation: CheckedContinuation<Void, Never>?

    func writeUserCopy(_ text: String) async throws {
        if shouldSuspendWrite {
            isWriting = true
            await withCheckedContinuation { writeContinuation = $0 }
        }
        // Production writeUserCopy checks cancellation after its async boundary
        // (gate acquisition) and before mutating the pasteboard.
        try Task.checkCancellation()
        writeCount += 1
        copiedText = text
    }

    func finishWrite() {
        writeContinuation?.resume()
        writeContinuation = nil
    }

    func awaitQuiescence() async -> ClipboardTerminalResult {
        awaitQuiescenceCallCount += 1
        isAwaitingQuiescence = true
        guard shouldSuspendQuiescence else { return .idle }
        return await withCheckedContinuation { continuation in
            quiescenceContinuation = continuation
        }
    }

    func finishQuiescence(_ result: ClipboardTerminalResult = .restored) {
        quiescenceContinuation?.resume(returning: result)
        quiescenceContinuation = nil
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

@MainActor
private func makeCoordinator(
    handler: any ActionHandling,
    clipboard: ClipboardSpy = ClipboardSpy(),
    notificationService: NotificationSpy = NotificationSpy(),
    panel: PanelSpy = PanelSpy(),
    appSettingsOpener: AppSettingsOpenerSpy = AppSettingsOpenerSpy(),
    diagnostics: DiagnosticSpy = DiagnosticSpy()
) -> ActionCoordinator {
    ActionCoordinator(
        actionHandler: handler,
        clipboard: clipboard,
        permissionService: AccessibilityPermissionService(),
        notificationService: notificationService,
        panel: panel,
        hotkeyRegistrar: DefaultHotkeyRegistrar(),
        appSettingsOpener: appSettingsOpener,
        diagnostics: diagnostics
    )
}

@MainActor
@Test func coordinatorPublishesStableFailureAndClearsActivity() async {
    let coordinator = makeCoordinator(handler: FailingActionHandler())

    coordinator.perform(.correctSelection)
    while coordinator.isActive { await Task.yield() }

    #expect(coordinator.lastError == "Correct Selection is not implemented in this configuration.")
}

@MainActor
@Test func actionErrorsNeverExposeArbitraryLocalizedDescriptions() async {
    let coordinator = makeCoordinator(handler: UnsafeFailingActionHandler())

    coordinator.perform(.translateSelectionToUkrainian)
    #expect(await waitUntil {
        if case .error = coordinator.panelState { return true }
        return false
    })

    guard case .error(_, let message, _) = coordinator.panelState else {
        Issue.record("Expected error panel")
        return
    }
    #expect(message == "Something went wrong. Please try again.")
    #expect(!message.contains("sentinel"))
}

@MainActor
@Test func accessibilityFailureKeepsThePanelPermissionAction() async {
    let coordinator = makeCoordinator(handler: AccessibilityFailingActionHandler())

    coordinator.perform(.translateSelectionToUkrainian)
    #expect(await waitUntil {
        if case .error = coordinator.panelState { return true }
        return false
    })
    #expect(coordinator.panelState.operationID != nil)
    guard case .error(_, _, let recoveryAction) = coordinator.panelState else {
        Issue.record("Expected error panel")
        return
    }
    #expect(recoveryAction == .openAccessibilitySettings)
}

@MainActor
@Test func correctionAccessibilityFailureAlwaysUsesThePanelEvenWhenNotificationsAreAuthorized() async {
    let notifications = NotificationSpy()
    notifications.status = .authorized
    let coordinator = makeCoordinator(
        handler: AccessibilityFailingActionHandler(),
        notificationService: notifications
    )

    coordinator.perform(.correctSelection)
    #expect(await waitUntil {
        if case .error = coordinator.panelState { return true }
        return false
    })
    guard case .error(_, _, let recoveryAction) = coordinator.panelState else {
        Issue.record("Expected accessibility error panel")
        return
    }
    #expect(recoveryAction == .openAccessibilitySettings)
    #expect(notifications.delivered.isEmpty)
}

@MainActor
@Test func missingProviderSetupOffersOpenSettingsAndDrivesTheAppSettingsSeam() async {
    let panel = PanelSpy()
    let appSettingsOpener = AppSettingsOpenerSpy()
    let coordinator = makeCoordinator(
        handler: ProviderSetupFailingActionHandler(),
        panel: panel,
        appSettingsOpener: appSettingsOpener
    )

    coordinator.perform(.translateSelectionToUkrainian)
    #expect(await waitUntil {
        if case .error = coordinator.panelState { return true }
        return false
    })
    guard case .error(let operationID, let message, let recoveryAction) = coordinator.panelState else {
        Issue.record("Expected provider-setup error panel")
        return
    }
    #expect(recoveryAction == .openAppSettings)
    #expect(message == "Add an API key for Anthropic in Settings.")

    // The current panel's recovery action drives the injectable app-settings seam.
    panel.onRecoveryAction?(operationID, .openAppSettings)
    #expect(appSettingsOpener.openCount == 1)

    // A stale operation ID cannot open Settings behind the current panel.
    panel.onRecoveryAction?(OperationID(), .openAppSettings)
    #expect(appSettingsOpener.openCount == 1)
}

@MainActor
@Test func staleCompletionCannotOverwriteTheNewestOperation() async {
    let handler = ControlledActionHandler()
    let coordinator = makeCoordinator(handler: handler)

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let correctOperationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let translateOperationID) = coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    while !handler.isPending(translateOperationID) { await Task.yield() }

    handler.fail(translateOperationID)
    while coordinator.isActive { await Task.yield() }

    handler.fail(correctOperationID)
    await Task.yield()

    #expect(coordinator.lastError == "Translate Selection to Ukrainian is not implemented in this configuration.")
}

@MainActor
@Test func sameActionSupersessionPublishesOnlyNewestTranslation() async {
    let handler = ControlledActionHandler()
    let panel = PanelSpy()
    let coordinator = makeCoordinator(handler: handler, panel: panel)

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let olderOperationID) = coordinator.panelState else {
        Issue.record("Expected first loading panel")
        return
    }
    while !handler.isPending(olderOperationID) { await Task.yield() }

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let newerOperationID) = coordinator.panelState else {
        Issue.record("Expected second loading panel")
        return
    }
    while !handler.isPending(newerOperationID) { await Task.yield() }

    handler.complete(newerOperationID, output: .panelText("newest"))
    while coordinator.isActive { await Task.yield() }
    #expect(coordinator.panelState == .result(newerOperationID, "newest"))

    handler.complete(olderOperationID, output: .panelText("stale"))
    await Task.yield()

    #expect(coordinator.panelState == .result(newerOperationID, "newest"))
    #expect(!panel.states.contains(.result(olderOperationID, "stale")))
}

@MainActor
@Test func dismissingLoadingPanelSuppressesLateResult() async {
    let handler = ControlledActionHandler()
    let panel = PanelSpy()
    let coordinator = makeCoordinator(handler: handler, panel: panel)

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let operationID) = coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    while !handler.isPending(operationID) { await Task.yield() }

    panel.onDismiss?(operationID)
    handler.complete(operationID, output: .panelText("late"))
    await Task.yield()

    #expect(coordinator.panelState == .hidden)
    #expect(!panel.states.contains(.result(operationID, "late")))
}

@MainActor
@Test func resultCopyUsesSerializedClipboardBoundaryAndClosesPanel() async {
    let handler = ControlledActionHandler()
    let clipboard = ClipboardSpy()
    let panel = PanelSpy()
    let coordinator = makeCoordinator(handler: handler, clipboard: clipboard, panel: panel)

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let operationID) = coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    while !handler.isPending(operationID) { await Task.yield() }
    handler.complete(operationID, output: .panelText("result"))
    while coordinator.isActive { await Task.yield() }

    panel.onCopy?(operationID, "result")
    while clipboard.copiedText == nil { await Task.yield() }
    await Task.yield()

    #expect(clipboard.copiedText == "result")
    #expect(coordinator.panelState == .hidden)
}

@MainActor
@Test func correctionSafetyOutputUsesResultPanelAndSuccessfulReplacementStaysSilent() async {
    let handler = ControlledActionHandler()
    let panel = PanelSpy()
    let coordinator = makeCoordinator(handler: handler, panel: panel)

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let firstOperationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }
    handler.complete(firstOperationID, output: .panelText("recoverable correction"))
    while coordinator.isActive { await Task.yield() }
    #expect(coordinator.panelState == .result(firstOperationID, "recoverable correction"))

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let secondOperationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected second pending correction")
        return
    }
    handler.complete(secondOperationID, output: .none)
    while coordinator.isActive { await Task.yield() }

    #expect(coordinator.panelState == .hidden)
    #expect(!panel.states.contains(.result(secondOperationID, "recoverable correction")))
}

@MainActor
@Test func correctionFailureUsesErrorPanelWhenNotificationsAreUnavailable() async {
    let handler = ControlledActionHandler()
    let panel = PanelSpy()
    let coordinator = makeCoordinator(handler: handler, panel: panel)

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let operationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }
    handler.fail(operationID)
    #expect(await waitUntil {
        if case .error = coordinator.panelState { return true }
        return false
    })

    #expect(coordinator.panelState == .error(
        operationID,
        "Correct Selection is not implemented in this configuration.",
        recoveryAction: .none
    ))
}

@MainActor
@Test func undeterminedNotificationAuthorizationUsesTheErrorPanelWithoutBlockingCorrection() async {
    let handler = ControlledActionHandler()
    let notifications = NotificationSpy()
    notifications.status = .notDetermined
    let coordinator = makeCoordinator(handler: handler, notificationService: notifications)

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let operationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }
    handler.fail(operationID)

    #expect(await waitUntil {
        coordinator.panelState == .error(
            operationID,
            "Correct Selection is not implemented in this configuration.",
            recoveryAction: .none
        )
    })
    #expect(notifications.delivered.isEmpty)
    #expect(await waitUntil { notifications.authorizationRequestCount == 1 })
}

@MainActor
@Test func authorizedCorrectionFailureDeliversSanitizedNotification() async {
    let handler = ControlledActionHandler()
    let notifications = NotificationSpy()
    notifications.status = .authorized
    let coordinator = makeCoordinator(handler: handler, notificationService: notifications)

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let operationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }
    handler.fail(operationID)

    #expect(await waitUntil { notifications.delivered.count == 1 })
    #expect(notifications.delivered[0].operationID == operationID)
    #expect(notifications.delivered[0].title == "Correction failed")
    #expect(notifications.delivered[0].body == "Correct Selection is not implemented in this configuration.")
    #expect(coordinator.panelState == .hidden)
}

@MainActor
@Test func authorizedUnknownCorrectionFailureDeliversOnlyGenericContent() async {
    let notifications = NotificationSpy()
    notifications.status = .authorized
    let coordinator = makeCoordinator(
        handler: UnsafeFailingActionHandler(),
        notificationService: notifications
    )

    coordinator.perform(.correctSelection)
    #expect(await waitUntil { notifications.delivered.count == 1 })
    let notification = notifications.delivered[0]
    #expect(notification.title == "Correction failed")
    #expect(notification.body == "Something went wrong. Please try again.")
    #expect(!notification.title.contains("selected text"))
    #expect(!notification.title.contains("API key"))
    #expect(!notification.title.contains("response body"))
    #expect(!notification.body.contains("selected text"))
    #expect(!notification.body.contains("API key"))
    #expect(!notification.body.contains("response body"))
}

@MainActor
@Test func correctionNotificationDeliveryFailureFallsBackToPanel() async {
    let handler = ControlledActionHandler()
    let notifications = NotificationSpy()
    notifications.status = .authorized
    notifications.deliveryError = EnLLMError.clipboardUnavailable
    let coordinator = makeCoordinator(handler: handler, notificationService: notifications)

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let operationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }
    handler.fail(operationID)

    #expect(await waitUntil {
        coordinator.panelState == .error(
            operationID,
            "Correct Selection is not implemented in this configuration.",
            recoveryAction: .none
        )
    })
}

@MainActor
@Test func translateFailureAlwaysUsesPanelEvenWhenNotificationsAreAuthorized() async {
    let handler = ControlledActionHandler()
    let notifications = NotificationSpy()
    notifications.status = .authorized
    let coordinator = makeCoordinator(handler: handler, notificationService: notifications)

    coordinator.perform(.translateSelectionToUkrainian)
    while handler.pendingOperation(for: .translateSelectionToUkrainian) == nil { await Task.yield() }
    guard let operationID = handler.pendingOperation(for: .translateSelectionToUkrainian) else {
        Issue.record("Expected pending translation")
        return
    }
    handler.fail(operationID)

    #expect(await waitUntil {
        coordinator.panelState == .error(
            operationID,
            "Translate Selection to Ukrainian is not implemented in this configuration.",
            recoveryAction: .none
        )
    })
    #expect(notifications.delivered.isEmpty)
}

@MainActor
@Test func firstCorrectRequestsNotificationAuthorizationOnlyAfterClipboardQuiescence() async {
    let handler = ControlledActionHandler()
    let clipboard = ClipboardSpy()
    clipboard.shouldSuspendQuiescence = true
    let notifications = NotificationSpy()
    notifications.status = .notDetermined
    let coordinator = makeCoordinator(
        handler: handler,
        clipboard: clipboard,
        notificationService: notifications
    )

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let operationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }
    handler.complete(operationID, output: .none)

    #expect(await waitUntil { clipboard.isAwaitingQuiescence })
    #expect(notifications.authorizationRequestCount == 0)
    clipboard.finishQuiescence()
    #expect(await waitUntil { notifications.authorizationRequestCount == 1 })
}

@MainActor
@Test func notificationAuthorizationDefersUntilNewerActionIsIdleAndRunsOnce() async {
    let handler = ControlledActionHandler()
    let clipboard = ClipboardSpy()
    clipboard.shouldSuspendQuiescence = true
    let notifications = NotificationSpy()
    notifications.status = .notDetermined
    let coordinator = makeCoordinator(
        handler: handler,
        clipboard: clipboard,
        notificationService: notifications
    )

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let firstCorrect = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected first correction")
        return
    }
    handler.complete(firstCorrect, output: .none)
    #expect(await waitUntil { clipboard.isAwaitingQuiescence })

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let translation) = coordinator.panelState else {
        Issue.record("Expected active translation")
        return
    }
    while !handler.isPending(translation) { await Task.yield() }
    clipboard.finishQuiescence()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(notifications.authorizationRequestCount == 0)

    handler.complete(translation, output: .panelText("result"))
    #expect(await waitUntil { notifications.authorizationRequestCount == 1 })

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let secondCorrect = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected second correction")
        return
    }
    handler.complete(secondCorrect, output: .none)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(notifications.authorizationRequestCount == 1)
}

@MainActor
@Test func supersededOrTerminatedNotificationDeliveryHasNoLateEffects() async {
    let handler = ControlledActionHandler()
    let notifications = NotificationSpy()
    notifications.status = .authorized
    notifications.shouldSuspendDelivery = true
    let panel = PanelSpy()
    let coordinator = makeCoordinator(handler: handler, notificationService: notifications, panel: panel)

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let operationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }
    handler.fail(operationID)
    #expect(await waitUntil { notifications.isDelivering })

    coordinator.perform(.translateSelectionToUkrainian)
    notifications.finishDelivery()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(notifications.delivered.isEmpty)
    #expect(await waitUntil { notifications.cancelledOperationIDs.contains(operationID) })

    let termination = coordinator.prepareForTermination()
    #expect(coordinator.isTerminating)
    _ = await termination.value
    #expect(notifications.delivered.isEmpty)
    #expect(panel.states.allSatisfy {
        if case .error = $0 { return false }
        return true
    })
}

@MainActor
@Test func terminationLatchesAndRejectsNewWorkWhileAwaitingClipboard() async {
    let handler = ControlledActionHandler()
    let clipboard = ClipboardSpy()
    clipboard.shouldSuspendQuiescence = true
    let panel = PanelSpy()
    let appSettingsOpener = AppSettingsOpenerSpy()
    let coordinator = makeCoordinator(
        handler: handler,
        clipboard: clipboard,
        panel: panel,
        appSettingsOpener: appSettingsOpener
    )

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let operationID) = coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    while !handler.isPending(operationID) { await Task.yield() }
    handler.complete(operationID, output: .panelText("result"))
    while coordinator.isActive { await Task.yield() }
    #expect(coordinator.panelState == .result(operationID, "result"))

    let priorInvocationCount = handler.invocationCount
    let priorPresentedStates = panel.states
    let cleanupTask = coordinator.prepareForTermination()
    let repeatedCleanupTask = coordinator.prepareForTermination()

    #expect(coordinator.isTerminating)
    #expect(coordinator.panelState == .hidden)

    coordinator.perform(.translateSelectionToUkrainian)
    coordinator.perform(.correctSelection)
    coordinator.start()
    panel.onCopy?(operationID, "result")
    panel.onRecoveryAction?(operationID, .openAppSettings)
    await Task.yield()

    #expect(handler.invocationCount == priorInvocationCount)
    #expect(panel.states == priorPresentedStates)
    #expect(coordinator.panelState == .hidden)
    #expect(!coordinator.isActive)
    #expect(clipboard.writeCount == 0)
    #expect(clipboard.copiedText == nil)
    #expect(appSettingsOpener.openCount == 0)

    while !clipboard.isAwaitingQuiescence { await Task.yield() }
    #expect(clipboard.awaitQuiescenceCallCount == 1)

    clipboard.finishQuiescence(.restored)
    #expect(await cleanupTask.value == .restored)
    #expect(await repeatedCleanupTask.value == .restored)
}

// MARK: - BL-007 supersession boundaries: panel copy, correction result, notification check

@MainActor
@Test func stalePanelCopyCallbackIsIgnoredAndWritesNothing() async {
    let handler = ControlledActionHandler()
    let clipboard = ClipboardSpy()
    let panel = PanelSpy()
    let coordinator = makeCoordinator(handler: handler, clipboard: clipboard, panel: panel)

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let operationID) = coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    while !handler.isPending(operationID) { await Task.yield() }
    handler.complete(operationID, output: .panelText("result"))
    while coordinator.isActive { await Task.yield() }
    #expect(coordinator.panelState == .result(operationID, "result"))

    // A copy callback bearing a stale operation ID or mismatched text must not write.
    panel.onCopy?(OperationID(), "result")
    panel.onCopy?(operationID, "different text")
    await Task.yield()

    #expect(clipboard.writeCount == 0)
    #expect(clipboard.copiedText == nil)
    #expect(coordinator.panelState == .result(operationID, "result"))
}

@MainActor
@Test func supersessionDuringPanelCopyCancelsTheWriteForTheOlderOperation() async {
    let handler = ControlledActionHandler()
    let clipboard = ClipboardSpy()
    clipboard.shouldSuspendWrite = true
    let panel = PanelSpy()
    let coordinator = makeCoordinator(handler: handler, clipboard: clipboard, panel: panel)

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let operationID) = coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    while !handler.isPending(operationID) { await Task.yield() }
    handler.complete(operationID, output: .panelText("result"))
    while coordinator.isActive { await Task.yield() }

    panel.onCopy?(operationID, "result")
    #expect(await waitUntil { clipboard.isWriting })

    // Supersede while the older copy write is in flight.
    coordinator.perform(.correctSelection)
    clipboard.finishWrite()
    await Task.yield()

    // The cancelled copy writes no user-copy output.
    #expect(clipboard.writeCount == 0)
    #expect(clipboard.copiedText == nil)

    // Drain the newest pending operation to release its handler continuation.
    if let newer = handler.pendingOperation(for: .correctSelection) {
        handler.complete(newer, output: .none)
    }
    while coordinator.isActive { await Task.yield() }
}

@MainActor
@Test func supersededCorrectionSafetyResultCannotPresent() async {
    let handler = ControlledActionHandler()
    let panel = PanelSpy()
    let coordinator = makeCoordinator(handler: handler, panel: panel)

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let olderOperationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let newerOperationID) = coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    while !handler.isPending(newerOperationID) { await Task.yield() }

    // The older correction resolves to a safety-panel result after supersession.
    handler.complete(olderOperationID, output: .panelText("stale correction"))
    await Task.yield()

    #expect(!panel.states.contains(.result(olderOperationID, "stale correction")))
    #expect(coordinator.panelState == .loading(newerOperationID))

    handler.complete(newerOperationID, output: .panelText("newest"))
    while coordinator.isActive { await Task.yield() }
    #expect(coordinator.panelState == .result(newerOperationID, "newest"))
}

@MainActor
@Test func supersessionDuringNotificationAuthorizationCheckDeliversNothing() async {
    let handler = ControlledActionHandler()
    let notifications = NotificationSpy()
    notifications.status = .authorized
    notifications.shouldSuspendAuthorizationStatus = true
    let panel = PanelSpy()
    let coordinator = makeCoordinator(handler: handler, notificationService: notifications, panel: panel)

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let operationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }
    handler.fail(operationID)

    // The delivery task is parked at the authorization-status check, before delivery.
    #expect(await waitUntil { notifications.authorizationStatusCallCount >= 1 })
    #expect(!notifications.isDelivering)

    // Supersede while the older failure is still checking authorization.
    coordinator.perform(.translateSelectionToUkrainian)
    while handler.pendingOperation(for: .translateSelectionToUkrainian) == nil { await Task.yield() }
    // Disable suspension first so the concurrent auth-sequencing task cannot park
    // on a continuation that never resumes, then release the parked delivery task.
    // (All actors here are @MainActor, so no call can be mid-suspend at this point.)
    notifications.shouldSuspendAuthorizationStatus = false
    notifications.finishAuthorizationStatus()
    try? await Task.sleep(for: .milliseconds(20))

    #expect(notifications.delivered.isEmpty)
    #expect(notifications.cancelledOperationIDs.contains(operationID))
    #expect(panel.states.allSatisfy {
        if case .error = $0 { return false }
        return true
    })

    // Drain the newest pending operation.
    if let newer = handler.pendingOperation(for: .translateSelectionToUkrainian) {
        handler.complete(newer, output: .panelText("newest"))
    }
    while coordinator.isActive { await Task.yield() }
}

// MARK: - BL-008 quit and teardown state machine

@MainActor
@Test func terminationReportsRestorationFailureFaithfullyAndIsIdempotent() async {
    let clipboard = ClipboardSpy()
    clipboard.shouldSuspendQuiescence = true
    let coordinator = makeCoordinator(handler: FailingActionHandler(), clipboard: clipboard)

    let firstTask = coordinator.prepareForTermination()
    let secondTask = coordinator.prepareForTermination()
    #expect(coordinator.isTerminating)
    while !clipboard.isAwaitingQuiescence { await Task.yield() }
    #expect(clipboard.awaitQuiescenceCallCount == 1)

    // Owned restoration ends in failure — the terminal result must be reported faithfully.
    clipboard.finishQuiescence(.restorationFailed)
    #expect(await firstTask.value == .restorationFailed)
    #expect(await secondTask.value == .restorationFailed)

    // A later termination returns the same memoized terminal result without re-awaiting.
    let thirdTask = coordinator.prepareForTermination()
    #expect(await thirdTask.value == .restorationFailed)
    #expect(clipboard.awaitQuiescenceCallCount == 1)
}

@MainActor
@Test func terminationDoesNotHangWhenActionAndNotificationTasksIgnoreCancellation() async {
    let handler = ControlledActionHandler()
    let notifications = NotificationSpy()
    notifications.status = .authorized
    notifications.shouldSuspendDelivery = true
    let clipboard = ClipboardSpy()
    let coordinator = makeCoordinator(handler: handler, clipboard: clipboard, notificationService: notifications)

    // A correction failure parks a delivery task that ignores cancellation.
    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let failing = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }
    handler.fail(failing)
    #expect(await waitUntil { notifications.isDelivering })

    // A second action leaves a handler task that also ignores cancellation.
    coordinator.perform(.translateSelectionToUkrainian)
    while handler.pendingOperation(for: .translateSelectionToUkrainian) == nil { await Task.yield() }

    // Termination awaits only clipboard ownership, so it completes despite the
    // cancellation-insensitive action and notification tasks.
    let terminal = await coordinator.prepareForTermination().value
    #expect(terminal == .idle)
    #expect(notifications.delivered.isEmpty)

    // Drain the parked continuations.
    notifications.finishDelivery()
    if let pending = handler.pendingOperation(for: .translateSelectionToUkrainian) {
        handler.complete(pending, output: .panelText("late"))
    }
    await Task.yield()
}

@MainActor
@Test func terminationTearsDownPanelMonitorsIdempotently() async {
    let panel = PanelSpy()
    let coordinator = makeCoordinator(handler: FailingActionHandler(), panel: panel)

    _ = await coordinator.prepareForTermination().value
    #expect(panel.stopMonitoringCount >= 1)

    // Repeated termination is memoized and must not re-run teardown.
    let priorStopCount = panel.stopMonitoringCount
    _ = await coordinator.prepareForTermination().value
    #expect(panel.stopMonitoringCount == priorStopCount)
}

@MainActor
@Test func terminationRemovesDeliveredCorrectionNotification() async {
    let handler = ControlledActionHandler()
    let notifications = NotificationSpy()
    notifications.status = .authorized
    let coordinator = makeCoordinator(handler: handler, notificationService: notifications)

    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let operationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }
    handler.fail(operationID)
    #expect(await waitUntil {
        notifications.delivered.count == 1 && notifications.delivered[0].operationID == operationID
    })

    let deliveredCount = notifications.delivered.count
    _ = await coordinator.prepareForTermination().value

    // The operation's notification is removed regardless of interleaving: whichever
    // of the pending/delivered op-ID slots holds it routes through cancelDelivery,
    // and none is delivered late.
    #expect(notifications.cancelledOperationIDs.contains(operationID))
    #expect(notifications.delivered.count == deliveredCount)
}

@MainActor
@Test func terminationCancelsInFlightPanelCopyWithoutWriting() async {
    let handler = ControlledActionHandler()
    let clipboard = ClipboardSpy()
    clipboard.shouldSuspendWrite = true
    let panel = PanelSpy()
    let coordinator = makeCoordinator(handler: handler, clipboard: clipboard, panel: panel)

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let operationID) = coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    while !handler.isPending(operationID) { await Task.yield() }
    handler.complete(operationID, output: .panelText("result"))
    while coordinator.isActive { await Task.yield() }

    panel.onCopy?(operationID, "result")
    #expect(await waitUntil { clipboard.isWriting })

    // Terminate while the copy write is in flight.
    let terminationTask = coordinator.prepareForTermination()
    clipboard.finishWrite()
    _ = await terminationTask.value
    await Task.yield()

    // The cancelled copy writes nothing and the panel is torn down.
    #expect(clipboard.writeCount == 0)
    #expect(clipboard.copiedText == nil)
    #expect(coordinator.panelState == .hidden)
}

@MainActor
@Test func terminationCancelsPendingNotificationAuthorizationRequest() async {
    let handler = ControlledActionHandler()
    let notifications = NotificationSpy()
    notifications.status = .notDetermined
    notifications.shouldSuspendAuthorizationStatus = true
    let coordinator = makeCoordinator(handler: handler, notificationService: notifications)

    // A successful first correction schedules the one-time authorization request,
    // which parks at the authorization-status check.
    coordinator.perform(.correctSelection)
    while handler.pendingOperation(for: .correctSelection) == nil { await Task.yield() }
    guard let operationID = handler.pendingOperation(for: .correctSelection) else {
        Issue.record("Expected pending correction")
        return
    }
    handler.complete(operationID, output: .none)
    #expect(await waitUntil { notifications.authorizationStatusCallCount >= 1 && !coordinator.isActive })

    // Termination cancels the parked authorization task; releasing it must not
    // request authorization.
    let terminal = await coordinator.prepareForTermination().value
    #expect(terminal == .idle)
    notifications.shouldSuspendAuthorizationStatus = false
    notifications.finishAuthorizationStatus()
    try? await Task.sleep(for: .milliseconds(20))

    #expect(notifications.authorizationRequestCount == 0)
}

// MARK: - BL-004 action-level lifecycle diagnostics

@MainActor
@Test func coordinatorRecordsActionStartedAndSuccessLifecycle() async {
    let handler = ControlledActionHandler()
    let diagnostics = DiagnosticSpy()
    let coordinator = makeCoordinator(handler: handler, diagnostics: diagnostics)

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let operationID) = coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    while !handler.isPending(operationID) { await Task.yield() }
    handler.complete(operationID, output: .panelText("result"))
    while coordinator.isActive { await Task.yield() }

    #expect(await waitUntil { diagnostics.events.count == 2 })
    let events = diagnostics.events
    #expect(events.allSatisfy { $0.operationID == operationID })
    #expect(events.allSatisfy { $0.action == .translateSelectionToUkrainian })
    #expect(events[0].phase == .actionStarted)
    #expect(events[0].provider == nil)
    #expect(events[1].phase == .actionCompleted)
    #expect(events[1].outcome == .success)
    #expect(events[1].duration != nil)
}

@MainActor
@Test func coordinatorRecordsActionFailureLifecycleWithStableCategory() async {
    let diagnostics = DiagnosticSpy()
    let coordinator = makeCoordinator(handler: FailingActionHandler(), diagnostics: diagnostics)

    coordinator.perform(.correctSelection)
    #expect(await waitUntil { diagnostics.events.count == 2 })

    let events = diagnostics.events
    #expect(events[0].phase == .actionStarted)
    #expect(events[1].phase == .actionCompleted)
    // featureUnavailable maps to the stable `unavailable` category.
    #expect(events[1].outcome == .failure(.unavailable))
    #expect(events[1].duration != nil)
    #expect(events.allSatisfy { $0.action == .correctSelection })
}

@MainActor
@Test func coordinatorRecordsCancellationLifecycleForSupersededOperation() async {
    let handler = CancellableActionHandler()
    let diagnostics = DiagnosticSpy()
    let coordinator = makeCoordinator(handler: handler, diagnostics: diagnostics)

    coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let olderOperationID) = coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    while !handler.isPending(olderOperationID) { await Task.yield() }

    // Supersede: the older operation is cancelled.
    coordinator.perform(.correctSelection)

    #expect(await waitUntil {
        diagnostics.events.contains {
            $0.operationID == olderOperationID && $0.phase == .actionCompleted && $0.outcome == .cancelled
        }
    })
    // The superseded operation's terminal is recorded as cancellation, not failure.
    let olderCompleted = diagnostics.events.first {
        $0.operationID == olderOperationID && $0.phase == .actionCompleted
    }
    #expect(olderCompleted?.outcome == .cancelled)

    if let newer = handler.pendingOperation(for: .correctSelection) {
        handler.complete(newer, output: .none)
    }
    while coordinator.isActive { await Task.yield() }
}

@MainActor
@Test func coordinatorActionDiagnosticsCarryOperationIDAndNeverContainContent() async {
    let diagnostics = DiagnosticSpy()
    let coordinator = makeCoordinator(handler: UnsafeFailingActionHandler(), diagnostics: diagnostics)

    coordinator.perform(.translateSelectionToUkrainian)
    #expect(await waitUntil { diagnostics.events.count == 2 })

    let sentinels = ["selected text", "API key", "response body", "sentinel"]
    for event in diagnostics.events {
        #expect(event.operationID != nil)
        for sentinel in sentinels {
            #expect(!event.summary.contains(sentinel))
        }
    }
}
