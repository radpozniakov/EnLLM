import AppKit
import Carbon
import EnLLMCore
import Foundation
import Testing
@testable import EnLLMPlatform

@MainActor
@Test func scaffoldHandlerFailsClosed() async {
    let handler = UnavailableActionHandler()

    await #expect(throws: EnLLMError.featureUnavailable(.correctSelection)) {
        try await handler.perform(.correctSelection, operationID: OperationID())
    }
}

@MainActor
@Test func defaultHotkeysMatchTheSpecification() {
    #expect(DefaultHotkeyRegistrar.defaultCorrectKeyCode == UInt32(kVK_ANSI_T))
    #expect(DefaultHotkeyRegistrar.defaultCorrectModifiers == UInt32(controlKey | shiftKey))
    #expect(DefaultHotkeyRegistrar.defaultTranslateKeyCode == UInt32(kVK_ANSI_T))
    #expect(DefaultHotkeyRegistrar.defaultTranslateModifiers == UInt32(optionKey))
}

@MainActor
@Test func hotkeyRegistrarDispatchesBothActionIDs() throws {
    let registrar = DefaultHotkeyRegistrar(system: HotkeySystemSpy())
    var actions: [AppAction] = []
    try registrar.registerDefaults { actions.append($0) }

    registrar.fire(hotkeyID: 1)
    registrar.fire(hotkeyID: 2)
    registrar.fire(hotkeyID: 99)

    #expect(actions == [.correctSelection, .translateSelectionToUkrainian])
}

@MainActor
@Test func hotkeyRecorderSessionSuppressesActiveDispatch() throws {
    let registrar = DefaultHotkeyRegistrar(system: HotkeySystemSpy())
    var actions: [AppAction] = []
    try registrar.registerDefaults { actions.append($0) }
    registrar.setRecordingAction(.correctSelection)
    registrar.fire(hotkeyID: 1)
    registrar.fire(hotkeyID: 2)
    #expect(actions.isEmpty)
    registrar.setRecordingAction(nil)
    registrar.fire(hotkeyID: 2)
    #expect(actions == [.translateSelectionToUkrainian])
}

@MainActor
@Test func directShortcutSwapRemovesBothBlockingOldRegistrationsBeforeActivation() throws {
    let system = HotkeySystemSpy()
    let registrar = DefaultHotkeyRegistrar(system: system)
    var actions: [AppAction] = []
    try registrar.registerDefaults { actions.append($0) }
    try registrar.prepare(
        correct: BuiltInDefaults.translateHotkey,
        translate: BuiltInDefaults.correctHotkey,
        action: { actions.append($0) }
    )
    #expect(system.unregisterCount == 2)
    #expect(system.registerCount == 4)
    registrar.activate()
    #expect(registrar.activeDefinitions[.correctSelection] == BuiltInDefaults.translateHotkey)
    #expect(registrar.activeDefinitions[.translateSelectionToUkrainian] == BuiltInDefaults.correctHotkey)
    let stagedIDs = system.registeredIDs.suffix(2)
    registrar.fire(hotkeyID: stagedIDs[stagedIDs.startIndex])
    registrar.fire(hotkeyID: stagedIDs[stagedIDs.index(after: stagedIDs.startIndex)])
    #expect(actions == [.correctSelection, .translateSelectionToUkrainian])
}

@MainActor
@Test func eachSupersededHotkeyUnregisterFailureAbortsPreparationAndRestoresPreviousGeneration() throws {
    for failedCall in [1, 2] {
        let system = HotkeySystemSpy()
        let registrar = DefaultHotkeyRegistrar(system: system)
        var actions: [AppAction] = []
        try registrar.registerDefaults { actions.append($0) }
        system.failureUnregistrationCall = failedCall

        #expect(throws: EnLLMError.hotkeyRegistrationFailed) {
            try registrar.prepare(
                correct: HotkeyDefinition(keyCode: 0, modifiers: HotkeyDefinition.commandModifier),
                translate: HotkeyDefinition(keyCode: 1, modifiers: HotkeyDefinition.optionModifier),
                action: { actions.append($0) }
            )
        }

        #expect(registrar.lastRollbackResult == .restored)
        #expect(registrar.activeDefinitions[.correctSelection] == BuiltInDefaults.correctHotkey)
        #expect(registrar.activeDefinitions[.translateSelectionToUkrainian] == BuiltInDefaults.translateHotkey)
        registrar.fire(hotkeyID: 1)
        registrar.fire(hotkeyID: 2)
        #expect(actions == [.correctSelection, .translateSelectionToUkrainian])
    }
}

