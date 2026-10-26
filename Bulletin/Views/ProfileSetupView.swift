import SwiftUI

/// Collects a phone number for accounts that don't have one yet — for example
/// accounts created before phone matching existed. New accounts enter their
/// number during sign-up instead of seeing this sheet.
struct ProfileSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fb = FirebaseManager.shared
    @StateObject private var friends = FriendsManager.shared

    /// When true the sheet is dismissing itself after a save.
    var allowsSkip: Bool = true

    @State private var phone = ""
    @State private var errorText: String?
    @State private var isSaving = false
    @FocusState private var phoneFocused: Bool

    private var isEditing: Bool {
        !(fb.phoneNumber ?? "").isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    phoneField
                    privacyNote
                    saveButton
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.secondaryBG)
            .navigationTitle(isEditing ? "Phone number" : "Add your number")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if allowsSkip {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Not now") { dismiss() }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { phoneFocused = false }
                }
            }
            .onAppear {
                phone = fb.phoneNumber.map(FirebaseManager.formatPhone) ?? ""
                phoneFocused = phone.isEmpty
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "phone.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(AppTheme.blueMatte)

            Text(isEditing ? "Update your phone number" : "Let friends find you")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)

            Text("Bulletin uses your number privately to match you with people already in your contacts who use the app.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var phoneField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Phone number")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)

            TextField("(555) 123-4567", text: $phone)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .focused($phoneFocused)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppTheme.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.separator, lineWidth: 1)
                )

            if !phone.isEmpty && FirebaseManager.normalizePhone(phone) == nil {
                Text("Include your area code, for example (555) 123-4567.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Your number stays private", systemImage: "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            Text("It stays on this device and only a one-way hash is sent for matching. Nobody on Bulletin can see your number. Friends see the name and photo already saved in their own contacts.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.separator.opacity(0.6), lineWidth: 1)
        )
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack {
                Spacer()
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Text(isEditing ? "Save changes" : "Save number")
                        .font(.subheadline.weight(.bold))
                }
                Spacer()
            }
            .frame(minHeight: 46)
            .background(AppTheme.blueMatte, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(isSaving || FirebaseManager.normalizePhone(phone) == nil)
        .opacity(FirebaseManager.normalizePhone(phone) == nil ? 0.55 : 1)
    }

    private func save() async {
        errorText = nil
        isSaving = true
        defer { isSaving = false }

        do {
            try await fb.savePhoneNumber(phone)
            await friends.refresh(force: true)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
