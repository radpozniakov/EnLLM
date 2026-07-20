import EnLLMCore
import Foundation

public struct AnthropicMessagesClient: LLMProviderClient {
    public let provider = LLMProvider.anthropic

    private let endpoint: URL
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        self.transport = transport
    }

    init(endpoint: URL, transport: any HTTPTransport) {
        self.endpoint = endpoint
        self.transport = transport
    }

    public func complete(
        _ request: LLMCompletionRequest,
        credential: String
    ) async throws -> String {
        try Task.checkCancellation()

        let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCredential.isEmpty else {
            throw EnLLMError.providerCredentialMissing(.anthropic)
        }
        guard !request.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.maxOutputTokens > 0 else {
            throw EnLLMError.providerFailure(.anthropic)
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Self.timeInterval(for: request.timeout)
        urlRequest.setValue(trimmedCredential, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            urlRequest.httpBody = try JSONEncoder().encode(
                AnthropicRequest(
                    model: request.model,
                    maxTokens: request.maxOutputTokens,
                    system: request.instruction,
                    messages: [AnthropicMessage(role: "user", content: request.userText)]
                )
            )
        } catch {
            throw EnLLMError.providerFailure(.anthropic)
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw EnLLMError.providerTimeout(.anthropic)
        } catch is URLError {
            throw EnLLMError.providerNetworkFailure(.anthropic)
        } catch {
            throw EnLLMError.providerFailure(.anthropic)
        }

        try Task.checkCancellation()
        guard 200..<300 ~= response.statusCode else {
            throw Self.error(forHTTPStatus: response.statusCode)
        }

        let decoded: AnthropicResponse
        do {
            decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        } catch {
            throw EnLLMError.providerFailure(.anthropic)
        }

        guard decoded.stopReason == "end_turn" else {
            throw EnLLMError.providerIncompleteResponse(.anthropic)
        }

        var textBlocks: [String] = []
        for block in decoded.content where block.type == "text" {
            guard let text = block.text else {
                throw EnLLMError.providerFailure(.anthropic)
            }
            textBlocks.append(text)
        }
        let output = textBlocks.joined()
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnLLMError.emptyOutput
        }
        return output
    }

    private static func error(forHTTPStatus statusCode: Int) -> EnLLMError {
        switch statusCode {
        case 401, 403:
            .providerAuthenticationFailed(.anthropic)
        case 408:
            .providerTimeout(.anthropic)
        case 429:
            .providerRateLimited(.anthropic)
        default:
            .providerFailure(.anthropic)
        }
    }

    private static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return max(
            0.001,
            TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        )
    }
}

private struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [AnthropicMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

private struct AnthropicMessage: Encodable {
    let role: String
    let content: String
}

private struct AnthropicResponse: Decodable {
    let content: [AnthropicContentBlock]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}

private struct AnthropicContentBlock: Decodable {
    let type: String
    let text: String?
}
