import Foundation

public enum AppAction: String, CaseIterable, Equatable, Hashable, Sendable {
    case correctSelection
    case translateSelectionToUkrainian

    public var title: String {
        switch self {
        case .correctSelection:
            "Correct Selection"
        case .translateSelectionToUkrainian:
            "Translate Selection to Ukrainian"
        }
    }
}

@MainActor
public protocol ActionHandling: Sendable {
    func perform(_ action: AppAction, operationID: OperationID) async throws -> ActionOutput
}
