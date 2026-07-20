import AppKit
import EnLLMCore
import Testing
@testable import EnLLMApp

/// Records event-monitor install/removal and captures the installed handlers so
/// dismissal and cleanup can be exercised without a real NSEvent stream.
@MainActor
private final class EventMonitorSpy: EventMonitoring {
    private(set) var installedCount = 0
    private(set) var totalInstalls = 0
    private(set) var removeAllCallCount = 0
    var localHandler: ((NSEvent) -> NSEvent?)?
    var globalHandler: ((NSEvent) -> Void)?

    func installLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) {
        installedCount += 1
        totalInstalls += 1
        localHandler = handler
    }

    func installGlobalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    ) {
        installedCount += 1
        totalInstalls += 1
        globalHandler = handler
    }

    func removeAll() {
        removeAllCallCount += 1
        installedCount = 0
        localHandler = nil
        globalHandler = nil
    }
}

@MainActor
private func makeKeyDownEvent(keyCode: UInt16) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
    )!
}

@MainActor
private func makeMouseDownEvent() -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )!
}

@MainActor
@Test func repeatedShowReplacesMonitorsRatherThanAccumulating() {
    let monitor = EventMonitorSpy()
    let controller = ResultPanelController(eventMonitor: monitor)

    controller.show(.loading(OperationID()))
    #expect(monitor.installedCount == 2)

    controller.show(.loading(OperationID()))
    controller.show(.loading(OperationID()))

    // Never accumulates: exactly the two active monitors remain after each show,
    // and every show first tears the previous pair down.
    #expect(monitor.installedCount == 2)
    #expect(monitor.totalInstalls == 6)
    #expect(monitor.removeAllCallCount >= 3)
}

@MainActor
@Test func hideRemovesAllMonitorsAndIsIdempotent() {
    let monitor = EventMonitorSpy()
    let controller = ResultPanelController(eventMonitor: monitor)

    controller.show(.loading(OperationID()))
    #expect(monitor.installedCount == 2)

    controller.hide()
    #expect(monitor.installedCount == 0)

    controller.hide()
    controller.stopMonitoring()
    #expect(monitor.installedCount == 0)
}

@MainActor
@Test func escapeDismissalRemovesMonitorsAndReportsTheCurrentOperation() {
    let monitor = EventMonitorSpy()
    let controller = ResultPanelController(eventMonitor: monitor)
    var dismissed: [OperationID] = []
    controller.onDismiss = { dismissed.append($0) }

    let operationID = OperationID()
    controller.show(.loading(operationID))
    let localHandler = monitor.localHandler

    let swallowed = localHandler?(makeKeyDownEvent(keyCode: 53))

    // Escape is swallowed (returns nil), dismisses the current operation, and
    // leaves no monitor installed.
    #expect(swallowed == nil)
    #expect(dismissed == [operationID])
    #expect(monitor.installedCount == 0)
}

@MainActor
@Test func outsideClickDismissalRemovesMonitorsAndReportsTheCurrentOperation() {
    let monitor = EventMonitorSpy()
    let controller = ResultPanelController(eventMonitor: monitor)
    var dismissed: [OperationID] = []
    controller.onDismiss = { dismissed.append($0) }

    let operationID = OperationID()
    controller.show(.loading(operationID))

    let mouse = makeMouseDownEvent()
    let passedThrough = monitor.localHandler?(mouse)

    // A click outside the panel passes the event through but dismisses and tears
    // down monitors, reporting only the current operation ID.
    #expect(passedThrough === mouse)
    #expect(dismissed == [operationID])
    #expect(monitor.installedCount == 0)
}

@MainActor
@Test func stopMonitoringDuringTerminationLeavesNoMonitorAndIsIdempotent() {
    let monitor = EventMonitorSpy()
    let controller = ResultPanelController(eventMonitor: monitor)

    controller.show(.loading(OperationID()))
    #expect(monitor.installedCount == 2)

    // Termination calls stopMonitoring directly; it must be idempotent and leave
    // nothing installed even without a preceding hide.
    controller.stopMonitoring()
    #expect(monitor.installedCount == 0)
    controller.stopMonitoring()
    #expect(monitor.installedCount == 0)

    // A dismissal after teardown cannot resurrect a monitor or report an
    // operation, because the current operation was already cleared by hide.
    let danglingLocalHandler = monitor.localHandler
    #expect(danglingLocalHandler == nil)
}
