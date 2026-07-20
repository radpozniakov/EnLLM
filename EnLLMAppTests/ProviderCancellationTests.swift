import AppKit
import EnLLMCore
import EnLLMPlatform
import Foundation
import Testing
@testable import EnLLMApp

// BL-006 — Verify and harden production provider cancellation.
//
// These tests drive the real production async chain
// (ActionCoordinator -> TranslationUseCase -> LLMRouter -> real provider client)
// with a suspended HTTP transport, so cancellation is proven end to end rather
// than only at the individual client boundary.

/// A transport that suspends every request until the test resumes it, and
/// resumes with `CancellationError` when the awaiting task is cancelled. Each
/// in-flight call is tracked independently so concurrent operations cannot
/// resume the wrong continuation.
private actor ControlledTransport: HTTPTransport {
    private(set) var callCount = 0
    private(set) var cancelledCount = 0
    private(set) var cancelSignalCount = 0
    private(set) var completedCount = 0
    private let ignoresCancellation: Bool
    private var pending: [Int: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]

    init(ignoresCancellation: Bool = false) {
        self.ignoresCancellation = ignoresCancellation
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        let id = callCount
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                store(continuation, id: id)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func store(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>, id: Int) {
        pending[id] = continuation
    }

    private func cancel(id: Int) {
        // Simulate a request that already "won" on the wire: record the
        // cancellation signal but leave the continuation pending so a late
        // successful completion can still be delivered.
        if ignoresCancellation {
            cancelSignalCount += 1
            return
        }
        guard let continuation = pending.removeValue(forKey: id) else { return }
        cancelledCount += 1
        continuation.resume(throwing: CancellationError())
    }

    /// Resume every still-pending call with a successful (empty) HTTP 200. Used
    /// to simulate a late transport completion and to drain leftovers at teardown.
    func completeAllSuccessfully() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        for (_, continuation) in pending {
            completedCount += 1
            continuation.resume(returning: (Data(), response))
        }
        pending.removeAll()
    }
}

@MainActor
private struct StubAccessibilityReader: AccessibilitySelectionReading {
    func readSelection() throws -> AccessibilitySelectionResult {
        .selected("selected text", context: .unavailable)
    }
}

@MainActor
private struct StubClipboardCapture: ClipboardSelectionCapturing {
    func captureSelectedText(operationID: OperationID) async throws -> String { "selected text" }
}

@MainActor
private struct TranslationOnlyHandler: ActionHandling {
    let useCase: TranslationUseCase

    func perform(_ action: AppAction, operationID: OperationID) async throws -> ActionOutput {
        .panelText(try await useCase.run(operationID: operationID))
    }
}

@MainActor
private final class NoopClipboardCoordinator: ClipboardCoordinating {
    private(set) var copiedUserText: String?

    func writeUserCopy(_ text: String) async throws { copiedUserText = text }
    func awaitQuiescence() async -> ClipboardTerminalResult { .idle }
}

@MainActor
private final class CancellationPanelSpy: PanelPresenting {
    var onDismiss: ((OperationID) -> Void)?
    var onCopy: ((OperationID, String) -> Void)?
    var onRecoveryAction: ((OperationID, ErrorRecoveryAction) -> Void)?
    var states: [ActionCoordinator.PanelState] = []

    func show(_ state: ActionCoordinator.PanelState) { states.append(state) }
    func hide() {}
    func stopMonitoring() {}

    var errorStates: [ActionCoordinator.PanelState] {
        states.filter { if case .error = $0 { return true } else { return false } }
    }

    func containsResult(_ operationID: OperationID) -> Bool {
        states.contains { if case .result(let id, _) = $0 { return id == operationID } else { return false } }
    }
}

@MainActor
private final class SilentNotificationService: CorrectionFailureNotifying {
    private(set) var delivered: [CorrectionFailureNotification] = []

    func authorizationStatus() async -> NotificationAuthorizationStatus { .denied }
    func requestAuthorization() async {}
    func deliver(_ notification: CorrectionFailureNotification) async throws { delivered.append(notification) }
    func cancelDelivery(for operationID: OperationID) {}
}

@MainActor
private struct CancellationHarness {
    let coordinator: ActionCoordinator
    let anthropicTransport: ControlledTransport
    let openAITransport: ControlledTransport
    let panel: CancellationPanelSpy
    let clipboard: NoopClipboardCoordinator
    let notifications: SilentNotificationService