@MainActor
@Test func hotkeyRegistrarReusesRegistrationAndTearsDownEveryCarbonResource() throws {
    let system = HotkeySystemSpy()
    var registrar: DefaultHotkeyRegistrar? = DefaultHotkeyRegistrar(system: system)

    try registrar?.registerDefaults { _ in }
    try registrar?.registerDefaults { _ in }
    #expect(system.installCount == 1)
    #expect(system.registerCount == 2)

    registrar?.unregister()
    registrar?.unregister()
    #expect(system.unregisterCount == 2)
    #expect(system.removeHandlerCount == 1)

    try registrar?.registerDefaults { _ in }
    #expect(system.installCount == 2)
    #expect(system.registerCount == 4)

    registrar = nil
    #expect(system.unregisterCount == 4)
    #expect(system.removeHandlerCount == 2)
}

@MainActor
@Test func failedHotkeyRegistrationRemovesHandlerAndAllowsRetry() throws {
    let system = HotkeySystemSpy()
    system.registrationStatus = OSStatus(eventHotKeyExistsErr)
    let registrar = DefaultHotkeyRegistrar(system: system)

    #expect(throws: EnLLMError.hotkeyRegistrationFailed) {
        try registrar.registerDefaults { _ in }
    }
    #expect(system.installCount == 1)
    #expect(system.registerCount == 1)
    #expect(system.unregisterCount == 0)
    #expect(system.removeHandlerCount == 1)

    system.registrationStatus = noErr
    try registrar.registerDefaults { _ in }
    #expect(system.installCount == 2)
    #expect(system.registerCount == 3)

    registrar.unregister()
    #expect(system.unregisterCount == 2)
    #expect(system.removeHandlerCount == 2)
}

@MainActor
@Test func customSecondRegistrationConflictPreservesBothActiveShortcuts() throws {
    let system = HotkeySystemSpy()
    let registrar = DefaultHotkeyRegistrar(system: system)
    var actions: [AppAction] = []
    try registrar.registerDefaults { actions.append($0) }
    system.failureRegistrationCall = 4
    #expect(throws: EnLLMError.hotkeyRegistrationFailed) {
        try registrar.prepare(
            correct: HotkeyDefinition(keyCode: 0, modifiers: HotkeyDefinition.commandModifier),
            translate: HotkeyDefinition(keyCode: 1, modifiers: HotkeyDefinition.optionModifier),
            action: { actions.append($0) }
        )
    }
    #expect(registrar.lastRollbackResult == .restored)
    #expect(registrar.activeDefinitions[.correctSelection] == BuiltInDefaults.correctHotkey)
    #expect(registrar.activeDefinitions[.translateSelectionToUkrainian] == BuiltInDefaults.translateHotkey)
    registrar.fire(hotkeyID: 1); registrar.fire(hotkeyID: 2)
    #expect(actions == [.correctSelection, .translateSelectionToUkrainian])
}

@MainActor
@Test func rollbackChecksFailedStagedUnregisterAndRequiresTruthfulCleanupBeforeRetry() throws {
    let system = HotkeySystemSpy()
    let registrar = DefaultHotkeyRegistrar(system: system)
    try registrar.registerDefaults { _ in }
    system.failureRegistrationCall = 4
    system.failureUnregistrationCall = 3

    #expect(throws: EnLLMError.hotkeyRegistrationFailed) {
        try registrar.prepare(
            correct: HotkeyDefinition(keyCode: 0, modifiers: HotkeyDefinition.commandModifier),
            translate: HotkeyDefinition(keyCode: 1, modifiers: HotkeyDefinition.optionModifier),
            action: { _ in }
        )
    }
    #expect(registrar.lastRollbackResult == .uncertain([.correctSelection]))
    #expect(registrar.activeDefinitions[.correctSelection] == BuiltInDefaults.correctHotkey)
    #expect(registrar.activeDefinitions[.translateSelectionToUkrainian] == BuiltInDefaults.translateHotkey)

    system.failureRegistrationCall = nil
    system.failureUnregistrationCall = nil
    try registrar.prepare(
        correct: HotkeyDefinition(keyCode: 0, modifiers: HotkeyDefinition.commandModifier),
        translate: HotkeyDefinition(keyCode: 1, modifiers: HotkeyDefinition.optionModifier),
        action: { _ in }
    )
    registrar.activate()
    #expect(registrar.lastRollbackResult == .restored)
    #expect(registrar.activeDefinitions[.correctSelection]?.keyCode == 0)
    #expect(registrar.activeDefinitions[.translateSelectionToUkrainian]?.keyCode == 1)
}

