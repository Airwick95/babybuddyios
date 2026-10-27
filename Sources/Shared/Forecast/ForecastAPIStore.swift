import Foundation
import Security

/// Separate app-only Keychain item. Never reuses Baby Buddy server credentials or access group.
enum ForecastAPIStore {
    static let consentKey = "forecastAPIConsent"
    private static let service = "com.kurtisguy.BabyBuddy.forecast-api"
    private static let account = "configuration"
    private static let accessGroup = "547DWTTFY6.com.kurtisguy.BabyBuddy.Forecast"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: accessGroup,
         kSecAttrSynchronizable as String: false]
    }

    static func load() -> ForecastAPIConfiguration? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ForecastAPIConfiguration.self, from: data)
    }

    @discardableResult
    static func save(_ configuration: ForecastAPIConfiguration) -> Bool {
        guard configuration.isValid, let data = try? JSONEncoder().encode(configuration) else { return false }
        let values: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        var result = status
        if status == errSecItemNotFound { result = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
        guard result == errSecSuccess else { return false }
        // Changing a destination, model or key requires renewed consent before sending data.
        UserDefaults.standard.set(false, forKey: consentKey)
        return true
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: consentKey)
    }
}
