import EnLLMCore
import Foundation
import Testing
@testable import EnLLMPlatform

private actor StubHTTPTransport: HTTPTransport {
    enum Behavior: Sendable {
        case response(status: Int, body: Data)
        case urlError(URLError.Code)
        case suspend
    }

    let behavior: Behavior
    private(set) var requests: [URLRequest] = []
    private(set) var cancellationObserved = false

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        switch behavior {
        case .response(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body, response)
        case .urlError(let code):
            throw URLError(code)
        case .suspend:
            do {
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            } catch is CancellationError {
                cancellationObserved = true
                throw CancellationError()
            }
        }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

private func request() -> LLMCompletionRequest {
    LLMCompletionRequest(
        instruction: "system instruction",
        userText: "selected user text",
        model: "claude-haiku-4-5"
    )
}

private func responseBody(
    stopReason: String? = "end_turn",
    content: String = #"[{"type":"text","text":"output"}]"#
) -> Data {
    let stopJSON = stopReason.map { #""\#($0)""# } ?? "null"
    return Data(#"{"content":\#(content),"stop_reason":\#(stopJSON)}"#.utf8)
}

@Test func anthropicRequestUsesRequiredHeadersAndSeparateSystemAndUserContent() async throws {
    let transport = StubHTTPTransport(.response(
        status: 200,
        body: responseBody(
            content: #"[{"type":"text","text":" first"},{"type":"tool_use"},{"type":"text","text":"\nsecond "}]"#
        )
    ))
    let client = AnthropicMessagesClient(transport: transport)

    let output = try await client.complete(request(), credential: "test-key")
    let sent = try #require(await transport.requests.first)

    #expect(output == " first\nsecond ")
    #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(sent.httpMethod == "POST")
    #expect(sent.timeoutInterval == 15)
    #expect(sent.value(forHTTPHeaderField: "x-api-key") == "test-key")
    #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(sent.value(forHTTPHeaderField: "content-type") == "application/json")

    let body = try #require(sent.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "claude-haiku-4-5")
    #expect(json["max_tokens"] as? Int == 4_096)
    #expect(json["system"] as? String == "system instruction")
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(messages[0]["role"] as? String == "user")
    #expect(messages[0]["content"] as? String == "selected user text")
    #expect(!(json["system"] as? String ?? "").contains("selected user text"))
}

@Test func anthropicRejectsEveryNonEndTurnOrMissingStopReason() async {
    for stopReason in ["max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal", "future_status"] {
        let client = AnthropicMessagesClient(transport: StubHTTPTransport(.response(
            status: 200,
            body: responseBody(stopReason: stopReason)
        )))
        await #expect(throws: EnLLMError.providerIncompleteResponse(.anthropic)) {
            try await client.complete(request(), credential: "key")
        }
    }

    let missing = Data(#"{"content":[{"type":"text","text":"output"}]}"#.utf8)
    let client = AnthropicMessagesClient(transport: StubHTTPTransport(.response(
        status: 200,
        body: missing
    )))
    await #expect(throws: EnLLMError.providerIncompleteResponse(.anthropic)) {
        try await client.complete(request(), credential: "key")
    }
}

@Test func anthropicRejectsEmptyOrMalformedSuccessfulResponses() async {
    let emptyClient = AnthropicMessagesClient(transport: StubHTTPTransport(.response(
        status: 200,
        body: responseBody(content: #"[{"type":"text","text":"  \n "}]"#)
    )))
    await #expect(throws: EnLLMError.emptyOutput) {
        try await emptyClient.complete(request(), credential: "key")
    }

    let malformedClient = AnthropicMessagesClient(transport: StubHTTPTransport(.response(
        status: 200,
        body: Data("private selected text and secret-key".utf8)
    )))
    await #expect(throws: EnLLMError.providerFailure(.anthropic)) {
        try await malformedClient.complete(request(), credential: "secret-key")
    }

    for content in [
        #"[{"type":"text"},{"type":"text","text":"partial"}]"#,
        #"[{"type":"text","text":null},{"type":"text","text":"partial"}]"#
    ] {
        let malformedTextBlockClient = AnthropicMessagesClient(
            transport: StubHTTPTransport(.response(
                status: 200,
                body: responseBody(content: content)
            ))
        )
        await #expect(throws: EnLLMError.providerFailure(.anthropic)) {
            try await malformedTextBlockClient.complete(request(), credential: "key")
        }
    }
}

@Test func anthropicMapsHTTPFailuresWithoutExposingRawBodies() async {
    let cases: [(Int, EnLLMError)] = [
        (401, .providerAuthenticationFailed(.anthropic)),
        (403, .providerAuthenticationFailed(.anthropic)),
        (408, .providerTimeout(.anthropic)),
        (429, .providerRateLimited(.anthropic)),
        (500, .providerFailure(.anthropic)),
        (529, .providerFailure(.anthropic))
    ]

    for (status, expected) in cases {
        let client = AnthropicMessagesClient(transport: StubHTTPTransport(.response(
            status: status,
            body: Data(#"{"error":{"message":"secret-key private selected text"}}"#.utf8)
        )))
        do {
            _ = try await client.complete(request(), credential: "secret-key")
            Issue.record("Expected HTTP status \(status) to fail")
        } catch let error as EnLLMError {
            #expect(error == expected)
            #expect(!error.localizedDescription.contains("secret-key"))
            #expect(!error.localizedDescription.contains("private selected text"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func anthropicMapsTimeoutAndNetworkAndPropagatesCancellation() async {
    let timeoutClient = AnthropicMessagesClient(
        transport: StubHTTPTransport(.urlError(.timedOut))
    )
    await #expect(throws: EnLLMError.providerTimeout(.anthropic)) {
        try await timeoutClient.complete(request(), credential: "key")
    }

    let networkClient = AnthropicMessagesClient(
        transport: StubHTTPTransport(.urlError(.notConnectedToInternet))
    )
    await #expect(throws: EnLLMError.providerNetworkFailure(.anthropic)) {
        try await networkClient.complete(request(), credential: "key")
    }

    let cancellationTransport = StubHTTPTransport(.suspend)
    let cancellationClient = AnthropicMessagesClient(transport: cancellationTransport)
    let task = Task {
        try await cancellationClient.complete(request(), credential: "key")
    }
    let transportStarted = await waitUntil {
        !(await cancellationTransport.requests.isEmpty)
    }
    #expect(transportStarted, "Injected transport should be entered before cancellation")
    task.cancel()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(await cancellationTransport.cancellationObserved)
}

@Test func anthropicRejectsBlankCredentialBeforeTransport() async {
    let transport = StubHTTPTransport(.response(status: 200, body: responseBody()))
    let client = AnthropicMessagesClient(transport: transport)

    await #expect(throws: EnLLMError.providerCredentialMissing(.anthropic)) {
        try await client.complete(request(), credential: " \n ")
    }
    #expect(await transport.requests.isEmpty)
}