@MainActor
@Test func secondHotkeyFailureRollsBackFirstRegistrationAndAllowsRetry() throws {
    let system = HotkeySystemSpy()
    system.failureRegistrationCall = 2
    let registrar = DefaultHotkeyRegistrar(system: system)

    #expect(throws: EnLLMError.hotkeyRegistrationFailed) {
        try registrar.registerDefaults { _ in }
    }
    #expect(system.registerCount == 2)
    #expect(system.unregisterCount == 1)
    #expect(system.removeHandlerCount == 1)

    system.failureRegistrationCall = nil
    try registrar.registerDefaults { _ in }
    #expect(system.registerCount == 4)
    registrar.unregister()
    #expect(system.unregisterCount == 3)
    #expect(system.removeHandlerCount == 2)
}

@MainActor
@Test func clipboardFallbackWaitsForShortcutReleaseBeforePostingCopy() async throws {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))
    let pause = CopyPostedPause()
    var copyCount = 0
    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {
            copyCount += 1
            pasteboard.clearContents()
            #expect(pasteboard.setString("source", forType: .string))
        },
        beforeCopyPosted: { await pause.wait() },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(10)
    )

    let captureTask = Task {
        try await service.captureSelectedText(operationID: OperationID())
    }
    while !pause.wasReached { await Task.yield() }
    #expect(copyCount == 0)
    #expect(pasteboard.string(forType: .string) == "original")

    pause.resume()
    #expect(try await captureTask.value == "source")
    #expect(copyCount == 1)
    #expect(pasteboard.string(forType: .string) == "original")
}

@MainActor
@Test func clipboardFallbackRejectsUnchangedStaleTextAndRestoresIt() async throws {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    #expect(pasteboard.setString("stale", forType: .string))
    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {},
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(10)
    )

    await #expect(throws: EnLLMError.noSelection) {
        try await service.captureSelectedText(operationID: OperationID())
    }
    #expect(pasteboard.string(forType: .string) == "stale")
    #expect(await service.awaitQuiescence() == .restored)
}

@MainActor
@Test func clipboardFallbackRequiresTransitionAndRestoresMultiItemSnapshot() async throws {
    let pasteboard = makePasteboard()
    let first = NSPasteboardItem()
    #expect(first.setData(Data("plain".utf8), forType: .string))
    #expect(first.setData(Data([0, 1, 2, 3]), forType: .init("public.test-binary")))
    let second = NSPasteboardItem()
    #expect(second.setData(Data("file:///tmp/example".utf8), forType: .fileURL))
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([first, second]))
    let expected = try PasteboardSnapshot.capture(from: pasteboard)

    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {
            pasteboard.clearContents()
            guard pasteboard.setString("new selection", forType: .string) else {
                throw EnLLMError.clipboardUnavailable
            }
        },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(20)
    )

    let selected = try await service.captureSelectedText(operationID: OperationID())

    #expect(selected == "new selection")
    #expect(try PasteboardSnapshot.capture(from: pasteboard) == expected)
    #expect(await service.awaitQuiescence() == .restored)
}

