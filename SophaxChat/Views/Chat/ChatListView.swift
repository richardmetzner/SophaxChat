// ChatListView.swift
// SophaxChat
//
// Main screen: list of conversations + nearby peers.

import SwiftUI
import SophaxChatCore

struct ChatListView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("com.sophax.gettingStartedDismissed") private var gettingStartedDismissed = false
    @State private var showingIdentity    = false
    @State private var showingSettings    = false
    @State private var showingCreateGroup = false
    @State private var showingScanner     = false
    @State private var peerToBlock: KnownPeer? = nil
    @State private var reconnectBannerPeer: KnownPeer? = nil
    @State private var keyChangePeerID: String? = nil

    private var showGettingStartedCard: Bool {
        appState.peers.filter({ !appState.isBlocked($0.id) }).isEmpty
        && appState.groups.isEmpty
        && !gettingStartedDismissed
    }

    var body: some View {
        NavigationStack {
            List {
                // Local AI assistant — always at the top
                NavigationLink(destination: AIAssistantView()) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.purple.opacity(0.12))
                                .frame(width: 48, height: 48)
                            Image(systemName: "sparkles")
                                .font(.system(size: 20))
                                .foregroundStyle(.purple)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Assistant")
                                .font(.subheadline.weight(.semibold))
                            Text("Local · Private · On-device")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                // Active conversations (peers with messages, not blocked)
                let conversationPeers = appState.peers.filter {
                    appState.messages[$0.id] != nil && !appState.isBlocked($0.id)
                }
                if !conversationPeers.isEmpty {
                    Section("Conversations") {
                        ForEach(conversationPeers) { peer in
                            NavigationLink(destination: ChatView(peer: peer)) {
                                ConversationRow(
                                    peer: peer,
                                    messages: appState.messages[peer.id] ?? [],
                                    unreadCount: appState.unreadCounts[peer.id] ?? 0
                                )
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    appState.deleteConversation(peerID: peer.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    peerToBlock = peer
                                } label: {
                                    Label("Block", systemImage: "nosign")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }

                if !appState.groups.isEmpty {
                    Section("Groups") {
                        ForEach(appState.groups) { group in
                            NavigationLink(destination: GroupChatView(group: group)) {
                                GroupConversationRow(group: group)
                            }
                        }
                    }
                }

                // Nearby channels — groups announced by peers the local user hasn't joined
                let nearbyChannels = Array(appState.discoveredChannels.values)
                    .sorted { $0.groupName < $1.groupName }
                if !nearbyChannels.isEmpty {
                    Section {
                        ForEach(nearbyChannels, id: \.groupID) { channel in
                            NearbyChannelRow(channel: channel)
                        }
                    } header: {
                        Text("Nearby Channels")
                    } footer: {
                        Text("Groups advertised by nearby peers. Contact the creator to request an invite.")
                            .font(.caption2)
                    }
                }

                // Online peers without conversations yet
                let newPeers = appState.peers.filter {
                    appState.messages[$0.id] == nil
                    && appState.onlinePeers.contains($0.id)
                    && !appState.isBlocked($0.id)
                }
                if !newPeers.isEmpty {
                    Section("Nearby") {
                        ForEach(newPeers) { peer in
                            NavigationLink(destination: ChatView(peer: peer)) {
                                PeerRow(peer: peer, isOnline: true)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    peerToBlock = peer
                                } label: {
                                    Label("Block", systemImage: "nosign")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }

                if showGettingStartedCard {
                    Section {
                        GettingStartedCard(dismiss: { gettingStartedDismissed = true })
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                } else if appState.peers.filter({ !appState.isBlocked($0.id) }).isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 40))
                                .foregroundStyle(.tertiary)
                            Text("No conversations yet")
                                .font(.subheadline.weight(.medium))
                            Button {
                                showingIdentity = true
                            } label: {
                                Label("Share My Contact", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                            .tint(.accentColor)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("SophaxChat")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Button {
                            showingCreateGroup = true
                        } label: {
                            Image(systemName: "person.2.badge.plus")
                        }
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        Button {
                            showingIdentity = true
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
            }
        }
        .onChange(of: appState.reconnectedPeer?.id) { _, peerID in
            reconnectBannerPeer = appState.reconnectedPeer
        }
        .overlay(alignment: .top) {
            if let peer = reconnectBannerPeer {
                HStack(spacing: 8) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("\(appState.displayName(for: peer)) is back online")
                        .font(.subheadline)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { withAnimation { reconnectBannerPeer = nil } }
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { reconnectBannerPeer = nil }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: reconnectBannerPeer?.id)
        .onChange(of: appState.keyChangeAlerts) { _, alerts in
            if let peerID = alerts.last {
                keyChangePeerID = peerID
            }
        }
        .alert("Security Key Changed", isPresented: Binding(
            get: { keyChangePeerID != nil },
            set: { if !$0 { keyChangePeerID = nil } }
        ), presenting: keyChangePeerID) { peerID in
            Button("Verify Now") {
                keyChangePeerID = nil
            }
            Button("Dismiss", role: .cancel) {
                keyChangePeerID = nil
                appState.keyChangeAlerts.removeAll { $0 == peerID }
            }
        } message: { peerID in
            let name = appState.peers.first(where: { $0.id == peerID }).map { appState.displayName(for: $0) } ?? peerID
            Text("\(name)'s identity key has changed. Open the conversation and verify their Safety Number to confirm this is expected.")
        }
        .sheet(isPresented: $showingIdentity) {
            IdentityView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sophaxShowSettings)) { _ in
            showingSettings = true
        }
        .sheet(isPresented: $showingCreateGroup) {
            CreateGroupView()
        }
        .sheet(isPresented: $showingScanner) {
            ContactScannerView().environmentObject(appState)
        }
        .alert("Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        ), presenting: appState.errorMessage) { _ in
            Button("OK") { appState.errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .confirmationDialog(
            "Block \(peerToBlock?.username ?? "")?",
            isPresented: Binding(get: { peerToBlock != nil }, set: { if !$0 { peerToBlock = nil } }),
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                if let peer = peerToBlock {
                    appState.blockPeer(peerID: peer.id)
                }
                peerToBlock = nil
            }
            Button("Cancel", role: .cancel) { peerToBlock = nil }
        } message: {
            Text("You won't receive messages from this person. This can be undone in Settings.")
        }
    }
}

// MARK: - Group Conversation Row

struct GroupConversationRow: View {
    @EnvironmentObject var appState: AppState
    let group: GroupInfo

    private var lastMessage: StoredMessage? {
        appState.messages[group.conversationID]?.last
    }
    private var unreadCount: Int {
        appState.unreadCounts[group.conversationID] ?? 0
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(group.name)
                        .font(.subheadline.weight(unreadCount > 0 ? .bold : .semibold))
                    Spacer()
                    if let last = lastMessage {
                        Text(last.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    Text("\(group.memberIDs.count) members")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let last = lastMessage {
                        Text("· \(last.body)")
                            .font(.subheadline)
                            .foregroundStyle(unreadCount > 0 ? .primary : .secondary)
                            .fontWeight(unreadCount > 0 ? .medium : .regular)
                            .lineLimit(1)
                    }
                    Spacer()
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Nearby Channel Row

/// Row shown for groups announced by nearby peers that the local user hasn't joined.
struct NearbyChannelRow: View {
    @EnvironmentObject var appState: AppState
    let channel: ChannelAnnouncement

    /// The peer that created the channel, so the user can tap to open a DM.
    private var creatorPeer: KnownPeer? {
        appState.peers.first { $0.id == channel.creatorID }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.groupName)
                    .font(.subheadline.weight(.semibold))
                Text("\(channel.memberCount) member\(channel.memberCount == 1 ? "" : "s") · Contact creator to join")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.right.circle")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    @EnvironmentObject var appState: AppState
    let peer: KnownPeer
    let messages: [StoredMessage]
    let unreadCount: Int

    var lastMessage: StoredMessage? { messages.last }

    var body: some View {
        HStack(spacing: 12) {
            PeerAvatar(peer: peer, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(appState.displayName(for: peer))
                        .font(.subheadline.weight(unreadCount > 0 ? .bold : .semibold))
                    Spacer()
                    if let last = lastMessage {
                        Text(last.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    if let last = lastMessage {
                        if last.direction == .sent {
                            statusIcon(for: last.status)
                        }
                        Text(last.body)
                            .font(.subheadline)
                            .foregroundStyle(unreadCount > 0 ? .primary : .secondary)
                            .fontWeight(unreadCount > 0 ? .medium : .regular)
                            .lineLimit(1)
                    }
                    Spacer()
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    } else if peer.isOnline {
                        Circle().fill(.green).frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusIcon(for status: StoredMessage.MessageStatus) -> some View {
        switch status {
        case .sending:
            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
        case .delivered:
            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .read:
            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(Color.accentColor)
        case .failed:
            Image(systemName: "exclamationmark.circle").font(.caption2).foregroundStyle(.red)
        }
    }
}

// MARK: - Peer Row (no messages yet)

struct PeerRow: View {
    @EnvironmentObject var appState: AppState
    let peer: KnownPeer
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 12) {
            PeerAvatar(peer: peer, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.displayName(for: peer))
                    .font(.subheadline.weight(.medium))
                Text("Tap to send a message")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isOnline {
                Circle().fill(.green).frame(width: 8, height: 8)
            }
        }
    }
}

// MARK: - Peer Avatar

struct PeerAvatar: View {
    @EnvironmentObject var appState: AppState
    let peer: KnownPeer
    let size: CGFloat

    private var avatarColor: Color {
        let hash = peer.id.prefix(6)
        let value = Int(hash, radix: 16) ?? 0
        let hue = Double(value % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    private var initials: String {
        peer.username.prefix(1).uppercased()
    }

    var body: some View {
        if let data = appState.peerAvatars[peer.id], let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle()
                    .fill(avatarColor.opacity(0.2))
                    .frame(width: size, height: size)
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(avatarColor)
            }
        }
    }
}

// MARK: - Getting Started Card

private struct GettingStartedCard: View {
    @EnvironmentObject var appState: AppState
    let dismiss: () -> Void
    @State private var showingIdentity = false
    @State private var showingScanner  = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Get started")
                        .font(.headline)
                    Text("Connect with people nearby or anywhere in the world.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            CardActionRow(
                icon: "square.and.arrow.up",
                iconColor: .accentColor,
                title: "Share my contact",
                subtitle: "Let others add you by scanning a QR code"
            ) { showingIdentity = true }

            Divider().padding(.leading, 56)

            CardActionRow(
                icon: "qrcode.viewfinder",
                iconColor: .green,
                title: "Scan a QR code",
                subtitle: "Add someone who's nearby"
            ) { showingScanner = true }

            Divider().padding(.leading, 56)

            CardActionRow(
                icon: "globe",
                iconColor: .orange,
                title: "Enable Global Reach",
                subtitle: "Chat with anyone, anywhere in the world"
            ) {
                NotificationCenter.default.post(name: .sophaxShowSettings, object: nil)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .sheet(isPresented: $showingIdentity) {
            IdentityView().environmentObject(appState)
        }
        .sheet(isPresented: $showingScanner) {
            ContactScannerView().environmentObject(appState)
        }
    }
}

private struct CardActionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundStyle(iconColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ChatListView().environmentObject(AppState())
}
