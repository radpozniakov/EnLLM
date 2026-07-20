import Foundation
import os

// Privacy-safe operation diagnostics (NFR-013).
//
// Diagnostics may record only closed, content-free facts: the operation ID, the
// app action, a lifecycle phase, the provider identity when applicable, a stable
// error category, and a duration. Selected text, generated text, credentials,
// clipboard data, and HTTP request/response bodies must never enter a diagnostic
// event. This is enforced structurally: `DiagnosticEvent` has no free-form
// String or Data field, so there is no channel through which content can be
// recorded.

/// A point in an operation's lifecycle that a diagnostic event describes.
public enum DiagnosticLifecyclePhase: String, Equatable, Sendable, CaseIterable {
    case actionStarted
    case providerAttemptStarted
    case providerAttemptCompleted
    case actionCompleted
}

/// The terminal outcome of an operation or provider attempt.
///
/// Failures carry only the stable `UserFacingErrorCategory` taxonomy — never a
/// message or raw error. Cancellation is a distinct outcome so it can never be
/// recorded as a provider failure.
public enum DiagnosticOutcome: Equatable, Sendable {
    case success
    case cancelled
    case failure(UserFacingErrorCategory)

    var summary: String {
        switch self {
        case .success: "success"
        case .cancelled: "cancelled"
        case .failure(let category): "failure(\(category.rawValue))"
        }
    }
}

/// A single content-free diagnostic fact about an operation.
///
/// Every field is a closed enum, a typed identifier, or a numeric duration. There
/// is deliberately no `String`/`Data` payload, so provider bodies, credentials,
/// clipboard data, and selected/generated text cannot be represented.
public struct DiagnosticEvent: Equatable, Sendable {
    public let operationID: OperationID
    public let action: AppAction
    public let phase: DiagnosticLifecyclePhase
    public let provider: LLMProvider?
    public let outcome: DiagnosticOutcome?
    public let duration: Duration?

    public init(
        operationID: OperationID,
        action: AppAction,
        phase: DiagnosticLifecyclePhase,
        provider: LLMProvider? = nil,
        outcome: DiagnosticOutcome? = nil,
        duration: Duration? = nil
    ) {
        self.operationID = operationID
        self.action = action
        self.phase = phase
        self.provider = provider
        self.outcome = outcome
        self.duration = duration
    }

    /// A stable, content-free single-line rendering built only from the typed
    /// fields above.
    public var summary: String {
        var parts = [
            "op=\(operationID.rawValue.uuidString)",
            "action=\(action.rawValue)",
            "phase=\(phase.rawValue)"
        ]
        if let provider {
            parts.append("provider=\(provider.rawValue)")
        }
        if let outcome {
            parts.append("outcome=\(outcome.summary)")
        }
        if let duration {
            parts.append("duration=\(Self.milliseconds(duration))ms")
        }
        return parts.joined(separator: " ")
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        // Operation durations are non-negative; sub-millisecond precision is
        // truncated toward zero. `seconds * 1000` only overflows past ~2.9e8
        // years, which is not reachable for a request timing.
        let components = duration.components
        return components.seconds * 1000
            + Int64(components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Carries the current operation's identity into deeper layers (e.g. routing)
/// for diagnostics only, without threading a diagnostics parameter through the
/// domain protocols. A use case establishes the scope around the work whose
/// provider attempts should be attributed to that operation.
public enum DiagnosticContext {
    @TaskLocal public static var operationID: OperationID?
}

/// Injectable sink for privacy-safe diagnostics. Implementations receive only the
/// closed `DiagnosticEvent`; there is no content-carrying or history/query method.
public protocol DiagnosticRecording: Sendable {
    func record(_ event: DiagnosticEvent)
}

/// Records nothing and keeps no state. The minimal, local Release behavior: no
/// history, analytics, telemetry, or persisted operation content.
public struct NoOpDiagnosticRecorder: DiagnosticRecording {
    public init() {}
    public func record(_ event: DiagnosticEvent) {}
}

#if DEBUG
/// Debug-only recorder that renders each event's content-free summary to an
/// injectable sink and retains nothing. Absent from Release builds, so Release
/// can never emit operation content through this path.
public struct LocalDiagnosticRecorder: DiagnosticRecording {
    private let emit: @Sendable (String) -> Void

    public init(emit: @escaping @Sendable (String) -> Void = LocalDiagnosticRecorder.defaultEmit) {
        self.emit = emit
    }

    public func record(_ event: DiagnosticEvent) {
        emit(event.summary)
    }

    private static let logger = Logger(subsystem: "com.radpozniakov.enllm", category: "diagnostics")

    /// The summary is content-free by construction, so it is logged as public.
    public static let defaultEmit: @Sendable (String) -> Void = { message in
        logger.debug("\(message, privacy: .public)")
    }
}
#endif

/// The default recorder for the current build: a local Debug recorder in DEBUG,
/// and the no-op recorder otherwise.
public enum DefaultDiagnosticRecorder {
    public static func make() -> any DiagnosticRecording {
        #if DEBUG
        LocalDiagnosticRecorder()
        #else
        NoOpDiagnosticRecorder()
        #endif
    }
}
