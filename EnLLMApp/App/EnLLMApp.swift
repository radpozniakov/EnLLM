import AppKit
import EnLLMCore
import SwiftUI

@main
@MainActor
struct EnLLMApp: App {
    @NSApplicationDelegateAdaptor(ApplicationTerminationDelegate.self) private var appDelegate
    @StateObject private var coordinator: ActionCoordinator
    @StateObject private var settingsModel: ProviderSettingsModel

    init() {
        let runtime = AppComposition.makeRuntime()
        _coordinator = StateObject(wrappedValue: runtime.coordinator)
        _settingsModel = StateObject(wrappedValue: runtime.settingsModel)
        appDelegate.coordinator = runtime.coordinator
        appDelegate.settingsModel = runtime.settingsModel
        runtime.loadStoredCredentials()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(coordinator)
        } label: {
            Image(systemName: coordinator.isActive ? "ellipsis.circle" : "text.bubble")
                .accessibilityLabel(coordinator.isActive ? "EnLLM working" : "EnLLM")
        }

        Settings {
            SettingsView(model: settingsModel)
        }
    }
}

@MainActor
final class ApplicationTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: ActionCoordinator?
    weak var settingsModel: ProviderSettingsModel?
    private var terminationTask: Task<Void, Never>?
    private var didReply = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }

        let settingsModel = settingsModel
        terminationTask = Task { @MainActor [weak self, weak sender] in
            // Decide the Settings commit/rollback first, so a blocked save can cancel
            // termination before any clipboard teardown happens.
            var settingsSafe = await settingsModel?.prepareForTermination() ?? true
            if !settingsSafe {
                let discard = self?.presentSafeDiscardAlert() ?? true
                if discard {
                    settingsModel?.confirmSafeDiscard()
                    settingsSafe = await settingsModel?.prepareForTermination() ?? true
                }
            }
            guard let self else { return }
            guard settingsSafe else {
                // Cancel termination; the app remains usable with the last good runtime.
                self.terminationTask = nil
                sender?.reply(toApplicationShouldTerminate: false)
                return
            }
            // Settings are durable; now quiesce clipboard ownership before replying.
            let cleanupTask = coordinator.prepareForTermination()
            _ = await cleanupTask.value
            guard !self.didReply else { return }
            self.didReply = true
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Presents a blocking confirmation when an uncommittable or failed settings edit
    /// would be lost on quit. Returns true when the user chooses to discard and quit.
    private func presentSafeDiscardAlert() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Discard unsaved settings changes?"
        alert.informativeText = "Some settings changes could not be saved. Quitting now discards them and keeps the last saved configuration."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard and Quit")
        alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
