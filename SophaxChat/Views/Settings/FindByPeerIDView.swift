// FindByPeerIDView.swift
// SophaxChat
//
// Lets the user enter a 16-character peerID and resolve it to a contact
// via the Kademlia DHT network (requires Tor to be running).

import SwiftUI
import SophaxChatCore

struct FindByPeerIDView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var peerIDInput  = ""
    @State private var isSearching  = false
    @State private var foundPeer:   KnownPeer? = nil
    @State private var errorText:   String? = nil

    // Navigation path so we can push into ChatView after "Start Chat"
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            Form {
                // MARK: Input
                Section {
                    HStack {
                        TextField("16-character peer ID", text: $peerIDInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: peerIDInput) { _, v in
                                // Clamp to 16 hex chars
                                peerIDInput = String(v.lowercased()
                                    .filter { $0.isHexDigit }
                                    .prefix(16))
                                foundPeer = nil
                                errorText = nil
                            }
                        if !peerIDInput.isEmpty {
                            Button {
                                peerIDInput = ""
                                foundPeer   = nil
                                errorText   = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Peer ID")
                } footer: {
                    Text("Enter the 16-character ID shown on another user's Contact Card (under their username).")
                }

                // MARK: Search button
                Section {
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSearching {
                                ProgressView()
                                    .padding(.trailing, 6)
                                Text("Searching DHT…")
                            } else {
                                Label("Find via DHT", systemImage: "network")
                            }
                            Spacer()
                        }
                    }
                    .disabled(peerIDInput.count != 16 || isSearching)
                }

                // MARK: Error
                if let err = errorText {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                // MARK: Result
                if let peer = foundPeer {
                    Section("Found") {
                        PeerResultRow(peer: peer)

                        Button {
                            dismiss()
                            // Post notification so ChatListView can navigate to ChatView
                            NotificationCenter.default.post(
                                name: .sophaxOpenChat,
                                object: peer
                            )
                        } label: {
                            Label("Start Chat", systemImage: "bubble.left.and.bubble.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Find by Peer ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: KnownPeer.self) { peer in
                ChatView(peer: peer)
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Search

    private func search() async {
        isSearching = true
        foundPeer   = nil
        errorText   = nil
        do {
            foundPeer = try await appState.lookupPeerViaDHT(peerID: peerIDInput)
        } catch {
            errorText = lookupErrorMessage(error)
        }
        isSearching = false
    }

    private func lookupErrorMessage(_ error: Error) -> String {
        if TorManager.shared.state != .ready {
            return "Tor is not connected. Enable Tor in Settings and wait for it to bootstrap."
        }
        if appState.chatManager?.dhtEngine == nil {
            return "DHT is not running. Make sure Tor is enabled and restart the app."
        }
        return "Peer not found. They may be offline or not yet reachable over the DHT network."
    }
}

// MARK: - Peer result row

private struct PeerResultRow: View {
    @EnvironmentObject var appState: AppState
    let peer: KnownPeer

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                if let data = appState.peerAvatars[peer.id],
                   let uiImg = UIImage(data: data) {
                    Image(uiImage: uiImg)
                        .resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                } else {
                    Text(String(peer.username.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.displayName(for: peer))
                    .font(.headline)
                Text(peer.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let addr = peer.tcpAddress {
                    Text(addr)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .padding(.vertical, 4)
    }
}