@MainActor
@Test func cancellationAfterCopyMutationRestoresBeforeQuiescenceCompletes() async throws {
    let pasteboard = makePasteboard()
    let first = NSPasteboardItem()
    #expect(first.setData(Data("original".utf8), forType: .string))
    #expect(first.setData(Data([7, 8, 9]), forType: .init("public.test-binary")))
    let second = NSPasteboardItem()
    #expect(second.setData(Data("file:///tmp/original".utf8), forType: .fileURL))
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([first, second]))
    let expected = try PasteboardSnapshot.capture(from: pasteboard)
    let pause = CopyPostedPause()

    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {
            pasteboard.clearContents()
            guard pasteboard.setString("copied selection", forType: .string) else {
                throw EnLLMError.clipboardUnavailable
            }
        },
        afterCopyPosted: {
            await pause.wait()
        },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(20)
    )

    let captureTask = Task {
        try await service.captureSelectedText(operationID: OperationID())
    }
    while !pause.wasReached { await Task.yield() }
    #expect(pasteboard.string(forType: .string) == "copied selection")
    #expect(try PasteboardSnapshot.capture(from: pasteboard) != expected)

    captureTask.cancel()
    var terminalResult: ClipboardTerminalResult?
    let quiescenceTask = Task {
        terminalResult = await service.awaitQuiescence()
    }
    await Task.yield()
    #expect(terminalResult == nil)

    pause.resume()
    await #expect(throws: CancellationError.self) {
        try await captureTask.value
    }
    await quiescenceTask.value

    #expect(terminalResult == .restored)
    #expect(try PasteboardSnapshot.capture(from: pasteboard) == expected)
}

@MainActor
@Test func cancellationBeforeCopyPostPreservesExternalClipboardChange() async throws {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))
    let beforePostPause = CopyPostedPause()
    var copyCount = 0
    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: { copyCount += 1 },
        beforeCopyPosted: { await beforePostPause.wait() },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(10)
    )

    let captureTask = Task {
        try await service.captureSelectedText(operationID: OperationID())
    }
    while !beforePostPause.wasReached { await Task.yield() }

    pasteboard.clearContents()
    #expect(pasteboard.setString("external change", forType: .string))
    captureTask.cancel()
    beforePostPause.resume()

    await #expect(throws: CancellationError.self) {
        try await captureTask.value
    }
    #expect(copyCount == 0)
    #expect(pasteboard.string(forType: .string) == "external change")
}

@MainActor
@Test func cancellationAfterCopyPostWaitsForDelayedMutationAndRestoration() async throws {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))
    let delayedCopyPause = CopyPostedPause()
    let afterPostPause = CopyPostedPause()
    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {
            Task { @MainActor in
                await delayedCopyPause.wait()
                pasteboard.clearContents()
                #expect(pasteboard.setString("delayed selection", forType: .string))
            }
        },
        afterCopyPosted: { await afterPostPause.wait() },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(20)
    )

    let captureTask = Task {
        try await service.captureSelectedText(operationID: OperationID())
    }
    while !delayedCopyPause.wasReached || !afterPostPause.wasReached { await Task.yield() }

    captureTask.cancel()
    var terminalResult: ClipboardTerminalResult?
    let quiescenceTask = Task {
        terminalResult = await service.awaitQuiescence()
    }
    await Task.yield()
    #expect(terminalResult == nil)

    afterPostPause.resume()
    await Task.yield()
    #expect(terminalResult == nil)
    delayedCopyPause.resume()

    await #expect(throws: CancellationError.self) {
        try await captureTask.value
    }
    await quiescenceTask.value

    #expect(terminalResult == .restored)
    #expect(pasteboard.string(forType: .string) == "original")
}

@MainActor
@Test func verifiedCorrectionPastesOutputAndRestoresCompleteSnapshot() async throws {
    let pasteboard = makePasteboard()
    let first = NSPasteboardItem()
    #expect(first.setData(Data("original".utf8), forType: .string))
    #expect(first.setData(Data([4, 5, 6]), forType: .init("public.test-binary")))
    let second = NSPasteboardItem()
    #expect(second.setData(Data("file:///tmp/original".utf8), forType: .fileURL))
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([first, second]))
    let expected = try PasteboardSnapshot.capture(from: pasteboard)
    var pastedText: String?

    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {},
        postPasteEvent: { pastedText = pasteboard.string(forType: .string) },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(10),
        pasteConsumptionDelay: .milliseconds(1)
    )
    let capture = correctionCapture(method: .accessibility)

    let result = try await service.applyCorrection("corrected", to: capture) {
        matchingCurrentTarget(text: "source")
    }

    #expect(result == .replaced)
    #expect(pastedText == "corrected")
    #expect(try PasteboardSnapshot.capture(from: pasteboard) == expected)
    #expect(await service.awaitQuiescence() == .restored)
}

