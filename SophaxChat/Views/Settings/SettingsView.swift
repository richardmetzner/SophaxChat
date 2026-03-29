// SettingsView.swift
// SophaxChat

import SwiftUI
import SophaxChatCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    #if !targetEnvironment(macCatalyst)
    @ObservedObject private var torManager = TorManager.shared
    #endif

    @State private var tcpConnectAddress: String = ""
    @State private var showTCPConnectAlert: Bool  = false
    @State private var tcpConnectError: String?   = nil
    @State private var showingContactCard: Bool   = false
    @State private var showingBackup: Bool        = false
    @State private var showingIdentity: Bool      = false
    @State private var showingWipeConfirm: Bool   = false
    @State private var showingWipeConfirm2: Bool  = false

    private var trimmedTCPAddress: String {
        tcpConnectAddress.trimmingCharacters(in: .whitespaces)
    }

    var blockedList: [(id: String, name: String)] {
        appState.blockedPeers.sorted().map { id in
            let name = appState.blockedPeerNames[id] ?? String(id.prefix(12)) + "…"
            return (id: id, name: name)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                identitySection
                securitySection
                globalSection
                backupSection
                helpSection
                blockedSection
                dangerSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Connection Failed", isPresented: $showTCPConnectAlert) {
                Button("OK", role: .cancel) { tcpConnectError = nil }
            } message: {
                Text(tcpConnectError ?? "")
            }
            .sheet(isPresented: $showingContactCard) {
                ContactCardView().environmentObject(appState)
            }
            .sheet(isPresented: $showingBackup) {
                BackupView().environmentObject(appState)
            }
            .sheet(isPresented: $showingIdentity) {
                IdentityView().environmentObject(appState)
            }
            .confirmationDialog(
                "Delete account and all data?",
                isPresented: $showingWipeConfirm,
                titleVisibility: .visible
            ) {
                Button("Yes, delete everything", role: .destructive) {
                    showingWipeConfirm2 = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently erase your identity, all messages, and all attachments. There is no undo.")
            }
            .confirmationDialog(
                "Are you absolutely sure?",
                isPresented: $showingWipeConfirm2,
                titleVisibility: .visible
            ) {
                Button("Delete everything now", role: .destructive) {
                    dismiss()
                    appState.wipeAccount()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your identity keys will be destroyed. You cannot recover your account after this.")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var identitySection: some View {
        Section {
            Button { showingIdentity = true } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 40, height: 40)
                        Text(String(appState.myUsername?.prefix(1) ?? "?").uppercased())
                            .font(.headline.bold())
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.myUsername ?? "My Profile")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Identity, safety number, backup")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        } header: {
            Text("Profile")
        }
    }

    @ViewBuilder
    private var blockedSection: some View {
        Section {
            if blockedList.isEmpty {
                Text("No blocked users").foregroundStyle(.secondary)
            } else {
                ForEach(blockedList, id: \.id) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.subheadline.weight(.medium))
                            Text(String(entry.id.prefix(16)) + "…")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Unblock") { appState.unblockPeer(peerID: entry.id) }
                            .font(.subheadline)
                            .buttonStyle(.bordered)
                            .tint(.accentColor)
                    }
                }
            }
        } header: {
            Text("Blocked Users")
        } footer: {
            Text("Blocked users cannot send you messages. Unblocking allows future messages if they are nearby.")
        }
    }

    @ViewBuilder
    private var securitySection: some View {
        Section {
            Toggle("App Lock", isOn: Binding(
                get: { appState.appLockEnabled },
                set: { enabled in
                    appState.appLockEnabled = enabled
                    if !enabled { appState.isAppLocked = false }
                }
            ))
        } header: {
            Text("Security")
        } footer: {
            Text("Require Face ID, Touch ID, or passcode to open SophaxChat.")
        }
    }

    @ViewBuilder
    private var globalSection: some View {
        Section {
            // Main toggle
            Toggle(isOn: Binding(
                get: { appState.tcpEnabled },
                set: { appState.tcpEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chat with anyone in the world")
                        .font(.body)
                    Text("Not just people nearby — reach anyone, anywhere")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if appState.tcpEnabled {
                #if !targetEnvironment(macCatalyst)
                torStatusCard
                #endif
                connectCard
            }
        } header: {
            Text("Global Reach")
        } footer: {
            Text(appState.tcpEnabled
                 ? "Messages are always end-to-end encrypted. No server, no account — only you and the person you're chatting with."
                 : "Turn this on to chat with people anywhere in the world.")
        }
    }

    #if !targetEnvironment(macCatalyst)
    @ViewBuilder
    private var torStatusCard: some View {
        switch torManager.state {
        case .ready:
            Button { showingContactCard = true } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.green.opacity(0.12)).frame(width: 44, height: 44)
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.green)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Anonymous & ready")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Tor is running — share your address to receive messages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "qrcode")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

        case .starting:
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.10)).frame(width: 44, height: 44)
                    Image(systemName: "network")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Connecting to Tor…")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(torManager.bootstrapProgress)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(torManager.bootstrapProgress), total: 100)
                        .tint(Color.accentColor)
                }
            }
            .padding(.vertical, 4)

        case .failed(let reason):
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.red.opacity(0.10)).frame(width: 44, height: 44)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tor unavailable")
                        .font(.subheadline.weight(.semibold))
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

        case .stopped:
            EmptyView()
        }
    }
    #endif // !targetEnvironment(macCatalyst)

    @ViewBuilder
    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.10)).frame(width: 44, height: 44)
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect to someone")
                        .font(.subheadline.weight(.semibold))
                    Text("Enter the address they shared with you")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                TextField("e.g. abc123.onion:25519", text: $tcpConnectAddress)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button {
                    if let err = appState.connectViaTCP(address: trimmedTCPAddress) {
                        tcpConnectError = err
                        showTCPConnectAlert = true
                    } else {
                        tcpConnectAddress = ""
                    }
                } label: {
                    Text("Connect")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(trimmedTCPAddress.isEmpty ? Color(.systemGray4) : Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(trimmedTCPAddress.isEmpty)
            }
            .padding(.leading, 58)

            // Expert options — collapsed by default
            DisclosureGroup("Expert settings") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Warning: changing the proxy overrides Tor and exposes your IP. Only modify if you know exactly what you're doing.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.vertical, 4)
                }
                VStack(spacing: 0) {
                    HStack {
                        Text("Proxy")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("127.0.0.1:9050", text: $appState.tcpSocksProxy)
                            .keyboardType(.asciiCapable)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    Divider()
                    HStack {
                        Text("Port")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("25519", text: $appState.tcpPort)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    Divider()
                    HStack {
                        Text("My address")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("host:port", text: $appState.myTCPAddress)
                            .keyboardType(.asciiCapable)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.leading, 58)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var backupSection: some View {
        Section {
            Button {
                showingBackup = true
            } label: {
                Label("Backup & Restore", systemImage: "externaldrive.badge.checkmark")
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Encrypted local backup. No cloud, no server — you keep the key.")
        }
    }

    @ViewBuilder
    private var helpSection: some View {
        Section {
            Link(destination: URL(string: "https://github.com/SophaxTechnologies/SophaxChat")!) {
                HStack {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("GitHub")
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Version")
                Spacer()
                Text(appVersion).foregroundStyle(.secondary)
            }
            HStack {
                Text("Protocol")
                Spacer()
                Text("X3DH + Double Ratchet")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            HStack {
                Text("Transport")
                Spacer()
                Text(appState.tcpEnabled ? "BLE / WiFi + TCP" : "Bluetooth LE / WiFi Direct")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } header: {
            Text("Help & About")
        }
    }

    @ViewBuilder
    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showingWipeConfirm = true
            } label: {
                Label("Delete Account & All Data", systemImage: "trash.fill")
            }
        } header: {
            Text("Danger Zone")
        } footer: {
            Text("Permanently deletes your identity keys, all messages, and attachments. This cannot be undone.")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

#Preview {
    SettingsView().environmentObject(AppState())
}
