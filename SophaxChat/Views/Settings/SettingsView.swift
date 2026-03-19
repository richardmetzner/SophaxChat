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
            Toggle("Connect Globally", isOn: Binding(
                get: { appState.tcpEnabled },
                set: { enabled in
                    appState.tcpEnabled = enabled
                    if enabled && !UserDefaults.standard.bool(forKey: "com.sophax.tor.onboardingShown") {
                        showingTorOnboarding = true
                        UserDefaults.standard.set(true, forKey: "com.sophax.tor.onboardingShown")
                    }
                }
            ))
            if appState.tcpEnabled {
                orbotRow
                advancedGroup
            }
        } header: {
            Text("Global")
        } footer: {
            Text(appState.tcpEnabled
                 ? "Messages stay end-to-end encrypted. No server, no account — your identity is your address."
                 : "Reach anyone in the world, not just nearby. Uses Tor for anonymity.")
        }
    }

    @ViewBuilder
    private var orbotRow: some View {
        if appState.isOrbotDetected {
            Button { showingContactCard = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Share your address to connect with anyone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "qrcode").foregroundStyle(.secondary)
                }
            }
        } else {
            Link(destination: URL(string: "https://apps.apple.com/app/orbot/id1609461599")!) {
                HStack(spacing: 14) {
                    Image(systemName: "globe.badge.chevron.backward")
                        .font(.title2)
                        .foregroundStyle(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Install Orbot")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Enable Tor VPN inside Orbot — that's it")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var advancedGroup: some View {
        DisclosureGroup("Advanced") {
            HStack {
                Text("SOCKS5 Proxy")
                Spacer()
                TextField("127.0.0.1:9050", text: $appState.tcpSocksProxy)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Port")
                Spacer()
                TextField("25519", text: $appState.tcpPort)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Custom Address")
                Spacer()
                TextField("host:port", text: $appState.myTCPAddress)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Connect to host:port", text: $tcpConnectAddress)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Connect") {
                    if let err = appState.connectViaTCP(address: trimmedTCPAddress) {
                        tcpConnectError     = err
                        showTCPConnectAlert = true
                    } else {
                        tcpConnectAddress = ""
                    }
                }
                .buttonStyle(.bordered)
                .disabled(trimmedTCPAddress.isEmpty)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
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
