// ChatView.swift
// SophaxChat
//
// Individual conversation view with end-to-end encrypted messaging.

import SwiftUI
import SophaxChatCore
import CoreImage.CIFilterBuiltins
import PhotosUI
import AVFoundation

// MARK: - Disappearing messages interval

enum DisappearingInterval: String, CaseIterable, Identifiable {
    case off      = "Off"
    case thirtySeconds = "30 seconds"
    case fiveMinutes   = "5 minutes"
    case oneHour       = "1 hour"
    case oneDay        = "24 hours"
    case oneWeek       = "7 days"

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .off:           return nil
        case .thirtySeconds: return 30
        case .fiveMinutes:   return 5 * 60
        case .oneHour:       return 60 * 60
        case .oneDay:        return 24 * 60 * 60
        case .oneWeek:       return 7 * 24 * 60 * 60
        }
    }

    var icon: String {
        self == .off ? "timer" : "timer.circle.fill"
    }
}

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let peer: KnownPeer

    @State private var vm: ChatViewModel
    @FocusState private var isInputFocused: Bool

    // Pure UI flags (sheet/dialog visibility)
    @State private var showingSafetyNumber = false
    @State private var showingBlockConfirm = false
    @State private var showingCamera       = false
    @State private var showingFilePicker   = false
    @State private var showingRenameAlert  = false
    @State private var showingDeadDrop     = false
    @State private var showAISheet         = false

    // PTT recording
    @StateObject private var voiceRecorder = VoiceRecorder()

    // TOFU nudge dismiss state persisted per peer
    @AppStorage private var verifyNudgeDismissed: Bool

    init(peer: KnownPeer) {
        self.peer = peer
        _vm = State(initialValue: ChatViewModel(peerID: peer.id))
        _verifyNudgeDismissed = AppStorage(wrappedValue: false, "verifyNudgeDismissed.\(peer.id)")
    }

    private var messages: [StoredMessage] {
        appState.messages[peer.id] ?? []
    }

    private var displayedMessages: [StoredMessage] {
        guard vm.isSearching, !vm.searchQuery.isEmpty else { return messages }
        return messages.filter { $0.body.localizedCaseInsensitiveContains(vm.searchQuery) }
    }

    private var isOnline: Bool {
        appState.onlinePeers.contains(peer.id)
    }

    private var hasIncomingMessage: Bool {
        messages.contains { $0.direction == .received }
    }

    var body: some View {
        @Bindable var vm = vm
        chatContent
            .sheet(isPresented: $showingSafetyNumber) {
                SafetyNumberView(peer: peer)
            }
            .confirmationDialog(
                "Block \(peer.username)?",
                isPresented: $showingBlockConfirm,
                titleVisibility: .visible
            ) {
                Button("Block", role: .destructive) {
                    appState.blockPeer(peerID: peer.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You won't receive messages from this person.")
            }
            .alert("Rename Contact", isPresented: $showingRenameAlert) {
                TextField("Name", text: $vm.renameText)
                    .autocorrectionDisabled()
                Button("Save") { appState.setAlias(vm.renameText.isEmpty ? nil : vm.renameText, for: peer.id) }
                Button("Reset") { appState.setAlias(nil, for: peer.id) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Set a custom name for \(peer.username).")
            }
            .sheet(item: $vm.forwardingMessage) { message in
                ForwardPickerView(message: message)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showAISheet) {
                NavigationStack {
                    AIAssistantView(seedPrompt: vm.aiSeedPrompt)
                }
            }
            .alert("Dead Drop", isPresented: $showingDeadDrop) {
                TextField("Message", text: $vm.deadDropText)
                    .autocorrectionDisabled()
                Button("Send via Mesh") {
                    let text = vm.deadDropText.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    appState.sendDeadDrop(text: text, toPeerID: peer.id)
                    vm.deadDropText = ""
                }
                Button("Cancel", role: .cancel) { vm.deadDropText = "" }
            } message: {
                Text("Your message will be flooded over the mesh network. \(peer.username) will receive it when they come online nearby — no internet needed.")
            }
    }

    // Extracted so the Swift type checker doesn't time out on one giant body expression.
    @ViewBuilder private var pinnedMessageBanner: some View {
        if let msgID = appState.pinnedMessages[peer.id],
           let msg = messages.first(where: { $0.id == msgID }) {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(msg.body.isEmpty ? "Attachment" : msg.body)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    appState.unpinMessage(inConversation: peer.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.08))
        }
    }

    private var chatContent: some View {
        @Bindable var vm = vm
        return VStack(spacing: 0) {
            messageList
            pinnedMessageBanner
            Divider()
            searchBar
            replyBar
            editBar
            warningBanners
            inputBar
        }
        .navigationTitle(appState.displayName(for: peer))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                chatToolbar
            }
        }
    }

    @ViewBuilder private var chatToolbar: some View {
        @Bindable var vm = vm
        HStack(spacing: 12) {
            // AI summarize
            if #available(iOS 26.0, *) {
                Button {
                    let displayName = appState.displayName(for: peer)
                    let msgs = messages.suffix(20).map { msg in
                        (msg.direction == .sent ? "Me" : displayName) + ": " + msg.body
                    }.joined(separator: "\n")
                    vm.aiSeedPrompt = "Summarize this conversation in 3 concise bullet points:\n\n\(msgs)"
                    showAISheet = true
                } label: {
                    Image(systemName: "sparkles")
                }
                .disabled(messages.isEmpty)
            }

            // Search toggle
            Button {
                withAnimation { vm.isSearching.toggle() }
                if !vm.isSearching { vm.searchQuery = "" }
            } label: {
                Image(systemName: vm.isSearching ? "xmark.circle" : "magnifyingglass")
            }

            // Online indicator + dead drop when offline
            if isOnline {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Online")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    showingDeadDrop = true
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color.gray).frame(width: 8, height: 8)
                        Text("Dead Drop")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }

            // Disappearing messages
            Menu {
                ForEach(DisappearingInterval.allCases) { interval in
                    Button {
                        vm.disappearingInterval = interval
                        vm.saveDisappearing()
                    } label: {
                        if vm.disappearingInterval == interval {
                            Label(interval.rawValue, systemImage: "checkmark")
                        } else {
                            Text(interval.rawValue)
                        }
                    }
                }
            } label: {
                Image(systemName: vm.disappearingInterval.icon)
                    .foregroundStyle(vm.disappearingInterval == .off ? Color.primary : Color.orange)
            }

            // Safety number + more actions
            Menu {
                Button {
                    showingSafetyNumber = true
                } label: {
                    if appState.isVerified(peer.id, currentSafetyNumber: peer.safetyNumber) {
                        Label("Identity Verified", systemImage: "checkmark.shield.fill")
                    } else if appState.hasKeyChanged(for: peer.id, currentSafetyNumber: peer.safetyNumber) {
                        Label("Key Changed — Verify Now!", systemImage: "exclamationmark.shield.fill")
                    } else {
                        Label("Verify Identity", systemImage: "checkmark.shield")
                    }
                }
                Button {
                    vm.renameText = appState.peerAliases[peer.id] ?? ""
                    showingRenameAlert = true
                } label: {
                    Label("Rename Contact", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    showingBlockConfirm = true
                } label: {
                    Label("Block \(peer.username)", systemImage: "nosign")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder private var messageList: some View {
        @Bindable var vm = vm
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(displayedMessages) { message in
                        MessageBubbleView(
                            message:   message,
                            onDelete:  { appState.deleteMessage(message) },
                            onReply:   { withAnimation { vm.replyingTo = message } },
                            onForward: { vm.forwardingMessage = message },
                            onEdit:    {
                                vm.messageText = message.body
                                withAnimation { vm.editingMessage = message }
                                isInputFocused = true
                            },
                            onPin: {
                                if appState.pinnedMessages[peer.id] == message.id {
                                    appState.unpinMessage(inConversation: peer.id)
                                } else {
                                    appState.pinMessage(message.id, inConversation: peer.id)
                                }
                            },
                            onAIAction: { prompt in
                                vm.aiSeedPrompt = prompt
                                showAISheet = true
                            }
                        )
                        .id(message.id)
                    }
                    if appState.typingPeers.contains(peer.id) {
                        TypingBubbleView().id("typing-indicator")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                appState.markAsRead(peerID: peer.id)
            }
            .onChange(of: appState.typingPeers.contains(peer.id)) { _, isTyping in
                if isTyping { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
                appState.markAsRead(peerID: peer.id)
            }
            .onDisappear {
                // Never persist drafts when app lock is enabled — UserDefaults is
                // unencrypted and included in device backups.  When lock is off the
                // device is already considered accessible, so drafts are safe to keep.
                if appState.appLockEnabled {
                    vm.clearDraft()
                } else {
                    vm.saveDraft()
                }
            }
        }
    }

    @ViewBuilder private var searchBar: some View {
        @Bindable var vm = vm
        if vm.isSearching {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search messages…", text: $vm.searchQuery)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !vm.searchQuery.isEmpty {
                    Button { vm.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder private var replyBar: some View {
        @Bindable var vm = vm
        if let replying = vm.replyingTo {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(replying.direction == .sent ? "Reply to yourself" : "Reply to \(appState.displayName(for: peer))")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                    Text(replying.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { withAnimation { vm.replyingTo = nil } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private var editBar: some View {
        @Bindable var vm = vm
        if vm.editingMessage != nil {
            HStack(spacing: 10) {
                Image(systemName: "pencil")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit message")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                    Text(vm.editingMessage?.body ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    withAnimation { vm.cancelEdit() }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private var warningBanners: some View {
        if appState.hasKeyChanged(for: peer.id, currentSafetyNumber: peer.safetyNumber) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
                Text("\(peer.username)'s security key changed — verify identity before continuing.")
                    .font(.caption)
                Spacer()
                Button("Verify") { showingSafetyNumber = true }
                    .font(.caption.bold()).foregroundStyle(.red)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.red.opacity(0.08))
        }
        if appState.noOPKSessions.contains(peer.id) {
            HStack(spacing: 6) {
                Image(systemName: "key.slash").foregroundStyle(.yellow)
                Text("Session established without one-time prekey — slightly reduced initial security.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.yellow.opacity(0.08))
        }
        if hasIncomingMessage,
           !appState.isVerified(peer.id, currentSafetyNumber: peer.safetyNumber),
           !verifyNudgeDismissed {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.shield.checkmark").foregroundStyle(.yellow)
                Text("Verify \(peer.username)'s identity to confirm you're talking to the right person.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Verify") { showingSafetyNumber = true }
                    .font(.caption.bold()).foregroundStyle(.yellow)
                Button { verifyNudgeDismissed = true } label: {
                    Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.yellow.opacity(0.08))
        }
        if vm.disappearingInterval != .off {
            HStack(spacing: 4) {
                Image(systemName: "timer").font(.caption2)
                Text("Messages disappear after \(vm.disappearingInterval.rawValue.lowercased())").font(.caption2)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 16).padding(.top, 6)
        }
    }

    @ViewBuilder private var inputBar: some View {
        @Bindable var vm = vm
        HStack(spacing: 10) {
            PhotosPicker(selection: $vm.photoPickerItem, matching: .any(of: [.images, .videos])) {
                Image(systemName: "paperclip")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .onChange(of: vm.photoPickerItem) { _, item in
                guard let item else { return }
                Task {
                    let expiresAt = vm.disappearingInterval.seconds.map { Date().addingTimeInterval($0) }
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) || $0.identifier.contains("video") }) {
                        if let url = try? await item.loadTransferable(type: URL.self) {
                            await appState.sendVideo(url, toPeerID: peer.id, expiresAt: expiresAt)
                        }
                    } else if let data = try? await item.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) {
                        appState.sendImage(image, toPeerID: peer.id, expiresAt: expiresAt)
                    }
                    vm.photoPickerItem = nil
                }
            }
            Button { showingCamera = true } label: {
                Image(systemName: "camera")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            Button { showingFilePicker = true } label: {
                Image(systemName: "doc")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            TextField("Message", text: $vm.messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .focused($isInputFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.sentences)
                .textContentType(.none)
                .onChange(of: vm.messageText) { _, newValue in
                    let nonEmpty = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if nonEmpty {
                        appState.sendTypingIndicator(toPeerID: peer.id, isTyping: true)
                        vm.typingTask?.cancel()
                        vm.typingTask = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(5))
                            appState.sendTypingIndicator(toPeerID: peer.id, isTyping: false)
                            vm.typingTask = nil
                        }
                    } else {
                        vm.typingTask?.cancel()
                        vm.typingTask = nil
                        appState.sendTypingIndicator(toPeerID: peer.id, isTyping: false)
                    }
                }
            sendOrMicButton
        }
        .animation(.easeInOut(duration: 0.15), value: canSend)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .sheet(isPresented: $showingCamera) {
            CameraPickerView { image in
                guard let image else { return }
                appState.sendImage(image, toPeerID: peer.id,
                                   expiresAt: vm.disappearingInterval.seconds.map { Date().addingTimeInterval($0) })
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let expiresAt = vm.disappearingInterval.seconds.map { Date().addingTimeInterval($0) }
                appState.sendFile(url, toPeerID: peer.id, expiresAt: expiresAt)
            }
        }
    }

    @ViewBuilder private var sendOrMicButton: some View {
        if canSend {
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
            }
            .transition(.scale.combined(with: .opacity))
        } else {
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
                            guard let data else { return }
                            appState.sendAudio(data, duration: duration, toPeerID: peer.id,
                                               expiresAt: vm.disappearingInterval.seconds.map { Date().addingTimeInterval($0) })
                        }
                    }
            )
        }
    }

    private var canSend: Bool {
        !vm.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendMessage() {
        let text = vm.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        vm.typingTask?.cancel()
        vm.typingTask = nil
        appState.sendTypingIndicator(toPeerID: peer.id, isTyping: false)
        vm.messageText = ""
        vm.clearDraft()
        if let editing = vm.editingMessage {
            withAnimation { vm.editingMessage = nil }
            appState.sendEditMessage(messageID: editing.id, newBody: text, toPeerID: peer.id)
        } else {
            let reply = vm.replyingTo
            withAnimation { vm.replyingTo = nil }
            let expiresAt = vm.disappearingInterval.seconds.map { Date().addingTimeInterval($0) }
            appState.sendMessage(text, toPeerID: peer.id, expiresAt: expiresAt, replyToID: reply?.id)
        }
    }
}

// MARK: - Typing Bubble

private struct TypingBubbleView: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(phase == i ? 1.0 : 0.3))
                    .frame(width: 7, height: 7)
                    .offset(y: phase == i ? -3 : 0)
                    .animation(.easeInOut(duration: 0.35), value: phase)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                for i in 0..<3 {
                    phase = i
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
        }
    }
}

// MARK: - Safety Number View

struct SafetyNumberView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let peer: KnownPeer

    @State private var showingMyQR      = false
    @State private var showingPeerQR    = false
    @State private var showingKeyHistory = false

    private var mySafetyNumber: String? {
        appState.chatManager?.identity.publicIdentity.safetyNumber
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                        .padding(.top, 24)

                    Text("Compare both numbers out loud or in person. If they match on both devices, the connection is authentic.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    // Their number
                    SafetyNumberBlock(
                        label: "\(peer.username)'s number",
                        sublabel: "They read this to you",
                        safetyNumber: peer.safetyNumber,
                        color: .blue,
                        onShowQR: { showingPeerQR = true }
                    )

                    // Your number
                    if let mine = mySafetyNumber {
                        SafetyNumberBlock(
                            label: "Your number",
                            sublabel: "You read this to them",
                            safetyNumber: mine,
                            color: .green,
                            onShowQR: { showingMyQR = true }
                        )
                        .sheet(isPresented: $showingMyQR) {
                            QRSheet(title: "Your Safety Number", safetyNumber: mine)
                        }
                    }

                    // Key History — collapsible section
                    KeyHistorySection(peerID: peer.id, isExpanded: $showingKeyHistory)

                    Text("If either number doesn't match, someone may be intercepting your messages. Do not continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle("Verify Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if appState.isVerified(peer.id, currentSafetyNumber: peer.safetyNumber) {
                        Label("Identity Verified", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline.bold())
                    } else {
                        Button {
                            appState.markPeerVerified(peer.id, safetyNumber: peer.safetyNumber)
                            dismiss()
                        } label: {
                            Label("Mark as Verified", systemImage: "checkmark.shield")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 12)
                .background(.bar)
            }
            .sheet(isPresented: $showingPeerQR) {
                QRSheet(title: "\(peer.username)'s Safety Number", safetyNumber: peer.safetyNumber)
            }
        }
    }
}

private struct QRSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let safetyNumber: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                QRCodeView(safetyNumber: safetyNumber)
                    .padding(.top, 24)
                Text("Scan this with the other device to compare safety numbers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - QR Code generator

private struct QRCodeView: View {
    let safetyNumber: String

    private var qrImage: Image? {
        let context = CIContext()
        let filter  = CIFilter.qrCodeGenerator()
        filter.message = Data(safetyNumber.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }

    var body: some View {
        if let img = qrImage {
            img
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .padding(12)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Forward Picker

struct ForwardPickerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let message: StoredMessage

    var body: some View {
        NavigationStack {
            Group {
                if appState.peers.isEmpty {
                    ContentUnavailableView(
                        "No Contacts",
                        systemImage: "person.slash",
                        description: Text("No nearby peers to forward to.")
                    )
                } else {
                    List(appState.peers) { peer in
                        Button {
                            appState.forwardMessage(message, toPeerID: peer.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        Text(String(appState.displayName(for: peer).prefix(1)).uppercased())
                                            .font(.subheadline.bold())
                                            .foregroundStyle(Color.accentColor)
                                    }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(appState.displayName(for: peer))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if appState.onlinePeers.contains(peer.id) {
                                        Text("Online")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    } else {
                                        Text("Offline")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "arrowshape.turn.up.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Forward To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Key History Section

private struct KeyHistorySection: View {
    @EnvironmentObject var appState: AppState
    let peerID: String
    @Binding var isExpanded: Bool

    private var history: [KeyLogEntry] { appState.keyHistory(for: peerID) }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Label("Key History", systemImage: "key.horizontal")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if history.count <= 1 {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Text("\(history.count) keys")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 16)
                if history.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.badge.questionmark")
                            .foregroundStyle(.tertiary)
                        Text("No history recorded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                } else if history.count == 1 {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text("Key has never changed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(history.enumerated().reversed()), id: \.offset) { idx, entry in
                            let isCurrent = idx == history.indices.last
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(entry.signingKeyPublic.prefix(4)
                                            .map { String(format: "%02x", $0) }.joined())
                                            .font(.system(.caption, design: .monospaced).bold())
                                        Text(isCurrent ? "Current" : "Previous")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(isCurrent ? Color.green.opacity(0.12) : Color.secondary.opacity(0.1))
                                            .foregroundStyle(isCurrent ? .green : .secondary)
                                            .clipShape(Capsule())
                                    }
                                    Text(entry.firstSeen.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            if idx != history.startIndex {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

private struct SafetyNumberBlock: View {
    let label: String
    let sublabel: String
    let safetyNumber: String
    let color: Color
    let onShowQR: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                    Text(sublabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onShowQR) {
                    Image(systemName: "qrcode")
                        .foregroundStyle(color)
                }
            }
            .padding(.horizontal)

            let groups = safetyNumber.split(separator: " ")
            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 10) {
                ForEach(groups, id: \.self) { group in
                    Text(group)
                        .font(.system(.body, design: .monospaced).bold())
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(color.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
        }
    }
}
