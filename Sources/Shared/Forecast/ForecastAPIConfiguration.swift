import Foundation

struct ForecastAPIConfiguration: Codable, Equatable, Sendable {
    enum TokenLimit: String, Codable, CaseIterable, Sendable {
        case completion = "max_completion_tokens", legacy = "max_tokens"
    }
    var endpoint = ""
    var model = ""
    var apiKey = ""
    var tokenLimit: TokenLimit = .completion

    var url: URL? {
        guard let components = URLComponents(string: endpoint), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        return components.url
    }
    var isValid: Bool {
        url != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.count <= 128
            && apiKey.count <= 4096 && !apiKey.contains(where: { $0.isNewline || $0 == "\0" })
    }
}
