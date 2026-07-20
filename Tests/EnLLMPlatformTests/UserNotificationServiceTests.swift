import EnLLMCore
import EnLLMPlatform
import Testing
import UserNotifications
@testable import EnLLMPlatform

@MainActor
private final class NotificationCenterSpy: UserNotificationCenterClient {
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var requestedOptions: [UNAuthorizationOptions] = []
    var requests: [UNNotificationRequest] = []
    var removedPendingIdentifiers: [[String]] = []
    var removedDeliveredIdentifiers: [[String]] = []
    var addError: Error?
    var shouldSuspendAdd = false
    private var addContinuation: CheckedContinuation<Void, any Error>?
    var isAdding: Bool { addContinuation != nil }

    func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatus
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions.append(options)
        return true
    }

    func add(_ request: UNNotificationRequest) async throws {
        requests.append(request)
        if shouldSuspendAdd {
            try await withCheckedThrowingContinuation { continuation in
                addContinuation = continuation
            }
        }
        if let addError { throw addError }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPendingIdentifiers.append(identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDeliveredIdentifiers.append(identifiers)
    }

    func finishAdd() {
        addContinuation?.resume()
        addContinuation = nil
    }
}

private func makeNotification(_ operationID: OperationID = OperationID()) -> CorrectionFailureNotification {
    CorrectionFailureNotification(
        operationID: operationID,
        presentation: ErrorPresentation.present(EnLLMError.providerNetworkFailure(.anthropic))
    )
}

@MainActor
@Test func notificationServiceMapsAuthorizationStatusesAndRequestsOnlyAlertAndSound() async {
    let center = NotificationCenterSpy()
    let service = UserNotificationService(center: center)

    center.authorizationStatus = .authorized
    #expect(await service.authorizationStatus() == .authorized)
    center.authorizationStatus = .provisional
    #expect(await service.authorizationStatus() == .authorized)
    center.authorizationStatus = .notDetermined
    #expect(await service.authorizationStatus() == .notDetermined)
    center.authorizationStatus = .denied
    #expect(await service.authorizationStatus() == .denied)

    await service.requestAuthorization()
    #expect(center.requestedOptions == [[.alert, .sound]])
}

@MainActor
@Test func notificationServiceBuildsAStableActionFreeSystemRequest() async throws {
    let center = NotificationCenterSpy()
    let service = UserNotificationService(center: center)
    let operationID = OperationID()
    let notification = makeNotification(operationID)

    try await service.deliver(notification)

    #expect(center.requests.count == 1)
    guard let request = center.requests.first else {
        Issue.record("Expected notification request")
        return
    }
    #expect(request.identifier == UserNotificationService.identifier(for: operationID))
    #expect(request.trigger == nil)
    #expect(request.content.title == "Correction failed")
    #expect(request.content.body == "Could not reach Anthropic. Check your network connection.")
    #expect(request.content.sound != nil)
    #expect(request.content.categoryIdentifier.isEmpty)
    #expect(request.content.userInfo.isEmpty)
}

@MainActor
@Test func cancellingDeliveryRemovesPendingAndDeliveredRequestsIncludingPostAddCancellation() async {
    let center = NotificationCenterSpy()
    center.shouldSuspendAdd = true
    let service = UserNotificationService(center: center)
    let operationID = OperationID()
    let identifier = UserNotificationService.identifier(for: operationID)
    let task = Task { try await service.deliver(makeNotification(operationID)) }

    while !center.isAdding { await Task.yield() }
    service.cancelDelivery(for: operationID)
    #expect(center.removedPendingIdentifiers == [[identifier]])
    #expect(center.removedDeliveredIdentifiers == [[identifier]])

    center.finishAdd()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(center.removedPendingIdentifiers == [[identifier], [identifier]])
    #expect(center.removedDeliveredIdentifiers == [[identifier], [identifier]])
}

@MainActor
@Test func notificationServicePropagatesDeliveryFailureAfterRemovingTheRequest() async {
    let center = NotificationCenterSpy()
    center.addError = EnLLMError.clipboardUnavailable
    let service = UserNotificationService(center: center)
    let operationID = OperationID()
    let identifier = UserNotificationService.identifier(for: operationID)

    await #expect(throws: EnLLMError.clipboardUnavailable) {
        try await service.deliver(makeNotification(operationID))
    }
    #expect(center.removedPendingIdentifiers == [[identifier]])
    #expect(center.removedDeliveredIdentifiers == [[identifier]])
}
