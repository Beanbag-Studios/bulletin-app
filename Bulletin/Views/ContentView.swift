import SwiftUI
import CoreLocation

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedCategory: Event.Category = .all
    @State private var searchText = ""
    @State private var selectedEvent: Event?
    @State private var showCreate = false
    @State private var showAuth = false
    @State private var showGate = false
    @State private var showLocationPicker = false
    @State private var showFilters = false
    @State private var showProfile = false
    @State private var events: [Event] = []
    @State private var resolvedCoordinates: [UUID: CLLocationCoordinate2D] = [:]
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var scrollOffset: CGFloat = 0
    @State private var showSplash = true
    @StateObject private var fb = FirebaseManager.shared
    @StateObject private var loc = LocationManager.shared
    @StateObject private var friends = FriendsManager.shared
    @State private var filterOptions = FilterOptions()
    @AppStorage("bulletin.friends.bannerDismissed") private var friendsBannerDismissed = false
    @FocusState private var searchFocused: Bool

    // MARK: - Derived state

    private var origin: CLLocationCoordinate2D? {
        switch filterOptions.locationSource {
        case .anywhere:
            return nil
        case .savedLocation:
            if let id = filterOptions.selectedSavedLocationId,
               let saved = loc.savedLocations.first(where: { $0.id == id }) {
                return saved.coordinate
            }
            return loc.selectedLocation?.coordinate
        case .myLocation:
            // A location the person picked wins over the device's raw GPS fix.
            return loc.selectedLocation?.coordinate ?? loc.currentLocation?.coordinate
        }
    }

    /// Past events never appear in the public feed — organizers find them in
    /// their account's My Events.
    private var upcomingEvents: [Event] {
        events.filter { !$0.isPast }
    }

    private func coordinate(for event: Event) -> CLLocationCoordinate2D? {
        event.coordinate ?? resolvedCoordinates[event.id]
    }

    private var filteredEvents: [Event] {
        var list = upcomingEvents

        if selectedCategory != .all {
            list = list.filter { $0.category == selectedCategory }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.description.localizedCaseInsensitiveContains(query) ||
                $0.address.localizedCaseInsensitiveContains(query)
            }
        }

        return list.filter {
            filterOptions.matches(
                event: $0,
                origin: origin,
                eventCoordinate: coordinate(for: $0)
            )
        }
    }

    private var searchCollapse: CGFloat {
        max(0, min(1, -scrollOffset / 60))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            NavigationStack {
                VStack(spacing: 0) {
                    pinnedNav
                        .background(AppTheme.white)
                        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)

                    ScrollView {
                        VStack(spacing: 0) {
                            offsetReader
                            collapsingSearchBar
                                .opacity(1 - searchCollapse)
                                .scaleEffect(1 - searchCollapse * 0.06, anchor: .top)
                                .frame(height: max(0, 62 * (1 - searchCollapse)))
                                .clipped()
                                .allowsHitTesting(searchCollapse < 0.9)
                            categoryChips
                            feed
                        }
                    }
                    .coordinateSpace(name: "feedScroll")
                    .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize, axes: [.vertical])
                    .scrollDismissesKeyboard(.immediately)
                    .background(AppTheme.secondaryBG)
                    .refreshable {
                        await loadEvents()
                        await friends.refresh(force: true)
                    }
                }
                .background(AppTheme.secondaryBG)
                .navigationBarHidden(true)
                .navigationDestination(item: $selectedEvent) { event in
                    EventDetailView(
                        event: event,
                        onUpdated: { updated in
                            if let index = events.firstIndex(where: { $0.id == updated.id }) {
                                events[index] = updated
                            }
                        },
                        onDeleted: { deleted in
                            events.removeAll { $0.id == deleted.id }
                        }
                    )
                }
                .sheet(isPresented: $showCreate) {
                    CreateEventView { newEvent in
                        withAnimation { events.insert(newEvent, at: 0) }
                    } onUpdate: { updated in
                        if let index = events.firstIndex(where: { $0.id == updated.id }) {
                            events[index] = updated
                        }
                    }
                }
                .sheet(isPresented: $showAuth) { AuthView(isGate: false) }
                .fullScreenCover(isPresented: $showGate) {
                    AuthView(isGate: true)
                        .interactiveDismissDisabled(true)
                }
                .sheet(isPresented: $showLocationPicker) {
                    LocationPickerView { saved in
                        loc.addLocation(saved)
                        filterOptions.selectedSavedLocationId = saved.id
                        filterOptions.radiusMiles = saved.radiusMiles
                    }
                }
                .sheet(isPresented: $showFilters) { FilterSheetView(options: $filterOptions) }
                .sheet(isPresented: $showProfile) { ProfileView() }
                .onAppear {
                    if !showSplash { showGate = !fb.isSignedIn }
                }
                .onChange(of: fb.isSignedIn) { _, signedIn in
                    if !showSplash { showGate = !signedIn }
                    if signedIn {
                        Task { await loadEvents() }
                        Task { await friends.refresh(force: true) }
                    } else {
                        friends.reset()
                    }
                }
                .task {
                    if let saved = loc.selectedLocation {
                        filterOptions.radiusMiles = saved.radiusMiles
                    }
                    await fb.publishAttendanceForJoinedEvents()
                    await loadEvents()
                    await fb.publishDirectoryEntry()
                    await friends.refresh()
                    if loc.authorization == .authorizedWhenInUse || loc.authorization == .authorizedAlways {
                        loc.requestCurrentLocation()
                    }
                }
            }
            .onAppear { UIScrollView.appearance().bounces = false }
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await friends.refresh() }
                }
            }
            .onTapGesture { searchFocused = false }

            if showSplash {
                SplashView {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        showSplash = false
                        showGate = !fb.isSignedIn
                    }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }

    // MARK: - Pinned navigation bar

    private var pinnedNav: some View {
        HStack(alignment: .center, spacing: 12) {
            locationMenu

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Button {
                    if fb.isSignedIn { showCreate = true } else { showGate = true }
                } label: {
                    Label("Create", systemImage: "plus")
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(AppTheme.blueMatte, in: Capsule())
                        .foregroundStyle(.white)
                }

                Button {
                    if fb.isSignedIn { showProfile = true } else { showAuth = true }
                } label: {
                    if fb.isSignedIn, let email = fb.userEmail {
                        Text(String(email.prefix(1)).uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(AppTheme.blueMatte, in: Circle())
                    } else {
                        Image(systemName: "person.crop.circle")
                            .font(.title3)
                            .foregroundStyle(AppTheme.blueMatte)
                            .frame(width: 36, height: 36)
                            .background(AppTheme.secondaryBG, in: Circle())
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var locationMenu: some View {
        Menu {
            if loc.savedLocations.isEmpty {
                Button {
                    showLocationPicker = true
                } label: {
                    Label("Add location", systemImage: "plus.circle")
                }
                Button {
                    loc.requestPermission()
                } label: {
                    Label("Use current location", systemImage: "location")
                }
            } else {
                ForEach(loc.savedLocations) { saved in
                    Button {
                        loc.select(saved)
                        filterOptions.selectedSavedLocationId = saved.id
                        filterOptions.radiusMiles = saved.radiusMiles
                    } label: {
                        Label(
                            "\(saved.name) — \(Int(saved.radiusMiles)) mi",
                            systemImage: loc.selectedLocation?.id == saved.id ? "checkmark" : "mappin"
                        )
                    }
                }

                Divider()

                Button {
                    showLocationPicker = true
                } label: {
                    Label("Add new location…", systemImage: "plus")
                }

                Menu("Radius") {
                    ForEach([1, 5, 10, 20, 25, 50], id: \.self) { radius in
                        Button("\(radius) mi") {
                            guard let selected = loc.selectedLocation else { return }
                            loc.updateRadius(for: selected.id, miles: Double(radius))
                            filterOptions.radiusMiles = Double(radius)
                        }
                    }
                }

                Divider()

                Button {
                    loc.delete(loc.selectedLocation ?? loc.savedLocations[0])
                } label: {
                    Label("Remove current location", systemImage: "trash")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("My Location")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.blueMatte)
                    Text(loc.selectedLocation?.name ?? "Choose location")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                }
                Text(loc.selectedLocation?.address ?? "Tap to add a location")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 190, alignment: .leading)
        }
        .menuIndicator(.hidden)
    }

    // MARK: - Search

    private var offsetReader: some View {
        Color.clear
            .frame(height: 0)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ScrollOffsetKey.self,
                        value: proxy.frame(in: .named("feedScroll")).minY
                    )
                }
            )
    }

    private var collapsingSearchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.textSecondary)
                TextField("Search garage sales, pop-ups, markets…", text: $searchText)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textPrimary)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { searchFocused = false }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppTheme.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppTheme.separator, lineWidth: 1)
            )

            Button {
                showFilters = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .padding(10)
                        .background(AppTheme.white, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(AppTheme.separator, lineWidth: 1)
                        )
                    if filterOptions.activeCount > 0 {
                        Text("\(filterOptions.activeCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(AppTheme.blueMatte, in: Circle())
                            .offset(x: 4, y: -4)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.white)
    }

    // MARK: - Categories

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Event.Category.allCases) { category in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            selectedCategory = category
                        }
                    } label: {
                        Label(category.rawValue, systemImage: category.icon)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                selectedCategory == category ? AppTheme.blueMatte : AppTheme.white,
                                in: Capsule()
                            )
                            .foregroundStyle(
                                selectedCategory == category ? .white : AppTheme.textPrimary
                            )
                            .overlay(
                                Capsule()
                                    .stroke(
                                        AppTheme.separator.opacity(selectedCategory == category ? 0 : 1),
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
        .background(AppTheme.white)
        .overlay(Divider().overlay(AppTheme.separator), alignment: .bottom)
    }

    // MARK: - Feed

    private var feed: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bulletin")
                        .font(.headline)
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if fb.isSignedIn, friends.needsPermission, !friendsBannerDismissed {
                friendsBanner
            }

            if isLoading {
                ProgressView("Loading events…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
            } else if upcomingEvents.isEmpty, let loadError {
                messageState(
                    icon: "wifi.exclamationmark",
                    title: "Couldn't load events",
                    message: loadError,
                    actionTitle: "Try again"
                ) {
                    Task { await loadEvents() }
                }
            } else if upcomingEvents.isEmpty {
                messageState(
                    icon: "calendar.badge.plus",
                    title: "No events yet",
                    message: "Be the first to post something happening near you.",
                    actionTitle: fb.isSignedIn ? "Create an event" : "Sign in to create"
                ) {
                    if fb.isSignedIn { showCreate = true } else { showGate = true }
                }
            } else if filteredEvents.isEmpty {
                messageState(
                    icon: "magnifyingglass",
                    title: "No matches",
                    message: "Try a different search, category, or distance.",
                    actionTitle: "Clear filters"
                ) {
                    searchText = ""
                    selectedCategory = .all
                    filterOptions = FilterOptions()
                }
            } else {
                LazyVStack(spacing: 16) {
                    ForEach(filteredEvents) { event in
                        Button {
                            selectedEvent = event
                        } label: {
                            EventCardView(
                                event: event,
                                friendsGoing: friends.friendsGoing(to: event.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private var summaryText: String {
        if isLoading { return "Loading…" }
        if upcomingEvents.isEmpty { return "Nothing posted yet" }
        let count = filteredEvents.count
        return count == 1 ? "1 event" : "\(count) events"
    }

    private var friendsBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.fill")
                .font(.subheadline)
                .foregroundStyle(AppTheme.blueMatte)

            VStack(alignment: .leading, spacing: 2) {
                Text("See which friends are going")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Match your contacts privately to spot events friends already joined.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            Button {
                Task { await friends.requestAccess() }
            } label: {
                Text("Enable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AppTheme.blueMatte, in: Capsule())
            }
            .disabled(friends.isLoading)

            Button {
                friendsBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(AppTheme.blueMatte.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.blueMatte.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func messageState(
        icon: String,
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundStyle(AppTheme.textSecondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(actionTitle, action: action)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(AppTheme.blueMatte, in: Capsule())
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.bottom, 40)
    }

    // MARK: - Data

    private func loadEvents() async {
        isLoading = true

        do {
            var fetched = try await fb.fetchEvents()
            if let counts = await fb.fetchAttendanceCounts() {
                for index in fetched.indices {
                    fetched[index].attendeeCount = counts[fetched[index].id.uuidString] ?? 0
                }
            }
            events = fetched
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
        await resolveMissingCoordinates()
    }

    /// Older events were saved before coordinates were stored. Resolve their
    /// addresses once so the distance filter still applies to them.
    private func resolveMissingCoordinates() async {
        let missing = events.filter {
            !$0.isPast && $0.coordinate == nil && resolvedCoordinates[$0.id] == nil
        }

        for event in missing.prefix(25) {
            guard let coordinate = await loc.coordinate(for: event.address) else { continue }
            resolvedCoordinates[event.id] = coordinate
        }
    }
}