    /// Primary provider is Anthropic by BuiltInDefaults; the OpenAI transport is
    /// therefore the fallback and must never be touched when a request is cancelled.
    var primaryTransport: ControlledTransport { anthropicTransport }
    var fallbackTransport: ControlledTransport { openAITransport }
}

@MainActor
private func makeHarness(primaryIgnoresCancellation: Bool = false) -> CancellationHarness {
    let anthropicTransport = ControlledTransport(ignoresCancellation: primaryIgnoresCancellation)
    let openAITransport = ControlledTransport()
    let anthropicClient = AnthropicMessagesClient(transport: anthropicTransport)
    let openAIClient = OpenAIResponsesClient(transport: openAITransport)

    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(
        settings: BuiltInDefaults.configuration,
        anthropicCredential: .available("anthropic-key"),
        openAICredential: .available("openai-key")
    ))
    let router = LLMRouter(
        action: .translateSelectionToUkrainian,
        runtimeConfigurationProvider: runtime,
        anthropicClient: anthropicClient,
        openAIClient: openAIClient
    )
    let useCase = TranslationUseCase(
        selectionPolicy: SelectionCapturePolicy(
            accessibilityReader: StubAccessibilityReader(),
            clipboardFallback: StubClipboardCapture()
        ),
        transformer: router
    )
    let panel = CancellationPanelSpy()
    let clipboard = NoopClipboardCoordinator()
    let notifications = SilentNotificationService()
    let coordinator = ActionCoordinator(
        actionHandler: TranslationOnlyHandler(useCase: useCase),
        clipboard: clipboard,
        permissionService: AccessibilityPermissionService(),
        notificationService: notifications,
        panel: panel,
        hotkeyRegistrar: DefaultHotkeyRegistrar()
    )
    return CancellationHarness(
        coordinator: coordinator,
        anthropicTransport: anthropicTransport,
        openAITransport: openAITransport,
        panel: panel,
        clipboard: clipboard,
        notifications: notifications
    )
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

@MainActor
@Test func supersessionCancelsActiveProviderAttemptWithoutFallback() async {
    let harness = makeHarness()

    harness.coordinator.perform(.translateSelectionToUkrainian)
    #expect(await waitUntil { await harness.primaryTransport.callCount == 1 })

    // A newer invocation supersedes the in-flight one.
    harness.coordinator.perform(.translateSelectionToUkrainian)

    #expect(await waitUntil { await harness.primaryTransport.cancelledCount == 1 })
    // Cancellation must never spill into the fallback provider.
    #expect(await harness.fallbackTransport.callCount == 0)
    // The superseded operation produced no error panel.
    #expect(harness.panel.errorStates.isEmpty)
    #expect(harness.notifications.delivered.isEmpty)

    _ = await harness.coordinator.prepareForTermination().value
    await harness.primaryTransport.completeAllSuccessfully()
}

@MainActor
@Test func translationPanelDismissalCancelsActiveRequestWithoutFallback() async {
    let harness = makeHarness()

    harness.coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let operationID) = harness.coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    #expect(await waitUntil { await harness.primaryTransport.callCount == 1 })

    // Dismissing the loading panel cancels the active provider request.
    harness.panel.onDismiss?(operationID)

    #expect(await waitUntil { await harness.primaryTransport.cancelledCount == 1 })
    #expect(await harness.fallbackTransport.callCount == 0)
    #expect(harness.coordinator.panelState == .hidden)
    #expect(harness.panel.errorStates.isEmpty)
}

@MainActor
@Test func quitCancelsActiveRequestWithoutFallbackOrLateEffects() async {
    let harness = makeHarness()

    harness.coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let operationID) = harness.coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    #expect(await waitUntil { await harness.primaryTransport.callCount == 1 })

    let cleanup = harness.coordinator.prepareForTermination()
    #expect(harness.coordinator.isTerminating)

    #expect(await waitUntil { await harness.primaryTransport.cancelledCount == 1 })
    #expect(await harness.fallbackTransport.callCount == 0)
    _ = await cleanup.value

    // A late transport completion after quit cannot present the result.
    await harness.primaryTransport.completeAllSuccessfully()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(!harness.panel.containsResult(operationID))
    #expect(harness.panel.errorStates.isEmpty)
    #expect(harness.notifications.delivered.isEmpty)
}

