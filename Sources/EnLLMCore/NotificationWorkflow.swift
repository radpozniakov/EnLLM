import Foundation

public enum NotificationAuthorizationStatus: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
}

/// A correction-failure notification built only from Core's stable error
/// presentation. Selected text, generated text, credentials, and raw provider
/// data cannot enter this value through its public API.
public struct CorrectionFailureNotification: Equatable, Sendable {
    public let operationID: OperationID
    public let title: String
    public let body: String

    public init(operationID: OperationID, presentation: UserFacingErrorPresentation) {
        self.operationID = operationID
        title = "Correction failed"
        body = presentation.message
    }
}

@MainActor
public protocol CorrectionFailureNotifying: Sendable {
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func requestAuthorization() async
    func deliver(_ notification: CorrectionFailureNotification) async throws
    func cancelDelivery(for operationID: OperationID)
}
