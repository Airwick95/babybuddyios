import SwiftUI

struct ForecastAPICard: View {
    let entities: [LocalEntity]
    let childID: Int
    let lastSync: Date?
    @Environment(\.scenePhase) private var phase
    @AppStorage(ForecastPreferences.enabledKey, store: SharedDefaults.suite) private var enabled = false
    @AppStorage(ForecastAPIStore.consentKey) private var consent = false
    @State private var result: ForecastAPIResult?
    @State private var failure: ForecastAPIError?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var service = ""

    var body: some View {
        if enabled {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                BBCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(forecastAPIText("API comparison"), systemImage: "sparkles").font(.headline)
                        if !service.isEmpty { Text(service).font(.caption).foregroundStyle(.secondary) }
                        NavigationLink(forecastAPIText("Configure own API")) { ForecastAPISettingsView() }
                            .accessibilityIdentifier("forecast-api-settings")
                        if consent {
                            Button(forecastAPIText("Request API estimate")) { request() }
                                .disabled(busy)
                                .accessibilityIdentifier("forecast-api-request")
                        } else {
                            Text(forecastAPIText("API sharing is off. Calculated estimates work without it."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if busy { ProgressView(forecastAPIText("Requesting estimate…")) }
                        if let failure { Text(failure.message).font(.caption).foregroundStyle(.secondary) }
                        if let result, timeline.date < result.expiresAt {
                            if result.predictions.isEmpty {
                                Text(forecastAPIText("The model did not provide an estimate."))
                            }
                            ForEach(result.predictions) { prediction in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(prediction.kind.title).font(.subheadline.weight(.semibold))
                                    Text(ForecastFormat.window(result.window(prediction)))
                                }
                                .accessibilityElement(children: .combine)
                            }
                        } else if result != nil {
                            Text(forecastAPIText("The API estimate has expired. Request a new one if needed."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(forecastAPIText("Experimental model estimate, not a care schedule. Follow your baby's cues and your care plan."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { reset(); service = ForecastAPIStore.load()?.url?.host ?? "" }
            .onChange(of: relevantRecords) { _, _ in reset() }
            .onChange(of: timerFingerprint) { _, _ in reset() }
            .onChange(of: lastSync) { _, _ in reset() }
            .onChange(of: consent) { _, _ in reset() }
            .onChange(of: phase) { _, phase in if phase != .active { reset() } }
            .onDisappear { reset() }
        }
    }

    private var relevantRecords: [ForecastRecord] { ForecastCache.records(entities).filter { $0.childID == childID } }
    private var timerFingerprint: [String] {
        ForecastCache.timers(entities).filter { $0.childID == childID }.map {
            "\($0.kind?.rawValue ?? "unknown")|\($0.start.timeIntervalSince1970)|\($0.stopped)"
        }
    }
    private func reset() { task?.cancel(); task = nil; result = nil; failure = nil; busy = false }

    private func request() {
        reset()
        guard let configuration = ForecastAPIStore.load() else { failure = .configuration; return }
        let snapshot = ForecastCache.snapshot(entities, childID: childID, lastSync: lastSync)
        let allowed = consent
        busy = true
        task = Task { @MainActor in
            do {
                let value = try await ForecastAPIClient().predict(snapshot: snapshot, configuration: configuration, consent: allowed)
                guard !Task.isCancelled else { return }
                result = value
                busy = false
            } catch {
                guard !Task.isCancelled else { return }
                failure = error as? ForecastAPIError ?? .transport
                busy = false
            }
        }
    }
}
