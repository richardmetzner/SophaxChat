// SettingsView.swift
// SophaxChat

import SwiftUI
import SophaxChatCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var tcpConnectAddress: String = ""
    @State private var showTCPConnectAlert: Bool  = false
    @State private var tcpConnectError: String?   = nil
    @State private var showingContactCard: Bool   = false
    @State private var showingTorOnboarding: Bool = false
    @State private var showingBackup: Bool        = false

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
                blockedSection
                securitySection
                globalSection
                backupSection
                aboutSection
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
            .sheet(isPresented: $showingTorOnboarding) {
                TorOnboardingView()
            }
            .sheet(isPresented: $showingBackup) {
                BackupView().environmentObject(appState)
            }
        }
    }

    // MARK: - Sections

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
                set: { enabled in
                    appState.tcpEnabled = enabled
                    if enabled && !UserDefaults.standard.bool(forKey: "com.sophax.tor.onboardingShown") {
                        showingTorOnboarding = true
                        UserDefaults.standard.set(true, forKey: "com.sophax.tor.onboardingShown")
                    }
                }
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
                torStatusCard
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

    @ViewBuilder
    private var torStatusCard: some View {
        if appState.isOrbotDetected {
            // Tor is running — show share card
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
                        Text("Share your address so others can reach you")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "qrcode")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } else {
            // Tor not running — guide user
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.orange.opacity(0.12)).frame(width: 44, height: 44)
                        Image(systemName: "lock.shield")
                            .font(.system(size: 20))
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add anonymity with Tor")
                            .font(.subheadline.weight(.semibold))
                        Text("Hides your IP address from the other person")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                #if targetEnvironment(macCatalyst)
                VStack(alignment: .leading, spacing: 6) {
                    Text("How to set up on Mac:")
                        .font(.caption.weight(.medium))
                    Label("Download Tor Browser at torproject.org", systemImage: "1.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("Open Tor Browser and keep it running", systemImage: "2.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("That's it — SophaxChat will use it automatically", systemImage: "3.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 58)
                Link("Download Tor Browser →", destination: URL(string: "https://www.torproject.org/download/")!)
                    .font(.caption.weight(.medium))
                    .padding(.leading, 58)
                #else
                VStack(alignment: .leading, spacing: 6) {
                    Text("How to set up on iPhone:")
                        .font(.caption.weight(.medium))
                    Label("Install Orbot from the App Store", systemImage: "1.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("Open Orbot and turn on the VPN", systemImage: "2.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("Come back here — it will say \"ready\"", systemImage: "3.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 58)
                Link("Get Orbot on App Store →", destination: URL(string: "https://apps.apple.com/app/orbot/id1609461599")!)
                    .font(.caption.weight(.medium))
                    .padding(.leading, 58)
                #endif
            }
            .padding(.vertical, 6)
        }
    }

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
    private var aboutSection: some View {
        Section {
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
            Text("About")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

#Preview {
    SettingsView().environmentObject(AppState())
}
