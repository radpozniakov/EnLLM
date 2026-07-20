import Foundation
import Testing
@testable import EnLLMCore

private let completeTargetContext = SelectionTargetContext(
    frontmostProcessID: 42,
    focusedWindowToken: SelectionWindowToken(),
    targetToken: SelectionTargetToken(),
    selectedRange: TextSelectionRange(location: 3, length: 4)
)

@MainActor
private struct StubAccessibilityReader: AccessibilitySelectionReading {
    let result: AccessibilitySelectionResult
    func readSelection() throws -> AccessibilitySelectionResult { result }
}

@MainActor
private final class StubClipboardCapture: ClipboardSelectionCapturing {
    var calls = 0
    let text: String

    init(text: String = "fallback") { self.text = text }

    func captureSelectedText(operationID: OperationID) async throws -> String {
        calls += 1
        return text
    }
}

@MainActor
@Test func accessibilitySelectionWinsWithoutTouchingClipboard() async throws {
    let clipboard = StubClipboardCapture()
    let policy = SelectionCapturePolicy(
        accessibilityReader: StubAccessibilityReader(
            result: .selected("  kept  ", context: completeTargetContext)
        ),
        clipboardFallback: clipboard
    )

    let capture = try await policy.capture(operationID: OperationID())

    #expect(capture.text == "  kept  ")
    #expect(capture.method == .accessibility)
    #expect(capture.targetContext == completeTargetContext)
    #expect(clipboard.calls == 0)
}

@MainActor
@Test func unavailableAccessibilityUsesClipboardFallback() async throws {
    let clipboard = StubClipboardCapture(text: "from clipboard")
    let policy = SelectionCapturePolicy(
        accessibilityReader: StubAccessibilityReader(
            result: .unavailable(context: completeTargetContext)
        ),
        clipboardFallback: clipboard
    )

    let capture = try await policy.capture(operationID: OperationID())

    #expect(capture.text == "from clipboard")
    #expect(capture.method == .clipboardFallback)
    #expect(capture.targetContext == completeTargetContext)
    #expect(clipboard.calls == 1)
}

@MainActor
@Test func emptyAccessibilityResultDoesNotFallBack() async {
    let clipboard = StubClipboardCapture()
    let policy = SelectionCapturePolicy(
        accessibilityReader: StubAccessibilityReader(result: .empty),
        clipboardFallback: clipboard
    )

    await #expect(throws: EnLLMError.noSelection) {
        try await policy.capture(operationID: OperationID())
    }
    #expect(clipboard.calls == 0)
}

@MainActor
@Test func missingAccessibilityPermissionDoesNotFallBack() async {
    let clipboard = StubClipboardCapture()
    let policy = SelectionCapturePolicy(
        accessibilityReader: StubAccessibilityReader(result: .permissionMissing),
        clipboardFallback: clipboard
    )

    await #expect(throws: EnLLMError.accessibilityPermissionMissing) {
        try await policy.capture(operationID: OperationID())
    }
    #expect(clipboard.calls == 0)
}

@MainActor
@Test func secureFieldDoesNotFallBack() async {
    let clipboard = StubClipboardCapture()
    let policy = SelectionCapturePolicy(
        accessibilityReader: StubAccessibilityReader(result: .secureField),
        clipboardFallback: clipboard
    )

    await #expect(throws: EnLLMError.secureFieldUnsupported) {
        try await policy.capture(operationID: OperationID())
    }
    #expect(clipboard.calls == 0)
}

@Test func inputValidationPreservesFormattingAndEnforcesSwiftCharacterBoundary() throws {
    #expect(try InputValidationPolicy.validate("  text\n") == "  text\n")
    #expect(try InputValidationPolicy.validate(String(repeating: "🧑🏽‍💻", count: 10_000)).count == 10_000)
    #expect(throws: EnLLMError.inputTooLong(maximum: 10_000)) {
        try InputValidationPolicy.validate(String(repeating: "a", count: 10_001))
    }
    #expect(throws: EnLLMError.noSelection) {
        try InputValidationPolicy.validate(" \n\t ")
    }
}