@MainActor
@Test func lateTransportCompletionForSupersededOperationHasNoUIEffect() async {
    let harness = makeHarness()

    harness.coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let staleOperationID) = harness.coordinator.panelState else {
        Issue.record("Expected first loading panel")
        return
    }
    #expect(await waitUntil { await harness.primaryTransport.callCount == 1 })

    harness.coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let newestOperationID) = harness.coordinator.panelState else {
        Issue.record("Expected second loading panel")
        return
    }
    #expect(await waitUntil { await harness.primaryTransport.callCount == 2 })

    // The superseded operation's transport call was already cancelled by the
    // newer perform, so completing pending calls resumes only the newest one.
    // Its empty body fails decoding and parks it in fallback, while the stale
    // operation produces no panel, notification, or copy effect and the newest
    // operation remains the only one able to present.
    await harness.primaryTransport.completeAllSuccessfully()
    try? await Task.sleep(for: .milliseconds(20))

    #expect(!harness.panel.containsResult(staleOperationID))
    #expect(harness.coordinator.panelState == .loading(newestOperationID))
    #expect(harness.panel.errorStates.isEmpty)
    #expect(harness.notifications.delivered.isEmpty)

    _ = await harness.coordinator.prepareForTermination().value
    await harness.fallbackTransport.completeAllSuccessfully()
}

@MainActor
@Test func lateSuccessfulTransportCompletionAfterCancellationHasNoEffect() async {
    // The transport ignores cancellation and returns success late, simulating a
    // request that already won on the wire after the coordinator cancelled it.
    let harness = makeHarness(primaryIgnoresCancellation: true)

    harness.coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let operationID) = harness.coordinator.panelState else {
        Issue.record("Expected loading panel")
        return
    }
    #expect(await waitUntil { await harness.primaryTransport.callCount == 1 })

    // Dismiss the panel: the coordinator cancels the active request, but the
    // transport ignores the cancellation signal.
    harness.panel.onDismiss?(operationID)
    #expect(await waitUntil { await harness.primaryTransport.cancelSignalCount == 1 })
    #expect(harness.coordinator.panelState == .hidden)

    // The transport now delivers a genuine late success through the real client
    // and router; the post-transport cancellation check must suppress it.
    await harness.primaryTransport.completeAllSuccessfully()
    #expect(await harness.primaryTransport.completedCount == 1)
    try? await Task.sleep(for: .milliseconds(30))

    #expect(!harness.panel.containsResult(operationID))
    #expect(harness.panel.errorStates.isEmpty)
    #expect(harness.notifications.delivered.isEmpty)
    #expect(harness.clipboard.copiedUserText == nil)
    // A late success must never spill into the fallback provider either.
    #expect(await harness.fallbackTransport.callCount == 0)
}

// MARK: - BL-007 supersession boundary matrix (real production chain)

/// Returns a fixed HTTP status with an empty body immediately (no suspension).
/// Used to make the primary provider fail with a fallbackable error so the
/// router transitions to the fallback provider.
private struct ImmediateStatusTransport: HTTPTransport {
    let statusCode: Int

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.invalid")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), response)
    }
}

/// A selection capturer that suspends every call until released and resumes with
/// CancellationError when its awaiting task is cancelled. Mirrors ControlledTransport
/// so concurrent operations track independently.
@MainActor
private final class SuspendingClipboardCapture: ClipboardSelectionCapturing {
    private(set) var callCount = 0
    private(set) var cancelledCount = 0
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]

    func captureSelectedText(operationID: OperationID) async throws -> String {
        callCount += 1
        let id = callCount
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        cancelledCount += 1
        continuation.resume(throwing: CancellationError())
    }

    func completeAll(with text: String) {
        for (_, continuation) in pending { continuation.resume(returning: text) }
        pending.removeAll()
    }
}

@MainActor
private struct UnavailableAccessibilityReader: AccessibilitySelectionReading {
    func readSelection() throws -> AccessibilitySelectionResult { .unavailable(context: .unavailable) }
}

@MainActor
private struct EchoTranslationTransformer: TranslationTransforming {
    func transform(_ text: String) async throws -> String {
        try Task.checkCancellation()
        return "translated: \(text)"
    }
}

@MainActor
private struct FallbackTransitionHarness {
    let coordinator: ActionCoordinator
    let fallbackTransport: ControlledTransport
    let panel: CancellationPanelSpy
    let notifications: SilentNotificationService
}

