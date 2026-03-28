// IdentityView.swift
// SophaxChat
//
// Shows the local user's identity info and safety number.
// Also links to settings and security options.

import SwiftUI
import PhotosUI
import SophaxChatCore

struct IdentityView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showingRenameAlert  = false
    @State private var renameText          = ""
    @State private var avatarPickerItem:   PhotosPickerItem? = nil

    private var identity: IdentityManager? { appState.chatManager?.identity }

    var body: some View {
        NavigationStack {
            List {
                // Identity summary
                Section {
                    if let id = identity?.publicIdentity {
                        VStack(spacing: 16) {
                            // Avatar — tap to change
                            PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                                if let data = appState.myAvatarData, let uiImage = UIImage(data: data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(Color.accentColor.opacity(0.3), lineWidth: 2))
                                } else {
                                    ZStack {
                                        Circle()
                                            .fill(Color.accentColor.opacity(0.12))
                                            .frame(width: 80, height: 80)
                                        Text(String(id.username.prefix(1)).uppercased())
                                            .font(.system(size: 36, weight: .bold))
                                            .foregroundStyle(Color.accentColor)
                                        Image(systemName: "camera.fill")
                                            .font(.caption)
                                            .foregroundStyle(.white)
                                            .padding(5)
                                            .background(Color.accentColor)
                                            .clipShape(Circle())
                                            .offset(x: 26, y: 26)
                                    }
                                }
                            }
                            .onChange(of: avatarPickerItem) { _, item in
                                guard let item else { return }
                                Task {
                                    if let data = try? await item.loadTransferable(type: Data.self),
                                       let img  = UIImage(data: data) {
                                        appState.setMyAvatar(img)
                                    }
                                    avatarPickerItem = nil
                                }
                            }

                            VStack(spacing: 4) {
                                Text(id.username)
                                    .font(.title3.bold())
                                Text("Peer ID: \(id.peerID.prefix(16))…")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Button("Change Username") {
                                        renameText = id.username
                                        showingRenameAlert = true
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                    .tint(.accentColor)

                                    if appState.myAvatarData != nil {
                                        Button("Remove Photo", role: .destructive) {
                                            appState.removeMyAvatar()
                                        }
                                        .font(.caption)
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                    }
                }

                // Share contact link
                Section {
                    if let link = appState.generateInviteLink() {
                        ShareLink(item: link, subject: Text("Add me on SophaxChat"),
                                  message: Text("Tap to add me as a contact in SophaxChat — encrypted, serverless, no account needed.")) {
                            Label("Share Contact Link", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("Invite")
                } footer: {
                    Text("Share this link so others can add you as a contact — no Bluetooth or WiFi needed.")
                }

                // Safety number
                Section {
                    if let safetyNumber = identity?.publicIdentity.safetyNumber {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Your Safety Number", systemImage: "checkmark.shield.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)

                            let groups = safetyNumber.split(separator: " ")
                            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 8) {
                                ForEach(groups, id: \.self) { group in
                                    Text(group)
                                        .font(.system(.footnote, design: .monospaced).bold())
                                        .padding(8)
                                        .background(Color(.tertiarySystemGroupedBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }

                            Text("Share this with contacts to verify your identity out-of-band.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Identity Verification")
                }

                // Security info
                Section {
                    Label("End-to-end encrypted", systemImage: "lock.fill")
                        .foregroundStyle(.green)
                    Label("No servers — P2P only", systemImage: "wifi.slash")
                        .foregroundStyle(.blue)
                    Label("Anonymous — no account needed", systemImage: "person.slash")
                        .foregroundStyle(.purple)
                    Label("Keys stored in iOS Keychain", systemImage: "key.shield")
                        .foregroundStyle(.orange)

                    if appState.opkCount < 5 {
                        HStack {
                            Label("One-time prekeys low (\(appState.opkCount) left)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Regenerate") {
                                appState.chatManager?.replenishPreKeys()
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .font(.caption)
                        }
                    }
                } header: {
                    Text("Security")
                }

                // Open source link
                Section {
                    Link(destination: URL(string: "https://github.com/SophaxTechnologies/SophaxChat")!) {
                        HStack {
                            Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("GitHub")
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Open Source")
                } footer: {
                    Text("SophaxChat is fully open-source. Audit the code at github.com/SophaxTechnologies/SophaxChat")
                }
            }
            .navigationTitle("My Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Change Username", isPresented: $showingRenameAlert) {
                TextField("New username", text: $renameText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save") {
                    appState.changeUsername(renameText)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your new username will be shared with nearby peers.")
            }
        }
    }
}

#Preview {
    IdentityView().environmentObject(AppState())
}
