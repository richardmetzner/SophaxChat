// SettingsView.swift
// SophaxChat
//
// App settings: blocked peers and other user preferences.

import SwiftUI
import SophaxChatCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var tcpConnectAddress: String = ""
    @State private var showTCPConnectAlert: Bool  = false
    @State private var tcpConnectError: String?   = nil
    @State private var showingContactCard: Bool   = false
    @State private var useCustomAddress: Bool     = false

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
                // Blocked peers
                Section {
                    if blockedList.isEmpty {
                        Text("No blocked users")
                            .foregroundStyle(.secondary)
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
                                Button("Unblock") {
                                    appState.unblockPeer(peerID: entry.id)
                                }
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

                // App lock
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

                // Internet mode — Tor-first
                Section {
                    Toggle("Internet Mode", isOn: $appState.tcpEnabled)

                    if appState.tcpEnabled {
                        // ── Your Tor address (auto-derived from identity key) ─────────────
                        if let onionAddress = appState.derivedOnionAddress {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text("Your Tor Address")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    // Orbot status indicator
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(appState.isOrbotDetected ? Color.green : Color.secondary.opacity(0.5))
                                            .frame(width: 8, height: 8)
                                        Text(appState.isOrbotDetected ? "Orbot active" : "Orbot offline")
                                            .font(.caption2)
                                            .foregroundStyle(appState.isOrbotDetected ? .green : .secondary)
                                    }
                                }
                                Text(onionAddress)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                HStack(spacing: 8) {
                                    Button {
                                        UIPasteboard.general.string = onionAddress
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    Button {
                                        showingContactCard = true
                                    } label: {
                                        Label("Share Card", systemImage: "qrcode")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        // ── Orbot install prompt (if not detected) ───────────────────────
                        if !appState.isOrbotDetected {
                            Link(destination: URL(string: "https://apps.apple.com/app/orbot/id1609461599")!) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Install Orbot — Tor VPN")
                                            .foregroundStyle(.primary)
                                        Text("Enable VPN mode in Orbot to accept connections")
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

                        // ── Advanced: custom address override ────────────────────────────
                        Toggle("Use Custom Address", isOn: $useCustomAddress)
                            .font(.subheadline)
                        if useCustomAddress {
                            HStack {
                                Text("My Address")
                                Spacer()
                                TextField("host:port or .onion:25519", text: $appState.myTCPAddress)
                                    .keyboardType(.asciiCapable)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .multilineTextAlignment(.trailing)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // ── Advanced: manual SOCKS5 proxy ────────────────────────────────
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
                            Text("TCP Port")
                            Spacer()
                            TextField("25519", text: $appState.tcpPort)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .foregroundStyle(.secondary)
                        }

                        // ── Direct connect ────────────────────────────────────────────────
                        HStack {
                            TextField("host:port", text: $tcpConnectAddress)
                                .keyboardType(.asciiCapable)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button("Connect") {
                                if let err = appState.connectViaTCP(address: trimmedTCPAddress) {
                                    tcpConnectError    = err
                                    showTCPConnectAlert = true
                                } else {
                                    tcpConnectAddress = ""
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(trimmedTCPAddress.isEmpty)
                        }
                    }
                } header: {
                    Text("Internet Mode")
                } footer: {
                    if appState.tcpEnabled {
                        Text("Your Tor address is derived from your identity key — it's permanent and requires no server. Install Orbot and enable VPN mode to accept incoming connections. Share your card with contacts so they can reach you from anywhere in the world.")
                    } else {
                        Text("Extend beyond local Bluetooth/WiFi. Your Tor address is derived from your identity key — permanent, anonymous, no registration needed.")
                    }
                }
                .sheet(isPresented: $showingContactCard) {
                    ContactCardView().environmentObject(appState)
                }

                #if SUPPORT_ENABLED
                Section {
                    Link(destination: URL(string: "https://github.com/sophaxtechnologies/SophaxChat#support")!) {
                        Label("Support SophaxChat", systemImage: "heart.fill")
                            .foregroundStyle(.pink)
                    }
                    Link(destination: URL(string: "https://github.com/sophaxtechnologies/SophaxChat")!) {
                        Label("View Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                            .foregroundStyle(.primary)
                    }
                } footer: {
                    Text("SophaxChat is free, open-source, and server-free. If it's useful to you, consider supporting it — via Bitcoin or Monero, no account needed.")
                }
                #endif

                // App info
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
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
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

#Preview {
    SettingsView().environmentObject(AppState())
}
