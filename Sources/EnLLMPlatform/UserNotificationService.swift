import EnLLMCore
import Foundation
import UserNotifications

@MainActor
protocol UserNotificationCenterClient: AnyObject {
    func notificationAuthorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@MainActor
public final class UserNotificationService: CorrectionFailureNotifying {
    private let center: any UserNotificationCenterClient
    private var inFlightIdentifiers: Set<String> = []
    private var cancelledIdentifiers: Set<String> = []

    public convenience init() {
        self.init(center: UNUserNotificationCenterClient(center: .current()))
    }

    init(center: any UserNotificationCenterClient) {
        self.center = center
    }

    public func authorizationStatus() async -> NotificationAuthorizationStatus {
        switch await center.notificationAuthorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            .authorized
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        @unknown default:
            .denied
        }
    }

    public func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    public func deliver(_ notification: CorrectionFailureNotification) async throws {
        let identifier = Self.identifier(for: notification.operationID)
        guard cancelledIdentifiers.remove(identifier) == nil else {
            throw CancellationError()
        }
        inFlightIdentifiers.insert(identifier)
        defer {
            inFlightIdentifiers.remove(identifier)
            cancelledIdentifiers.remove(identifier)
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        do {
            try Task.checkCancellation()
            try await withTaskCancellationHandler(operation: {
                try await center.add(request)
                try Task.checkCancellation()
                guard !cancelledIdentifiers.contains(identifier) else {
                    throw CancellationError()
                }
            }, onCancel: { [weak self] in
                Task { @MainActor in
                    self?.removeNotification(identifier)
                }
            })
        } catch {
            removeNotification(identifier)
            throw error
        }
    }

    public func cancelDelivery(for operationID: OperationID) {
        let identifier = Self.identifier(for: operationID)
        if inFlightIdentifiers.contains(identifier) {
            cancelledIdentifiers.insert(identifier)
        }
        removeNotification(identifier)
    }

    static func identifier(for operationID: OperationID) -> String {
        "com.radpozniakov.enllm.correction-failure.\(operationID.rawValue.uuidString)"
    }

    private func removeNotification(_ identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

@MainActor
private final class UNUserNotificationCenterClient: UserNotificationCenterClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: options) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