@MainActor
private func makeFallbackTransitionHarness() -> FallbackTransitionHarness {
    // HTTP 500 maps to providerFailure(.anthropic), which is fallbackable.
    let primaryTransport = ImmediateStatusTransport(statusCode: 500)
    let fallbackTransport = ControlledTransport()
    let anthropicClient = AnthropicMessagesClient(transport: primaryTransport)
    let openAIClient = OpenAIResponsesClient(transport: fallbackTransport)
    let runtime = RuntimeConfigurationStore(RuntimeConfiguration(
        settings: BuiltInDefaults.configuration,
        anthropicCredential: .available("anthropic-key"),
        openAICredential: .available("openai-key")
    ))
    let router = LLMRouter(
        action: .translateSelectionToUkrainian,
        runtimeConfigurationProvider: runtime,
        anthropicClient: anthropicClient,
        openAIClient: openAIClient
    )
    let useCase = TranslationUseCase(
        selectionPolicy: SelectionCapturePolicy(
            accessibilityReader: StubAccessibilityReader(),
            clipboardFallback: StubClipboardCapture()
        ),
        transformer: router
    )
    let panel = CancellationPanelSpy()
    let notifications = SilentNotificationService()
    let coordinator = ActionCoordinator(
        actionHandler: TranslationOnlyHandler(useCase: useCase),
        clipboard: NoopClipboardCoordinator(),
        permissionService: AccessibilityPermissionService(),
        notificationService: notifications,
        panel: panel,
        hotkeyRegistrar: DefaultHotkeyRegistrar()
    )
    return FallbackTransitionHarness(
        coordinator: coordinator,
        fallbackTransport: fallbackTransport,
        panel: panel,
        notifications: notifications
    )
}

@MainActor
private struct CaptureSuspendHarness {
    let coordinator: ActionCoordinator
    let capturer: SuspendingClipboardCapture
    let panel: CancellationPanelSpy
    let notifications: SilentNotificationService
}

@MainActor
private func makeCaptureSuspendHarness() -> CaptureSuspendHarness {
    let capturer = SuspendingClipboardCapture()
    let useCase = TranslationUseCase(
        selectionPolicy: SelectionCapturePolicy(
            accessibilityReader: UnavailableAccessibilityReader(),
            clipboardFallback: capturer
        ),
        transformer: EchoTranslationTransformer()
    )
    let panel = CancellationPanelSpy()
    let notifications = SilentNotificationService()
    let coordinator = ActionCoordinator(
        actionHandler: TranslationOnlyHandler(useCase: useCase),
        clipboard: NoopClipboardCoordinator(),
        permissionService: AccessibilityPermissionService(),
        notificationService: notifications,
        panel: panel,
        hotkeyRegistrar: DefaultHotkeyRegistrar()
    )
    return CaptureSuspendHarness(
        coordinator: coordinator,
        capturer: capturer,
        panel: panel,
        notifications: notifications
    )
}

@MainActor
@Test func supersessionDuringFallbackTransitionCancelsSecondaryWithoutThirdAttempt() async {
    let harness = makeFallbackTransitionHarness()

    harness.coordinator.perform(.translateSelectionToUkrainian)
    // Primary fails fallbackably and the router transitions to the fallback
    // provider, whose request suspends — we are now at the transition boundary.
    #expect(await waitUntil { await harness.fallbackTransport.callCount == 1 })

    harness.coordinator.perform(.translateSelectionToUkrainian)

    #expect(await waitUntil { await harness.fallbackTransport.cancelledCount == 1 })
    // Cancellation during fallback is non-fallbackable: no bothProvidersFailed
    // and no third attempt surface to the user.
    #expect(harness.panel.errorStates.isEmpty)
    #expect(harness.notifications.delivered.isEmpty)

    _ = await harness.coordinator.prepareForTermination().value
    await harness.fallbackTransport.completeAllSuccessfully()
}

@MainActor
@Test func supersessionDuringSelectionCaptureLeavesNoEffectForOlderOperation() async {
    let harness = makeCaptureSuspendHarness()

    harness.coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let olderOperationID) = harness.coordinator.panelState else {
        Issue.record("Expected first loading panel")
        return
    }
    #expect(await waitUntil { await harness.capturer.callCount == 1 })

    harness.coordinator.perform(.translateSelectionToUkrainian)
    guard case .loading(let newestOperationID) = harness.coordinator.panelState else {
        Issue.record("Expected second loading panel")
        return
    }

    // The older capture is cancelled; only the newest operation may present.
    #expect(await waitUntil { await harness.capturer.cancelledCount == 1 })
    #expect(!harness.panel.containsResult(olderOperationID))
    #expect(harness.panel.errorStates.isEmpty)
    #expect(harness.notifications.delivered.isEmpty)
    #expect(harness.coordinator.panelState == .loading(newestOperationID))

    _ = await harness.coordinator.prepareForTermination().value
    harness.capturer.completeAll(with: "late")
}
