import EnLLMCore
import Foundation

public struct OpenAIResponsesClient: LLMProviderClient {
    public let provider = LLMProvider.openAI

    private let endpoint: URL
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        endpoint = URL(string: "https://api.openai.com/v1/responses")!
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
            throw EnLLMError.providerCredentialMissing(.openAI)
        }
        guard !request.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.maxOutputTokens > 0 else {
            throw EnLLMError.providerFailure(.openAI)
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Self.timeInterval(for: request.timeout)
        urlRequest.setValue("Bearer \(trimmedCredential)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            urlRequest.httpBody = try JSONEncoder().encode(
                OpenAIRequest(
                    model: request.model,
                    instructions: request.instruction,
                    input: request.userText,
                    maxOutputTokens: request.maxOutputTokens,
                    store: false
                )
            )
        } catch {
            throw EnLLMError.providerFailure(.openAI)
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
            throw EnLLMError.providerTimeout(.openAI)
        } catch is URLError {
            throw EnLLMError.providerNetworkFailure(.openAI)
        } catch {
            throw EnLLMError.providerFailure(.openAI)
        }

        try Task.checkCancellation()
        guard 200..<300 ~= response.statusCode else {
            throw Self.error(forHTTPStatus: response.statusCode)
        }

        let decoded: OpenAIResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        } catch {
            throw EnLLMError.providerFailure(.openAI)
        }

        guard decoded.status == "completed" else {
            throw EnLLMError.providerIncompleteResponse(.openAI)
        }
        guard let outputItems = decoded.output else {
            throw EnLLMError.providerFailure(.openAI)
        }

        var textBlocks: [String] = []
        for item in outputItems {
            guard let contentBlocks = item.content else { continue }
            for block in contentBlocks {
                guard block.type != "output_text" || block.text != nil else {
                    throw EnLLMError.providerFailure(.openAI)
                }
                if block.type == "output_text", let text = block.text {
                    textBlocks.append(text)
                }
            }
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
            .providerAuthenticationFailed(.openAI)
        case 408:
            .providerTimeout(.openAI)
        case 429:
            .providerRateLimited(.openAI)
        default:
            .providerFailure(.openAI)
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

private struct OpenAIRequest: Encodable {
    let model: String
    let instructions: String
    let input: String
    let maxOutputTokens: Int
    let store: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case input
        case maxOutputTokens = "max_output_tokens"
        case store
    }
}

private struct OpenAIResponse: Decodable {
    let status: String?
    let output: [OpenAIOutputItem]?
}

private struct OpenAIOutputItem: Decodable {
    let content: [OpenAIContentBlock]?
}

private struct OpenAIContentBlock: Decodable {
    let type: String
    let text: String?
}