@MainActor
@Test func clipboardCompatibilityCorrectionRecopiesPastesAndRestoresSnapshot() async throws {
    let pasteboard = makePasteboard()
    let first = NSPasteboardItem()
    #expect(first.setData(Data("original".utf8), forType: .string))
    #expect(first.setData(Data([7, 8, 9]), forType: .init("public.test-binary")))
    let second = NSPasteboardItem()
    #expect(second.setData(Data("file:///tmp/original".utf8), forType: .fileURL))
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([first, second]))
    let expected = try PasteboardSnapshot.capture(from: pasteboard)
    var pastedText: String?
    var targetReadCount = 0

    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {
            pasteboard.clearContents()
            #expect(pasteboard.setString("source", forType: .string))
        },
        postPasteEvent: { pastedText = pasteboard.string(forType: .string) },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(10),
        pasteConsumptionDelay: .milliseconds(1)
    )

    let result = try await service.applyCorrection(
        "corrected",
        to: compatibilityCorrectionCapture()
    ) {
        targetReadCount += 1
        return matchingCompatibilityTarget(text: nil)
    }

    #expect(result == .replaced)
    #expect(targetReadCount == 2)
    #expect(pastedText == "corrected")
    #expect(try PasteboardSnapshot.capture(from: pasteboard) == expected)
    #expect(await service.awaitQuiescence() == .restored)
}

@MainActor
@Test func clipboardCompatibilityWindowMismatchDoesNotRecopyOrPaste() async throws {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))
    var copyCount = 0
    var pasteCount = 0
    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: { copyCount += 1 },
        postPasteEvent: { pasteCount += 1 },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(10),
        pasteConsumptionDelay: .milliseconds(1)
    )

    let result = try await service.applyCorrection(
        "corrected",
        to: compatibilityCorrectionCapture()
    ) {
        CurrentSelectionTarget(
            frontmostProcessID: 42,
            focusedWindowMatches: false,
            focusedElementMatches: nil,
            selectedRange: nil,
            selectedText: nil
        )
    }

    #expect(result == .safetyPanel(.focusedWindowMismatch))
    #expect(copyCount == 0)
    #expect(pasteCount == 0)
    #expect(pasteboard.string(forType: .string) == "original")
}

@MainActor
@Test func snapshotCompletesBeforeFinalAXVerification() async throws {
    let pasteboard = makePasteboard()
    var targetChanged = false
    let provider = SnapshotDataProvider {
        targetChanged = true
    }
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [.string])
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([item]))
    var pasteCount = 0
    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {},
        postPasteEvent: { pasteCount += 1 },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(10),
        pasteConsumptionDelay: .milliseconds(1)
    )

    let result = try await service.applyCorrection(
        "corrected",
        to: correctionCapture(method: .accessibility)
    ) {
        targetChanged
            ? CurrentSelectionTarget(
                frontmostProcessID: 99,
                focusedWindowMatches: true,
                focusedElementMatches: true,
                selectedRange: TextSelectionRange(location: 2, length: 6),
                selectedText: "source"
            )
            : matchingCurrentTarget(text: "source")
    }

    #expect(targetChanged)
    #expect(result == .safetyPanel(.processMismatch))
    #expect(pasteCount == 0)
}

@MainActor
@Test func targetMismatchDoesNotRecopyOrPaste() async throws {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))
    var copyCount = 0
    var pasteCount = 0
    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: { copyCount += 1 },
        postPasteEvent: { pasteCount += 1 },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(10),
        pasteConsumptionDelay: .milliseconds(1)
    )

    let result = try await service.applyCorrection(
        "corrected",
        to: correctionCapture(method: .clipboardFallback)
    ) {
        CurrentSelectionTarget(
            frontmostProcessID: 99,
            focusedWindowMatches: true,
            focusedElementMatches: true,
            selectedRange: TextSelectionRange(location: 2, length: 6),
            selectedText: nil
        )
    }

    #expect(result == .safetyPanel(.processMismatch))
    #expect(copyCount == 0)
    #expect(pasteCount == 0)
    #expect(pasteboard.string(forType: .string) == "original")
}

