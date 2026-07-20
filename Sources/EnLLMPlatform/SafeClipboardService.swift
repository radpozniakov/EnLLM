import AppKit
import CoreGraphics
import EnLLMCore
import Foundation

struct PasteboardSnapshot: Equatable {
    struct Item: Equatable {
        struct Value: Equatable {
            let type: NSPasteboard.PasteboardType
            let data: Data
        }

        let values: [Value]
    }

    let items: [Item]

    static func capture(from pasteboard: NSPasteboard) throws -> PasteboardSnapshot {
        let items = try (pasteboard.pasteboardItems ?? []).map { item in
            let values = try item.types.map { type in
                guard let data = item.data(forType: type) else {
                    throw EnLLMError.clipboardSnapshotIncomplete
                }
                return Item.Value(type: type, data: data)
            }
            return Item(values: values)
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()
        guard !items.isEmpty else {
            return
        }

        let pasteboardItems = try items.map { storedItem in
            let item = NSPasteboardItem()
            for value in storedItem.values {
                guard item.setData(value.data, forType: value.type) else {
                    throw EnLLMError.clipboardRestorationFailed
                }
            }
            return item
        }

        guard pasteboard.writeObjects(pasteboardItems) else {
            throw EnLLMError.clipboardRestorationFailed
        }
    }
}

private actor ExclusiveGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
public final class SafeClipboardService: ClipboardSelectionCapturing, ClipboardCoordinating {
    public typealias KeyboardEventPoster = @MainActor @Sendable () throws -> Void
    typealias EventPostedHook = @MainActor @Sendable () async -> Void

    private let pasteboard: NSPasteboard
    private let postCopyEvent: KeyboardEventPoster
    private let postPasteEvent: KeyboardEventPoster
    private let beforeCopyPosted: EventPostedHook
    private let afterCopyPosted: EventPostedHook
    private let afterPastePosted: EventPostedHook
    private let pollInterval: Duration
    private let captureTimeout: Duration
    private let pasteConsumptionDelay: Duration
    private let gate = ExclusiveGate()
    private var terminalResult: ClipboardTerminalResult = .idle

    public convenience init() {
        self.init(
            pasteboard: .general,
            postCopyEvent: Self.postSystemCopy,
            postPasteEvent: Self.postSystemPaste,
            beforeCopyPosted: Self.waitForKeyboardShortcutRelease,
            afterCopyPosted: {},
            afterPastePosted: {},
            pollInterval: .milliseconds(25),
            timeout: .milliseconds(500),
            pasteConsumptionDelay: .milliseconds(400)
        )
    }

    init(
        pasteboard: NSPasteboard,
        postCopyEvent: @escaping KeyboardEventPoster,
        postPasteEvent: @escaping KeyboardEventPoster = {},
        beforeCopyPosted: @escaping EventPostedHook = {},
        afterCopyPosted: @escaping EventPostedHook = {},
        afterPastePosted: @escaping EventPostedHook = {},
        pollInterval: Duration = .milliseconds(25),
        timeout: Duration = .milliseconds(500),
        pasteConsumptionDelay: Duration = .milliseconds(150)
    ) {
        self.pasteboard = pasteboard
        self.postCopyEvent = postCopyEvent
        self.postPasteEvent = postPasteEvent
        self.beforeCopyPosted = beforeCopyPosted
        self.afterCopyPosted = afterCopyPosted
        self.afterPastePosted = afterPastePosted
        self.pollInterval = pollInterval
        self.captureTimeout = timeout
        self.pasteConsumptionDelay = pasteConsumptionDelay
    }

    public func captureSelectedText(operationID: OperationID) async throws -> String {
        await gate.acquire()
        do {
            let text = try await copySelectedTextLocked()
            await gate.release()
            return text
        } catch {
            await gate.release()
            throw error
        }
    }

    public func writeUserCopy(_ text: String) async throws {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw EnLLMError.clipboardUnavailable
            }
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    public func awaitQuiescence() async -> ClipboardTerminalResult {
        await gate.acquire()
        let result = terminalResult
        await gate.release()
        return result
    }

    func applyCorrection(
        _ correctedText: String,
        to capture: SelectionCapture,
        currentTarget: @MainActor @Sendable () -> CurrentSelectionTarget
    ) async throws -> CorrectionApplicationResult {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let replacementSnapshot: PasteboardSnapshot
            var current: CurrentSelectionTarget

            if capture.method == .clipboardFallback {
                current = currentTarget()
                if let failure = TargetVerificationPolicy.metadataFailure(for: capture, current: current) {
                    await gate.release()
                    return .safetyPanel(failure)
                }

                let recopied: CopiedSelection
                do {
                    recopied = try await copySelectedTextTransactionLocked()
                } catch let error as EnLLMError where error == .noSelection
                    || error == .clipboardUnavailable
                    || error == .clipboardSnapshotIncomplete {
                    await gate.release()
                    return .safetyPanel(.selectedTextUnavailable)
                }

                replacementSnapshot = recopied.restoredSnapshot
                let refreshedTarget = currentTarget()
                current = CurrentSelectionTarget(
                    frontmostProcessID: refreshedTarget.frontmostProcessID,
                    focusedWindowMatches: refreshedTarget.focusedWindowMatches,
                    focusedElementMatches: refreshedTarget.focusedElementMatches,
                    selectedRange: refreshedTarget.selectedRange,
                    selectedText: recopied.text
                )
            } else {
                // Snapshotting can eagerly read many pasteboard representations, so do it
                // before the final synchronous AX verification.
                replacementSnapshot = try PasteboardSnapshot.capture(from: pasteboard)
                current = currentTarget()
            }

            if let failure = TargetVerificationPolicy.failure(for: capture, current: current) {
                await gate.release()
                return .safetyPanel(failure)
            }

            try await replaceSelectedTextLocked(
                with: correctedText,
                restoring: replacementSnapshot
            )
            await gate.release()
            return .replaced
        } catch {
            await gate.release()
            throw error
        }
    }