@Test func accessibilityTargetVerificationRequiresExactElementRangeAndText() {
    let capture = captureWith(context: completeTargetContext)
    let valid = CurrentSelectionTarget(
        frontmostProcessID: 42,
        focusedWindowMatches: true,
        focusedElementMatches: true,
        selectedRange: TextSelectionRange(location: 3, length: 4),
        selectedText: "source"
    )

    #expect(TargetVerificationPolicy.failure(for: capture, current: valid) == nil)
    #expect(TargetVerificationPolicy.failure(
        for: captureWith(context: .init(
            frontmostProcessID: nil,
            focusedWindowToken: completeTargetContext.focusedWindowToken,
            targetToken: completeTargetContext.targetToken,
            selectedRange: completeTargetContext.selectedRange
        )), current: valid
    ) == .capturedProcessUnavailable)
    #expect(TargetVerificationPolicy.failure(
        for: captureWith(context: .init(
            frontmostProcessID: 42,
            focusedWindowToken: completeTargetContext.focusedWindowToken,
            targetToken: nil,
            selectedRange: completeTargetContext.selectedRange
        )), current: valid
    ) == .capturedElementUnavailable)
    #expect(TargetVerificationPolicy.failure(
        for: captureWith(context: .init(
            frontmostProcessID: 42,
            focusedWindowToken: completeTargetContext.focusedWindowToken,
            targetToken: completeTargetContext.targetToken,
            selectedRange: nil
        )), current: valid
    ) == .capturedRangeUnavailable)

    let currentFailures: [(CurrentSelectionTarget, TargetVerificationFailure)] = [
        (.init(frontmostProcessID: nil, focusedWindowMatches: true, focusedElementMatches: true, selectedRange: valid.selectedRange, selectedText: "source"), .currentProcessUnavailable),
        (.init(frontmostProcessID: 99, focusedWindowMatches: true, focusedElementMatches: true, selectedRange: valid.selectedRange, selectedText: "source"), .processMismatch),
        (.init(frontmostProcessID: 42, focusedWindowMatches: true, focusedElementMatches: nil, selectedRange: valid.selectedRange, selectedText: "source"), .focusedElementUnavailable),
        (.init(frontmostProcessID: 42, focusedWindowMatches: true, focusedElementMatches: false, selectedRange: valid.selectedRange, selectedText: "source"), .focusedElementMismatch),
        (.init(frontmostProcessID: 42, focusedWindowMatches: true, focusedElementMatches: true, selectedRange: nil, selectedText: "source"), .selectedRangeUnavailable),
        (.init(frontmostProcessID: 42, focusedWindowMatches: true, focusedElementMatches: true, selectedRange: .init(location: 4, length: 4), selectedText: "source"), .selectedRangeMismatch),
        (.init(frontmostProcessID: 42, focusedWindowMatches: true, focusedElementMatches: true, selectedRange: valid.selectedRange, selectedText: nil), .selectedTextUnavailable),
        (.init(frontmostProcessID: 42, focusedWindowMatches: true, focusedElementMatches: true, selectedRange: valid.selectedRange, selectedText: "changed"), .selectedTextMismatch)
    ]

    for (current, expectedFailure) in currentFailures {
        #expect(TargetVerificationPolicy.failure(for: capture, current: current) == expectedFailure)
    }
}

@Test func clipboardFallbackVerificationAllowsMissingElementAndRangeWithStableWindow() {
    let context = SelectionTargetContext(
        frontmostProcessID: 42,
        focusedWindowToken: SelectionWindowToken(),
        targetToken: nil,
        selectedRange: nil
    )
    let capture = captureWith(method: .clipboardFallback, context: context)
    let valid = CurrentSelectionTarget(
        frontmostProcessID: 42,
        focusedWindowMatches: true,
        focusedElementMatches: nil,
        selectedRange: nil,
        selectedText: "source"
    )

    #expect(TargetVerificationPolicy.failure(for: capture, current: valid) == nil)
    let metadataOnly = CurrentSelectionTarget(
        frontmostProcessID: 42,
        focusedWindowMatches: true,
        focusedElementMatches: nil,
        selectedRange: nil,
        selectedText: nil
    )
    #expect(TargetVerificationPolicy.metadataFailure(for: capture, current: metadataOnly) == nil)
    #expect(TargetVerificationPolicy.failure(for: capture, current: metadataOnly) == .selectedTextUnavailable)
    #expect(TargetVerificationPolicy.failure(
        for: captureWith(method: .clipboardFallback, context: .init(
            frontmostProcessID: 42,
            focusedWindowToken: nil,
            targetToken: nil,
            selectedRange: nil
        )), current: valid
    ) == .capturedWindowUnavailable)
    #expect(TargetVerificationPolicy.failure(
        for: capture,
        current: .init(
            frontmostProcessID: 42,
            focusedWindowMatches: nil,
            focusedElementMatches: nil,
            selectedRange: nil,
            selectedText: "source"
        )
    ) == .focusedWindowUnavailable)
    #expect(TargetVerificationPolicy.failure(
        for: capture,
        current: .init(
            frontmostProcessID: 42,
            focusedWindowMatches: false,
            focusedElementMatches: nil,
            selectedRange: nil,
            selectedText: "source"
        )
    ) == .focusedWindowMismatch)
}