@MainActor
@Test func unavailableFallbackRecopyReturnsRecoverableSafetyResult() async throws {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))
    var pasteCount = 0
    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {},
        postPasteEvent: { pasteCount += 1 },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(5),
        pasteConsumptionDelay: .milliseconds(1)
    )

    let result = try await service.applyCorrection(
        "corrected",
        to: correctionCapture(method: .clipboardFallback)
    ) {
        matchingCurrentTarget(text: nil)
    }

    #expect(result == .safetyPanel(.selectedTextUnavailable))
    #expect(pasteCount == 0)
    #expect(pasteboard.string(forType: .string) == "original")
    #expect(await service.awaitQuiescence() == .restored)
}

@MainActor
@Test func fallbackRecopyTextMismatchRestoresClipboardAndDoesNotPaste() async throws {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))
    var pasteCount = 0
    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {
            pasteboard.clearContents()
            #expect(pasteboard.setString("changed selection", forType: .string))
        },
        postPasteEvent: { pasteCount += 1 },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(10),
        pasteConsumptionDelay: .milliseconds(1)
    )

    let result = try await service.applyCorrection(
        "corrected",
        to: correctionCapture(method: .clipboardFallback)
    ) {
        matchingCurrentTarget(text: nil)
    }

    #expect(result == .safetyPanel(.selectedTextMismatch))
    #expect(pasteCount == 0)
    #expect(pasteboard.string(forType: .string) == "original")
    #expect(await service.awaitQuiescence() == .restored)
}

@MainActor
@Test func fallbackRechecksMetadataAfterRecopyBeforePasting() async throws {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))
    var targetReadCount = 0
    var pasteCount = 0
    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {
            pasteboard.clearContents()
            #expect(pasteboard.setString("source", forType: .string))
        },
        postPasteEvent: { pasteCount += 1 },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(10),
        pasteConsumptionDelay: .milliseconds(1)
    )

    let result = try await service.applyCorrection(
        "corrected",
        to: correctionCapture(method: .clipboardFallback)
    ) {
        targetReadCount += 1
        if targetReadCount == 1 {
            return matchingCurrentTarget(text: nil)
        }
        return CurrentSelectionTarget(
            frontmostProcessID: 99,
            focusedWindowMatches: true,
            focusedElementMatches: true,
            selectedRange: TextSelectionRange(location: 2, length: 6),
            selectedText: nil
        )
    }

    #expect(result == .safetyPanel(.processMismatch))
    #expect(targetReadCount == 2)
    #expect(pasteCount == 0)
    #expect(pasteboard.string(forType: .string) == "original")
}

@MainActor
@Test func supersedingClipboardOperationWaitsForCorrectionRestorationOwnership() async throws {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))
    let pause = CopyPostedPause()
    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {},
        postPasteEvent: {},
        afterPastePosted: { await pause.wait() },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(10),
        pasteConsumptionDelay: .milliseconds(1)
    )

    let olderTask = Task {
        try await service.applyCorrection(
            "corrected",
            to: correctionCapture(method: .accessibility)
        ) {
            matchingCurrentTarget(text: "source")
        }
    }
    while !pause.wasReached { await Task.yield() }
    olderTask.cancel()

    var newerOperationFinished = false
    let newerTask = Task {
        try await service.writeUserCopy("new owner")
        newerOperationFinished = true
    }
    await Task.yield()
    #expect(!newerOperationFinished)
    #expect(pasteboard.string(forType: .string) == "corrected")

    pause.resume()
    await #expect(throws: CancellationError.self) {
        try await olderTask.value
    }
    try await newerTask.value

    #expect(newerOperationFinished)
    #expect(pasteboard.string(forType: .string) == "new owner")
}

