import SwiftUI

struct MyEventsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fb = FirebaseManager.shared

    @State private var hosted: [Event] = []
    @State private var joined: [Event] = []
    @State private var isLoading = true
    @State private var selectedSegment = 0   // 0 = Upcoming, 1 = Past
    @State private var showCreate = false
    @State private var errorText: String?

    private var allEvents: [Event] {
        var byID: [UUID: Event] = [:]
        for event in hosted { byID[event.id] = event }
        for event in joined { byID[event.id] = event }
        return Array(byID.values)
    }

    private var upcoming: [Event] {
        allEvents.filter { !$0.isPast }.sorted { $0.eventDate < $1.eventDate }
    }

    private var past: [Event] {
        // Past events are private to their organizer.
        hosted.filter { $0.isPast }.sorted { $0.eventDate > $1.eventDate }
    }

    private var visibleEvents: [Event] {
        selectedSegment == 0 ? upcoming : past
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Events", selection: $selectedSegment) {
                    Text("Upcoming (\(upcoming.count))").tag(0)
                    Text("Past (\(past.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if isLoading {
                    ProgressView("Loading your events…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleEvents.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(visibleEvents) { event in
                            NavigationLink {
                                EventDetailView(
                                    event: event,
                                    onUpdated: { updated in apply(updated) },
                                    onDeleted: { deleted in remove(deleted) }
                                )
                            } label: {
                                EventRow(event: event, isHosting: hosted.contains { $0.id == event.id })
                            }
                            .listRowBackground(AppTheme.white)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if hosted.contains(where: { $0.id == event.id }) {
                                    Button(role: .destructive) {
                                        Task { await delete(event) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(AppTheme.secondaryBG)
                }

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.bottom, 8)
                }
            }
            .background(AppTheme.secondaryBG)
            .navigationTitle("My Events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateEventView(onCreate: { newEvent in
                    hosted.append(newEvent)
                })
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: selectedSegment == 0 ? "calendar.badge.clock" : "calendar.badge.checkmark")
                .font(.system(size: 46))
                .foregroundStyle(AppTheme.textSecondary)
            Text(selectedSegment == 0 ? "Nothing coming up" : "No past events")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Text(selectedSegment == 0
                 ? "Events you host or join will appear here."
                 : "Events you hosted will appear here once they end.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if selectedSegment == 0 {
                Button {
                    showCreate = true
                } label: {
                    Label("Create an event", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(AppTheme.blueMatte, in: Capsule())
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        guard let uid = fb.uid else {
            hosted = []
            joined = []
            return
        }

        do {
            let fresh = try await fb.fetchEvents()
            let joinedIDs = await fb.fetchJoinedEventIDs()

            hosted = fresh.filter { $0.creatorUid == uid }
            joined = fresh.filter {
                joinedIDs.contains($0.id.uuidString) && $0.creatorUid != uid
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func apply(_ updated: Event) {
        if let index = hosted.firstIndex(where: { $0.id == updated.id }) {
            hosted[index] = updated
        }
        if let index = joined.firstIndex(where: { $0.id == updated.id }) {
            joined[index] = updated
        }
    }

    private func remove(_ deleted: Event) {
        hosted.removeAll { $0.id == deleted.id }
        joined.removeAll { $0.id == deleted.id }
    }

    private func delete(_ event: Event) async {
        do {
            try await fb.deleteEvent(event)
            withAnimation { remove(event) }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct EventRow: View {
    let event: Event
    let isHosting: Bool

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .saturation(event.isPast ? 0 : 1)
                .opacity(event.isPast ? 0.7 : 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(event.isPast ? AppTheme.textSecondary : AppTheme.textPrimary)
                        .lineLimit(1)
                    if event.isPast {
                        Text("Past")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.textSecondary, in: Capsule())
                    }
                }
                Text("\(event.dateText) · \(event.timeText)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                Text(event.address)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                Text(isHosting ? "Hosting" : "Joined")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isHosting ? AppTheme.blueMatte : AppTheme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = event.bannerImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 62, height: 62)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppTheme.gradient(for: event.category))
                .frame(width: 62, height: 62)
                .overlay {
                    Image(systemName: event.imageSymbol)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                }
        }
    }
}
