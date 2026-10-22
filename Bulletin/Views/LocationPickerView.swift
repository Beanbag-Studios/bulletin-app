import SwiftUI
import MapKit
import Combine

/// Wraps `MKLocalSearchCompleter` so the search field can show Apple Maps
/// suggestions while the user types.
@MainActor
final class AddressCompleter: NSObject, ObservableObject {
    @Published private(set) var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, around region: MKCoordinateRegion?) {
        if let region { completer.region = region }
        completer.queryFragment = query
    }

    func clear() {
        completer.queryFragment = ""
        results = []
    }
}

extension AddressCompleter: @preconcurrency MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

struct LocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loc = LocationManager.shared
    @StateObject private var completer = AddressCompleter()

    @State private var query = ""
    @State private var selectedItem: MKMapItem?
    @State private var nameField = ""
    @State private var radius: Double = 20
    @State private var isResolving = false
    @State private var didAutofill = false
    @State private var errorText: String?
    @FocusState private var queryFocused: Bool

    var onSave: (SavedLocation) -> Void

    var body: some View {
        NavigationStack {
            Form {
                currentLocationSection
                searchSection
                if let selectedItem { detailsSection(for: selectedItem) }
                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isResolving || (selectedItem == nil && query.trimmingCharacters(in: .whitespaces).count < 3))
                }
            }
            .task {
                startLocating()
                if let existing = loc.currentLocation {
                    await autofill(from: existing)
                }
            }
            .onChange(of: loc.authorization) { _, status in
                if status == .authorizedWhenInUse || status == .authorizedAlways {
                    loc.requestCurrentLocation()
                }
            }
            .onChange(of: loc.currentLocation) { _, location in
                guard let location, !didAutofill, selectedItem == nil else { return }
                Task { await autofill(from: location) }
            }
        }
    }

    // MARK: - Sections

    private var currentLocationSection: some View {
        Section {
            Button {
                Task { await useCurrentLocation() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(AppTheme.blueMatte)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use my current location")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(currentLocationSubtitle)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if isResolving {
                        ProgressView()
                    }
                }
            }
            .disabled(isResolving)
        }
    }

    private var searchSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search an address", text: $query)
                    .focused($queryFocused)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onChange(of: query) { _, value in
                        handleQueryChange(value)
                    }
                    .onSubmit {
                        Task { await resolveTypedAddress() }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        selectedItem = nil
                        completer.clear()
                        queryFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if selectedItem == nil, !completer.results.isEmpty {
                ForEach(completer.results.prefix(6), id: \.self) { completion in
                    Button {
                        Task { await choose(completion) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(completion.title)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.textPrimary)
                            if !completion.subtitle.isEmpty {
                                Text(completion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        } header: {
            Text("Search")
        } footer: {
            Text("Start typing and pick a suggestion from Apple Maps.")
        }
    }

    private func detailsSection(for item: MKMapItem) -> some View {
        Group {
            Section("Selected") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name ?? "Address")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(item.address?.fullAddress ?? query)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Details") {
                TextField("Name (e.g. Home)", text: $nameField)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Radius")
                        Spacer()
                        Text("\(Int(radius)) mi")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Radius", selection: $radius) {
                        ForEach([1, 5, 10, 20, 25, 50], id: \.self) { miles in
                            Text("\(miles) mi").tag(Double(miles))
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Text("Events further than \(Int(radius)) miles from this place won't appear in your feed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Location helpers

    private var currentLocationSubtitle: String {
        switch loc.authorization {
        case .denied, .restricted:
            return "Location is off — search for an address below"
        case .notDetermined:
            return "Tap to allow location access"
        default:
            if let current = loc.currentLocation {
                return "\(current.coordinate.latitude.formatted(.number.precision(.fractionLength(3)))), \(current.coordinate.longitude.formatted(.number.precision(.fractionLength(3))))"
            }
            return "Finding your location…"
        }
    }

    private func startLocating() {
        switch loc.authorization {
        case .notDetermined:
            loc.requestPermission()
        case .authorizedWhenInUse, .authorizedAlways:
            loc.requestCurrentLocation()
        default:
            break
        }
    }

    private func useCurrentLocation() async {
        switch loc.authorization {
        case .notDetermined:
            loc.requestPermission()
            return
        case .denied, .restricted:
            errorText = "Location access is off. Search for an address below, or enable it in Settings."
            return
        default:
            break
        }

        if loc.currentLocation == nil {
            loc.requestCurrentLocation()
            errorText = nil
            return
        }

        guard let location = loc.currentLocation else { return }
        await autofill(from: location, force: true)
    }

    private func autofill(from location: CLLocation, force: Bool = false) async {
        if !force, selectedItem != nil { return }

        isResolving = true
        defer { isResolving = false }

        guard let item = await loc.reverseGeocode(location) else {
            errorText = "Couldn't read your address. Search for it below."
            return
        }

        didAutofill = true
        errorText = nil
        select(item, suggestedName: item.name ?? "Home")
    }

    // MARK: - Search helpers

    private func handleQueryChange(_ value: String) {
        // Ignore the programmatic update that happens right after a selection.
        if let selectedItem,
           value == (selectedItem.address?.fullAddress ?? selectedItem.name ?? "") {
            return
        }

        if selectedItem != nil { selectedItem = nil }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            completer.clear()
            return
        }

        let anchor = loc.currentLocation
            ?? loc.selectedLocation.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let region = anchor.map {
            MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        completer.update(query: trimmed, around: region)
    }

    private func choose(_ completion: MKLocalSearchCompletion) async {
        isResolving = true
        defer { isResolving = false }

        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else {
            errorText = "Couldn't load that address. Try another suggestion."
            return
        }

        errorText = nil
        select(item, suggestedName: completion.title)
    }

    private func resolveTypedAddress() async {
        guard selectedItem == nil else { return }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return }

        isResolving = true
        defer { isResolving = false }

        guard let item = await loc.geocodeMapItem(trimmed) else {
            errorText = "Couldn't find that address. Try adding the city or ZIP code."
            return
        }

        errorText = nil
        select(item)
    }

    private func select(_ item: MKMapItem, suggestedName: String? = nil) {
        selectedItem = item
        completer.clear()
        queryFocused = false

        let address = item.address?.fullAddress ?? item.name ?? query
        if query != address { query = address }
        if nameField.trimmingCharacters(in: .whitespaces).isEmpty {
            nameField = suggestedName ?? item.name ?? "Saved location"
        }
    }

    // MARK: - Save

    private func save() async {
        if selectedItem == nil {
            await resolveTypedAddress()
        }

        guard let item = selectedItem else {
            if errorText == nil {
                errorText = "Pick a suggestion or search for the address first."
            }
            return
        }

        let coordinate = item.location.coordinate
        let address = item.address?.fullAddress ?? query
        let name = nameField.trimmingCharacters(in: .whitespaces)

        onSave(
            SavedLocation(
                name: name.isEmpty ? (item.name ?? "Saved location") : name,
                address: address,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radiusMiles: radius,
                isHome: loc.savedLocations.isEmpty
            )
        )
        dismiss()
    }
}
