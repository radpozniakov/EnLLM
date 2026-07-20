import EnLLMCore
import Foundation
import Testing
@testable import EnLLMPlatform

private actor StubOpenAIHTTPTransport: HTTPTransport {
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

private func openAIRequest(model: String = BuiltInDefaults.openAIModel) -> LLMCompletionRequest {
    LLMCompletionRequest(
        instruction: "system instruction",
        userText: "selected user text",
        model: model
    )
}

@Test func openAIRequestUsesRequiredHeadersAndBodyWithoutCombiningInstructionAndInput() async throws {
    let transport = StubOpenAIHTTPTransport(.response(
        status: 200,
        body: Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"first "}]},{"content":[{"type":"refusal"},{"type":"output_text","text":"second"}]}]}"#.utf8)
    ))
    let client = OpenAIResponsesClient(transport: transport)

    let output = try await client.complete(openAIRequest(), credential: " test-key ")
    let sent = try #require(await transport.requests.first)

    #expect(output == "first second")
    #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(sent.httpMethod == "POST")
    #expect(sent.timeoutInterval == 15)
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(sent.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == BuiltInDefaults.openAIModel)
    #expect(json["instructions"] as? String == "system instruction")
    #expect(json["input"] as? String == "selected user text")
    #expect(json["max_output_tokens"] as? Int == 4_096)
    #expect(json["store"] as? Bool == false)
    #expect(!(json["instructions"] as? String ?? "").contains("selected user text"))
}

@Test func openAIRequiresExactCompletedStatusAndRejectsMissingOrFutureStatuses() async {
    for status in [nil, "queued", "in_progress", "incomplete", "failed", "cancelled", "future_status"] {
        let body: Data
        if let status {
            body = Data("{\"status\":\"\(status)\",\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"output\"}]}]}".utf8)
        } else {
            body = Data(#"{"status":null,"output":[{"content":[{"type":"output_text","text":"output"}]}]}"#.utf8)
        }
        let client = OpenAIResponsesClient(transport: StubOpenAIHTTPTransport(.response(status: 200, body: body)))

        await #expect(throws: EnLLMError.providerIncompleteResponse(.openAI)) {
            try await client.complete(openAIRequest(), credential: "key")
        }
    }
}

@Test func openAIScansAllOutputTextBlocksAndRejectsMalformedOrEmptyCompletedResponses() async throws {
    let multiBlockBody = Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":" first"},{"type":"output_audio"}]},{"content":[{"type":"output_text","text":"\nsecond "}]},{"content":[{"type":"reasoning","text":"ignored"},{"type":"output_text","text":"third"}]}]}"#.utf8)
    let client = OpenAIResponsesClient(transport: StubOpenAIHTTPTransport(.response(status: 200, body: multiBlockBody)))
    #expect(try await client.complete(openAIRequest(), credential: "key") == " first\nsecond third")

    let emptyClient = OpenAIResponsesClient(transport: StubOpenAIHTTPTransport(.response(
        status: 200,
        body: Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"  \n "}]}]}"#.utf8)
    )))
    await #expect(throws: EnLLMError.emptyOutput) {
        try await emptyClient.complete(openAIRequest(), credential: "key")
    }

    for body in [
        Data(#"{"status":"completed"}"#.utf8),
        Data(#"{"status":"completed","output":[{"content":[{"type":"output_text"}]}]}"#.utf8),
        Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":null}]}]}"#.utf8),
        Data("secret-key private selected text".utf8)
    ] {
        let malformedClient = OpenAIResponsesClient(transport: StubOpenAIHTTPTransport(.response(status: 200, body: body)))
        await #expect(throws: EnLLMError.providerFailure(.openAI)) {
            try await malformedClient.complete(openAIRequest(), credential: "secret-key")
        }
    }
}

@Test func openAIMapsHTTPFailuresWithoutExposingRawBodies() async {
    let cases: [(Int, EnLLMError)] = [
        (401, .providerAuthenticationFailed(.openAI)),
        (403, .providerAuthenticationFailed(.openAI)),
        (408, .providerTimeout(.openAI)),
        (429, .providerRateLimited(.openAI)),
        (500, .providerFailure(.openAI))
    ]

    for (status, expected) in cases {
        let client = OpenAIResponsesClient(transport: StubOpenAIHTTPTransport(.response(
            status: status,
            body: Data(#"{"error":{"message":"secret-key private selected text"}}"#.utf8)
        )))
        do {
            _ = try await client.complete(openAIRequest(), credential: "secret-key")
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

@Test func openAIMapsTimeoutNetworkAndCancellationAndRejectsBlankCredentialBeforeTransport() async {
    let timeoutClient = OpenAIResponsesClient(
        transport: StubOpenAIHTTPTransport(.urlError(.timedOut))
    )
    await #expect(throws: EnLLMError.providerTimeout(.openAI)) {
        try await timeoutClient.complete(openAIRequest(), credential: "key")
    }

    let networkClient = OpenAIResponsesClient(
        transport: StubOpenAIHTTPTransport(.urlError(.notConnectedToInternet))
    )
    await #expect(throws: EnLLMError.providerNetworkFailure(.openAI)) {
        try await networkClient.complete(openAIRequest(), credential: "key")
    }

    let cancellationTransport = StubOpenAIHTTPTransport(.suspend)
    let cancellationClient = OpenAIResponsesClient(transport: cancellationTransport)
    let task = Task {
        try await cancellationClient.complete(openAIRequest(), credential: "key")
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

    let blankCredentialTransport = StubOpenAIHTTPTransport(.response(
        status: 200,
        body: Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"OK"}]}]}"#.utf8)
    ))
    let blankCredentialClient = OpenAIResponsesClient(transport: blankCredentialTransport)
    await #expect(throws: EnLLMError.providerCredentialMissing(.openAI)) {
        try await blankCredentialClient.complete(openAIRequest(), credential: " \n ")
    }
    #expect(await blankCredentialTransport.requests.isEmpty)
}
