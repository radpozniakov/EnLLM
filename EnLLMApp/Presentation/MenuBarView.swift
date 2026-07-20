import AppKit
import EnLLMCore
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var coordinator: ActionCoordinator

    var body: some View {
        Button(AppAction.correctSelection.title) {
            coordinator.perform(.correctSelection)
        }
        .disabled(coordinator.isTerminating)

        Button(AppAction.translateSelectionToUkrainian.title) {
            coordinator.perform(.translateSelectionToUkrainian)
        }
        .disabled(coordinator.isTerminating)

        if coordinator.isActive {
            Divider()
            Text("Working…")
        }

        if let lastError = coordinator.lastError {
            Divider()
            Text(lastError)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Settings…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(coordinator.isTerminating)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

@MainActor
private final class NonactivatingResultPanel: NSPanel {
    // The panel is not made key when shown, but may become key after an explicit
    // click so text selection and the Copy button remain usable.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Injectable seam over the temporary `NSEvent` monitors the result panel installs
/// while visible. Wrapping install and removal lets tests prove monitors never
/// accumulate across repeated show and are always torn down on hide, dismissal,
/// and termination (NFR-012) without driving a real event stream.
@MainActor
protocol EventMonitoring: AnyObject {
    func installLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    )
    func installGlobalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    )
    func removeAll()
    var installedCount: Int { get }
}

@MainActor
final class SystemEventMonitor: EventMonitoring {
    private var tokens: [Any] = []

    var installedCount: Int { tokens.count }

    func installLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) {
        if let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) {
            tokens.append(token)
        }
    }

    func installGlobalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    ) {
        if let token = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            tokens.append(token)
        }
    }

    func removeAll() {
        for token in tokens {
            NSEvent.removeMonitor(token)
        }
        tokens.removeAll()
    }
}

@MainActor
final class ResultPanelController: PanelPresenting {
    var onDismiss: ((OperationID) -> Void)?
    var onCopy: ((OperationID, String) -> Void)?
    var onRecoveryAction: ((OperationID, ErrorRecoveryAction) -> Void)?

    private let panel: NonactivatingResultPanel
    private let eventMonitor: any EventMonitoring
    private var currentOperationID: OperationID?

    init(eventMonitor: any EventMonitoring = SystemEventMonitor()) {
        self.eventMonitor = eventMonitor
        panel = NonactivatingResultPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(_ state: ActionCoordinator.PanelState) {
        guard let operationID = state.operationID else {
            hide()
            return
        }
        currentOperationID = operationID
        panel.contentView = NSHostingView(
            rootView: ResultPanelContent(
                state: state,
                onCopy: { [weak self] text in self?.onCopy?(operationID, text) },
                onRecoveryAction: { [weak self] action in
                    self?.onRecoveryAction?(operationID, action)
                }
            )
        )
        positionNearPointer()
        panel.orderFrontRegardless()
        startMonitoring()
    }

    func hide() {
        currentOperationID = nil
        stopMonitoring()
        panel.orderOut(nil)
    }

    func stopMonitoring() {
        eventMonitor.removeAll()
    }

    private func dismissCurrent() {
        guard let operationID = currentOperationID else { return }
        hide()
        onDismiss?(operationID)
    }

    private func startMonitoring() {
        // Replace rather than accumulate: repeated show installs exactly the two
        // monitors below and never leaves a stale token behind.
        eventMonitor.removeAll()
        eventMonitor.installGlobalMonitor(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismissCurrent() }
        }
        eventMonitor.installLocalMonitor(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismissCurrent()
                return nil
            }
            if event.type != .keyDown, event.window !== self.panel {
                self.dismissCurrent()
            }
            return event
        }
    }

    private func positionNearPointer() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let size = NSSize(width: 420, height: 340)
        let margin: CGFloat = 8
        var origin = NSPoint(x: pointer.x, y: pointer.y - size.height - margin)
        if origin.y < visibleFrame.minY + margin {
            origin.y = pointer.y + 24
        }
        origin.x = min(
            max(origin.x, visibleFrame.minX + margin),
            visibleFrame.maxX - size.width - margin
        )
        origin.y = min(
            max(origin.y, visibleFrame.minY + margin),
            visibleFrame.maxY - size.height - margin
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

private struct ResultPanelContent: View {
    let state: ActionCoordinator.PanelState
    let onCopy: (String) -> Void
    let onRecoveryAction: (ErrorRecoveryAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .hidden:
                EmptyView()
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading selection…")
                        .foregroundStyle(.secondary)
                }
                .padding()
            case .result(_, let text):
                ScrollView(.vertical) {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Copy") { onCopy(text) }
                        .accessibilityLabel("Copy result")
                }
                .padding([.horizontal, .bottom])
            case .error(_, let message, let recoveryAction):
                VStack(alignment: .leading, spacing: 14) {
                    Text(message)
                        .textSelection(.enabled)
                    switch recoveryAction {
                    case .none:
                        EmptyView()
                    case .openAccessibilitySettings:
                        Button("Open Accessibility Settings") {
                            onRecoveryAction(.openAccessibilitySettings)
                        }
                    case .openAppSettings:
                        Button("Open Settings") {
                            onRecoveryAction(.openAppSettings)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 420, height: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