    private enum CopyObservation {
        case text(String)
        case noSelection
    }

    private struct CopiedSelection {
        let text: String
        let restoredSnapshot: PasteboardSnapshot
    }

    private func copySelectedTextLocked() async throws -> String {
        try await copySelectedTextTransactionLocked().text
    }

    private func copySelectedTextTransactionLocked() async throws -> CopiedSelection {
        let snapshot = try PasteboardSnapshot.capture(from: pasteboard)
        let baselineChangeCount = pasteboard.changeCount
        terminalResult = .idle

        try Task.checkCancellation()
        await beforeCopyPosted()
        try Task.checkCancellation()
        do {
            try postCopyEvent()
        } catch {
            // The poster may fail after a partial synchronous side effect. No
            // pre-post cancellation or external clipboard change reaches here.
            if pasteboard.changeCount != baselineChangeCount {
                _ = restore(snapshot)
            }
            throw error
        }
        await afterCopyPosted()

        // Once Copy has been posted, this transaction retains clipboard ownership
        // through the bounded observation and restoration even if its task is cancelled.
        let observation = await observeCopy(after: baselineChangeCount)
        let restoration = restore(snapshot)
        guard restoration == .restored else {
            throw EnLLMError.clipboardRestorationFailed
        }
        try Task.checkCancellation()

        guard case .text(let text) = observation else {
            throw EnLLMError.noSelection
        }
        return CopiedSelection(text: text, restoredSnapshot: snapshot)
    }

    private func replaceSelectedTextLocked(
        with correctedText: String,
        restoring snapshot: PasteboardSnapshot
    ) async throws {
        guard !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnLLMError.emptyOutput
        }

        terminalResult = .idle
        var pasteboardWasMutated = false
        var pasteWasPosted = false

        do {
            try Task.checkCancellation()
            pasteboard.clearContents()
            pasteboardWasMutated = true
            guard pasteboard.setString(correctedText, forType: .string) else {
                throw EnLLMError.clipboardUnavailable
            }
            try Task.checkCancellation()
            try postPasteEvent()
            pasteWasPosted = true
            await afterPastePosted()
            await waitForPasteConsumptionIgnoringCancellation()
        } catch {
            if pasteboardWasMutated {
                let restoration = restore(snapshot)
                guard restoration == .restored else {
                    throw EnLLMError.clipboardRestorationFailed
                }
            }
            throw error
        }

        let restoration = restore(snapshot)
        guard restoration == .restored else {
            throw EnLLMError.clipboardRestorationFailed
        }
        if pasteWasPosted {
            try Task.checkCancellation()
        }
    }

    private func observeCopy(after baselineChangeCount: Int) async -> CopyObservation {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: captureTimeout)

        while clock.now < deadline {
            if pasteboard.changeCount != baselineChangeCount {
                guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
                    return .noSelection
                }
                return .text(text)
            }
            try? await Task.sleep(for: pollInterval)
        }
        return .noSelection
    }

    private func restore(_ snapshot: PasteboardSnapshot) -> ClipboardTerminalResult {
        do {
            try snapshot.restore(to: pasteboard)
            let restored = try PasteboardSnapshot.capture(from: pasteboard)
            terminalResult = restored == snapshot ? .restored : .restorationFailed
        } catch {
            terminalResult = .restorationFailed
        }
        return terminalResult
    }

    private func waitForPasteConsumptionIgnoringCancellation() async {
        let delay = pasteConsumptionDelay
        await Task.detached {
            try? await Task.sleep(for: delay)
        }.value
    }

    private static func waitForKeyboardShortcutRelease() async {
        let shortcutModifiers: CGEventFlags = [
            .maskCommand,
            .maskControl,
            .maskAlternate,
            .maskShift
        ]
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))

        while clock.now < deadline {
            if CGEventSource.flagsState(.combinedSessionState)
                .intersection(shortcutModifiers).isEmpty {
                // Carbon can dispatch the hotkey while its non-modifier key is
                // still transitioning to key-up. Give the source app one short
                // event-loop turn before posting the synthetic Command-C.
                try? await Task.sleep(for: .milliseconds(30))
                return
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func postSystemCopy() throws {
        try postSystemKey(keyCode: 8)
    }

    private static func postSystemPaste() throws {
        try postSystemKey(keyCode: 9)
    }

    private static func postSystemKey(keyCode: CGKeyCode) throws {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw EnLLMError.clipboardUnavailable
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

@MainActor
public final class CorrectionApplicationService: CorrectionApplying {
    private let accessibility: AccessibilitySelectionService
    private let clipboard: SafeClipboardService

    public init(
        accessibility: AccessibilitySelectionService,
        clipboard: SafeClipboardService
    ) {
        self.accessibility = accessibility
        self.clipboard = clipboard
    }

    public func apply(
        _ correctedText: String,
        to capture: SelectionCapture
    ) async throws -> CorrectionApplicationResult {
        try await clipboard.applyCorrection(correctedText, to: capture) { [accessibility] in
            accessibility.readCurrentTarget(
                for: capture,
                includeSelectedText: capture.method == .accessibility
            )
        }
    }
}
