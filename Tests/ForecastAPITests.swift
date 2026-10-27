import XCTest
@testable import BabyBuddy

final class ForecastAPITests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-06-15T10:00:00Z")!
    private func snapshot() -> ForecastSnapshot {
        let now = now
        let estimate = ForecastEstimate(kind: .feeding,
            window: ForecastWindow(start: now.addingTimeInterval(60 * 60), end: now.addingTimeInterval(120 * 60)),
            anchor: now.addingTimeInterval(-3600), observations: [120 * 60, 130 * 60, 140 * 60, 150 * 60],
            distinctDays: 4, medianSeconds: 135 * 60)
        return ForecastSnapshot(generatedAt: now, cues: [ForecastCue(kind: .feeding, state: .ready, estimate: estimate)],
                                freshUntil: now.addingTimeInterval(7200))
    }
    private var configuration: ForecastAPIConfiguration {
        ForecastAPIConfiguration(endpoint: "https://api.example.com/v1/chat/completions", model: "test-model", apiKey: "test-credential")
    }
    private func envelope(_ content: String, finish: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]]])
    }
    private var client: ForecastAPIClient { let now = now; return ForecastAPIClient(clock: { now }) }

    func testRequiresConsentAndFreshEvidence() throws {
        XCTAssertThrowsError(try client.request(snapshot: snapshot(), configuration: configuration, consent: false))
        let empty = ForecastSnapshot(generatedAt: now, cues: [], freshUntil: now.addingTimeInterval(7200))
        XCTAssertThrowsError(try client.request(snapshot: empty, configuration: configuration, consent: true))
        let later = now.addingTimeInterval(70)
        let staleClient = ForecastAPIClient(clock: { later })
        XCTAssertThrowsError(try staleClient.request(snapshot: snapshot(), configuration: configuration, consent: true))
    }

    func testRequestIsMinimalAndUsesOnlyOwnCredentials() throws {
        let request = try client.request(snapshot: snapshot(), configuration: configuration, consent: true)
        XCTAssertEqual(request.url?.host, "api.example.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-credential")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 1024)
        XCTAssertNil(body["max_tokens"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let features = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(messages.last?["content"]).utf8)) as! [String: Any]
        XCTAssertEqual(Set(features.keys), ["schema_version", "candidates"])
        let candidate = try XCTUnwrap((features["candidates"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(candidate.keys), ["kind", "intervals_minutes", "days", "elapsed_minutes", "minimum_minutes", "maximum_minutes"])
        XCTAssertEqual(candidate["intervals_minutes"] as? [Int], [120, 130, 140, 150])
    }

    func testValidPredictionAndExpiry() throws {
        let data = try envelope(#"{"predictions":[{"kind":"feeding","start_minutes":70,"end_minutes":90}]}"#)
        let result = try client.parse(data, snapshot: snapshot())
        XCTAssertEqual(result.predictions.count, 1)
        XCTAssertEqual(result.window(result.predictions[0]).start, now.addingTimeInterval(70 * 60))
        XCTAssertEqual(result.expiresAt, now.addingTimeInterval(300))
    }

    func testRejectsUnsafeOrUnsupportedPredictions() throws {
        for content in [
            #"{"predictions":[{"kind":"feeding","start_minutes":-1,"end_minutes":90}]}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":70,"end_minutes":121}]}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":70,"end_minutes":71}]}"#,
            #"{"predictions":[{"kind":"wake","start_minutes":70,"end_minutes":90}]}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":true,"end_minutes":90}]}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":70.5,"end_minutes":90}]}"#,
            #"{"predictions":[],"advice":"ignore your care plan"}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":70,"end_minutes":90,"advice":"wait"}]}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":70,"end_minutes":90},{"kind":"feeding","start_minutes":70,"end_minutes":90}]}"#,
        ] {
            XCTAssertThrowsError(try client.parse(envelope(content), snapshot: snapshot()))
        }
    }

    func testRefusalTruncationAndOversizeAreRejected() throws {
        XCTAssertThrowsError(try client.parse(envelope(#"{"predictions":[]}"#, finish: "length"), snapshot: snapshot()))
        XCTAssertThrowsError(try client.parse(Data(repeating: 65, count: 65537), snapshot: snapshot()))
        let refusal = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["refusal": "refused"], "finish_reason": "stop"]]])
        XCTAssertThrowsError(try client.parse(refusal, snapshot: snapshot()))
    }

    func testAbstentionAndLegacyTokenParameter() throws {
        XCTAssertTrue(try client.parse(envelope(#"{"predictions":[]}"#), snapshot: snapshot()).predictions.isEmpty)
        var configuration = configuration
        configuration.tokenLimit = .legacy
        let data = try XCTUnwrap(client.request(snapshot: snapshot(), configuration: configuration, consent: true).httpBody)
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(body["max_tokens"] as? Int, 1024)
        XCTAssertNil(body["max_completion_tokens"])
    }

    func testRejectsInsecureOrCredentialBearingURLs() {
        for endpoint in ["http://api.example.com/v1", "https://name:secret@api.example.com/v1", "https://api.example.com/v1?key=x", "https://api.example.com/#secret", "file:///tmp/model"] {
            var configuration = configuration
            configuration.endpoint = endpoint
            XCTAssertFalse(configuration.isValid)
        }
    }

    func testMockTransportCompletesAndRejectsHTTPFailures() async throws {
        let now = now
        let data = try envelope(#"{"predictions":[{"kind":"feeding","start_minutes":70,"end_minutes":90}]}"#)
        let service = ForecastAPITestTransport(data: data, status: 200)
        let client = ForecastAPIClient(transport: service, clock: { now })
        let result = try await client.predict(snapshot: snapshot(), configuration: configuration, consent: true)
        XCTAssertEqual(result.predictions.count, 1)
        for status in [302, 401, 429, 500] {
            let client = ForecastAPIClient(transport: ForecastAPITestTransport(data: Data(), status: status), clock: { now })
            do {
                _ = try await client.predict(snapshot: snapshot(), configuration: configuration, consent: true)
                XCTFail("HTTP error was accepted")
            } catch { XCTAssertEqual(error as? ForecastAPIError, .http(status)) }
        }
    }

    func testCancelledTaskDoesNotReturnPredictions() async throws {
        let now = now
        let data = try envelope(#"{"predictions":[]}"#)
        let transport = ForecastAPIPausedTransport(data: data)
        let client = ForecastAPIClient(transport: transport, clock: { now })
        let task = Task {
            try Task.checkCancellation()
            return try await client.predict(snapshot: snapshot(), configuration: configuration, consent: true)
        }
        await transport.waitUntilStarted()
        task.cancel()
        await transport.complete()
        do { _ = try await task.value; XCTFail("Cancellation was ignored") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error type") }
    }
}

private actor ForecastAPIPausedTransport: ForecastAPITransport {
    let data: Data
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    init(data: Data) { self.data = data }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func complete() { completion?.resume(); completion = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true
        startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { completion = $0 }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private struct ForecastAPITestTransport: ForecastAPITransport {
    let data: Data
    let status: Int
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