@MainActor
@Test func cancellationAfterPasteWaitsForRestorationBeforeReleasingClipboardOwner() async throws {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))
    let pause = CopyPostedPause()
    let service = SafeClipboardService(
        pasteboard: pasteboard,
        postCopyEvent: {},
        postPasteEvent: {},
        afterPastePosted: { await pause.wait() },
        pollInterval: .milliseconds(1),
        timeout: .milliseconds(10),
        pasteConsumptionDelay: .milliseconds(1)
    )

    let correctionTask = Task {
        try await service.applyCorrection(
            "corrected",
            to: correctionCapture(method: .accessibility)
        ) {
            matchingCurrentTarget(text: "source")
        }
    }
    while !pause.wasReached { await Task.yield() }
    #expect(pasteboard.string(forType: .string) == "corrected")

    correctionTask.cancel()
    var terminalResult: ClipboardTerminalResult?
    let quiescenceTask = Task {
        terminalResult = await service.awaitQuiescence()
    }
    await Task.yield()
    #expect(terminalResult == nil)

    pause.resume()
    await #expect(throws: CancellationError.self) {
        try await correctionTask.value
    }
    await quiescenceTask.value

    #expect(terminalResult == .restored)
    #expect(pasteboard.string(forType: .string) == "original")
}

@MainActor
private final class SnapshotDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let onProvide: () -> Void

    init(onProvide: @escaping () -> Void) {
        self.onProvide = onProvide
    }

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        MainActor.assumeIsolated {
            onProvide()
        }
        _ = item.setData(Data("original".utf8), forType: type)
    }
}

private func correctionCapture(method: SelectionCaptureMethod) -> SelectionCapture {
    SelectionCapture(
        operationID: OperationID(),
        text: "source",
        method: method,
        targetContext: SelectionTargetContext(
            frontmostProcessID: 42,
            focusedWindowToken: SelectionWindowToken(),
            targetToken: SelectionTargetToken(),
            selectedRange: TextSelectionRange(location: 2, length: 6)
        )
    )
}

private func compatibilityCorrectionCapture() -> SelectionCapture {
    SelectionCapture(
        operationID: OperationID(),
        text: "source",
        method: .clipboardFallback,
        targetContext: SelectionTargetContext(
            frontmostProcessID: 42,
            focusedWindowToken: SelectionWindowToken(),
            targetToken: nil,
            selectedRange: nil
        )
    )
}

private func matchingCurrentTarget(text: String?) -> CurrentSelectionTarget {
    CurrentSelectionTarget(
        frontmostProcessID: 42,
        focusedWindowMatches: true,
        focusedElementMatches: true,
        selectedRange: TextSelectionRange(location: 2, length: 6),
        selectedText: text
    )
}

private func matchingCompatibilityTarget(text: String?) -> CurrentSelectionTarget {
    CurrentSelectionTarget(
        frontmostProcessID: 42,
        focusedWindowMatches: true,
        focusedElementMatches: nil,
        selectedRange: nil,
        selectedText: text
    )
}

@MainActor
private final class CopyPostedPause {
    private(set) var wasReached = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        wasReached = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class HotkeySystemSpy: HotkeySystem {
    var registrationStatus: OSStatus = noErr
    var failureRegistrationCall: Int?
    var failureUnregistrationCall: Int?
    var installCount = 0
    var registerCount = 0
    var unregisterCount = 0
    var removeHandlerCount = 0
    var registeredIDs: [UInt32] = []

    func installEventHandler(
        eventType: inout EventTypeSpec,
        context: UnsafeMutableRawPointer,
        handler: inout EventHandlerRef?
    ) -> OSStatus {
        installCount += 1
        handler = OpaquePointer(bitPattern: installCount)
        return noErr
    }

    func registerHotkey(
        keyCode: UInt32,
        modifiers: UInt32,
        hotkeyID: EventHotKeyID,
        hotkey: inout EventHotKeyRef?
    ) -> OSStatus {
        registerCount += 1
        registeredIDs.append(hotkeyID.id)
        let status = failureRegistrationCall == registerCount
            ? OSStatus(eventHotKeyExistsErr)
            : registrationStatus
        if status == noErr {
            hotkey = OpaquePointer(bitPattern: registerCount)
        }
        return status
    }

    func unregisterHotkey(_ hotkey: EventHotKeyRef) -> OSStatus {
        unregisterCount += 1
        return failureUnregistrationCall == unregisterCount ? OSStatus(eventNotHandledErr) : noErr
    }

    func removeEventHandler(_ handler: EventHandlerRef) -> OSStatus {
        removeHandlerCount += 1
        return noErr
    }
}

@MainActor
private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: .init("EnLLMTests.\(UUID().uuidString)"))
}
