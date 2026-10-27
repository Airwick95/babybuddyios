import SwiftUI

struct ForecastAPISettingsView: View {
    @State private var configuration = ForecastAPIConfiguration()
    @State private var saved = false
    @State private var saveFailed = false
    @State private var hasConfiguration = false
    @AppStorage(ForecastAPIStore.consentKey) private var consent = false

    var body: some View {
        Form {
            Section {
                TextField(forecastAPIText("HTTPS endpoint"), text: $configuration.endpoint)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("forecast-api-endpoint")
                TextField(forecastAPIText("Model"), text: $configuration.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("forecast-api-model")
                SecureField(forecastAPIText("API key, if required"), text: $configuration.apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("forecast-api-key")
                Picker(forecastAPIText("Token limit parameter"), selection: $configuration.tokenLimit) {
                    ForEach(ForecastAPIConfiguration.TokenLimit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Button(forecastAPIText("Save API configuration")) {
                    configuration.endpoint = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    configuration.model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
                    configuration.apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved = ForecastAPIStore.save(configuration)
                    saveFailed = !saved
                    if saved { hasConfiguration = true; consent = false }
                }
                .disabled(!configuration.isValid)
                if saved { Text(forecastAPIText("Saved on this device. Enable data sharing below to use it.")) }
                if saveFailed { Text(forecastAPIText("The configuration could not be saved in Keychain.")) }
            } header: {
                Text(forecastAPIText("Your service"))
            } footer: {
                Text(forecastAPIText("Enter a complete OpenAI-compatible Chat Completions HTTPS URL and a model supported by your service. JSON-object responses are required. Use max_tokens only if your service requires that older field. No provider is selected automatically."))
            }
            Section {
                Toggle(forecastAPIText("Allow sharing activity patterns with this service"), isOn: $consent)
                    .disabled(!hasConfiguration)
                    .accessibilityIdentifier("forecast-api-consent")
                Text(forecastAPIText("Only rounded intervals, elapsed minutes and calculated window limits are sent. Names, birth dates, notes, photos, child IDs, exact event dates and Baby Buddy credentials are excluded. These patterns can still reveal health information."))
                Text(forecastAPIText("Requests run only when you tap Request API estimate on Home. Your provider may charge fees and retain data under its own policy. A request to disable storage is sent, but the app cannot guarantee the provider's retention behavior."))
            } header: {
                Text(forecastAPIText("Data sharing"))
            }
            Section {
                Text(forecastAPIText("AI may produce a different estimate, but has not been shown to be more accurate. It cannot bypass missing-data checks or extend the calculated window. API estimates expire after five minutes or a data change."))
                Button(forecastAPIText("Remove API configuration"), role: .destructive) {
                    ForecastAPIStore.clear()
                    configuration = ForecastAPIConfiguration()
                    hasConfiguration = false
                    saved = false
                    consent = false
                }
            }
        }
        .navigationTitle(forecastAPIText("Own API"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let stored = ForecastAPIStore.load() { configuration = stored; hasConfiguration = true }
        }
        .onChange(of: configuration) { _, _ in saved = false; saveFailed = false }
    }
}
