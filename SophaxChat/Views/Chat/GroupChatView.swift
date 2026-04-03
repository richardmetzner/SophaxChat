// GroupChatView.swift
// SophaxChat
//
// Chat view for an encrypted group conversation.

import SwiftUI
import SophaxChatCore
import PhotosUI
import AVFoundation

struct GroupChatView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo

    @State private var messageText: String = ""
    @FocusState private var isInputFocused: Bool

    // Disappearing messages
    @State private var disappearingInterval: DisappearingInterval = .off
    private var disappearingKey: String { "com.sophax.disappearingInterval.group.\(group.id)" }
    private var draftKey: String { "com.sophax.draft.group.\(group.id)" }

    // Attachment / camera
    @State private var photoPickerItem: PhotosPickerItem? = nil

    // PTT recording
    @StateObject private var voiceRecorder = VoiceRecorder()

    // Reply
    @State private var replyingTo: StoredMessage? = nil

    // Forward
    @State private var forwardingMessage: StoredMessage? = nil

    // Search
    @State private var isSearching: Bool   = false
    @State private var searchQuery: String = ""

    // UI state
    @State private var showingMemberList    = false
    @State private var showingLeaveConfirm  = false
    @State private var showingRotateConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var showingMigrationAlert   = false
    @State private var migrationAlertMessage   = ""

    private var messages: [StoredMessage] {
        appState.messages[group.conversationID] ?? []
    }

    private var displayedMessages: [StoredMessage] {
        guard isSearching, !searchQuery.isEmpty else { return messages }
        return messages.filter { $0.body.localizedCaseInsensitiveContains(searchQuery) }
    }

    private var memberCount: Int { group.memberIDs.count }

    var body: some View {
        mainContent
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingMemberList) {
                GroupMemberListView(group: group).environmentObject(appState)
            }
            .sheet(item: $forwardingMessage) { message in
                ForwardPickerView(message: message)
                    .environmentObject(appState)
            }
            .confirmationDialog(
                "Leave \"\(group.name)\"?",
                isPresented: $showingLeaveConfirm,
                titleVisibility: .visible
            ) {
                Button("Leave Group", role: .destructive) {
                    appState.leaveGroup(group); dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will no longer receive messages from this group. This cannot be undone.")
            }
            .confirmationDialog(
                "Delete \"\(group.name)\" for everyone?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Group", role: .destructive) {
                    appState.deleteGroup(group); dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All members will lose access to this group immediately. This cannot be undone.")
            }
            .alert("Upgrade to MLS", isPresented: $showingMigrationAlert) {
                Button("OK") {}
            } message: {
                Text(migrationAlertMessage)
            }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            messageScrollView
            disappearingBanner
            Divider()
            if isSearching {
                searchBar
            }
            replyPreviewBar
            inputBar
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search messages…", text: $searchQuery)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var messageScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(displayedMessages) { message in
                        GroupMessageBubble(
                            message:    message,
                            group:      group,
                            replyingTo: messages.first { $0.id == message.replyToID },
                            onReply:    { withAnimation { replyingTo = message } },
                            onForward:  { forwardingMessage = message }
                        )
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                appState.markGroupAsRead(group: group)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
                appState.markGroupAsRead(group: group)
                if let saved = UserDefaults.standard.string(forKey: disappearingKey),
                   let interval = DisappearingInterval(rawValue: saved) {
                    disappearingInterval = interval
                }
                messageText = UserDefaults.standard.string(forKey: draftKey) ?? ""
            }
            .onDisappear {
                UserDefaults.standard.set(messageText, forKey: draftKey)
            }
        }
    }

    @ViewBuilder
    private var disappearingBanner: some View {
        if disappearingInterval != .off {
            HStack(spacing: 4) {
                Image(systemName: "timer").font(.caption2)
                Text("Messages disappear after \(disappearingInterval.rawValue.lowercased())")
                    .font(.caption2)
            }
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                withAnimation { isSearching.toggle() }
                if !isSearching { searchQuery = "" }
            } label: {
                Image(systemName: isSearching ? "xmark.circle" : "magnifyingglass")
            }
        }
        ToolbarItem(placement: .topBarTrailing) { timerMenu }
        ToolbarItem(placement: .topBarTrailing) { groupMenu }
    }

    private var timerMenu: some View {
        Menu {
            ForEach(DisappearingInterval.allCases) { interval in
                Button {
                    disappearingInterval = interval
                    UserDefaults.standard.set(interval.rawValue, forKey: disappearingKey)
                } label: {
                    if disappearingInterval == interval {
                        Label(interval.rawValue, systemImage: "checkmark")
                    } else {
                        Text(interval.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: disappearingInterval.icon)
                .foregroundStyle(disappearingInterval == .off ? Color.primary : Color.orange)
        }
    }

    private var groupMenu: some View {
        Menu {
            Button { showingMemberList = true } label: {
                Label("Members (\(group.memberIDs.count))", systemImage: "person.2")
            }
            Divider()
            Button { showingRotateConfirm = true } label: {
                Label("Reset Encryption Key", systemImage: "key.slash")
            }
            if group.cryptoVersion == .senderKeysV2,
               group.creatorID == appState.chatManager?.identity.publicIdentity.peerID {
                Divider()
                Button {
                    appState.migrateGroupToMLS(group) { result in
                        switch result {
                        case .notNeeded:
                            break
                        case .initiated:
                            migrationAlertMessage = "Migration started. A new MLS group has been created with the same members."
                            showingMigrationAlert = true
                        case .requiresAllOnline(let ids):
                            migrationAlertMessage = "\(ids.count) member(s) are missing MLS keys. Ask them to open SophaxChat while nearby, then try again."
                            showingMigrationAlert = true
                        }
                    }
                } label: {
                    Label("Upgrade to MLS", systemImage: "lock.shield")
                }
            }
            Divider()
            Button(role: .destructive) { showingLeaveConfirm = true } label: {
                Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
            }
            if group.creatorID == appState.chatManager?.identity.publicIdentity.peerID {
                Button(role: .destructive) { showingDeleteConfirm = true } label: {
                    Label("Delete Group", systemImage: "trash")
                }
            }
        } label: {
            VStack(spacing: 0) {
                Image(systemName: "person.2").font(.caption2)
                Text("\(group.memberIDs.count)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Reset Encryption Key?",
            isPresented: $showingRotateConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Key", role: .destructive) {
                appState.rotateSenderKey(forGroup: group)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new encryption key will be generated and shared with all members. Use this if your device may have been compromised.")
        }
    }

    // MARK: - Sub-views (extracted to keep body type-checkable)

    @ViewBuilder
    private var replyPreviewBar: some View {
        if let replying = replyingTo {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(replying.direction == .sent
                         ? "Reply to yourself"
                         : "Reply to \(appState.displayName(forPeerID: replying.senderID ?? ""))")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                    Text(replying.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { withAnimation { replyingTo = nil } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var pttButton: some View {
        ZStack {
            Circle()
                .fill(voiceRecorder.isRecording ? Color.red.opacity(0.15) : Color.clear)
                .frame(width: 36, height: 36)
                .animation(.easeInOut(duration: 0.2), value: voiceRecorder.isRecording)
            Image(systemName: voiceRecorder.isRecording ? "waveform" : "mic")
                .font(.system(size: 20))
                .foregroundStyle(voiceRecorder.isRecording ? .red : .secondary)
                .symbolEffect(.pulse, isActive: voiceRecorder.isRecording)
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !voiceRecorder.isRecording else { return }
                    voiceRecorder.start()
                }
                .onEnded { _ in
                    voiceRecorder.stop { data, duration in
                        guard let data, duration > 0.5 else { return }
                        let expiresAt = disappearingInterval.seconds.map { Date().addingTimeInterval($0) }
                        appState.sendGroupAudio(data, duration: duration, group: group,
                                                expiresAt: expiresAt, replyToID: replyingTo?.id)
                        replyingTo = nil
                    }
                }
        )
    }

    private var inputBar: some View {
        let isTextNonEmpty = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 10) {
            PhotosPicker(selection: $photoPickerItem, matching: .any(of: [.images, .videos])) {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .onChange(of: photoPickerItem) { _, item in
                guard let item else { return }
                Task {
                    let expiresAt = disappearingInterval.seconds.map { Date().addingTimeInterval($0) }
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) || $0.identifier.contains("video") }) {
                        if let url = try? await item.loadTransferable(type: URL.self) {
                            await appState.sendGroupVideo(url, group: group, expiresAt: expiresAt)
                        }
                    } else if let data = try? await item.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) {
                        appState.sendGroupImage(image, group: group, expiresAt: expiresAt, replyToID: replyingTo?.id)
                        replyingTo = nil
                    }
                    photoPickerItem = nil
                }
            }
            pttButton
            TextField("Message", text: $messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .focused($isInputFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.sentences)
                .textContentType(.none)
            if isTextNonEmpty {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isTextNonEmpty)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        messageText = ""
        UserDefaults.standard.removeObject(forKey: draftKey)
        let expiresAt = disappearingInterval.seconds.map { Date().addingTimeInterval($0) }
        appState.sendGroupMessage(text, group: group, expiresAt: expiresAt, replyToID: replyingTo?.id)
        replyingTo = nil
    }
}

// MARK: - Group Member List Sheet

private struct GroupMemberListView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo

    private var myPeerID: String {
        (appState.chatManager?.identity.publicIdentity.peerID) ?? ""
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(group.memberIDs, id: \.self) { peerID in
                        HStack(spacing: 12) {
                            if let peer = appState.peers.first(where: { $0.id == peerID }) {
                                PeerAvatar(peer: peer, size: 36)
                            } else {
                                Circle()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        Image(systemName: "person")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                    }
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(appState.displayName(forPeerID: peerID))
                                        .font(.subheadline.weight(.medium))
                                    if peerID == group.creatorID {
                                        Text("Creator")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                    if group.cryptoVersion == .mls && peerID == group.currentCoordinatorID && peerID != group.creatorID {
                                        Text("Coordinator")
                                            .font(.caption2)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.purple.opacity(0.8))
                                            .clipShape(Capsule())
                                    }
                                    if peerID == myPeerID {
                                        Text("You")
                                            .font(.caption2)
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.1))
                                            .clipShape(Capsule())
                                    }
                                }
                                if appState.onlinePeers.contains(peerID) {
                                    Text("Online")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }

                            Spacer()

                            // Make Coordinator button — only visible to current coordinator,
                            // only for MLS groups, not for self or already-coordinator
                            if group.cryptoVersion == .mls
                                && appState.isCoordinator(of: group)
                                && peerID != myPeerID
                                && peerID != group.currentCoordinatorID {
                                Button("Make Coordinator") {
                                    appState.handoffGroupCoordinator(group, to: peerID)
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("\(group.memberIDs.count) Members")
                }
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Group Message Bubble

private struct GroupMessageBubble: View {
    @EnvironmentObject var appState: AppState
    let message:    StoredMessage
    let group:      GroupInfo
    let replyingTo: StoredMessage?
    let onReply:    () -> Void
    let onForward:  () -> Void

    private var isSent: Bool { message.direction == .sent }

    private var senderName: String {
        guard let senderID = message.senderID else { return "" }
        return appState.displayName(forPeerID: senderID)
    }

    var body: some View {
        HStack {
            if isSent { Spacer(minLength: 60) }

            VStack(alignment: isSent ? .trailing : .leading, spacing: 2) {
                if !isSent && !senderName.isEmpty {
                    Text(senderName)
                        .font(.caption2.bold())
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                }

                VStack(alignment: isSent ? .trailing : .leading, spacing: 4) {
                    if let quoted = replyingTo {
                        QuotedBubble(message: quoted, isSentContext: isSent)
                    }

                    groupBubbleContent
                }
                .contextMenu {
                    Button {
                        withAnimation { onReply() }
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    Button {
                        UIPasteboard.general.string = message.body
                        MessageBubbleView.clipboardClearTask?.cancel()
                        let task = DispatchWorkItem { UIPasteboard.general.items = [] }
                        MessageBubbleView.clipboardClearTask = task
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: task)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        onForward()
                    } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    Divider()
                    ForEach(["👍", "❤️", "😂", "😮", "😢", "👎"], id: \.self) { emoji in
                        Button {
                            let myID = appState.chatManager?.identity.publicIdentity.peerID ?? ""
                            let current = message.reactions?[myID]
                            appState.sendGroupReaction(
                                emoji: current == emoji ? nil : emoji,
                                messageID: message.id,
                                group: group
                            )
                        } label: {
                            let myID = appState.chatManager?.identity.publicIdentity.peerID ?? ""
                            if message.reactions?[myID] == emoji {
                                Label(emoji, systemImage: "checkmark")
                            } else {
                                Text(emoji)
                            }
                        }
                    }
                }

                if let reactions = message.reactions, !reactions.isEmpty {
                    ReactionPillRow(reactions: reactions)
                }

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if isSent {
                        let delivered    = message.deliveredBy?.count ?? 0
                        let read         = message.readBy?.count ?? 0
                        let total        = max(group.memberIDs.count - 1, 1)
                        let allRead      = read >= total
                        let anyDelivered = delivered > 0

                        Image(systemName: allRead
                              ? "checkmark.circle.fill"
                              : (anyDelivered ? "checkmark.circle" : "circle"))
                            .font(.caption2)
                            .foregroundStyle(
                                allRead        ? Color.accentColor
                                : anyDelivered ? Color(.tertiaryLabel)
                                              : Color(.quaternaryLabel))
                        if allRead {
                            Text("Read \(read)/\(total)")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Text("\(delivered)/\(total)")
                                .font(.caption2)
                                .foregroundStyle(anyDelivered ? Color(.tertiaryLabel) : Color(.quaternaryLabel))
                        }
                    }
                }
            }

            if !isSent { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var groupBubbleContent: some View {
        let mime = message.attachmentMimeType ?? ""
        if let id = message.attachmentID, mime.hasPrefix("image/"),
           let data = appState.loadAttachment(id: id),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: 220, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            if !message.body.isEmpty {
                Text(message.body)
                    .font(.subheadline)
                    .foregroundStyle(isSent ? .white : .primary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(isSent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        } else if mime.hasPrefix("audio/") {
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.body)
                if let dur = message.audioDuration { Text(formatDuration(dur)).font(.subheadline) }
            }
            .foregroundStyle(isSent ? .white : .primary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(isSent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
            Text(message.body)
                .font(.body)
                .foregroundStyle(isSent ? .white : .primary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(isSent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Quoted bubble (reply preview)

private struct QuotedBubble: View {
    let message:       StoredMessage
    let isSentContext: Bool

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
                .clipShape(Capsule())
            Text(message.body.isEmpty ? "Attachment" : message.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Reaction pill row (reused from 1:1)

private struct ReactionPillRow: View {
    let reactions: [String: String]

    private var counts: [(emoji: String, count: Int)] {
        var tally: [String: Int] = [:]
        for emoji in reactions.values { tally[emoji, default: 0] += 1 }
        return tally.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(counts, id: \.emoji) { item in
                HStack(spacing: 2) {
                    Text(item.emoji).font(.caption)
                    if item.count > 1 {
                        Text("\(item.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(Capsule())
            }
        }
    }
}

#Preview {
    NavigationStack {
        GroupChatView(group: GroupInfo(
            name: "Test Group",
            memberIDs: ["alice", "bob"],
            creatorID: "alice"
        ))
        .environmentObject(AppState())
    }
}
