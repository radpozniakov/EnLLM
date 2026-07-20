import EnLLMCore

/// Fail-closed composition used when no production action implementation exists.
public struct UnavailableActionHandler: ActionHandling {
    public init() {}

    @MainActor
    public func perform(_ action: AppAction, operationID: OperationID) async throws -> ActionOutput {
        throw EnLLMError.featureUnavailable(action)
    }
}
