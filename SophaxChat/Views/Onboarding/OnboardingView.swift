// OnboardingView.swift
// SophaxChat
//
// First-launch onboarding: 3 intro slides + username setup.
// No email, phone number, or account registration required.

import SwiftUI

// MARK: - Onboarding Page Model

private struct OnboardingPage {
    let icon: String
    let color: Color
    let title: String
    let body: String
}

private let pages: [OnboardingPage] = [
    .init(
        icon: "lock.shield.fill", color: .accentColor,
        title: "Private by design",
        body: "No servers. No accounts. Messages travel directly between devices, encrypted end-to-end."
    ),
    .init(
        icon: "antenna.radiowaves.left.and.right", color: .green,
        title: "Find people nearby",
        body: "Open the app on the same WiFi or Bluetooth range. Nearby devices appear instantly."
    ),
    .init(
        icon: "globe", color: .orange,
        title: "Chat globally",
        body: "Enable Tor in Settings to reach anyone in the world — no phone number, no VPN."
    ),
    .init(
        icon: "externaldrive.badge.exclamationmark", color: .orange,
        title: "Your keys, your device",
        body: "Your identity and messages are stored only on this device. No backup exists — if you lose your phone, your history cannot be recovered."
    ),
    .init(
        icon: "checkmark.shield.fill", color: .green,
        title: "Verify your contacts",
        body: "Always compare Safety Numbers with people you trust. Tap \"Verify Identity\" in any conversation to confirm you're talking to the right person."
    ),
]

// MARK: - Onboarding View

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    @State private var currentPage = 0
    @State private var username = ""
    @FocusState private var isTextFieldFocused: Bool

    private let totalPages = pages.count + 1 // slides + username page

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    SlidePage(page: page)
                        .tag(index)
                }
                UsernamePage(username: $username, focused: $isTextFieldFocused, onSubmit: createIdentity)
                    .tag(pages.count)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .animation(.easeInOut, value: currentPage)

            // Skip button — only visible on intro slides
            if currentPage < pages.count {
                Button("Skip") {
                    withAnimation { currentPage = pages.count }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding()
            }
        }
    }

    private func createIdentity() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard name.isValidUsername else { return }
        isTextFieldFocused = false
        appState.createIdentity(username: name)
    }
}

// MARK: - Slide Page

private struct SlidePage: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            ZStack {
                Circle()
                    .fill(page.color.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: page.icon)
                    .font(.system(size: 52))
                    .foregroundStyle(page.color)
            }
            VStack(spacing: 12) {
                Text(page.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(page.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
            Spacer() // extra bottom space for page dots
        }
    }
}

// MARK: - Username Page

private struct UsernamePage: View {
    @Binding var username: String
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 8) {
                Text("Choose your name")
                    .font(.title.bold())
                Text("Visible to nearby peers. No account required.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("e.g. alice", text: $username)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .focused(focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit(onSubmit)
            }
            .padding(.horizontal, 32)

            Button(action: onSubmit) {
                Label("Start Chatting", systemImage: "arrow.right.circle.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(username.isValidUsername ? Color.accentColor : Color.accentColor.opacity(0.3))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!username.isValidUsername)
            .padding(.horizontal, 32)
            .animation(.easeInOut, value: username.isValidUsername)

            Spacer()
            Spacer()
        }
    }
}

// MARK: - Helpers

private extension String {
    var isValidUsername: Bool {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 1 && trimmed.count <= 64
    }
}

// MARK: - Security Info (kept for use elsewhere)

struct SecurityInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Security Features") {
                    SecurityFeatureRow(icon: "lock.fill", color: .blue,
                        title: "End-to-End Encryption",
                        description: "Every message is encrypted on your device before sending. Only the recipient can decrypt it.")
                    SecurityFeatureRow(icon: "arrow.triangle.2.circlepath", color: .green,
                        title: "Double Ratchet Algorithm",
                        description: "The same protocol used by Signal. Each message uses a new key — forward secrecy + break-in recovery.")
                    SecurityFeatureRow(icon: "key.fill", color: .orange,
                        title: "X3DH Key Agreement",
                        description: "Sessions established with Extended Triple Diffie-Hellman. No server stores your keys.")
                    SecurityFeatureRow(icon: "wifi.slash", color: .purple,
                        title: "No Servers",
                        description: "Messages travel directly between devices via Bluetooth and WiFi Direct.")
                    SecurityFeatureRow(icon: "person.slash", color: .red,
                        title: "No Identity Required",
                        description: "No phone number, email, or account. Your identity is a cryptographic key pair.")
                    SecurityFeatureRow(icon: "eye.slash", color: .pink,
                        title: "Open Source",
                        description: "The full source code is publicly auditable.")
                }
            }
            .navigationTitle("How It Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SecurityFeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    OnboardingView().environmentObject(AppState())
}
