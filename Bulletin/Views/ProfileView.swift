import SwiftUI

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fb = FirebaseManager.shared

    @State private var hostedCount = 0
    @State private var joinedCount = 0
    @State private var attendedCount = 0
    @State private var isLoadingStats = true
    @State private var showMyEvents = false
    @State private var showSettings = false

    private var initials: String {
        guard let email = fb.userEmail, let first = email.first else { return "U" }
        return String(first).uppercased()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    stats
                    actions
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(AppTheme.secondaryBG)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showMyEvents) { MyEventsView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task { await loadStats() }
            .onChange(of: fb.isSignedIn) { _, signedIn in
                if !signedIn { dismiss() }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(AppTheme.blueMatte)
                    .frame(width: 76, height: 76)
                Text(initials)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
            }
            Text(fb.userEmail ?? "Not signed in")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.top, 10)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            StatTile(title: "Hosting", value: "\(hostedCount)", icon: "calendar")
            Divider().frame(height: 38)
            StatTile(title: "Joined", value: "\(joinedCount)", icon: "person.2")
            Divider().frame(height: 38)
            StatTile(
                title: "Attended",
                value: "\(attendedCount)",
                icon: "checkmark.seal"
            )
        }
        .frame(height: 82)
        .background(AppTheme.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.separator.opacity(0.6), lineWidth: 1)
        )
        .redacted(reason: isLoadingStats ? .placeholder : [])
    }

    private var actions: some View {
        VStack(spacing: 10) {
            rowButton(icon: "calendar.badge.plus", title: "My Events", subtitle: "Upcoming and past") {
                showMyEvents = true
            }
            rowButton(icon: "gearshape", title: "Settings", subtitle: "Account, privacy, and sign out") {
                showSettings = true
            }
        }
    }

    private func rowButton(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(AppTheme.blueMatte)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(14)
            .background(AppTheme.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.separator.opacity(0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    private func loadStats() async {
        isLoadingStats = true
        defer { isLoadingStats = false }

        guard let uid = fb.uid else {
            hostedCount = 0
            joinedCount = 0
            attendedCount = 0
            return
        }

        guard let all = try? await fb.fetchEvents() else { return }
        let joinedIDs = await fb.fetchJoinedEventIDs()

        let mine = all.filter { $0.creatorUid == uid }
        hostedCount = mine.count
        joinedCount = all.filter {
            joinedIDs.contains($0.id.uuidString) && $0.creatorUid != uid
        }.count
        attendedCount = all.filter {
            joinedIDs.contains($0.id.uuidString) && $0.isPast
        }.count
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(AppTheme.blueMatte)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
