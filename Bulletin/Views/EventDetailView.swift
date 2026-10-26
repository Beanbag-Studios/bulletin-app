import SwiftUI
import UIKit

struct EventDetailView: View {
    /// Callbacks let the feed and "My Events" list stay in sync after an edit
    /// or a delete without refetching everything.
    var onUpdated: (Event) -> Void
    var onDeleted: (Event) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var fb = FirebaseManager.shared
    @StateObject private var friends = FriendsManager.shared

    @State private var event: Event
    @State private var isJoined = false
    @State private var isBusy = false
    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    @State private var friendsExpanded = false
    @State private var errorText: String?

    init(
        event: Event,
        onUpdated: @escaping (Event) -> Void = { _ in },
        onDeleted: @escaping (Event) -> Void = { _ in }
    ) {
        self.onUpdated = onUpdated
        self.onDeleted = onDeleted
        _event = State(initialValue: event)
    }

    private var isOwner: Bool { fb.uid == event.creatorUid }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                content
            }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { topBar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .background(AppTheme.white)
        .task {
            let joined = await fb.fetchJoinedEventIDs()
            isJoined = joined.contains(event.id.uuidString)
            if let count = await fb.fetchAttendanceCount(eventID: event.id) {
                event.attendeeCount = count
            }
            await friends.refresh()
        }
        .alert("Delete this event?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task { await deleteEvent() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the event and its RSVPs. This can't be undone.")
        }
        .sheet(isPresented: $showEdit) {
            CreateEventView(
                existingEvent: event,
                onCreate: { _ in },
                onUpdate: { updated in
                    event = updated
                    onUpdated(updated)
                }
            )
        }
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if !event.allImages.isEmpty {
                    ImageCarouselView(images: event.allImages, height: 260, cornerRadius: 0)
                } else {
                    Rectangle()
                        .fill(AppTheme.gradient(for: event.category))
                        .frame(height: 260)
                        .overlay {
                            VStack(spacing: 12) {
                                Image(systemName: event.imageSymbol)
                                    .font(.system(size: 56))
                                    .foregroundStyle(.white.opacity(0.95))
                                Text(event.category.rawValue.uppercased())
                                    .font(.caption.weight(.bold))
                                    .tracking(1.2)
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 120)

            VStack(alignment: .leading, spacing: 6) {
                if event.isPast {
                    Text("ENDED")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.22), in: Capsule())
                        .foregroundStyle(.white)
                }
                Text(event.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Label(event.address, systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }
            .padding(16)
        }
        .frame(height: 260)
        .clipped()
    }

    // MARK: - Body content

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            statsRow
            organizerRow
            friendsSection
            Divider()
            aboutSection
            locationSection
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if isOwner {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("Delete Event", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isBusy)
            } else {
                Button {
                    reportEvent()
                } label: {
                    Label("Report this event", systemImage: "exclamationmark.bubble")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            Spacer(minLength: 90)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            StatBlock(icon: "clock.fill", title: event.timeText, subtitle: event.dateText)
            Divider().padding(.horizontal, 10)
            StatBlock(icon: "tag.fill", title: event.isFree ? "Free entry" : "Paid entry", subtitle: event.category.rawValue)
            Divider().padding(.horizontal, 10)
            StatBlock(
                icon: "person.2.fill",
                title: "\(event.attendeeCount)",
                subtitle: "going"
            )
        }
        .frame(height: 58)
        .padding(.vertical, 12)
        .background(AppTheme.secondaryBG, in: RoundedRectangle(cornerRadius: 12))
    }

    private var organizerRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AppTheme.blueMatte).frame(width: 44, height: 44)
                Text(event.organizerInitials)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.organizerName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.blueMatte)
                    Text(isOwner ? "You're the organizer" : "Event organizer")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            Spacer()
            if isOwner {
                Button("Edit") { showEdit = true }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.blueMatte)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(AppTheme.secondaryBG, in: Capsule())
            }
        }
    }

    // MARK: - Friends

    @ViewBuilder
    private var friendsSection: some View {
        if fb.isSignedIn {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Friends going")
                        .font(.headline)
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    if friends.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else if friends.hasAccess {
                        Button {
                            Task { await friends.refresh(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.blueMatte)
                        }
                        .accessibilityLabel("Refresh friends")
                    }
                }

                if !friends.hasAccess {
                    contactsPrompt
                } else if friends.isLoading {
                    Text("Checking your contacts…")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    let going = friends.friendsGoing(to: event.id)
                    if going.isEmpty {
                        Text("None of your contacts are going yet.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    } else {
                        VStack(spacing: 0) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    friendsExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    FriendAvatarStack(friends: going, size: 40, maxVisible: 5)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(
                                            going.count == 1
                                                ? "1 friend is going"
                                                : "\(going.count) friends are going"
                                        )
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppTheme.textPrimary)

                                        Text(friendsExpanded ? "Hide the list" : "Tap the photos to see who")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }

                                    Spacer(minLength: 4)

                                    Image(systemName: "chevron.down")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .rotationEffect(.degrees(friendsExpanded ? 180 : 0))
                                }
                                .padding(10)
                                .background(AppTheme.secondaryBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            if friendsExpanded {
                                VStack(spacing: 0) {
                                    ForEach(Array(going.enumerated()), id: \.element.id) { index, friend in
                                        if index > 0 {
                                            Divider().padding(.leading, 48)
                                        }
                                        friendRow(friend)
                                    }
                                }
                                .padding(.top, 4)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }

                        if !isJoined && !event.isPast && !isOwner {
                            Button {
                                Task { await toggleJoin() }
                            } label: {
                                Label("Join them", systemImage: "person.2.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.blueMatte)
                            }
                            .disabled(isBusy)
                            .padding(.top, 2)
                        }
                    }
                }
            }
        }
    }

    private var contactsPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See which of your contacts are going. Bulletin matches email addresses and phone numbers on your device — your address book is never uploaded.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if friends.isDenied {
                Button {
                    openSettings()
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.blueMatte)
                }
            } else {
                Button {
                    Task { await friends.requestAccess() }
                } label: {
                    Label("Allow Contacts", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(AppTheme.blueMatte, in: Capsule())
                }
                .disabled(friends.isLoading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.secondaryBG, in: RoundedRectangle(cornerRadius: 10))
    }

    private func friendRow(_ friend: ContactFriend) -> some View {
        HStack(spacing: 10) {
            FriendAvatarView(friend: friend, size: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(friend.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
                if !friend.subtitle.isEmpty {
                    Text(friend.subtitle)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("Going")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.blueMatte)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AppTheme.blueMatte.opacity(0.1), in: Capsule())
        }
        .padding(.vertical, 6)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About this event")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Text(event.description.isEmpty ? "No description provided." : event.description)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .lineSpacing(3)
        }
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Location")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            HStack(spacing: 10) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.blueMatte)
                Text(event.address)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Button("Directions") { openInMaps() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.blueMatte)
            }
            .padding(12)
            .background(AppTheme.secondaryBG, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(9)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(AppTheme.separator)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.isFree ? "Free to join" : "Paid entry")
                        .font(.headline)
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                if event.isPast {
                    Text("Event ended")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(AppTheme.secondaryBG, in: Capsule())
                } else if isOwner {
                    Text("You're hosting")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.blueMatte)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(AppTheme.secondaryBG, in: Capsule())
                } else {
                    Button { Task { await toggleJoin() } } label: {
                        HStack(spacing: 6) {
                            if isBusy {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: isJoined ? "checkmark.circle.fill" : "plus.circle.fill")
                                Text(isJoined ? "Joined" : "Join Event")
                            }
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(isJoined ? AppTheme.blueMatteLight : AppTheme.blueMatte, in: Capsule())
                    }
                    .disabled(isBusy || !fb.isSignedIn)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }

    private var statusText: String {
        if isOwner {
            return event.isPast ? "This event has ended" : "Share it with your neighbors"
        }
        if !fb.isSignedIn { return "Sign in to join" }
        if event.isPast { return "This event has already happened" }
        return isJoined ? "You're in · \(event.timeText)" : "Tap Join to save your spot"
    }

    // MARK: - Actions

    private func toggleJoin() async {
        guard fb.isSignedIn else {
            errorText = "Sign in to join events."
            return
        }
        guard !isOwner else { return }

        isBusy = true
        defer { isBusy = false }

        let joining = !isJoined
        do {
            if joining {
                try await fb.joinEvent(event)
            } else {
                try await fb.leaveEvent(event)
            }
            withAnimation(.snappy) { isJoined = joining }
            if let count = await fb.fetchAttendanceCount(eventID: event.id) {
                event.attendeeCount = count
            }
            onUpdated(event)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func deleteEvent() async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await fb.deleteEvent(event)
            onDeleted(event)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func openInMaps() {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: event.address)]
        if let url = components?.url {
            UIApplication.shared.open(url)
        }
    }

    private func reportEvent() {
        guard let url = LegalConfig.reportURL(for: event) else {
            errorText = "Could not open Mail. You can report this event at \(LegalConfig.supportEmail)."
            return
        }
        UIApplication.shared.open(url)
    }
}

private struct StatBlock: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(AppTheme.blueMatte)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}
