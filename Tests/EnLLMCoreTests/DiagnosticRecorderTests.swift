import EnLLMCore
import Foundation
import Testing

private let contentSentinels = [
    "selected text",
    "generated text",
    "API key",
    "sk-secret-credential",
    "response body",
    "clipboard payload",
    "secure field"
]

/// Every representative diagnostic event we can build across the closed field
/// space. Because no field accepts free-form content, this is the *complete*
/// input surface an attacker/content could reach.
@MainActor
private func representativeEvents() -> [DiagnosticEvent] {
    let outcomes: [DiagnosticOutcome?] =
        [nil, .success, .cancelled] + UserFacingErrorCategory.allCases.map { .failure($0) }
    let providers: [LLMProvider?] = [nil] + LLMProvider.allCases
    let durations: [Duration?] = [nil, .milliseconds(0), .milliseconds(1234), .seconds(3)]

    var events: [DiagnosticEvent] = []
    for action in AppAction.allCases {
        for phase in DiagnosticLifecyclePhase.allCases {
            for provider in providers {
                for outcome in outcomes {
                    for duration in durations {
                        events.append(DiagnosticEvent(
                            operationID: OperationID(),
                            action: action,
                            phase: phase,
                            provider: provider,
                            outcome: outcome,
                            duration: duration
                        ))
                    }
                }
            }
        }
    }
    return events
}

/// A summary token is content-free only if it matches one of the closed shapes:
/// op=<uuid>, action=<known>, phase=<known>, provider=<known>, outcome=<known>,
/// duration=<int>ms.
private func tokenIsAllowed(_ token: String) -> Bool {
    if let value = token.dropPrefixIfPresent("op=") {
        return UUID(uuidString: value) != nil
    }
    if let value = token.dropPrefixIfPresent("action=") {
        return AppAction.allCases.contains { $0.rawValue == value }
    }
    if let value = token.dropPrefixIfPresent("phase=") {
        return DiagnosticLifecyclePhase.allCases.contains { $0.rawValue == value }
    }
    if let value = token.dropPrefixIfPresent("provider=") {
        return LLMProvider.allCases.contains { $0.rawValue == value }
    }
    if let value = token.dropPrefixIfPresent("outcome=") {
        if value == "success" || value == "cancelled" { return true }
        guard value.hasPrefix("failure("), value.hasSuffix(")") else { return false }
        let category = String(value.dropFirst("failure(".count).dropLast())
        return UserFacingErrorCategory.allCases.contains { $0.rawValue == category }
    }
    if let value = token.dropPrefixIfPresent("duration="), value.hasSuffix("ms") {
        return Int64(value.dropLast(2)) != nil
    }
    return false
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

@MainActor
@Test func diagnosticEventSummaryContainsOnlyClosedContentFreeFacts() {
    for event in representativeEvents() {
        let summary = event.summary

        // No content sentinel can appear — there is no field to carry it.
        for sentinel in contentSentinels {
            #expect(!summary.contains(sentinel))
        }

        // Every token is one of the closed, whitelisted shapes.
        for token in summary.split(separator: " ").map(String.init) {
            #expect(tokenIsAllowed(token), "Unexpected diagnostic token: \(token)")
        }
    }
}

@MainActor
@Test func diagnosticEventRendersEachApprovedFieldAndOmitsAbsentOnes() {
    let operationID = OperationID()
    let full = DiagnosticEvent(
        operationID: operationID,
        action: .translateSelectionToUkrainian,
        phase: .providerAttemptCompleted,
        provider: .anthropic,
        outcome: .failure(.provider),
        duration: .milliseconds(250)
    )
    #expect(full.summary == "op=\(operationID.rawValue.uuidString) "
        + "action=translateSelectionToUkrainian phase=providerAttemptCompleted "
        + "provider=anthropic outcome=failure(provider) duration=250ms")

    let minimal = DiagnosticEvent(
        operationID: operationID,
        action: .correctSelection,
        phase: .actionStarted
    )
    #expect(minimal.summary == "op=\(operationID.rawValue.uuidString) "
        + "action=correctSelection phase=actionStarted")
    #expect(!minimal.summary.contains("provider="))
    #expect(!minimal.summary.contains("outcome="))
    #expect(!minimal.summary.contains("duration="))
}

@MainActor
@Test func cancellationIsADistinctOutcomeFromProviderFailure() {
    let cancelled = DiagnosticEvent(
        operationID: OperationID(),
        action: .translateSelectionToUkrainian,
        phase: .providerAttemptCompleted,
        provider: .openAI,
        outcome: .cancelled
    )
    #expect(cancelled.summary.contains("outcome=cancelled"))
    #expect(!cancelled.summary.contains("failure"))
}

@MainActor
@Test func noOpRecorderRecordsNothingAndExposesNoHistory() {
    let recorder = NoOpDiagnosticRecorder()
    for event in representativeEvents() {
        recorder.record(event)
    }
    // NoOpDiagnosticRecorder is a stateless value type: DiagnosticRecording's only
    // member is record(_:), so there is no history/analytics/query surface to read
    // back, and recording is side-effect-free.
    let asProtocol: any DiagnosticRecording = recorder
    asProtocol.record(DiagnosticEvent(
        operationID: OperationID(),
        action: .correctSelection,
        phase: .actionCompleted,
        outcome: .success
    ))
}

@Test func defaultRecorderIsMinimalPerBuildConfiguration() {
    let recorder = DefaultDiagnosticRecorder.make()
    #if DEBUG
    #expect(recorder is LocalDiagnosticRecorder)
    #else
    #expect(recorder is NoOpDiagnosticRecorder)
    #endif
}

#if DEBUG
@MainActor
@Test func localRecorderForwardsContentFreeSummaryAndRetainsNothing() {
    final class Sink: @unchecked Sendable {
        var messages: [String] = []
    }
    let sink = Sink()
    let recorder = LocalDiagnosticRecorder(emit: { message in sink.messages.append(message) })

    let events = representativeEvents()
    for event in events {
        recorder.record(event)
    }

    // The recorder forwards exactly one content-free summary per event and keeps
    // no buffer of its own (all state lives in the injected sink).
    #expect(sink.messages.count == events.count)
    for (event, message) in zip(events, sink.messages) {
        #expect(message == event.summary)
        for sentinel in contentSentinels {
            #expect(!message.contains(sentinel))
        }
    }
}
#endif
