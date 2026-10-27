import Foundation

func forecastAPIText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "ForecastAPI") }

extension ForecastAPIError {
    var message: String {
        switch self {
        case .consent: return forecastAPIText("Enable data sharing in Own API settings before requesting an estimate.")
        case .configuration: return forecastAPIText("Check your HTTPS endpoint, model and saved API configuration.")
        case .insufficient: return forecastAPIText("The local evidence is not sufficient for an API estimate.")
        case .transport: return forecastAPIText("The service could not be reached. Your calculated estimates still work.")
        case .http(let status): return "\(forecastAPIText("The service rejected the request.")) (\(status))"
        case .oversized: return forecastAPIText("The service returned too much data. The response was discarded.")
        case .invalidResponse: return forecastAPIText("The response did not meet the prediction limits and was discarded.")
        }
    }
}
