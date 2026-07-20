import AppKit
import EnLLMCore
import EnLLMPlatform
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ProviderSettingsModel
    @State private var accessibilityTrusted = false
    @State private var deletionConfirmationProvider: LLMProvider?
    private let permissionService = AccessibilityPermissionService()

    var body: some View {
        Form {
            Section("Routing") {
                Picker("Primary provider", selection: $model.primaryProvider) {
                    ForEach(LLMProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Enable fallback to the alternate provider", isOn: $model.fallbackEnabled)
                Text(model.fallbackEffectDescription).font(.caption).foregroundStyle(.secondary)
                if let message = model.fallbackAvailabilityMessage { Label(message, systemImage: "exclamationmark.triangle").font(.caption) }
                Text(model.routingPersistenceMessage).font(.caption).foregroundStyle(.secondary)
            }

            providerSection(.anthropic)
            providerSection(.openAI)

            Section("Instructions") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Correction")
                    TextEditor(text: $model.correctionInstruction)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(3)
                        .frame(height: 100)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator)
                        }
                    Button("Reset correction instructions") { model.correctionInstruction = BuiltInDefaults.correctionInstruction }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Ukrainian translation")
                    TextEditor(text: $model.translationInstruction)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(3)
                        .frame(height: 100)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator)
                        }
                    Button("Reset translation instructions") { model.translationInstruction = BuiltInDefaults.ukrainianTranslationInstruction }
                }
            }

            Section("Global shortcuts") {
                shortcutRow(.correctSelection, title: "Correct Selection", binding: $model.correctHotkey)
                shortcutRow(.translateSelectionToUkrainian, title: "Translate Selection", binding: $model.translateHotkey)
                ForEach(model.validationIssues, id: \.rawValue) { issue in
                    Label(issue.message, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
            }

            Section("Accessibility") {
                Label(
                    accessibilityTrusted ? "Accessibility access is granted." : "Accessibility access is required to read and safely replace selected text.",
                    systemImage: accessibilityTrusted ? "checkmark.circle" : "exclamationmark.triangle"
                )
                Button("Open Accessibility Settings") {
                    permissionService.requestAccessPrompt()
                    _ = permissionService.openSettings()
                }
            }

            Section {
                if let recovery = model.recoveryMessage { Label(recovery, systemImage: "exclamationmark.triangle.fill") }
                statusView(model.applyStatus)
                HStack {
                    Button("Reset Models & Prompts") { model.resetModelsAndPrompts() }
                    Spacer()
                    Text("Changes save automatically.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!model.isBootstrapped)
        .frame(width: 700, height: 760)
        .padding()
        .onAppear { accessibilityTrusted = permissionService.isTrusted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = permissionService.isTrusted
        }
        .onDisappear { model.settingsDidDisappear(); model.endRecording() }
    }

    @ViewBuilder
    private func providerSection(_ provider: LLMProvider) -> some View {
        Section(provider.displayName) {
            modelPicker(provider, action: .correctSelection, label: "Correction model")
            modelPicker(provider, action: .translateSelectionToUkrainian, label: "Translation model")
            HStack {
                SecureField("API key", text: Binding(
                    get: { model.draftAPIKey(for: provider) },
                    set: { model.setDraftAPIKey($0, for: provider) }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(provider.displayName) API key")
                // Delete only for a confirmed saved credential; Undo only while editing or pending deletion of one.
                if model.canDeleteCredential(provider) {
                    Button("Delete", role: .destructive) { deletionConfirmationProvider = provider }
                }
                if model.canUndoCredential(provider) {
                    Button("Undo") { model.undoCredentialEdit(provider) }
                }
            }
            .confirmationDialog(
                "Delete the \(provider.displayName) API key?",
                isPresented: Binding(
                    get: { deletionConfirmationProvider == provider },
                    set: { presented in if !presented { deletionConfirmationProvider = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete \(provider.displayName) Key", role: .destructive) {
                    model.confirmCredentialDeletion(provider)
                    deletionConfirmationProvider = nil
                }
                Button("Cancel", role: .cancel) { deletionConfirmationProvider = nil }
            } message: {
                Text("The saved key is removed from your Keychain when settings are saved. You can Undo before then.")
            }
            Text(credentialDescription(provider)).font(.caption).foregroundStyle(.secondary)
            if model.isPendingCredentialDeletion(provider) {
                Label("This key will be deleted when settings are saved. Undo to keep it.", systemImage: "trash")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Test Connection") { model.startTestConnection(for: provider) }
                    .disabled(model.isTesting(provider))
                if model.isTesting(provider) { ProgressView().controlSize(.small); Text("Testing…") }
            }
            if let message = model.statusMessage(for: provider) { Label(message, systemImage: statusIcon(model.status(for: provider))) }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ action: AppAction, title: String, binding: Binding<HotkeyDefinition>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                HotkeyRecorderView(
                    definition: binding,
                    action: action,
                    onBegin: model.beginRecording,
                    onEnd: model.endRecording,
                    onCapture: { keyCode, modifiers, recordedAction in
                        model.handleRecordedKey(keyCode: keyCode, modifiers: modifiers, for: recordedAction)
                            == .recorded(HotkeyDefinition(keyCode: keyCode, modifiers: modifiers))
                    },
                    onCancel: model.cancelRecording
                )
                .frame(width: 160, height: 24)
                if model.isRecording(action) {
                    Text("Recording…")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Recording \(title) shortcut. Press a key with a modifier, or Escape to cancel.")
                }
            }
        }
        if let message = model.recordingMessage(for: action) {
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func modelPicker(_ provider: LLMProvider, action: AppAction, label: String) -> some View {
        Picker(label, selection: Binding(
            get: { model.selectedModel(for: provider, action: action) },
            set: { model.setSelectedModel($0, for: provider, action: action) }
        )) {
            ForEach(LLMModelCatalog.allowedModels(for: provider, action: action), id: \.self) { modelID in
                Text(modelID).tag(modelID)
            }
        }
        .accessibilityLabel("\(provider.displayName) \(label)")
    }

    private func credentialDescription(_ provider: LLMProvider) -> String {
        switch model.credentialAvailability(for: provider) {
        case .present: "The saved key is shown securely and stored in macOS Keychain."
        case .absent: "No key is stored. Enter one to save it with the complete draft."
        case .unknown: "Stored-key status is unknown. This provider route is disabled until successfully applied."
        }
    }

    @ViewBuilder private func statusView(_ status: ProviderSettingsModel.Status) -> some View {
        switch status {
        case .idle: EmptyView()
        case .saving:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Saving…") }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Saving settings")
        case .saved:
            Label("Saved", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        case .success(let message): Label(message, systemImage: "checkmark.circle")
        case .failure(let message): Label(message, systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }
    private func statusIcon(_ status: ProviderSettingsModel.Status) -> String {
        if case .failure = status { return "xmark.circle" }
        return "checkmark.circle"
    }
}
