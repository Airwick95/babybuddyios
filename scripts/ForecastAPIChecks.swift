import Foundation

private struct FakeTransport: ForecastAPITransport {
    let data: Data
    let status: Int
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private actor PausedTransport: ForecastAPITransport {
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

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Date) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

@main
struct ForecastAPIChecks {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { count += 1; if !value { fatalError(message) } }
        let now = Date(timeIntervalSince1970: 1800000000)
        let estimate = ForecastEstimate(kind: .feeding,
            window: ForecastWindow(start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200)),
            anchor: now.addingTimeInterval(-3600), observations: [7200, 7800, 8400, 9000], distinctDays: 4, medianSeconds: 8100)
        let snapshot = ForecastSnapshot(generatedAt: now, cues: [ForecastCue(kind: .feeding, state: .ready, estimate: estimate)],
                                        freshUntil: now.addingTimeInterval(7200))
        var configuration = ForecastAPIConfiguration(endpoint: "https://api.example.com/v1/chat/completions", model: "test-model", apiKey: "test-credential")
        let client = ForecastAPIClient(clock: { now })
        func envelope(_ content: String, finish: String = "stop") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]]])
        }
        let request = try client.request(snapshot: snapshot, configuration: configuration, consent: true)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        check(request.url?.host == "api.example.com", "Chosen endpoint")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-credential", "Own credentials")
        check(body["store"] as? Bool == false, "Request no storage")
        check(body["max_completion_tokens"] as? Int == 1024, "Token cap")
        let messages = body["messages"] as! [[String: String]]
        let features = try JSONSerialization.jsonObject(with: Data(messages.last!["content"]!.utf8)) as! [String: Any]
        check(Set(features.keys) == ["schema_version", "candidates"], "Minimal top-level payload")
        let candidate = (features["candidates"] as! [[String: Any]]).first!
        check(Set(candidate.keys) == ["kind", "intervals_minutes", "days", "elapsed_minutes", "minimum_minutes", "maximum_minutes"], "No identifiers, dates or free text")
        check(candidate["intervals_minutes"] as? [Int] == [120, 130, 140, 150], "Rounded interval units")
        do {
            _ = try client.request(snapshot: snapshot, configuration: configuration, consent: false)
            fatalError("Consent bypass")
        } catch { check(error as? ForecastAPIError == .consent, "Consent gate") }
        for endpoint in ["http://api.example.com/", "https://user:secret@api.example.com/", "https://api.example.com/?key=x", "https://api.example.com/#x", "file:///tmp/model"] {
            var changed = configuration
            changed.endpoint = endpoint
            check(!changed.isValid, "Reject insecure/credential-bearing URL")
        }
        let valid = try envelope(#"{"predictions":[{"kind":"feeding","start_minutes":70,"end_minutes":90}]}"#)
        let result = try await ForecastAPIClient(transport: FakeTransport(data: valid, status: 200), clock: { now })
            .predict(snapshot: snapshot, configuration: configuration, consent: true)
        check(result.predictions.count == 1, "Mock end-to-end completion")
        check(result.window(result.predictions[0]).start == now.addingTimeInterval(4200), "Minutes convert to dates")
        check(result.expiresAt == now.addingTimeInterval(300), "Five-minute lifetime")
        var expiring = snapshot
        expiring.freshUntil = now.addingTimeInterval(30)
        check(try client.parse(valid, snapshot: expiring).expiresAt == now.addingTimeInterval(30), "Freshness cutoff")
        check(try client.parse(envelope(#"{"predictions":[]}"#), snapshot: snapshot).predictions.isEmpty, "Model abstention")
        for status in [302, 401, 429, 500] {
            do {
                _ = try await ForecastAPIClient(transport: FakeTransport(data: Data(), status: status), clock: { now })
                    .predict(snapshot: snapshot, configuration: configuration, consent: true)
                fatalError("HTTP failure accepted")
            } catch { check(error as? ForecastAPIError == .http(status), "HTTP error mapping") }
        }
        for content in [
            #"{"predictions":[{"kind":"feeding","start_minutes":-1,"end_minutes":90}]}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":70,"end_minutes":121}]}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":70,"end_minutes":71}]}"#,
            #"{"predictions":[{"kind":"wake","start_minutes":70,"end_minutes":90}]}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":true,"end_minutes":90}]}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":70.5,"end_minutes":90}]}"#,
            #"{"predictions":[],"advice":"wait"}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":70,"end_minutes":90,"advice":"wait"}]}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":70,"end_minutes":90},{"kind":"feeding","start_minutes":70,"end_minutes":90}]}"#,
            #"{"predictions":[{"kind":"feeding","start_minutes":9223372036854775807,"end_minutes":90}]}"#,
            "not JSON", "```json\n{\"predictions\":[]}\n```",
        ] {
            do { _ = try client.parse(envelope(content), snapshot: snapshot); fatalError("Invalid output accepted") }
            catch { check(error as? ForecastAPIError == .invalidResponse, "Reject invalid model output") }
        }
        do { _ = try client.parse(envelope(#"{"predictions":[]}"#, finish: "length"), snapshot: snapshot); fatalError("Truncation accepted") }
        catch { check(error as? ForecastAPIError == .invalidResponse, "Reject truncation") }
        do { _ = try client.parse(Data(repeating: 65, count: 65537), snapshot: snapshot); fatalError("Oversize accepted") }
        catch { check(error as? ForecastAPIError == .oversized, "Response size limit") }
        let later = now.addingTimeInterval(70)
        do { _ = try ForecastAPIClient(clock: { later }).request(snapshot: snapshot, configuration: configuration, consent: true); fatalError("Stale snapshot accepted") }
        catch { check(error as? ForecastAPIError == .insufficient, "Old snapshot gate") }
        configuration.tokenLimit = .legacy
        let legacy = try client.request(snapshot: snapshot, configuration: configuration, consent: true)
        let legacyBody = try JSONSerialization.jsonObject(with: legacy.httpBody!) as! [String: Any]
        check(legacyBody["max_tokens"] as? Int == 1024 && legacyBody["max_completion_tokens"] == nil, "Compatible legacy token parameter")
        let paused = PausedTransport(data: valid)
        let cancellationClient = ForecastAPIClient(transport: paused, clock: { now })
        let cancelled = Task { try await cancellationClient.predict(snapshot: snapshot, configuration: configuration, consent: true) }
        await paused.waitUntilStarted()
        cancelled.cancel()
        await paused.complete()
        do { _ = try await cancelled.value; fatalError("Cancelled response returned a prediction") }
        catch { check(error is CancellationError, "In-flight cancellation") }
        let clock = TestClock(now)
        let delayed = PausedTransport(data: valid)
        let delayedClient = ForecastAPIClient(transport: delayed, clock: { clock.read() })
        let delayedTask = Task { try await delayedClient.predict(snapshot: snapshot, configuration: configuration, consent: true) }
        await delayed.waitUntilStarted()
        clock.set(now.addingTimeInterval(301))
        await delayed.complete()
        do { _ = try await delayedTask.value; fatalError("Expired response returned a prediction") }
        catch { check(error as? ForecastAPIError == .insufficient, "Response expiry while request was in flight") }
        print("Forecast API: \(count) checks passed using fake transport; no live request or real key used")
    }
}
