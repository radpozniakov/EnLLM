import Foundation

public struct OperationID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct SelectionTargetToken: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct SelectionWindowToken: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TextSelectionRange: Hashable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct SelectionTargetContext: Equatable, Sendable {
    public let frontmostProcessID: Int32?
    public let focusedWindowToken: SelectionWindowToken?
    public let targetToken: SelectionTargetToken?
    public let selectedRange: TextSelectionRange?

    public init(
        frontmostProcessID: Int32?,
        focusedWindowToken: SelectionWindowToken?,
        targetToken: SelectionTargetToken?,
        selectedRange: TextSelectionRange?
    ) {
        self.frontmostProcessID = frontmostProcessID
        self.focusedWindowToken = focusedWindowToken
        self.targetToken = targetToken
        self.selectedRange = selectedRange
    }

    public static let unavailable = SelectionTargetContext(
        frontmostProcessID: nil,
        focusedWindowToken: nil,
        targetToken: nil,
        selectedRange: nil
    )
}

public enum SelectionCaptureMethod: Sendable, Equatable {
    case accessibility
    case clipboardFallback
}

public struct SelectionCapture: Equatable, Sendable {
    public let operationID: OperationID
    public let text: String
    public let method: SelectionCaptureMethod
    public let targetContext: SelectionTargetContext

    public init(
        operationID: OperationID,
        text: String,
        method: SelectionCaptureMethod,
        targetContext: SelectionTargetContext = .unavailable
    ) {
        self.operationID = operationID
        self.text = text
        self.method = method
        self.targetContext = targetContext
    }
}

public enum AccessibilitySelectionResult: Sendable, Equatable {
    case selected(String, context: SelectionTargetContext)
    case unavailable(context: SelectionTargetContext)
    case empty
    case secureField
    case permissionMissing
}

@MainActor
public protocol AccessibilitySelectionReading: Sendable {
    func readSelection() throws -> AccessibilitySelectionResult
}

@MainActor
public protocol ClipboardSelectionCapturing: Sendable {
    func captureSelectedText(operationID: OperationID) async throws -> String
}

@MainActor
public protocol ClipboardCoordinating: Sendable {
    func writeUserCopy(_ text: String) async throws
    func awaitQuiescence() async -> ClipboardTerminalResult
}

public enum ClipboardTerminalResult: Sendable, Equatable {
    case idle
    case restored
    case restorationFailed
}

@MainActor
public struct SelectionCapturePolicy: Sendable {
    private let accessibilityReader: any AccessibilitySelectionReading
    private let clipboardFallback: any ClipboardSelectionCapturing

    public init(
        accessibilityReader: any AccessibilitySelectionReading,
        clipboardFallback: any ClipboardSelectionCapturing
    ) {
        self.accessibilityReader = accessibilityReader
        self.clipboardFallback = clipboardFallback
    }

    public func capture(operationID: OperationID) async throws -> SelectionCapture {
        try Task.checkCancellation()

        switch try accessibilityReader.readSelection() {
        case .selected(let text, let context):
            return SelectionCapture(
                operationID: operationID,
                text: try InputValidationPolicy.validate(text),
                method: .accessibility,
                targetContext: context
            )
        case .unavailable(let context):
            let text = try await clipboardFallback.captureSelectedText(operationID: operationID)
            return SelectionCapture(
                operationID: operationID,
                text: try InputValidationPolicy.validate(text),
                method: .clipboardFallback,
                targetContext: context
            )
        case .empty:
            throw EnLLMError.noSelection
        case .secureField:
            throw EnLLMError.secureFieldUnsupported
        case .permissionMissing:
            throw EnLLMError.accessibilityPermissionMissing
        }
    }
}

public enum InputValidationPolicy {
    public static func validate(
        _ text: String,
        maximumCharacters: Int = BuiltInDefaults.maximumInputLength
    ) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnLLMError.noSelection
        }
        guard text.count <= maximumCharacters else {
            throw EnLLMError.inputTooLong(maximum: maximumCharacters)
        }
        return text
    }
}

public struct CurrentSelectionTarget: Equatable, Sendable {
    public let frontmostProcessID: Int32?
    public let focusedWindowMatches: Bool?
    public let focusedElementMatches: Bool?
    public let selectedRange: TextSelectionRange?
    public let selectedText: String?

    public init(
        frontmostProcessID: Int32?,
        focusedWindowMatches: Bool?,
        focusedElementMatches: Bool?,
        selectedRange: TextSelectionRange?,
        selectedText: String?
    ) {
        self.frontmostProcessID = frontmostProcessID
        self.focusedWindowMatches = focusedWindowMatches
        self.focusedElementMatches = focusedElementMatches
        self.selectedRange = selectedRange
        self.selectedText = selectedText
    }
}

public enum TargetVerificationFailure: String, CaseIterable, Equatable, Sendable {
    case capturedProcessUnavailable
    case capturedWindowUnavailable
    case capturedElementUnavailable
    case capturedRangeUnavailable
    case currentProcessUnavailable
    case processMismatch
    case focusedWindowUnavailable
    case focusedWindowMismatch
    case focusedElementUnavailable
    case focusedElementMismatch
    case selectedRangeUnavailable
    case selectedRangeMismatch
    case selectedTextUnavailable
    case selectedTextMismatch
}

