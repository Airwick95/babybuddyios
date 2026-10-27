import Foundation

enum ForecastAPIError: Error, Equatable {
    case consent, configuration, insufficient, transport, http(Int), oversized, invalidResponse
}

/// Deliberately restricted payload: no child IDs, names, birth dates, notes, record timestamps,
/// photos, server URL or Baby Buddy credentials. Intervals are rounded to whole minutes.
struct ForecastAPIInput: Encodable, Sendable {
    struct Candidate: Encodable, Sendable {
        let kind: ForecastKind
        let intervals_minutes: [Int]
        let days: Int
        let elapsed_minutes: Int
        let minimum_minutes: Int
        let maximum_minutes: Int
    }
    let schema_version = 1
    let candidates: [Candidate]

    init(snapshot: ForecastSnapshot) {
        candidates = snapshot.ready.compactMap { estimate in
            let minimum = max(0, Int(ceil(estimate.window.start.timeIntervalSince(snapshot.generatedAt) / 60)))
            let maximum = Int(floor(estimate.window.end.timeIntervalSince(snapshot.generatedAt) / 60))
            guard maximum - minimum >= 5 else { return nil }
            return Candidate(kind: estimate.kind,
                             intervals_minutes: estimate.observations.map { Int(($0 / 60).rounded()) },
                             days: estimate.distinctDays,
                             elapsed_minutes: max(0, Int(snapshot.generatedAt.timeIntervalSince(estimate.anchor) / 60)),
                             minimum_minutes: minimum, maximum_minutes: maximum)
        }
    }
}

struct ForecastAPIResult: Equatable, Sendable {
    struct Prediction: Decodable, Equatable, Identifiable, Sendable {
        let kind: ForecastKind
        let start_minutes: Int
        let end_minutes: Int
        var id: ForecastKind { kind }
    }
    let predictions: [Prediction]
    let generatedAt: Date
    let expiresAt: Date
    func window(_ prediction: Prediction) -> ForecastWindow {
        ForecastWindow(start: generatedAt.addingTimeInterval(Double(prediction.start_minutes) * 60),
                       end: generatedAt.addingTimeInterval(Double(prediction.end_minutes) * 60))
    }
}

protocol ForecastAPITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class ForecastRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A dedicated ephemeral HTTPS session. No shared cookies, credentials, cache, redirects or logs.
struct ForecastURLTransport: ForecastAPITransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 40
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: ForecastRedirectBlocker())
        guard let response = response as? HTTPURLResponse else { throw ForecastAPIError.transport }
        guard response.expectedContentLength <= 65536 else { throw ForecastAPIError.oversized }
        guard (200..<300).contains(response.statusCode) else { return (Data(), response) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65536 else { throw ForecastAPIError.oversized }
            data.append(byte)
        }
        return (data, response)
    }
}

struct ForecastAPIClient: Sendable {
    var transport: any ForecastAPITransport = ForecastURLTransport()
    var clock: @Sendable () -> Date = { .now }

    func request(snapshot: ForecastSnapshot, configuration: ForecastAPIConfiguration, consent: Bool) throws -> URLRequest {
        guard consent else { throw ForecastAPIError.consent }
        guard configuration.isValid, let url = configuration.url else { throw ForecastAPIError.configuration }
        guard let freshUntil = snapshot.freshUntil, clock() < freshUntil,
              clock().timeIntervalSince(snapshot.generatedAt) >= -1,
              clock().timeIntervalSince(snapshot.generatedAt) < 60 else { throw ForecastAPIError.insufficient }
        let input = ForecastAPIInput(snapshot: snapshot)
        guard !input.candidates.isEmpty else { throw ForecastAPIError.insufficient }
        let featureData = try JSONEncoder().encode(input)
        let instructions = """
        Compare patterns in the supplied logged-activity intervals. Return only a JSON object:
        {"predictions":[{"kind":"feeding","start_minutes":10,"end_minutes":25}]}.
        Use only candidate kinds. Times are integer minutes from now, not clock times.
        For each prediction, start_minutes must be at least minimum_minutes, end_minutes at most
        maximum_minutes, and end_minutes-start_minutes at least 5. Omit a kind if uncertain.
        You may return {"predictions":[]}. Never invent a new activity, widen the supplied window,
        diagnose a condition, recommend delaying care, or emit advice or any additional fields.
        These are experimental descriptive estimates, not prescribed schedules or probabilities.
        """
        let body: [String: Any] = [
            "model": configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [["role": "system", "content": instructions],
                         ["role": "user", "content": String(decoding: featureData, as: UTF8.self)]],
            "response_format": ["type": "json_object"], "store": false,
            configuration.tokenLimit.rawValue: 1024,
        ]
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.apiKey.isEmpty { request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    func predict(snapshot: ForecastSnapshot, configuration: ForecastAPIConfiguration, consent: Bool) async throws -> ForecastAPIResult {
        let request = try request(snapshot: snapshot, configuration: configuration, consent: consent)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ForecastAPIError { throw error }
        catch { throw ForecastAPIError.transport }
        try Task.checkCancellation()
        guard let freshUntil = snapshot.freshUntil, clock() < freshUntil else { throw ForecastAPIError.insufficient }
        guard (200..<300).contains(response.statusCode) else { throw ForecastAPIError.http(response.statusCode) }
        let result = try parse(data, snapshot: snapshot)
        guard clock() < result.expiresAt else { throw ForecastAPIError.insufficient }
        return result
    }

    func parse(_ data: Data, snapshot: ForecastSnapshot) throws -> ForecastAPIResult {
        guard data.count <= 65536 else { throw ForecastAPIError.oversized }
        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String?; let refusal: String? }
                let message: Message
                let finish_reason: String
            }
            let choices: [Choice]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.choices.count == 1, let choice = envelope.choices.first,
              choice.finish_reason == "stop", choice.message.refusal == nil,
              let content = choice.message.content, let json = content.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              Set(object.keys) == ["predictions"], let objects = object["predictions"] as? [[String: Any]],
              objects.count <= 4,
              objects.allSatisfy({ Set($0.keys) == ["kind", "start_minutes", "end_minutes"] }) else {
            throw ForecastAPIError.invalidResponse
        }
        struct Payload: Decodable { let predictions: [ForecastAPIResult.Prediction] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json) else { throw ForecastAPIError.invalidResponse }
        let input = ForecastAPIInput(snapshot: snapshot)
        var seen: Set<ForecastKind> = []
        for value in payload.predictions {
            guard let candidate = input.candidates.first(where: { $0.kind == value.kind }),
                  seen.insert(value.kind).inserted, value.start_minutes >= candidate.minimum_minutes,
                  value.end_minutes <= candidate.maximum_minutes, value.start_minutes >= 0,
                  value.end_minutes >= value.start_minutes,
                  value.end_minutes - value.start_minutes >= 5 else { throw ForecastAPIError.invalidResponse }
        }
        let end = payload.predictions.map { snapshot.generatedAt.addingTimeInterval(Double($0.end_minutes) * 60) }.min()
        return ForecastAPIResult(predictions: payload.predictions, generatedAt: snapshot.generatedAt,
                                 expiresAt: min(snapshot.generatedAt.addingTimeInterval(5 * 60),
                                                snapshot.freshUntil ?? snapshot.generatedAt, end ?? .distantFuture))
    }
}
