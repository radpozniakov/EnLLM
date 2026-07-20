import Foundation

public enum EnLLMError: LocalizedError, Equatable, Sendable {
    case featureUnavailable(AppAction)
    case accessibilityPermissionMissing
    case noSelection
    case selectionCaptureFailed
    case inputTooLong(maximum: Int)
    case secureFieldUnsupported
    case clipboardUnavailable
    case clipboardSnapshotIncomplete
    case clipboardRestorationFailed
    case emptyOutput
    case providerCredentialMissing(LLMProvider)
    case providerAuthenticationFailed(LLMProvider)
    case providerRateLimited(LLMProvider)
    case providerTimeout(LLMProvider)
    case providerNetworkFailure(LLMProvider)
    case providerFailure(LLMProvider)
    case providerIncompleteResponse(LLMProvider)
    case bothProvidersFailed(primary: LLMProvider, secondary: LLMProvider)
    case credentialStoreFailure
    case invalidSettings
    case settingsPersistenceFailed
    case settingsRecoveryRequired
    case runtimeCredentialUncertain(LLMProvider)
    case hotkeyRegistrationFailed

    public var errorDescription: String? {
        switch self {
        case .featureUnavailable(let action):
            "\(action.title) is not implemented in this configuration."
        case .accessibilityPermissionMissing:
            "Accessibility access is required to read the selected text."
        case .noSelection:
            "No selected text was found."
        case .selectionCaptureFailed:
            "The selected text could not be read safely."
        case .inputTooLong(let maximum):
            "The selection is longer than \(maximum) characters."
        case .secureFieldUnsupported:
            "Text in secure fields cannot be used."
        case .clipboardUnavailable:
            "The clipboard is unavailable."
        case .clipboardSnapshotIncomplete:
            "The clipboard could not be preserved safely."
        case .clipboardRestorationFailed:
            "The clipboard could not be restored completely."
        case .emptyOutput:
            "The provider returned an empty response."
        case .providerCredentialMissing(let provider):
            "Add an API key for \(provider.displayName) in Settings."
        case .providerAuthenticationFailed(let provider):
            "\(provider.displayName) rejected the API key. Check it in Settings."
        case .providerRateLimited(let provider):
            "\(provider.displayName) is rate limiting requests. Try again later."
        case .providerTimeout(let provider):
            "\(provider.displayName) did not respond within 15 seconds."
        case .providerNetworkFailure(let provider):
            "Could not reach \(provider.displayName). Check your network connection."
        case .providerFailure(let provider):
            "\(provider.displayName) could not complete the request."
        case .providerIncompleteResponse(let provider):
            "\(provider.displayName) returned an incomplete response."
        case .bothProvidersFailed(let primary, let secondary):
            "\(primary.displayName) and then \(secondary.displayName) could not complete the request."
        case .credentialStoreFailure:
            "The API key could not be accessed in macOS Keychain."
        case .invalidSettings:
            "Review the highlighted settings before applying changes."
        case .settingsPersistenceFailed:
            "Settings could not be saved. The previous runtime configuration remains active."
        case .settingsRecoveryRequired:
            "Settings recovery was incomplete. Actual stored state was reloaded and uncertain routes were disabled."
        case .runtimeCredentialUncertain(let provider):
            "The stored \(provider.displayName) credential could not be verified. Save it again in Settings."
        case .hotkeyRegistrationFailed:
            "A keyboard shortcut could not be registered."
        }
    }

    public func isFallbackableProviderFailure(for attemptedProvider: LLMProvider) -> Bool {
        switch self {
        case .emptyOutput:
            true
        case .providerCredentialMissing(let provider),
             .providerAuthenticationFailed(let provider),
             .providerRateLimited(let provider),
             .providerTimeout(let provider),
             .providerNetworkFailure(let provider),
             .providerFailure(let provider),
             .providerIncompleteResponse(let provider):
            provider == attemptedProvider
        case .featureUnavailable,
             .accessibilityPermissionMissing,
             .noSelection,
             .selectionCaptureFailed,
             .inputTooLong,
             .secureFieldUnsupported,
             .clipboardUnavailable,
             .clipboardSnapshotIncomplete,
             .clipboardRestorationFailed,
             .bothProvidersFailed,
             .credentialStoreFailure,
             .invalidSettings,
             .settingsPersistenceFailed,
             .settingsRecoveryRequired,
             .runtimeCredentialUncertain,
             .hotkeyRegistrationFailed:
            false
        }
    }
}
