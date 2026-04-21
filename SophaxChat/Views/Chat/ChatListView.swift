// ChatListView.swift
// SophaxChat
//
// Main screen: list of conversations + nearby peers.

import SwiftUI
import SophaxChatCore

struct ChatListView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @AppStorage("com.sophax.gettingStartedDismissed") private var gettingStartedDismissed = false
    @State private var showingIdentity    = false
    @State private var showingSettings    = false
    @State private var showingCreateGroup = false
    @State private var showingScanner     = false
    @State private var peerToBlock: KnownPeer? = nil
    @State private var groupToLeave:        GroupInfo? = nil
    @State private var groupToDelete:       GroupInfo? = nil
    @State private var groupToDeleteLocally: GroupInfo? = nil
    @State private var reconnectBannerPeer: KnownPeer? = nil
    @State private var keyChangePeerID: String? = nil
    @State private var showingAddByLink    = false
    @State private var pastedInviteLink    = ""
    @State private var inviteLinkError: String? = nil
    @State private var showingFindByPeerID = false
    @State private var dhtFoundPeer: KnownPeer? = nil

    private var showGettingStartedCard: Bool {
        appState.peers.filter({ !appState.isBlocked($0.id) }).isEmpty
        && appState.groups.isEmpty
        && !gettingStartedDismissed
    }

    var body: some View {
        Group {
            if hSizeClass == .regular {
                splitBody
            } else {
                stackBody
            }
        }

    // MARK: - iPad split view

    private var splitBody: some View {
        NavigationSplitView {
            conversationList
                .navigationDestination(for: KnownPeer.self) { peer in
                    ChatView(peer: peer)
                }
                .navigationDestination(for: GroupInfo.self) { group in
                    GroupChatView(group: group)
                }
                .navigationDestination(for: AIDestination.self) { _ in AIAssistantView() }
                .navigationDestination(for: NoteToSelfDestination.self) { _ in NoteToSelfView() }
        } detail: {
            emptyDetailView
        }
    }

    private var emptyDetailView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("Select a conversation")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - iPhone stack

    private var stackBody: some View {
        NavigationStack {
            conversationList
                .navigationDestination(for: KnownPeer.self) { peer in
                    ChatView(peer: peer)
                }
                .navigationDestination(for: GroupInfo.self) { group in
                    GroupChatView(group: group)
                }
                .navigationDestination(for: AIDestination.self) { _ in AIAssistantView() }
                .navigationDestination(for: NoteToSelfDestination.self) { _ in NoteToSelfView() }
        }
    }

    // MARK: - Shared list content

    private var conversationList: some View {
        List {
            // Local AI assistant — always at the top
            NavigationLink(value: AIDestination.assistant) {
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

            NavigationLink(value: NoteToSelfDestination.noteToSelf) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.yellow.opacity(0.12))
                            .frame(width: 48, height: 48)
                        Image(systemName: "lock.doc.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.yellow)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Note to Self")
                            .font(.subheadline.weight(.semibold))
                        Text("Encrypted — local only")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            // Pending contact requests
            if !appState.pendingContactRequests.isEmpty {
                Section("Contact Requests") {
                    ForEach(appState.pendingContactRequests) { peer in
                        ContactRequestRow(peer: peer,
                            onAccept: { appState.acceptContact(peer) },
                            onReject: { appState.rejectContact(peer) })
                    }
                }
            }

            // Active conversations (peers with messages, not blocked)
            let conversationPeers = appState.peers.filter {
                appState.messages[$0.id] != nil && !appState.isBlocked($0.id)
            }
            if !conversationPeers.isEmpty {
                Section("Conversations") {
                    ForEach(conversationPeers) { peer in
                        NavigationLink(value: peer) {
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
                        NavigationLink(value: group) {
                            GroupConversationRow(group: group)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                groupToLeave = group
                            } label: {
                                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            if group.creatorID == appState.chatManager?.identity.publicIdentity.peerID {
                                Button(role: .destructive) {
                                    groupToDelete = group
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } else {
                                Button(role: .destructive) {
                                    groupToDeleteLocally = group
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }

            // Pending join requests — someone wants to join a group we created
            if !appState.pendingGroupJoinRequests.isEmpty {
                Section {
                    ForEach(appState.pendingGroupJoinRequests, id: \.requesterPeerID) { req in
                        GroupJoinRequestRow(request: req)
                    }
                } header: {
                    Text("Join Requests")
                } footer: {
                    Text("Peers who want to join your group. Invite them or dismiss.")
                        .font(.caption2)
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
                    Text("Groups advertised by nearby peers. Tap a channel to request an invite.")
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
                        NavigationLink(value: peer) {
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
                HStack(spacing: 4) {
                    Button {
                        showingScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    Button {
                        showingAddByLink = true
                        pastedInviteLink = ""
                        inviteLinkError  = nil
                    } label: {
                        Image(systemName: "link.badge.plus")
                    }
                    Button {
                        showingFindByPeerID = true
                    } label: {
                        Image(systemName: "person.badge.magnifyingglass")
                    }
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
        .sheet(isPresented: $showingAddByLink) {
            addByLinkSheet
        }
        .sheet(isPresented: $showingFindByPeerID) {
            FindByPeerIDView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sophaxOpenChat)) { note in
            if let peer = note.object as? KnownPeer {
                dhtFoundPeer = peer
            }
        }
        .navigationDestination(item: $dhtFoundPeer) { peer in
            ChatView(peer: peer)
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
        .confirmationDialog(
            "Leave \"\(groupToLeave?.name ?? "")\"?",
            isPresented: Binding(get: { groupToLeave != nil }, set: { if !$0 { groupToLeave = nil } }),
            titleVisibility: .visible
        ) {
            Button("Leave Group", role: .destructive) {
                if let g = groupToLeave { appState.leaveGroup(g) }
                groupToLeave = nil
            }
            Button("Cancel", role: .cancel) { groupToLeave = nil }
        } message: {
            Text("You will no longer receive messages from this group. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete \"\(groupToDelete?.name ?? "")\" for everyone?",
            isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                if let g = groupToDelete { appState.deleteGroup(g) }
                groupToDelete = nil
            }
            Button("Cancel", role: .cancel) { groupToDelete = nil }
        } message: {
            Text("All members will lose access to this group immediately. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete \"\(groupToDeleteLocally?.name ?? "")\"?",
            isPresented: Binding(get: { groupToDeleteLocally != nil }, set: { if !$0 { groupToDeleteLocally = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete from My Device", role: .destructive) {
                if let g = groupToDeleteLocally { appState.deleteGroupLocally(g) }
                groupToDeleteLocally = nil
            }
            Button("Cancel", role: .cancel) { groupToDeleteLocally = nil }
        } message: {
            Text("Messages will be deleted from your device only. Other members will not be notified.")
        }
    }

    // MARK: - Add by Link sheet

    @ViewBuilder private var addByLinkSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("sophaxchat://…", text: $pastedInviteLink, axis: .vertical)
                        .lineLimit(3...6)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("Paste invite link")
                } footer: {
                    Text("Paste a sophaxchat:// link shared by another user via any channel (iMessage, email, etc.).")
                }

                if let err = inviteLinkError {
                    Section { Text(err).foregroundStyle(.red) }
                }

                Section {
                    Button("Add Contact") {
                        processLink()
                    }
                    .disabled(pastedInviteLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Add by Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddByLink = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func processLink() {
        let raw = pastedInviteLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme == "sophaxchat" else {
            inviteLinkError = "Not a valid sophaxchat:// link."
            return
        }
        inviteLinkError  = nil
        showingAddByLink = false
        appState.handleIncomingLink(url)
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
                    if group.cryptoVersion == .mls {
                        Text("MLS")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.85))
                            .clipShape(Capsule())
                    }
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
/// Tap to send a DR-encrypted join request to the creator (queued if they're offline).
struct NearbyChannelRow: View {
    @EnvironmentObject var appState: AppState
    let channel: ChannelAnnouncement

    @State private var showingRequestConfirm = false
    @State private var requestSent = false

    var body: some View {
        Button { showingRequestConfirm = true } label: {
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
                        .foregroundStyle(.primary)
                    Text(requestSent
                         ? "Request sent · waiting for creator"
                         : "\(channel.memberCount) member\(channel.memberCount == 1 ? "" : "s") · Tap to request invite")
                        .font(.caption2)
                        .foregroundStyle(requestSent ? .green : .secondary)
                }
                Spacer()
                Image(systemName: requestSent ? "checkmark.circle" : "arrow.right.circle")
                    .foregroundStyle(requestSent ? .green : .tertiary)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .disabled(requestSent)
        .confirmationDialog(
            "Request to join "\(channel.groupName)"?",
            isPresented: $showingRequestConfirm,
            titleVisibility: .visible
        ) {
            Button("Send Join Request") {
                appState.sendChannelJoinRequest(for: channel)
                requestSent = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A join request will be sent to the group creator. They'll receive it even if they're currently offline.")
        }
    }
}

// MARK: - Group Join Request Row

/// Row shown for each pending join request received from a peer who wants to join our group.
struct GroupJoinRequestRow: View {
    @EnvironmentObject var appState: AppState
    let request: ChannelJoinRequestMessage

    private var requesterPeer: KnownPeer? {
        appState.peers.first { $0.id == request.requesterPeerID }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar or generic icon
            if let peer = requesterPeer {
                PeerAvatar(peer: peer, size: 44)
            } else {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.blue)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(requesterPeer.map { appState.displayName(for: $0) } ?? request.requesterUsername)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("Wants to join \"\(request.groupName)\"")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Approve / dismiss buttons
            HStack(spacing: 8) {
                Button {
                    appState.approveGroupJoinRequest(request)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)

                Button {
                    appState.dismissGroupJoinRequest(request)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
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

// MARK: - Contact Request Row

struct ContactRequestRow: View {
    @EnvironmentObject var appState: AppState
    let peer: KnownPeer
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PeerAvatar(peer: peer, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.username)
                    .font(.subheadline.weight(.semibold))
                Text(String(peer.id.prefix(8)) + "…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onReject) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            Button(action: onAccept) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
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

// MARK: - Navigation

/// Type-safe navigation destination for the AI assistant row.
private enum AIDestination: Hashable { case assistant }

/// Type-safe navigation destination for the Note to Self row.
private enum NoteToSelfDestination: Hashable { case noteToSelf }

// MARK: - Hashable conformances for NavigationLink(value:)

extension KnownPeer: @retroactive Hashable {
    public static func == (lhs: KnownPeer, rhs: KnownPeer) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension GroupInfo: @retroactive Hashable {
    public static func == (lhs: GroupInfo, rhs: GroupInfo) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
