import Foundation

public enum RuntimeCredential: Equatable, Sendable {
    case available(String)
    case missing
    case disabledUncertain
}

public struct RuntimeConfiguration: Equatable, Sendable {
    public let settings: NonSecretConfiguration
    public let anthropicCredential: RuntimeCredential
    public let openAICredential: RuntimeCredential

    public init(
        settings: NonSecretConfiguration,
        anthropicCredential: RuntimeCredential,
        openAICredential: RuntimeCredential
    ) {
        self.settings = settings
        self.anthropicCredential = anthropicCredential
        self.openAICredential = openAICredential
    }

    public func credential(for provider: LLMProvider) -> RuntimeCredential {
        provider == .anthropic ? anthropicCredential : openAICredential
    }
}

@MainActor
public protocol RuntimeConfigurationProviding: Sendable {
    var runtimeConfiguration: RuntimeConfiguration { get }
}

@MainActor
public protocol RuntimeConfigurationPublishing: RuntimeConfigurationProviding {
    func publish(_ configuration: RuntimeConfiguration)
}

@MainActor
public final class RuntimeConfigurationStore: RuntimeConfigurationPublishing {
    public private(set) var runtimeConfiguration: RuntimeConfiguration

    public init(_ runtimeConfiguration: RuntimeConfiguration) {
        self.runtimeConfiguration = runtimeConfiguration
    }

    public func publish(_ configuration: RuntimeConfiguration) {
        runtimeConfiguration = configuration
    }
}
