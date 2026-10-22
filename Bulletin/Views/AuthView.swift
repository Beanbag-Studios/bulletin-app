import SwiftUI

struct AuthView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fb = FirebaseManager.shared

    @State private var selectedPage = 0
    @State private var email = ""
    @State private var password = ""
    @State private var errorText: String?
    @State private var infoText: String?
    @State private var isLoading = false
    @State private var legalDocument: LegalDocument?
    var isGate: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Auth mode", selection: $selectedPage) {
                    Text("Sign In").tag(0)
                    Text("Sign Up").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .onChange(of: selectedPage) { _, _ in errorText = nil; infoText = nil }

                TabView(selection: $selectedPage) {
                    signInPage.tag(0)
                    signUpPage.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: selectedPage)

                if fb.isSignedIn, let em = fb.userEmail, !isGate {
                    VStack(spacing: 8) {
                        Label("Signed in as \(em)", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.green)
                        Button("Sign Out", role: .destructive) { fb.signOut() }
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.bottom, 12)
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle(selectedPage == 0 ? "Sign In" : "Create Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isGate {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(isGate && !fb.isSignedIn)
        .sheet(item: $legalDocument) { document in
            LegalView(document: document)
        }
    }

    private var signInPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                header(icon: "person.crop.circle.badge.checkmark", title: "Welcome back")
                fields(isSignUp: false)
                HStack { Spacer(); Button("Forgot password?") { Task { await reset() } }.font(.caption.weight(.semibold)).foregroundStyle(AppTheme.blueMatte) }
                Button { Task { await doSignIn() } } label: {
                    if isLoading { ProgressView().tint(.white) } else { Text("Sign In").font(.subheadline.weight(.bold)) }
                }
                .frame(maxWidth: .infinity, minHeight: 44).padding(.vertical, 4)
                .background(AppTheme.blueMatte, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white).contentShape(RoundedRectangle(cornerRadius: 12)).buttonStyle(.plain)
                .disabled(isLoading || email.isEmpty || password.count < 6)
                Button("Need an account? Sign up") { withAnimation { selectedPage = 1 } }
                    .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.blueMatte)
                legalLinks
            }.padding(16)
        }
    }

    private var signUpPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                header(icon: "person.badge.plus", title: "Create account")
                fields(isSignUp: true)
                Button { Task { await doSignUp() } } label: {
                    if isLoading { ProgressView().tint(.white) } else { Text("Sign Up").font(.subheadline.weight(.bold)) }
                }
                .frame(maxWidth: .infinity, minHeight: 44).padding(.vertical, 4)
                .background(AppTheme.blueMatte, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white).contentShape(RoundedRectangle(cornerRadius: 12)).buttonStyle(.plain)
                .disabled(isLoading || email.isEmpty || password.count < 6)
                Button("Already have an account? Sign in") { withAnimation { selectedPage = 0 } }
                    .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.blueMatte)
                signUpLegalNotice
            }.padding(16)
        }
    }

    private var legalLinks: some View {
        HStack(spacing: 14) {
            Button("Privacy Policy") { legalDocument = .privacy }
            Button("Terms of Service") { legalDocument = .terms }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(AppTheme.blueMatte)
        .padding(.top, 4)
    }

    private var signUpLegalNotice: some View {
        VStack(spacing: 4) {
            Text("By creating an account, you agree to our")
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
            HStack(spacing: 12) {
                Button("Terms of Service") { legalDocument = .terms }
                Button("Privacy Policy") { legalDocument = .privacy }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.blueMatte)
        }
        .multilineTextAlignment(.center)
        .padding(.top, 4)
    }

    private func header(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 48)).foregroundStyle(AppTheme.blueMatte)
            Text(title).font(.title2.weight(.bold)).foregroundStyle(AppTheme.textPrimary)
        }.padding(.top, 8)
    }

    private func fields(isSignUp: Bool) -> some View {
        VStack(spacing: 10) {
            TextField("Email", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.next).textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            SecureField("Password (6+ chars)", text: $password)
                .textContentType(isSignUp ? .newPassword : .password)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            if let infoText { Text(infoText).font(.caption).foregroundStyle(.green).multilineTextAlignment(.center) }
        }.padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func doSignIn() async {
        errorText = nil; infoText = nil; isLoading = true; defer { isLoading = false }
        do {
            try await fb.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            infoText = "Signed in"; try? await Task.sleep(nanoseconds: 300_000_000); dismiss()
        } catch {
            let msg = error.localizedDescription
            if msg.lowercased().contains("no user") || msg.contains("user-not-found") || msg.contains("no user record") {
                errorText = "No account for \(email). Redirecting…"
                try? await Task.sleep(nanoseconds: 600_000_000)
                withAnimation { selectedPage = 1 }; errorText = nil; infoText = "Create your account now."
            } else { errorText = msg }
        }
    }

    private func doSignUp() async {
        errorText = nil; infoText = nil; isLoading = true; defer { isLoading = false }
        do {
            try await fb.signUp(email: email.trimmingCharacters(in: .whitespaces), password: password)
            infoText = "Account created"; try? await Task.sleep(nanoseconds: 300_000_000); dismiss()
        } catch {
            if error.localizedDescription.lowercased().contains("already in use") || error.localizedDescription.contains("email-already-in-use") {
                errorText = "Email in use. Redirecting…"
                try? await Task.sleep(nanoseconds: 600_000_000)
                withAnimation { selectedPage = 0 }; errorText = nil; infoText = "That email exists — sign in instead."
            } else { errorText = error.localizedDescription }
        }
    }

    private func reset() async {
        guard !email.isEmpty else { errorText = "Enter your email first."; return }
        do { try await fb.sendPasswordReset(email: email); infoText = "Reset email sent to \(email)." }
        catch { errorText = error.localizedDescription }
    }
}