public enum TargetVerificationPolicy {
    public static func metadataFailure(
        for capture: SelectionCapture,
        current: CurrentSelectionTarget
    ) -> TargetVerificationFailure? {
        guard let capturedProcessID = capture.targetContext.frontmostProcessID else {
            return .capturedProcessUnavailable
        }
        guard let currentProcessID = current.frontmostProcessID else {
            return .currentProcessUnavailable
        }
        guard currentProcessID == capturedProcessID else {
            return .processMismatch
        }

        switch capture.method {
        case .accessibility:
            return strictAccessibilityMetadataFailure(for: capture, current: current)
        case .clipboardFallback:
            return clipboardCompatibilityMetadataFailure(for: capture, current: current)
        }
    }

    public static func failure(
        for capture: SelectionCapture,
        current: CurrentSelectionTarget
    ) -> TargetVerificationFailure? {
        if let failure = metadataFailure(for: capture, current: current) {
            return failure
        }
        guard let selectedText = current.selectedText else {
            return .selectedTextUnavailable
        }
        guard selectedText == capture.text else {
            return .selectedTextMismatch
        }
        return nil
    }

    private static func strictAccessibilityMetadataFailure(
        for capture: SelectionCapture,
        current: CurrentSelectionTarget
    ) -> TargetVerificationFailure? {
        guard capture.targetContext.targetToken != nil else {
            return .capturedElementUnavailable
        }
        guard let capturedRange = capture.targetContext.selectedRange else {
            return .capturedRangeUnavailable
        }
        guard let focusedElementMatches = current.focusedElementMatches else {
            return .focusedElementUnavailable
        }
        guard focusedElementMatches else {
            return .focusedElementMismatch
        }
        guard let selectedRange = current.selectedRange else {
            return .selectedRangeUnavailable
        }
        guard selectedRange == capturedRange else {
            return .selectedRangeMismatch
        }
        return nil
    }

    private static func clipboardCompatibilityMetadataFailure(
        for capture: SelectionCapture,
        current: CurrentSelectionTarget
    ) -> TargetVerificationFailure? {
        guard capture.targetContext.focusedWindowToken != nil else {
            return .capturedWindowUnavailable
        }
        guard let focusedWindowMatches = current.focusedWindowMatches else {
            return .focusedWindowUnavailable
        }
        guard focusedWindowMatches else {
            return .focusedWindowMismatch
        }

        if capture.targetContext.targetToken != nil {
            guard let focusedElementMatches = current.focusedElementMatches else {
                return .focusedElementUnavailable
            }
            guard focusedElementMatches else {
                return .focusedElementMismatch
            }
        }

        if let capturedRange = capture.targetContext.selectedRange {
            guard let selectedRange = current.selectedRange else {
                return .selectedRangeUnavailable
            }
            guard selectedRange == capturedRange else {
                return .selectedRangeMismatch
            }
        }
        return nil
    }
}

public enum CorrectionApplicationResult: Equatable, Sendable {
    case replaced
    case safetyPanel(TargetVerificationFailure)
}

@MainActor
public protocol CorrectionApplying: Sendable {
    func apply(_ correctedText: String, to capture: SelectionCapture) async throws
        -> CorrectionApplicationResult
}

@MainActor
public protocol TranslationTransforming: Sendable {
    func transform(_ text: String) async throws -> String
}

@MainActor
public protocol CorrectionTransforming: Sendable {
    func transform(_ text: String) async throws -> String
}

@MainActor
public struct TranslationUseCase: Sendable {
    private let selectionPolicy: SelectionCapturePolicy
    private let transformer: any TranslationTransforming

    public init(
        selectionPolicy: SelectionCapturePolicy,
        transformer: any TranslationTransforming
    ) {
        self.selectionPolicy = selectionPolicy
        self.transformer = transformer
    }

    public func run(operationID: OperationID) async throws -> String {
        let capture = try await selectionPolicy.capture(operationID: operationID)
        try Task.checkCancellation()
        let translatedText = try await DiagnosticContext.$operationID.withValue(operationID) {
            try await transformer.transform(capture.text)
        }
        try Task.checkCancellation()
        guard !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnLLMError.emptyOutput
        }
        return translatedText
    }
}

@MainActor
public struct CorrectionUseCase: Sendable {
    private let selectionPolicy: SelectionCapturePolicy
    private let transformer: any CorrectionTransforming
    private let applier: any CorrectionApplying

    public init(
        selectionPolicy: SelectionCapturePolicy,
        transformer: any CorrectionTransforming,
        applier: any CorrectionApplying
    ) {
        self.selectionPolicy = selectionPolicy
        self.transformer = transformer
        self.applier = applier
    }

    public func run(operationID: OperationID) async throws -> ActionOutput {
        let capture = try await selectionPolicy.capture(operationID: operationID)
        try Task.checkCancellation()
        let correctedText = try await DiagnosticContext.$operationID.withValue(operationID) {
            try await transformer.transform(capture.text)
        }
        try Task.checkCancellation()
        guard !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnLLMError.emptyOutput
        }

        switch try await applier.apply(correctedText, to: capture) {
        case .replaced:
            return .none
        case .safetyPanel:
            return .panelText(correctedText)
        }
    }
}

public enum ActionOutput: Sendable, Equatable {
    case none
    case panelText(String)
}
