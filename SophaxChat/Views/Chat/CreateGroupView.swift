// CreateGroupView.swift
// SophaxChat
//
// Sheet for creating a new encrypted group conversation.
// The creator names the group and selects members from known peers.

import SwiftUI
import SophaxChatCore

struct CreateGroupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var groupName:        String = ""
    @State private var selectedPeerIDs:  Set<String> = []
    /// Defaults to true — MLS is preferred when all members support it.
    /// Auto-updated as the member selection changes.
    @State private var useMLS:           Bool = true
    @FocusState private var nameFocused: Bool

    private var allSelectedPeersHaveKeyPackage: Bool {
        selectedPeerIDs.allSatisfy { appState.peerHasMLSKeyPackage($0) }
    }

    private var canCreate: Bool {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64, !selectedPeerIDs.isEmpty else { return false }
        if useMLS && !allSelectedPeersHaveKeyPackage { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group name", text: $groupName)
                        .focused($nameFocused)
                        .autocorrectionDisabled()
                } header: {
                    Text("Group Name")
                }

                Section {
                    Toggle(isOn: $useMLS) {
                        Label("MLS (Post-Compromise Security)", systemImage: "lock.shield")
                    }
                    .disabled(!selectedPeerIDs.isEmpty && !allSelectedPeersHaveKeyPackage)
                } header: {
                    Text("Encryption Protocol")
                } footer: {
                    if useMLS {
                        if allSelectedPeersHaveKeyPackage || selectedPeerIDs.isEmpty {
                            Text("MLS (RFC 9420) is the default — provides post-compromise security per epoch. All members must have exchanged keys with you at least once.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("One or more selected members have not yet exchanged MLS keys. The group will use Sender Keys v2 instead. Ask them to open SophaxChat while nearby, then upgrade later.")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("Sender Keys v2 — Signal-style per-sender chains. Enable MLS for RFC 9420 post-compromise security.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if appState.peers.isEmpty {
                        Text("No nearby peers found. Make sure other devices have SophaxChat open.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(appState.peers.filter { !appState.isBlocked($0.id) }, id: \.id) { peer in
                            Button {
                                if selectedPeerIDs.contains(peer.id) {
                                    selectedPeerIDs.remove(peer.id)
                                } else {
                                    selectedPeerIDs.insert(peer.id)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    PeerAvatar(peer: peer, size: 36)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(appState.displayName(for: peer))
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        if appState.onlinePeers.contains(peer.id) {
                                            Text("Online")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    Spacer()
                                    if selectedPeerIDs.contains(peer.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Add Members")
                } footer: {
                    if !selectedPeerIDs.isEmpty {
                        Text("\(selectedPeerIDs.count) member\(selectedPeerIDs.count == 1 ? "" : "s") selected (plus you)")
                    }
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            // Auto-select MLS when all chosen members support it; fall back to SKv2 when not.
            // The user can still override the toggle manually.
            .onChange(of: selectedPeerIDs) {
                if !selectedPeerIDs.isEmpty {
                    useMLS = allSelectedPeersHaveKeyPackage
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if useMLS {
                            appState.createMLSGroup(name: name, memberPeerIDs: Array(selectedPeerIDs))
                        } else {
                            appState.createGroup(name: name, memberPeerIDs: Array(selectedPeerIDs))
                        }
                        dismiss()
                    }
                    .disabled(!canCreate)
                    .fontWeight(.semibold)
                }
            }
            .onAppear { nameFocused = true }
        }
    }
}

#Preview {
    CreateGroupView().environmentObject(AppState())
}
