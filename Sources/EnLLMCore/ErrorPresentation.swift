import Foundation

public enum UserFacingErrorCategory: String, Equatable, Sendable, CaseIterable {
    case accessibilityPermission
    case providerSetup
    case input
    case clipboard
    case provider
    case settings
    case unavailable
    case unknown
}

/// The single safe recovery affordance a user-facing error may offer.
///
/// Modeled as a closed enum so the presentation layer can render at most one
/// concrete action per error and never has to interpret an ambiguous set of
/// booleans. Notifications remain action-free; only the panel consumes this.
public enum ErrorRecoveryAction: Equatable, Sendable {
    case none
    case openAccessibilitySettings
    case openAppSettings
}

public struct UserFacingErrorPresentation: Equatable, Sendable {
    public let category: UserFacingErrorCategory
    public let message: String
    public let recoveryAction: ErrorRecoveryAction

    init(
        category: UserFacingErrorCategory,
        message: String,
        recoveryAction: ErrorRecoveryAction = .none
    ) {
        self.category = category
        self.message = message
        self.recoveryAction = recoveryAction
    }
}

public enum ErrorPresentation {
    public static func present(_ error: Error) -> UserFacingErrorPresentation {
        guard let error = error as? EnLLMError else {
            return UserFacingErrorPresentation(
                category: .unknown,
                message: "Something went wrong. Please try again."
            )
        }

        let category: UserFacingErrorCategory
        let recoveryAction: ErrorRecoveryAction
        switch error {
        case .accessibilityPermissionMissing:
            category = .accessibilityPermission
            recoveryAction = .openAccessibilitySettings
        case .providerCredentialMissing, .runtimeCredentialUncertain:
            category = .providerSetup
            recoveryAction = .openAppSettings
        case .noSelection, .selectionCaptureFailed, .inputTooLong, .secureFieldUnsupported:
            category = .input
            recoveryAction = .none
        case .clipboardUnavailable, .clipboardSnapshotIncomplete, .clipboardRestorationFailed:
            category = .clipboard
            recoveryAction = .none
        case .emptyOutput, .providerAuthenticationFailed, .providerRateLimited, .providerTimeout,
             .providerNetworkFailure, .providerFailure, .providerIncompleteResponse, .bothProvidersFailed:
            category = .provider
            recoveryAction = .none
        case .credentialStoreFailure, .invalidSettings, .settingsPersistenceFailed,
             .settingsRecoveryRequired, .hotkeyRegistrationFailed:
            category = .settings
            recoveryAction = .none
        case .featureUnavailable:
            category = .unavailable
            recoveryAction = .none
        }

        return UserFacingErrorPresentation(
            category: category,
            message: error.errorDescription ?? "Something went wrong. Please try again.",
            recoveryAction: recoveryAction
        )
    }
}
