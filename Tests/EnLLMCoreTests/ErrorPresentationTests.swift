import EnLLMCore
import Foundation
import Testing

private struct UnsafeError: LocalizedError {
    let errorDescription: String?
}

@Test func unknownErrorsNeverExposeTheirLocalizedDescription() {
    let sentinel = "selected text / API key / response body sentinel"
    let presentation = ErrorPresentation.present(UnsafeError(errorDescription: sentinel))

    #expect(presentation.category == .unknown)
    #expect(presentation.message == "Something went wrong. Please try again.")
    #expect(!presentation.message.contains(sentinel))
    #expect(presentation.recoveryAction == .none)
}

@Test func knownErrorsKeepStableActionableMessages() {
    let permission = ErrorPresentation.present(EnLLMError.accessibilityPermissionMissing)
    let credential = ErrorPresentation.present(EnLLMError.providerCredentialMissing(.anthropic))

    #expect(permission.category == .accessibilityPermission)
    #expect(permission.message == "Accessibility access is required to read the selected text.")
    #expect(permission.recoveryAction == .openAccessibilitySettings)
    #expect(credential.category == .providerSetup)
    #expect(credential.message == "Add an API key for Anthropic in Settings.")
    #expect(credential.recoveryAction == .openAppSettings)
}

@Test func recoveryActionsMapCategoriesToASingleSafeAffordance() {
    #expect(
        ErrorPresentation.present(EnLLMError.runtimeCredentialUncertain(.openAI)).recoveryAction
            == .openAppSettings
    )
    // Provider, network, clipboard, input, and settings failures carry no button.
    #expect(ErrorPresentation.present(EnLLMError.providerFailure(.anthropic)).recoveryAction == .none)
    #expect(ErrorPresentation.present(EnLLMError.providerNetworkFailure(.openAI)).recoveryAction == .none)
    #expect(ErrorPresentation.present(EnLLMError.clipboardRestorationFailed).recoveryAction == .none)
    #expect(ErrorPresentation.present(EnLLMError.noSelection).recoveryAction == .none)
    #expect(ErrorPresentation.present(EnLLMError.settingsRecoveryRequired).recoveryAction == .none)
}
