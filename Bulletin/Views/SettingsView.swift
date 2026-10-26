import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fb = FirebaseManager.shared
    @StateObject private var loc = LocationManager.shared
    @StateObject private var friends = FriendsManager.shared

    @State private var isDeleting = false
    @State private var activeSheet: SettingsSheet?
    @State private var activeAlert: SettingsAlert?

    private enum SettingsSheet: Identifiable {
        case addLocation
        case profilePhone
        case legal(LegalDocument)

        var id: String {
            switch self {
            case .addLocation:
                return "addLocation"
            case .profilePhone:
                return "profilePhone"
            case .legal(let document):
                return "legal-\(document.rawValue)"
            }
        }
    }

    private enum SettingsAlert: Identifiable {
        case deleteAccount
        case message(title: String, message: String)

        var id: String {
            switch self {
            case .deleteAccount:
                return "delete"
            case .message(let title, let message):
                return "\(title)-\(message)"
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    HStack(spacing: 12) {
                        Image(systemName: "person.circle.fill")
                            .font(.title2)
                            .foregroundStyle(AppTheme.blueMatte)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fb.userEmail ?? "Not signed in")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text("Signed in with email")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }

                    Button {
                        activeSheet = .profilePhone
                    } label: {
                        HStack {
                            Label("Phone number", systemImage: "phone")
                            Spacer()
                            Text(fb.phoneNumber.map { FirebaseManager.formatPhone($0) } ?? "Add")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Section {
                    HStack {
                        Label("Contacts", systemImage: "person.2")
                        Spacer()
                        Text(friends.authorizationLabel)
                            .foregroundStyle(.secondary)
                    }

                    if friends.hasAccess {
                        HStack {
                            Text("Friends on Bulletin")
                            Spacer()
                            Text("\(friends.friends.count)")
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            Task { await friends.refresh(force: true) }
                        } label: {
                            Label("Refresh friend matches", systemImage: "arrow.clockwise")
                        }
                        .disabled(friends.isLoading)
                    } else if friends.isDenied {
                        Button {
                            openSettings()
                        } label: {
                            Label("Open Settings", systemImage: "gearshape")
                        }
                    } else {
                        Button {
                            Task { await friends.requestAccess() }
                        } label: {
                            Label("Allow Contacts", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .disabled(friends.isLoading)
                    }
                } header: {
                    Text("Friends")
                } footer: {
                    Text("Bulletin matches your contacts' email addresses and phone numbers on this device to show when friends are going. Your address book is never uploaded, and other people never see your number.")
                }

                Section("Saved Locations") {
                    if loc.savedLocations.isEmpty {
                        Text("No saved locations yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(loc.savedLocations) { saved in
                            Button {
                                loc.select(saved)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(saved.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(AppTheme.textPrimary)
                                        Text("\(saved.address) · \(Int(saved.radiusMiles)) mi")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if loc.selectedLocation?.id == saved.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(AppTheme.blueMatte)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { indexSet in
                            indexSet.map { loc.savedLocations[$0] }.forEach(loc.delete)
                        }
                    }

                    Button {
                        activeSheet = .addLocation
                    } label: {
                        Label("Add Location", systemImage: "plus.circle")
                    }
                }

                Section {
                    Button {
                        Task { await sendPasswordReset() }
                    } label: {
                        Label("Send Password Reset Email", systemImage: "key")
                    }
                    .disabled(fb.userEmail?.isEmpty ?? true)
                } header: {
                    Text("Security")
                } footer: {
                    Text("We'll email a secure link to \(fb.userEmail ?? "your address") so you can choose a new password.")
                }

                Section {
                    Button {
                        activeSheet = .legal(.privacy)
                    } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }

                    Button {
                        activeSheet = .legal(.terms)
                    } label: {
                        Label("Terms of Service", systemImage: "doc.text")
                    }

                    if let url = LegalConfig.supportURL {
                        Link(destination: url) {
                            Label("Contact Support", systemImage: "envelope")
                        }
                    }
                } header: {
                    Text("Legal")
                } footer: {
                    Text("Version \(LegalConfig.termsVersion)")
                }

                Section {
                    Button(role: .destructive) {
                        fb.signOut()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        activeAlert = .deleteAccount
                    } label: {
                        if isDeleting {
                            HStack {
                                ProgressView()
                                Text("Deleting account…")
                            }
                        } else {
                            Label("Delete Account", systemImage: "person.crop.circle.badge.minus")
                        }
                    }
                    .disabled(isDeleting)
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("Permanently deletes your account, your hosted events, your RSVPs, and your friend-matching entry. This can't be undone.")
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .addLocation:
                    LocationPickerView { saved in
                        loc.addLocation(saved)
                    }
                case .profilePhone:
                    ProfileSetupView()
                case .legal(let document):
                    LegalView(document: document)
                }
            }
            .alert(item: $activeAlert) { alert in
                switch alert {
                case .deleteAccount:
                    return Alert(
                        title: Text("Delete account?"),
                        message: Text("This permanently deletes your account, your hosted events, your RSVPs, and your friend-matching entry. This can't be undone."),
                        primaryButton: .destructive(Text("Delete")) {
                            Task { await deleteAccount() }
                        },
                        secondaryButton: .cancel()
                    )
                case .message(let title, let message):
                    return Alert(
                        title: Text(title),
                        message: Text(message),
                        dismissButton: .default(Text("OK"))
                    )
                }
            }
            .onChange(of: fb.isSignedIn) { _, signedIn in
                if !signedIn { dismiss() }
            }
        }
    }

    private func sendPasswordReset() async {
        guard let email = fb.userEmail, !email.isEmpty else {
            activeAlert = .message(title: "Not signed in", message: "Sign in again to reset your password.")
            return
        }
        do {
            try await fb.sendPasswordReset(email: email)
            activeAlert = .message(
                title: "Check your email",
                message: "We sent a password reset link to \(email). Follow the link to choose a new password."
            )
        } catch {
            activeAlert = .message(
                title: "Couldn't send reset email",
                message: error.localizedDescription
            )
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await fb.deleteAccount()
            dismiss()
        } catch {
            activeAlert = .message(
                title: "Couldn't delete account",
                message: error.localizedDescription
            )
        }
    }
}
