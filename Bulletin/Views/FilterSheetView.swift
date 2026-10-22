import SwiftUI

struct FilterSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var options: FilterOptions
    @StateObject private var loc = LocationManager.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("From", selection: $options.locationSource) {
                        ForEach(FilterOptions.LocationSource.allCases) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    if options.locationSource == .savedLocation {
                        if loc.savedLocations.isEmpty {
                            Text("No saved locations yet. Add one from My Location ▾ on the feed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Saved location", selection: $options.selectedSavedLocationId) {
                                ForEach(loc.savedLocations) { saved in
                                    Text(saved.name).tag(saved.id as UUID?)
                                }
                            }
                        }
                    }

                    if options.locationSource != .anywhere {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Distance")
                                Spacer()
                                Text("\(Int(options.radiusMiles)) mi")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $options.radiusMiles, in: 1...50, step: 1)
                            HStack {
                                Text("1 mi")
                                Spacer()
                                Text("50 mi")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text("Distance only applies to events that have a mapped address.")
                }

                Section("Event Type") {
                    Picker("Type", selection: $options.eventType) {
                        Text("Any type").tag(nil as Event.Category?)
                        ForEach(Event.Category.allCases.filter { $0 != .all }) { category in
                            Text(category.rawValue).tag(category as Event.Category?)
                        }
                    }
                }

                Section("Entry Fee") {
                    Picker("Fee", selection: $options.feeFilter) {
                        ForEach(FilterOptions.FeeFilter.allCases) { fee in
                            Text(fee.rawValue).tag(fee)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        options = FilterOptions()
                    }
                    .disabled(options.activeCount == 0)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { dismiss() }
                }
            }
        }
    }
}