@Test func clipboardFallbackStillRequiresAvailableMetadataToRemainEqual() {
    let capture = captureWith(method: .clipboardFallback, context: completeTargetContext)

    #expect(TargetVerificationPolicy.failure(
        for: capture,
        current: .init(
            frontmostProcessID: 42,
            focusedWindowMatches: true,
            focusedElementMatches: false,
            selectedRange: completeTargetContext.selectedRange,
            selectedText: "source"
        )
    ) == .focusedElementMismatch)
    #expect(TargetVerificationPolicy.failure(
        for: capture,
        current: .init(
            frontmostProcessID: 42,
            focusedWindowMatches: true,
            focusedElementMatches: true,
            selectedRange: nil,
            selectedText: "source"
        )
    ) == .selectedRangeUnavailable)
}

@MainActor
@Test func translationRejectsEmptyOutput() async {
    let selectionPolicy = SelectionCapturePolicy(
        accessibilityReader: StubAccessibilityReader(
            result: .selected("source", context: completeTargetContext)
        ),
        clipboardFallback: StubClipboardCapture()
    )
    let useCase = TranslationUseCase(
        selectionPolicy: selectionPolicy,
        transformer: StubTranslationTransformer(output: " \n ")
    )

    await #expect(throws: EnLLMError.emptyOutput) {
        try await useCase.run(operationID: OperationID())
    }
}

@MainActor
@Test func correctionUsesSafetyPanelForAnUnverifiedTargetAndRejectsEmptyOutput() async throws {
    let selectionPolicy = SelectionCapturePolicy(
        accessibilityReader: StubAccessibilityReader(
            result: .selected("source", context: completeTargetContext)
        ),
        clipboardFallback: StubClipboardCapture()
    )
    let safetyApplier = StubCorrectionApplier(result: .safetyPanel(.processMismatch))
    let safetyUseCase = CorrectionUseCase(
        selectionPolicy: selectionPolicy,
        transformer: StubCorrectionTransformer(output: "corrected"),
        applier: safetyApplier
    )

    #expect(try await safetyUseCase.run(operationID: OperationID()) == .panelText("corrected"))
    #expect(safetyApplier.appliedText == "corrected")

    let replacementApplier = StubCorrectionApplier(result: .replaced)
    let replacementUseCase = CorrectionUseCase(
        selectionPolicy: selectionPolicy,
        transformer: StubCorrectionTransformer(output: "corrected"),
        applier: replacementApplier
    )
    #expect(try await replacementUseCase.run(operationID: OperationID()) == .none)

    let emptyUseCase = CorrectionUseCase(
        selectionPolicy: selectionPolicy,
        transformer: StubCorrectionTransformer(output: " \n "),
        applier: StubCorrectionApplier(result: .replaced)
    )
    await #expect(throws: EnLLMError.emptyOutput) {
        try await emptyUseCase.run(operationID: OperationID())
    }

    let cancelledApplier = StubCorrectionApplier(result: .replaced)
    let cancelledUseCase = CorrectionUseCase(
        selectionPolicy: selectionPolicy,
        transformer: CancellingCorrectionTransformer(),
        applier: cancelledApplier
    )
    await #expect(throws: CancellationError.self) {
        try await cancelledUseCase.run(operationID: OperationID())
    }
    #expect(cancelledApplier.appliedText == nil)
}

private func captureWith(
    method: SelectionCaptureMethod = .accessibility,
    context: SelectionTargetContext
) -> SelectionCapture {
    SelectionCapture(
        operationID: OperationID(),
        text: "source",
        method: method,
        targetContext: context
    )
}

@MainActor
private struct StubTranslationTransformer: TranslationTransforming {
    let output: String
    func transform(_ text: String) async throws -> String { output }
}

@MainActor
private struct StubCorrectionTransformer: CorrectionTransforming {
    let output: String
    func transform(_ text: String) async throws -> String { output }
}

@MainActor
private struct CancellingCorrectionTransformer: CorrectionTransforming {
    func transform(_ text: String) async throws -> String {
        withUnsafeCurrentTask { task in task?.cancel() }
        return "corrected"
    }
}

@MainActor
private final class StubCorrectionApplier: CorrectionApplying {
    let result: CorrectionApplicationResult
    private(set) var appliedText: String?

    init(result: CorrectionApplicationResult) {
        self.result = result
    }

    func apply(
        _ correctedText: String,
        to capture: SelectionCapture
    ) async throws -> CorrectionApplicationResult {
        appliedText = correctedText
        return result
    }
}
