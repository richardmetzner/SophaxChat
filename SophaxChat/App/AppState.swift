// AppState.swift
// SophaxChat
//
// Observable app state and ChatManager lifecycle.
// Created once and injected via @EnvironmentObject.

import SwiftUI
import UIKit
import Network
import AVFoundation
import CryptoKit
import LocalAuthentication
import UserNotifications
import ReplayKit
import UniformTypeIdentifiers
import SophaxChatCore

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    @Published var isSetupComplete: Bool = false
    @Published var isBlurred: Bool       = false
    @Published var isAppLocked: Bool     = false
    /// When true, all in-memory state is cleared and the app displays as empty.
    /// Incoming messages are silently dropped until the next real unlock.
    @Published var isDuressActive: Bool  = false
    @Published var peers:                [KnownPeer] = []
    @Published var pendingContactRequests: [KnownPeer] = []
    @Published var linkedDevices: [KnownPeer] = []
    @Published var messages:     [String: [StoredMessage]] = [:]  // peerID → messages
    @Published var onlinePeers:  Set<String> = []
    @Published var blockedPeers: Set<String> = []
    @Published var unreadCounts: [String: Int] = [:]
    @Published var typingPeers:  Set<String> = []
    @Published var peerAliases:  [String: String] = [:]
    @Published var errorMessage: String? = nil
    @Published var groups:       [GroupInfo] = []
    /// Groups announced by nearby peers that the local user is NOT a member of.
    /// Keyed by groupID; stale entries (>5 min old) are replaced on each announcement.
    @Published var discoveredChannels: [String: ChannelAnnouncement] = [:]

    /// Safety Number pinning: peerID → safety number at time of verification.
    /// Nil entry = never verified. Different value = key changed warning.
    @Published var verifiedPeers: [String: String] = [:]

    /// Pinned messages: conversationID → pinned messageID. Local-only, never broadcast.
    @Published var pinnedMessages: [String: String] = [:]

    /// peerID → true when their session was established without a one-time prekey (reduced entropy).
    @Published var noOPKSessions: Set<String> = []

    /// peerID → JPEG avatar data received from that peer's PreKeyBundle.
    @Published var peerAvatars: [String: Data] = [:]
    /// JPEG data for the local user's own avatar. nil = no avatar set.
    @Published var myAvatarData: Data? = nil
    /// peerIDs whose identity key changed since last known state — shown as security alerts.
    @Published var keyChangeAlerts: [String] = []
    /// Set when biometric/passcode evaluation is unavailable during unlock — shown in AppLockView.
    @Published var unlockError: String? = nil
    /// True while a biometric/passcode prompt is in progress — prevents multiple simultaneous prompts.
    @Published var isUnlocking: Bool = false
    /// Non-nil when unlock is rate-limited after too many failures. UI shows a countdown.
    @Published var unlockLockedUntil: Date? = nil

    private var failedUnlockAttempts: Int = 0

    // MARK: - TCP / internet mode

    /// Whether the TCP internet transport is active.
    @Published var tcpEnabled: Bool = false {
        didSet { applyTCPConfig(); UserDefaults.standard.set(tcpEnabled, forKey: tcpEnabledKey) }
    }
    /// Whether to route TCP traffic through the embedded Tor SOCKS5 proxy.
    @AppStorage("com.sophax.torEnabled") var torEnabled: Bool = true {
        didSet {
            #if !targetEnvironment(macCatalyst)
            if torEnabled {
                TorManager.shared.start()
                if tcpSocksProxy.isEmpty {
                    tcpSocksProxy = TorManager.socksProxy
                }
            } else {
                TorManager.shared.stop()
                if tcpSocksProxy == TorManager.socksProxy {
                    tcpSocksProxy = ""
                }
                // Tor-enforced mode requires Tor — stop TCP immediately if Tor is disabled
                if torEnforcedMode { chatManager?.stopTCP() }
            }
            #endif
        }
    }

    /// When true, TCP transport will not start until Tor is fully bootstrapped.
    /// If Tor stops while TCP is running, the TCP transport is also stopped (fail-closed).
    @AppStorage("com.sophax.torEnforcedMode") var torEnforcedMode: Bool = false {
        didSet {
            #if !targetEnvironment(macCatalyst)
            if torEnforcedMode {
                // Enforce immediately: if Tor is not ready, stop TCP
                if case .ready = TorManager.shared.state { /* Tor is up, keep TCP running */ }
                else { chatManager?.stopTCP() }
            } else {
                // Enforcement lifted: restart TCP if it should be running
                applyTCPConfig()
            }
            #endif
        }
    }
    /// Local listen port (default 25519).
    @Published var tcpPort: String = "25519" {
        didSet { applyTCPConfig(); UserDefaults.standard.set(tcpPort, forKey: tcpPortKey) }
    }
    /// Optional SOCKS5 proxy for Tor ("host:port", e.g. "127.0.0.1:9050").
    @Published var tcpSocksProxy: String = "" {
        didSet { applyTCPConfig(); UserDefaults.standard.set(tcpSocksProxy, forKey: tcpSocksProxyKey) }
    }
    /// User-entered public address ("IP:port") included in Hello so peers learn our internet address.
    @Published var myTCPAddress: String = "" {
        didSet {
            chatManager?.myTCPAddress = myTCPAddress.isEmpty ? nil : myTCPAddress
            UserDefaults.standard.set(myTCPAddress, forKey: tcpAddressKey)
        }
    }

    private let tcpEnabledKey    = "com.sophax.tcp.enabled"
    private let tcpPortKey       = "com.sophax.tcp.port"
    private let tcpSocksProxyKey = "com.sophax.tcp.socksProxy"
    private let tcpAddressKey    = "com.sophax.tcp.address"

    /// When true, sender name and message body are included in local notifications.
    /// Off by default: protects conversation metadata on the lock screen / Notification Centre.
    @Published var notifShowSender: Bool = false {
        didSet { UserDefaults.standard.set(notifShowSender, forKey: notifShowSenderKey) }
    }
    private let notifShowSenderKey = "com.sophax.notif.showSender"

    /// Set to a peer that just came back online; triggers reconnect banner in UI.
    @Published var reconnectedPeer: KnownPeer? = nil

    /// When true, the app content is wrapped in a UITextField(isSecureTextEntry:true) layer so
    /// iOS excludes it from screenshots and screen recordings. Opt-in — not enabled by default.
    /// NOTE: This is a documented-by-practice technique using a private CALayer flag in UITextField.
    ///       It may break in a future OS. Toggle off if content ever appears blank unexpectedly.
    @AppStorage("com.sophax.screenshotPreventionEnabled") var screenshotPreventionEnabled = false

    /// True while iOS screen recording is active — shown as a security warning banner.
    @Published var isScreenBeingRecorded: Bool = false
    /// Momentarily true after the user takes a screenshot — shown as a brief warning.
    @Published var didTakeScreenshot: Bool = false
    /// Momentarily non-nil after a contact card link is successfully parsed — shown as a toast.
    @Published var lastAddedContactAddress: String? = nil
    /// Non-nil when a sophaxchat:// link is waiting for user confirmation before connecting.
    @Published var pendingDeepLink: PendingDeepLink? = nil

    /// Username cache for blocked peers (persisted so they're still readable after restart).
    private(set) var blockedPeerNames: [String: String] = [:]
    private var typingTimeouts: [String: Task<Void, Never>] = [:]

    // MARK: - Core

    private(set) var chatManager: ChatManager?
    private let keychain = KeychainManager()

    // MARK: - Init

    init() {
        // Load unlock rate-limit state (persisted in Keychain, survives app restarts)
        let (attempts, lockedUntil) = keychain.loadUnlockAttempts()
        self.failedUnlockAttempts = attempts
        self.unlockLockedUntil    = (lockedUntil.map { $0 > Date() } ?? false) ? lockedUntil : nil

        loadSavedPeers()
        loadPendingRequests()
        loadBlockedPeers()
        loadAliases()
        loadGroups()
        loadVerifiedPeers()
        loadPinnedMessages()
        loadTCPSettings()
        if keychain.hasIdentity() {
            setupChatManager(username: nil)
        }
        // Start embedded Tor immediately (iOS only — Mac Catalyst uses system network directly).
        // Respects the torEnabled toggle stored in UserDefaults.
        #if !targetEnvironment(macCatalyst)
        if torEnabled {
            TorManager.shared.start()
        }
        observeTorState()
        #endif
    }

    // MARK: - Setup

    func createIdentity(username: String) {
        setupChatManager(username: username)
    }

    private func setupChatManager(username: String?) {
        do {
            let identity     = try IdentityManager(keychain: keychain)
            if let username {
                try identity.setUsername(username)
            }
            let preKeys      = try PreKeyManager(identity: identity, keychain: keychain)
            let mesh         = MeshManager(localIdentityHash: identity.publicIdentity.peerID)
            let store        = try MessageStore(keychain: keychain)
            let attachStore  = try AttachmentStore(keychain: keychain)

            let manager = ChatManager(
                identity:        identity,
                preKeys:         preKeys,
                mesh:            mesh,
                messageStore:    store,
                attachmentStore: attachStore,
                keychain:        keychain
            )
            manager.delegate      = self
            manager.deviceLabel   = UIDevice.current.name
            manager.myTCPAddress  = myTCPAddress.isEmpty ? nil : myTCPAddress
            manager.registerKnownGroups(groups)
            // Re-register pending contact requests so ChatManager knows to gate their messages
            for peer in pendingContactRequests { manager.registerPendingPeer(peer) }
            manager.start()
            // Rebuild linked device peer list from known peers + ChatManager's linked set
            linkedDevices = peers.filter { manager.linkedDevices.contains($0.id) }
            if tcpEnabled { startTCPTransport(on: manager) }

            self.chatManager     = manager
            self.isSetupComplete = true
            self.myAvatarData    = identity.loadAvatar()
            requestNotificationPermission()
            startScreenSecurityMonitor()

            loadExistingMessages(from: store)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Screen security

    /// Polls RPScreenRecorder every 1.5 s to detect active screen recording.
    /// On macOS Catalyst, screen recording is normal OS behaviour — skip the warning.
    private func startScreenSecurityMonitor() {
        #if !targetEnvironment(macCatalyst)
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            let recording = RPScreenRecorder.shared().isRecording
            Task { @MainActor [weak self] in
                self?.isScreenBeingRecorded = recording
            }
        }
        #endif
    }

    /// Call when the OS reports a screenshot was taken.
    func handleScreenshot() {
        guard isSetupComplete else { return }
        didTakeScreenshot = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            didTakeScreenshot = false
        }
    }

    // MARK: - Background operation

    /// Called by the BGAppRefreshTask when iOS re-wakes the app after suspension.
    /// Restarts the mesh briefly so any store-and-forward deliveries can complete
    /// and outbound pending queues can be drained if peers are in range.
    @MainActor
    func handleBackgroundMeshRefresh() async {
        // If setup is not complete (first launch) there's nothing to do.
        guard isSetupComplete, let manager = chatManager else { return }

        // Restart the mesh if it isn't already running
        manager.start()

        // Give MPC ~10 seconds to connect to any nearby peer and drain queues,
        // then stop to avoid draining the battery further.
        try? await Task.sleep(for: .seconds(10))
        manager.stop()
    }

    // MARK: - Note to Self

    /// Synthetic peerID for the local encrypted notepad. Never transmitted over the network.
    static let noteToSelfID = "__note_to_self__"

    var noteToSelfMessages: [StoredMessage] {
        messages[AppState.noteToSelfID] ?? []
    }

    /// Save a note locally. Goes directly to MessageStore, never to the network.
    func sendNoteToSelf(_ text: String) {
        let msg = StoredMessage(
            peerID:    AppState.noteToSelfID,
            direction: .sent,
            body:      text,
            status:    .delivered
        )
        try? chatManager?.messageStore.append(message: msg)
        appendMessage(msg)
    }

    func deleteNoteToSelf(_ message: StoredMessage) {
        try? chatManager?.messageStore.deleteMessage(id: message.id, peerID: AppState.noteToSelfID)
        messages[AppState.noteToSelfID]?.removeAll { $0.id == message.id }
    }

    // MARK: - Message sending

    func sendMessage(_ text: String, toPeerID peerID: String, expiresAt: Date? = nil, replyToID: String? = nil) {
        chatManager?.sendMessage(text, toPeerID: peerID, expiresAt: expiresAt, replyToID: replyToID)
    }

    func sendDeadDrop(text: String, toPeerID peerID: String) {
        try? chatManager?.sendDeadDrop(toPeerID: peerID, text: text)
    }

    func sendTypingIndicator(toPeerID peerID: String, isTyping: Bool) {
        chatManager?.sendTypingIndicator(toPeerID: peerID, isTyping: isTyping)
    }

    func sendReaction(emoji: String?, messageID: String, peerID: String) {
        chatManager?.sendReaction(emoji: emoji, toMessageID: messageID, toPeerID: peerID)
    }

    // MARK: - Group messaging

    func createGroup(name: String, memberPeerIDs: [String]) {
        guard let group = chatManager?.createGroup(name: name, memberPeerIDs: memberPeerIDs) else { return }
        chatManager?.broadcastChannelAnnouncement(for: group)
    }

    /// Whether the given peer has an MLS KeyPackage available.
    /// Required before creating an MLS group — all members must have exchanged keys at least once.
    func peerHasMLSKeyPackage(_ peerID: String) -> Bool {
        chatManager?.peerBundles[peerID]?.mlsKeyPackage != nil
    }

    /// Create a new MLS (RFC 9420) group. No channel announcement — MLS groups are
    /// closed-membership and onboard members via Welcome messages.
    func createMLSGroup(name: String, memberPeerIDs: [String]) {
        chatManager?.createMLSGroup(name: name, memberPeerIDs: memberPeerIDs)
    }

    /// Attempt to migrate an SKv2 group to MLS. Only the group creator can call this.
    func migrateGroupToMLS(_ group: GroupInfo, completion: @escaping (GroupMigrationResult) -> Void) {
        guard let cm = chatManager else { return }
        Task {
            let result = (try? migrateGroupToMLS(group, in: cm)) ?? .requiresAllOnline([])
            await MainActor.run { completion(result) }
        }
    }

    func sendGroupMessage(_ text: String, group: GroupInfo, expiresAt: Date? = nil, replyToID: String? = nil) {
        if group.cryptoVersion == .mls {
            chatManager?.sendMLSGroupMessage(text, group: group, expiresAt: expiresAt, replyToID: replyToID)
        } else {
            chatManager?.sendGroupMessage(text, groupID: group.id, members: group.memberIDs,
                                          expiresAt: expiresAt, replyToID: replyToID)
        }
    }

    func sendGroupReaction(emoji: String?, messageID: String, group: GroupInfo) {
        if group.cryptoVersion == .mls {
            chatManager?.sendMLSGroupReaction(emoji: emoji, toMessageID: messageID, group: group)
        } else {
            chatManager?.sendGroupReaction(emoji: emoji, toMessageID: messageID,
                                           groupID: group.id, members: group.memberIDs)
        }
    }

    func sendGroupImage(_ image: UIImage, group: GroupInfo, expiresAt: Date? = nil, replyToID: String? = nil) {
        guard let data = compressedJPEG(image) else { return }
        if group.cryptoVersion == .mls {
            chatManager?.sendMLSGroupAttachment(data, mimeType: "image/jpeg",
                                                group: group, expiresAt: expiresAt, replyToID: replyToID)
        } else {
            chatManager?.sendGroupAttachment(data, mimeType: "image/jpeg",
                                             groupID: group.id, members: group.memberIDs,
                                             expiresAt: expiresAt, replyToID: replyToID)
        }
    }

    func sendGroupAudio(_ data: Data, duration: Double, group: GroupInfo, expiresAt: Date? = nil, replyToID: String? = nil) {
        if group.cryptoVersion == .mls {
            chatManager?.sendMLSGroupAttachment(data, mimeType: "audio/m4a",
                                                audioDuration: duration,
                                                group: group, expiresAt: expiresAt, replyToID: replyToID)
        } else {
            chatManager?.sendGroupAttachment(data, mimeType: "audio/m4a",
                                             audioDuration: duration,
                                             groupID: group.id, members: group.memberIDs,
                                             expiresAt: expiresAt, replyToID: replyToID)
        }
    }

    // MARK: - Username change

    var myUsername: String? { chatManager?.identity.publicIdentity.username }

    func changeUsername(_ newUsername: String) {
        let trimmed = newUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return }
        guard let identity = chatManager?.identity else { return }
        try? identity.setUsername(trimmed)
        chatManager?.broadcastHello()
    }

    func leaveGroup(_ group: GroupInfo) {
        chatManager?.leaveGroup(group)
        groups.removeAll { $0.id == group.id }
        saveGroups()
        messages.removeValue(forKey: group.conversationID)
        unreadCounts.removeValue(forKey: group.conversationID)
    }

    func deleteGroup(_ group: GroupInfo) {
        chatManager?.deleteGroup(group)
        groups.removeAll { $0.id == group.id }
        saveGroups()
        messages.removeValue(forKey: group.conversationID)
        unreadCounts.removeValue(forKey: group.conversationID)
    }

    func handoffGroupCoordinator(_ group: GroupInfo, to newCoordinatorID: String) {
        chatManager?.handoffCoordinator(group: group, newCoordinatorID: newCoordinatorID)
    }

    var myPeerID: String? { chatManager?.identity.publicIdentity.peerID }

    func isCoordinator(of group: GroupInfo) -> Bool {
        guard let id = myPeerID else { return false }
        return group.currentCoordinatorID == id
    }

    func groupMessages(for group: GroupInfo) -> [StoredMessage] {
        messages[group.conversationID] ?? []
    }

    func markGroupAsRead(group: GroupInfo) {
        let convID = group.conversationID
        unreadCounts[convID] = 0
        let ids = messages[convID]?.map(\.id) ?? []
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UIApplication.shared.applicationIconBadgeNumber = totalUnreadCount

        // Send true read receipts for received messages we haven't acknowledged yet.
        // Group by senderID so each receipt goes unicast to the original sender.
        let myID = myPeerID ?? ""
        let unread = messages[convID]?.filter {
            $0.direction == .received &&
            !($0.readBy?.contains(myID) ?? false)
        } ?? []
        let bySender = Dictionary(grouping: unread) { $0.senderID ?? "" }
        for (senderID, msgs) in bySender where !senderID.isEmpty {
            chatManager?.sendGroupReadReceipts(
                messageIDs: msgs.map(\.id),
                senderPeerID: senderID,
                groupID: group.id
            )
        }
    }

    func displayName(forPeerID peerID: String) -> String {
        if let peer = peers.first(where: { $0.id == peerID }) {
            return displayName(for: peer)
        }
        return String(peerID.prefix(8)) + "…"
    }

    private let groupsDefaultsKey = "com.sophax.groups"

    private func loadGroups() {
        guard let data  = UserDefaults.standard.data(forKey: groupsDefaultsKey),
              let saved = try? JSONDecoder().decode([GroupInfo].self, from: data) else { return }
        groups = saved
        // Group messages are loaded later in loadExistingMessages(from:) once the store is ready
    }

    private func saveGroups() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: groupsDefaultsKey)
        }
    }

    func sendImage(_ image: UIImage, toPeerID peerID: String, expiresAt: Date? = nil) {
        guard let data = compressedJPEG(image) else { return }
        chatManager?.sendAttachment(data, mimeType: "image/jpeg", toPeerID: peerID, expiresAt: expiresAt)
    }

    private func compressedJPEG(_ image: UIImage) -> Data? {
        var quality: CGFloat = 0.75
        var data: Data? = image.jpegData(compressionQuality: quality)
        while let d = data, d.count > 400_000, quality > 0.1 {
            quality -= 0.1
            data = image.jpegData(compressionQuality: quality)
        }
        return data
    }

    /// Send a recorded M4A audio clip as an encrypted attachment.
    func sendAudio(_ data: Data, duration: Double, toPeerID peerID: String, expiresAt: Date? = nil) {
        chatManager?.sendAttachment(
            data, mimeType: "audio/m4a", audioDuration: duration,
            toPeerID: peerID, expiresAt: expiresAt
        )
    }

    /// Send an edit for a previously sent text message.
    func sendEditMessage(messageID: String, newBody: String, toPeerID peerID: String) {
        chatManager?.sendEditMessage(messageID: messageID, newBody: newBody, toPeerID: peerID)
        // Update local in-memory state immediately for instant UI feedback
        if let idx = messages[peerID]?.firstIndex(where: { $0.id == messageID }) {
            messages[peerID]?[idx].body     = newBody
            messages[peerID]?[idx].isEdited = true
            messages[peerID]?[idx].editedAt = Date()
        }
    }

    /// Rotate the local user's sender key for a group (break-in recovery).
    func rotateSenderKey(forGroup group: GroupInfo) {
        chatManager?.rotateSenderKey(forGroup: group)
    }

    /// Send a video file as an encrypted attachment.
    func sendVideo(_ url: URL, toPeerID peerID: String, expiresAt: Date? = nil) {
        Task {
            guard let data = await compressVideo(url) else { return }
            await MainActor.run {
                chatManager?.sendAttachment(data, mimeType: "video/mp4", toPeerID: peerID, expiresAt: expiresAt)
            }
        }
    }

    /// Send a video file as an encrypted group attachment.
    func sendGroupVideo(_ url: URL, group: GroupInfo, expiresAt: Date? = nil) {
        Task {
            guard let data = await compressVideo(url) else { return }
            await MainActor.run {
                chatManager?.sendGroupAttachment(data, mimeType: "video/mp4",
                                                 groupID: group.id, members: group.memberIDs,
                                                 expiresAt: expiresAt)
            }
        }
    }

    /// Send an arbitrary file (PDF, document, etc.) as an encrypted attachment.
    func sendFile(_ url: URL, toPeerID peerID: String, expiresAt: Date? = nil) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              data.count <= ChatManager.maxFileAttachmentBytes else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        chatManager?.sendAttachment(data, mimeType: mime, filename: url.lastPathComponent,
                                    toPeerID: peerID, expiresAt: expiresAt)
    }

    /// Send an arbitrary file to a group.
    func sendGroupFile(_ url: URL, group: GroupInfo, expiresAt: Date? = nil) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              data.count <= ChatManager.maxFileAttachmentBytes else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        chatManager?.sendGroupAttachment(data, mimeType: mime, filename: url.lastPathComponent,
                                         groupID: group.id, members: group.memberIDs,
                                         expiresAt: expiresAt)
    }

    private func compressVideo(_ url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            let asset = AVURLAsset(url: url)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
                continuation.resume(returning: nil)
                return
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            session.outputURL       = tmp
            session.outputFileType  = .mp4
            session.shouldOptimizeForNetworkUse = true
            session.exportAsynchronously {
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard session.status == .completed,
                      let data = try? Data(contentsOf: tmp),
                      data.count <= 30 * 1024 * 1024 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Avatar

    /// Set the local user's avatar from a UIImage.
    /// Resizes to 64×64 JPEG and broadcasts an updated Hello to all peers.
    func setMyAvatar(_ image: UIImage) {
        guard let data = resizedAvatarJPEG(image) else { return }
        try? chatManager?.identity.setAvatar(data)
        myAvatarData = data
        chatManager?.broadcastHello()
    }

    func removeMyAvatar() {
        chatManager?.identity.deleteAvatar()
        myAvatarData = nil
        chatManager?.broadcastHello()
    }

    private func resizedAvatarJPEG(_ image: UIImage) -> Data? {
        let targetSize = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }

    // MARK: - Invite link

    /// Generate a `sophaxchat://meet?...` URL encoding this device's public identity.
    /// The recipient can tap the link to pre-populate contact info without being in Bluetooth range.
    func generateInviteLink() -> URL? {
        guard let id = chatManager?.identity.publicIdentity else { return nil }
        var components = URLComponents()
        components.scheme = "sophaxchat"
        components.host   = "meet"
        components.queryItems = [
            URLQueryItem(name: "pid",  value: id.peerID),
            URLQueryItem(name: "name", value: Data(id.username.utf8).base64EncodedString()),
            URLQueryItem(name: "sk",   value: id.signingKeyPublic.base64EncodedString()),
            URLQueryItem(name: "dk",   value: id.dhKeyPublic.base64EncodedString())
        ]
        return components.url
    }

    /// Load attachment data from the local encrypted store (used by bubble views).
    func loadAttachment(id: String) -> Data? {
        try? chatManager?.attachmentStore.load(id: id)
    }

    // MARK: - Conversation management

    func deleteConversation(peerID: String) {
        try? chatManager?.messageStore.deleteConversation(peerID: peerID)
        messages.removeValue(forKey: peerID)
        unreadCounts.removeValue(forKey: peerID)
    }

    func deleteMessage(_ message: StoredMessage) {
        try? chatManager?.messageStore.deleteMessage(id: message.id, peerID: message.peerID)
        messages[message.peerID]?.removeAll { $0.id == message.id }
    }

    // MARK: - Contact request accept / reject

    func acceptContact(_ peer: KnownPeer) {
        chatManager?.acceptContactRequest(peerID: peer.id)
        pendingContactRequests.removeAll { $0.id == peer.id }
        savePendingRequests()
        // peer will appear in peers[] via the didDiscoverPeer callback
    }

    func rejectContact(_ peer: KnownPeer) {
        chatManager?.rejectContactRequest(peerID: peer.id)
        pendingContactRequests.removeAll { $0.id == peer.id }
        savePendingRequests()
    }

    // MARK: - Multi-device linking

    /// Generate QR payload data for showing on the "link device" screen.
    func generateDeviceLinkQR() -> Data? {
        let label = UIDevice.current.name
        return try? chatManager?.generateDeviceLinkPayload(label: label)
    }

    /// Called after scanning a device-link QR from another device.
    func acceptDeviceLink(_ data: Data) {
        do {
            try chatManager?.acceptDeviceLink(data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlinkDevice(_ peer: KnownPeer) {
        chatManager?.unlinkDevice(peerID: peer.id)
        linkedDevices.removeAll { $0.id == peer.id }
    }

    // MARK: - Blocking

    func blockPeer(peerID: String) {
        if let peer = peers.first(where: { $0.id == peerID }) {
            blockedPeerNames[peerID] = peer.username
        }
        blockedPeers.insert(peerID)
        saveBlockedPeers()
        // Remove from active peers list — they'll reappear if unblocked and online
        peers.removeAll { $0.id == peerID }
        let notifIDs = messages[peerID]?.map(\.id) ?? []
        messages.removeValue(forKey: peerID)
        unreadCounts.removeValue(forKey: peerID)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: notifIDs)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: notifIDs)
        savePeers()
    }

    func unblockPeer(peerID: String) {
        blockedPeers.remove(peerID)
        blockedPeerNames.removeValue(forKey: peerID)
        saveBlockedPeers()
    }

    func isBlocked(_ peerID: String) -> Bool {
        blockedPeers.contains(peerID)
    }

    // MARK: - Unread counts

    func markAsRead(peerID: String) {
        unreadCounts[peerID] = 0
        // Clear any delivered notifications for this conversation
        let ids = messages[peerID]?.map(\.id) ?? []
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        // Update app badge to reflect remaining unread count
        UIApplication.shared.applicationIconBadgeNumber = totalUnreadCount
        // Send read receipts for received messages still showing as .delivered
        let unread = messages[peerID]?.filter { $0.direction == .received && $0.status == .delivered } ?? []
        if !unread.isEmpty {
            chatManager?.sendReadReceipts(messageIDs: unread.map(\.id), toPeerID: peerID)
        }
    }

    // MARK: - Forward message

    /// Re-sends a stored message (text or attachment) to a different peer.
    func forwardMessage(_ message: StoredMessage, toPeerID peerID: String, expiresAt: Date? = nil) {
        if let id   = message.attachmentID,
           let mime = message.attachmentMimeType,
           let data = loadAttachment(id: id) {
            chatManager?.sendAttachment(data, mimeType: mime, caption: message.body,
                                        audioDuration: message.audioDuration,
                                        toPeerID: peerID, expiresAt: expiresAt)
        } else if !message.body.isEmpty {
            chatManager?.sendMessage(message.body, toPeerID: peerID, expiresAt: expiresAt)
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        // Register category with a placeholder so the message body is hidden
        // when the user has "Show Previews: When Unlocked" or "Never" set in system Settings.
        let category = UNNotificationCategory(
            identifier: "SOPHAX_MSG",
            actions: [],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: NSLocalizedString("New message", comment: ""),
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private var totalUnreadCount: Int { unreadCounts.values.reduce(0, +) }

    private func scheduleNotification(for message: StoredMessage, fromPeer peerID: String) {
        let (title, body): (String, String) = notifShowSender
            ? (peers.first(where: { $0.id == peerID }).map { displayName(for: $0) } ?? "SophaxChat",
               message.body.isEmpty ? "Attachment" : message.body)
            : ("SophaxChat", "New message")
        postNotification(id: message.id, title: title, body: body, threadKey: peerID)
    }

    private func scheduleGroupNotification(for message: StoredMessage, groupID: String) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let (title, body): (String, String) = notifShowSender
            ? (group.name, message.body.isEmpty ? "Attachment" : message.body)
            : ("SophaxChat", "New group message")
        postNotification(id: message.id, title: title, body: body, threadKey: groupID)
    }

    /// Common notification posting logic. `threadKey` is hashed before use so raw
    /// peer/group IDs are not exposed in Notification Centre grouping on the lock screen.
    private func postNotification(id: String, title: String, body: String, threadKey: String) {
        // Strip ASCII control characters and truncate to prevent lock-screen injection
        let safeBody = String(body.filter { c in
            !c.isASCII || (c.asciiValue.map { $0 >= 0x20 && $0 != 0x7F } ?? true)
        }.prefix(200))
        let content = UNMutableNotificationContent()
        content.title              = title
        content.body               = safeBody
        content.sound              = .default
        content.badge              = (totalUnreadCount + 1) as NSNumber
        content.threadIdentifier   = Data(SHA256.hash(data: Data(threadKey.utf8))).prefix(8).hexString
        content.categoryIdentifier = "SOPHAX_MSG"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }

    // MARK: - Contact aliases

    func displayName(for peer: KnownPeer) -> String {
        peerAliases[peer.id] ?? peer.username
    }

    func setAlias(_ alias: String?, for peerID: String) {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = trimmed, !name.isEmpty {
            peerAliases[peerID] = name
        } else {
            peerAliases.removeValue(forKey: peerID)
        }
        saveAliases()
    }

    // MARK: - Safety Number pinning

    /// Mark a peer's safety number as verified (called after successful QR or manual comparison).
    func markPeerVerified(_ peerID: String, safetyNumber: String) {
        verifiedPeers[peerID] = safetyNumber
        saveVerifiedPeers()
    }

    /// Returns true if this peer has been verified and their safety number hasn't changed.
    func isVerified(_ peerID: String, currentSafetyNumber: String) -> Bool {
        verifiedPeers[peerID] == currentSafetyNumber
    }

    /// Returns true if a peer was previously verified but their safety number has since changed.
    func hasKeyChanged(for peerID: String, currentSafetyNumber: String) -> Bool {
        guard let pinned = verifiedPeers[peerID] else { return false }
        return pinned != currentSafetyNumber
    }

    /// Returns the full key-change history for a peer from KeyTransparencyLog.
    func keyHistory(for peerID: String) -> [KeyLogEntry] {
        chatManager?.keyLog.history(for: peerID) ?? []
    }

    // MARK: - TCP internet mode

    /// Initiate an outbound TCP connection to a peer at "host:port" or "host.onion:port".
    /// Returns an error message string on failure, nil on success.
    @discardableResult
    func connectViaTCP(address: String) -> String? {
        guard Self.isValidTCPAddress(address) else {
            return "Invalid address. Use host:port format, e.g. 192.168.1.1:25519 or xyz.onion:25519"
        }
        do {
            try chatManager?.connectViaTCP(address: address)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Validates "host:port" format. Splits on the last colon to support .onion and IPv4.
    /// Rejects private/loopback addresses to prevent SSRF via peer-advertised TCP addresses.
    static func isValidTCPAddress(_ address: String) -> Bool {
        guard let colonIdx = address.lastIndex(of: ":") else { return false }
        let host = String(address[..<colonIdx])
        let portStr = String(address[address.index(after: colonIdx)...])
        guard !host.isEmpty, let port = UInt16(portStr), port > 0 else { return false }
        // Allow .onion addresses (Tor hidden services) — these are always safe to connect to
        if host.hasSuffix(".onion") { return true }
        // Block loopback, link-local, and private RFC-1918/RFC-4193 ranges to prevent SSRF
        let privateRanges = ["127.", "10.", "169.254.", "0.0.0.0",
                             "::1", "0:0:0:0:0:0:0:1", "fc", "fd", "fe80"]
        let lc = host.lowercased()
        if privateRanges.contains(where: { lc.hasPrefix($0) }) { return false }
        if lc == "0" || lc == "localhost" { return false }
        if lc.hasPrefix("172.") {
            let parts = lc.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return false }
        }
        if lc.hasPrefix("192.168.") { return false }
        return true
    }

    /// The Tor v3 .onion hostname derived from this device's identity key.
    /// Nil only before identity is created (first launch before onboarding completes).
    var derivedOnionHostname: String? { chatManager?.identity.onionHostname }

    /// Number of one-time prekeys remaining. Below 5 means reduced X3DH entropy.
    var opkCount: Int { chatManager?.preKeys.opkCount ?? 0 }

    /// The full advertised Tor address (hostname:port) for display and sharing.
    var derivedOnionAddress: String? {
        guard let host = derivedOnionHostname else { return nil }
        let port = tcpPort.isEmpty ? "25519" : tcpPort
        return "\(host):\(port)"
    }

    /// Called on `didBecomeActive` — reconnect to all known peers that have a TCP address.
    /// No-op if TCP is disabled or no peers have an address.
    /// Decentralized: connects directly peer-to-peer, no server involved.
    func reconnectTCPPeers() {
        guard tcpEnabled, let tcp = chatManager?.tcpTransport else { return }
        for peer in peers {
            guard let addr = peer.tcpAddress,
                  !tcp.isConnected(peerID: peer.id),
                  Self.isValidTCPAddress(addr) else { continue }
            try? chatManager?.connectViaTCP(address: addr)
        }
    }

    // MARK: - App lock

    var appLockEnabled: Bool {
        get { keychain.loadAppLockEnabled() ?? false }
        set { try? keychain.saveAppLockEnabled(newValue) }
    }

    // MARK: - Account wipe

    /// Permanently delete all identity keys, messages, attachments, and settings.
    /// The app returns to OnboardingView because `isSetupComplete` is reset to false.
    func wipeAccount() {
        try? chatManager?.wipeAllData()
        chatManager = nil

        // Delete Tor data directory — contains the hidden service private key.
        // Without this, the old .onion address could be reconstructed after a wipe.
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: appSupport.appendingPathComponent("tor_data"))
        }

        let ud = UserDefaults.standard
        for key in ud.dictionaryRepresentation().keys where key.hasPrefix("com.sophax.") || key.hasPrefix("sophax.") {
            ud.removeObject(forKey: key)
        }

        clearInMemoryState()
        blockedPeers     = []
        blockedPeerNames = [:]
        peerAliases      = [:]
        myAvatarData     = nil

        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UIApplication.shared.applicationIconBadgeNumber = 0

        isSetupComplete = false
    }

    func lockApp() {
        guard appLockEnabled else { return }
        chatManager?.stop()
        chatManager = nil          // release all session state and key material from RAM

        // Clear sensitive published state so plaintext is not readable from RAM while locked.
        // Data is reloaded from encrypted storage after successful authentication.
        clearInMemoryState()

        isAppLocked = true
        pendingDeepLink = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Zero out all in-memory conversation/peer state. Called on both lock and wipe.
    private func clearInMemoryState() {
        peers                  = []
        pendingContactRequests = []
        linkedDevices          = []
        messages               = [:]
        groups                 = []
        peerAvatars            = [:]
        onlinePeers            = []
        unreadCounts           = [:]
        typingPeers            = []
        keyChangeAlerts        = []
    }

    func tryUnlock() {
        // Rate-limit: check lockout before allowing another attempt
        if let until = unlockLockedUntil, Date() < until {
            let remaining = Int(until.timeIntervalSinceNow.rounded(.up))
            let mins = remaining / 60, secs = remaining % 60
            unlockError = mins > 0
                ? "Too many failed attempts. Try again in \(mins)m \(secs)s."
                : "Too many failed attempts. Try again in \(secs)s."
            return
        }

        guard !isUnlocking else { return }  // prevent multiple simultaneous prompts

        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Device has no passcode or biometrics configured.
            // Do NOT silently unlock — keep the app locked and surface an error.
            unlockError = "Device authentication unavailable. Set a passcode in iOS Settings."
            return
        }
        unlockError  = nil
        isUnlocking  = true
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "Unlock SophaxChat") { success, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isUnlocking = false
                if success {
                    // Reset rate-limit on successful unlock
                    self.failedUnlockAttempts = 0
                    self.unlockLockedUntil    = nil
                    self.keychain.saveUnlockAttempts(0, lockedUntil: nil)
                    self.unlockError  = nil
                    self.isAppLocked  = false
                    self.setupChatManager(username: nil)
                } else {
                    // Increment failure counter; apply exponential lockout after 6 failures
                    self.failedUnlockAttempts += 1
                    let delays: [TimeInterval] = [0, 0, 0, 0, 0, 0, 300, 900, 3600]
                    let delay = delays[min(self.failedUnlockAttempts, delays.count - 1)]
                    self.unlockLockedUntil = delay > 0 ? Date().addingTimeInterval(delay) : nil
                    self.keychain.saveUnlockAttempts(
                        self.failedUnlockAttempts, lockedUntil: self.unlockLockedUntil)
                }
            }
        }
    }

    // MARK: - Duress mode

    /// Activate duress mode: clears all in-memory state, stops the chat engine,
    /// and keeps the app open but appearing empty.
    /// Incoming messages are dropped while duress is active (they remain on disk).
    func activateDuress() {
        chatManager?.stop()
        chatManager = nil
        clearInMemoryState()
        isDuressActive = true
        isAppLocked    = false  // remove the lock overlay so the empty state is visible
    }

    /// Unlock using a custom numeric PIN (alternative to biometrics).
    /// Checks the duress PIN first; if it matches, activates duress mode.
    /// Then checks the real lock PIN; if it matches, performs a normal unlock.
    /// - Returns: `true` if the PIN was accepted (either duress or real).
    @discardableResult
    func tryUnlockWithPIN(_ pin: String) -> Bool {
        // Duress PIN takes priority — silent activation, no error shown
        if keychain.verifyDuressPIN(pin) {
            activateDuress()
            return true
        }
        // Real PIN — normal unlock
        if keychain.verifyRealLockPIN(pin) {
            failedUnlockAttempts = 0
            unlockLockedUntil    = nil
            keychain.saveUnlockAttempts(0, lockedUntil: nil)
            unlockError          = nil
            isAppLocked          = false
            setupChatManager(username: nil)
            return true
        }
        // Wrong PIN — increment failure counter
        failedUnlockAttempts += 1
        let delays: [TimeInterval] = [0, 0, 0, 0, 0, 0, 300, 900, 3600]
        let delay = delays[min(failedUnlockAttempts, delays.count - 1)]
        unlockLockedUntil = delay > 0 ? Date().addingTimeInterval(delay) : nil
        keychain.saveUnlockAttempts(failedUnlockAttempts, lockedUntil: unlockLockedUntil)
        unlockError = "Wrong PIN."
        return false
    }

    // MARK: - Private helpers

    private func loadExistingMessages(from store: MessageStore) {
        let peerIDs = store.allConversationPeerIDs()
        for peerID in peerIDs {
            guard !blockedPeers.contains(peerID) else { continue }
            if let msgs = try? store.messages(forPeer: peerID) {
                messages[peerID] = msgs
            }
        }
        // Also load group conversations
        for group in groups {
            if let msgs = try? store.messages(forPeer: group.conversationID) {
                messages[group.conversationID] = msgs
            }
        }
    }

    private func appendMessage(_ message: StoredMessage) {
        var existing = messages[message.peerID] ?? []
        guard !existing.contains(where: { $0.id == message.id }) else { return }
        existing.append(message)
        // Sort by receivedAt (local wall-clock) when available; fall back to sender timestamp.
        // This prevents a clock-skewed or malicious sender from reordering our conversation view.
        existing.sort {
            ($0.receivedAt ?? $0.timestamp) < ($1.receivedAt ?? $1.timestamp)
        }
        messages[message.peerID] = existing
    }

    // MARK: - TCP persistence + lifecycle

    private func loadTCPSettings() {
        let ud = UserDefaults.standard
        tcpEnabled      = ud.bool(forKey: tcpEnabledKey)
        tcpPort         = ud.string(forKey: tcpPortKey)       ?? "25519"
        tcpSocksProxy   = ud.string(forKey: tcpSocksProxyKey) ?? ""
        myTCPAddress    = ud.string(forKey: tcpAddressKey)    ?? ""
        notifShowSender = ud.bool(forKey: notifShowSenderKey)
    }

    private func makeTCPConfig() -> TCPTransport.Config {
        let port  = UInt16(tcpPort) ?? 25519
        let proxy = tcpSocksProxy.trimmingCharacters(in: .whitespaces)
        return TCPTransport.Config(port: port, socksProxy: proxy.isEmpty ? nil : proxy)
    }

    private func startTCPTransport(on manager: ChatManager) {
        let transport = TCPTransport(config: makeTCPConfig())
        manager.startTCP(transport)
    }

    private func applyTCPConfig() {
        guard let manager = chatManager else { return }
        // Auto-populate our advertised address from the identity-derived .onion hostname
        // if the user has not set a custom address. This means zero configuration:
        // the user's Tor address is their identity key, no manual entry needed.
        if myTCPAddress.isEmpty,
           let hostname = chatManager?.identity.onionHostname {
            let port = tcpPort.isEmpty ? "25519" : tcpPort
            manager.myTCPAddress = "\(hostname):\(port)"
        }
        if tcpEnabled {
            #if !targetEnvironment(macCatalyst)
            // Tor-enforced mode: refuse to start TCP until Tor is fully bootstrapped.
            if torEnforcedMode {
                guard case .ready = TorManager.shared.state else {
                    // Tor not ready — hold off; observeTorState will retry when Tor is ready.
                    return
                }
            }
            #endif
            startTCPTransport(on: manager)
        } else {
            manager.stopTCP()
        }
    }

    // MARK: - Embedded Tor

    #if !targetEnvironment(macCatalyst)
    /// Observes TorManager state. When Tor becomes ready, auto-wires the SOCKS5 proxy
    /// into tcpSocksProxy if the user has not manually overridden it.
    /// When Tor-enforced mode is on, also starts/stops TCP as Tor transitions.
    private func observeTorState() {
        Task { [weak self] in
            for await state in TorManager.shared.$state.values {
                guard let self else { return }
                switch state {
                case .ready:
                    if self.torEnabled, self.tcpSocksProxy.isEmpty {
                        self.tcpSocksProxy = TorManager.socksProxy
                    }
                    // In Tor-enforced mode, start TCP now that Tor is ready
                    if self.torEnforcedMode && self.tcpEnabled {
                        await MainActor.run { self.applyTCPConfig() }
                    }
                case .stopped, .failed:
                    // In Tor-enforced mode, stop TCP if Tor goes down (fail-closed)
                    if self.torEnforcedMode {
                        await MainActor.run { self.chatManager?.stopTCP() }
                    }
                default:
                    break
                }
            }
        }
    }
    #endif

    // MARK: - Deep link handling

    /// A parsed contact card link waiting for user confirmation before any TCP connection is made.
    struct PendingDeepLink: Identifiable {
        let id = UUID()
        let peerID: String
        let address: String   // "host.onion:port"
        let onionHost: String // display-only
    }

    /// Handles `sophaxchat://meet?pid=...&name=...&sk=...&dk=...` mesh identity invite links.
    /// Adds the contact to the known peers list without requiring a TCP connection.
    private func handleMeetLink(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let items = components?.queryItems,
              let pid     = items.first(where: { $0.name == "pid" })?.value,
              let nameB64 = items.first(where: { $0.name == "name" })?.value,
              let skB64   = items.first(where: { $0.name == "sk" })?.value,
              let dkB64   = items.first(where: { $0.name == "dk" })?.value,
              !pid.isEmpty,
              let nameData  = Data(base64Encoded: nameB64),
              let username  = String(data: nameData, encoding: .utf8),
              username.count <= 64,
              let signingKey = Data(base64Encoded: skB64),
              let dhKey     = Data(base64Encoded: dkB64),
              signingKey.count == 32, dhKey.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey)) != nil,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: dhKey)) != nil
        else { return }
        // Don't add ourselves
        guard pid != chatManager?.identity.publicIdentity.peerID else { return }
        // If already known, just surface them
        guard !peers.contains(where: { $0.id == pid }) else { return }
        let combined = signingKey + dhKey
        let hash = Data(CryptoKit.SHA512.hash(data: combined))
        let groups = stride(from: 0, to: 30, by: 5).map { i -> String in
            let chunk = hash[i..<(i + 5)]
            let value = chunk.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 100_000
            return String(format: "%05d", value)
        }
        let safetyNumber = groups.joined(separator: " ")
        var peer = KnownPeer(
            id:               pid,
            username:         username,
            signingKeyPublic: signingKey,
            dhKeyPublic:      dhKey,
            safetyNumber:     safetyNumber,
            lastSeen:         nil,
            isOnline:         false,
            isDirectlyConnected: false
        )
        peer.tcpAddress = nil
        peers.append(peer)
        savePeers()
        lastAddedContactAddress = username
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if lastAddedContactAddress == username { lastAddedContactAddress = nil }
        }
    }

    /// Handles `sophaxchat://add?id=<peerID>&onion=<host>&port=<port>` contact card links.
    /// Parsing is immediate; connecting requires explicit user confirmation via `confirmDeepLink()`.
    func handleIncomingLink(_ url: URL) {
        guard url.scheme?.lowercased() == "sophaxchat" else { return }
        if url.host?.lowercased() == "meet" {
            handleMeetLink(url)
            return
        }
        guard url.host?.lowercased() == "add" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let items = components?.queryItems,
              let peerID = items.first(where: { $0.name == "id" })?.value,
              let rawOnionHost = items.first(where: { $0.name == "onion" })?.value,
              !peerID.isEmpty else { return }
        let onionHost = rawOnionHost.lowercased()
        guard onionHost.hasSuffix(".onion") else { return }
        let portStr = items.first(where: { $0.name == "port" })?.value ?? "25519"
        guard let port = UInt16(portStr), port > 1023 else { return }
        let address = "\(onionHost):\(port)"
        guard Self.isValidTCPAddress(address) else { return }
        // Ask the user before making any TCP connection — prevents IP disclosure to attacker-
        // controlled addresses embedded in crafted sophaxchat:// links.
        pendingDeepLink = PendingDeepLink(peerID: peerID, address: address, onionHost: onionHost)
    }

    /// Called when the user taps "Add" in the deep-link confirmation alert.
    func confirmDeepLink() {
        guard let pending = pendingDeepLink else { return }
        pendingDeepLink = nil
        // Store the address on the peer if we already know them, or remember it for later
        if let idx = peers.firstIndex(where: { $0.id == pending.peerID }) {
            peers[idx].tcpAddress = pending.address
            savePeers()
        } else {
            UserDefaults.standard.set(pending.address, forKey: "com.sophax.pendingOnion.\(pending.peerID)")
        }
        // Attempt immediate TCP connect if TCP is enabled
        if tcpEnabled {
            connectViaTCP(address: pending.address)
        }
        // Show a brief toast so the user knows the card was added
        lastAddedContactAddress = pending.onionHost
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            lastAddedContactAddress = nil
        }
    }

    // MARK: - Peer persistence

    private let peersDefaultsKey    = "com.sophax.knownPeers"
    private let pendingRequestsKey  = "com.sophax.pendingRequests"

    private func loadSavedPeers() {
        guard let data = UserDefaults.standard.data(forKey: peersDefaultsKey),
              let saved = try? JSONDecoder().decode([KnownPeer].self, from: data) else { return }
        peers = saved.map { peer in
            var p = peer
            p.isOnline = false
            p.isDirectlyConnected = false
            return p
        }
        // Restore avatar cache from persisted peers
        for peer in peers {
            if let avatar = peer.avatarData { peerAvatars[peer.id] = avatar }
        }
    }

    private func savePeers() {
        if let data = try? JSONEncoder().encode(peers) {
            UserDefaults.standard.set(data, forKey: peersDefaultsKey)
        }
    }

    private func loadPendingRequests() {
        guard let data  = UserDefaults.standard.data(forKey: pendingRequestsKey),
              let saved = try? JSONDecoder().decode([KnownPeer].self, from: data) else { return }
        pendingContactRequests = saved
    }

    private func savePendingRequests() {
        if let data = try? JSONEncoder().encode(pendingContactRequests) {
            UserDefaults.standard.set(data, forKey: pendingRequestsKey)
        }
    }

    // MARK: - Alias persistence

    private func loadAliases() {
        // Primary: Keychain
        let fromKeychain = keychain.loadPeerAliases()
        if !fromKeychain.isEmpty {
            peerAliases = fromKeychain
            return
        }
        // One-time migration from UserDefaults → Keychain
        let legacyKey = "com.sophax.peerAliases"
        if let data  = UserDefaults.standard.data(forKey: legacyKey),
           let saved = try? JSONDecoder().decode([String: String].self, from: data),
           !saved.isEmpty {
            peerAliases = saved
            keychainSave("peerAliases") {
                try keychain.savePeerAliases(saved)
                UserDefaults.standard.removeObject(forKey: legacyKey)
            }
        }
    }

    private func saveAliases() {
        keychainSave("peerAliases") { try keychain.savePeerAliases(peerAliases) }
    }

    // MARK: - Blocked peers persistence

    private func loadBlockedPeers() {
        // Primary: Keychain
        let (ids, names) = keychain.loadBlockedPeers()
        if !ids.isEmpty || !names.isEmpty {
            blockedPeers = ids
            blockedPeerNames = names
            return
        }
        // One-time migration from UserDefaults → Keychain
        let legacyIDsKey   = "com.sophax.blockedPeers"
        let legacyNamesKey = "com.sophax.blockedPeerNames"
        let savedIDs   = Set(UserDefaults.standard.stringArray(forKey: legacyIDsKey) ?? [])
        var savedNames = [String: String]()
        if let data  = UserDefaults.standard.data(forKey: legacyNamesKey),
           let names = try? JSONDecoder().decode([String: String].self, from: data) {
            savedNames = names
        }
        if !savedIDs.isEmpty || !savedNames.isEmpty {
            blockedPeers     = savedIDs
            blockedPeerNames = savedNames
            keychainSave("blockedPeers") {
                try keychain.saveBlockedPeers(savedIDs, names: savedNames)
                UserDefaults.standard.removeObject(forKey: legacyIDsKey)
                UserDefaults.standard.removeObject(forKey: legacyNamesKey)
            }
        }
    }

    private func saveBlockedPeers() {
        keychainSave("blockedPeers") { try keychain.saveBlockedPeers(blockedPeers, names: blockedPeerNames) }
    }

    // MARK: - Keychain helpers

    /// Executes a Keychain save, logging failures in debug builds.
    /// Silent discard is intentional in release — Keychain errors are transient
    /// (locked device, quota) and must not crash the app or block the call site.
    @inline(__always)
    private func keychainSave(_ label: String, _ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            #if DEBUG
            print("[SophaxChat] ⚠️ Keychain save failed (\(label)): \(error)")
            #endif
        }
    }

    // MARK: - Verified peers persistence

    private func loadVerifiedPeers() {
        // Primary: Keychain (device-local, excluded from iCloud backup)
        let fromKeychain = keychain.loadVerifiedPeers()
        if !fromKeychain.isEmpty {
            verifiedPeers = fromKeychain
            return
        }
        // One-time migration from UserDefaults → Keychain
        let legacyKey = "com.sophax.verifiedPeers"
        if let data  = UserDefaults.standard.data(forKey: legacyKey),
           let saved = try? JSONDecoder().decode([String: String].self, from: data),
           !saved.isEmpty {
            verifiedPeers = saved
            do {
                try keychain.saveVerifiedPeers(saved)
                UserDefaults.standard.removeObject(forKey: legacyKey)
            } catch {
                // Leave in UserDefaults and retry on next launch
                #if DEBUG
                print("[AppState] ⚠️ verifiedPeers migration to Keychain failed: \(error)")
                #endif
            }
        }
    }

    private func saveVerifiedPeers() {
        keychainSave("verifiedPeers") { try keychain.saveVerifiedPeers(verifiedPeers) }
    }

    // MARK: - Pinned Messages

    func pinMessage(_ messageID: String, inConversation convID: String) {
        pinnedMessages[convID] = messageID
        keychainSave("pinnedMessages") { try keychain.savePinnedMessages(pinnedMessages) }
    }

    func unpinMessage(inConversation convID: String) {
        pinnedMessages.removeValue(forKey: convID)
        keychainSave("pinnedMessages") { try keychain.savePinnedMessages(pinnedMessages) }
    }

    private func loadPinnedMessages() {
        let saved = keychain.loadPinnedMessages()
        if !saved.isEmpty { pinnedMessages = saved }
    }

    // MARK: - Backup

    /// Build an encrypted backup blob. Caller presents the ShareSheet.
    func exportBackup(passphrase: String) throws -> Data {
        guard let cm = chatManager else {
            throw SophaxError.sessionNotInitialized
        }
        let store    = cm.messageStore
        let peerIDs  = store.allConversationPeerIDs()
        var messages = [String: [StoredMessage]]()
        for pid in peerIDs {
            messages[pid] = (try? store.messages(forPeer: pid)) ?? []
        }
        // Include identity fingerprint so restore can warn if the backup belongs to a different identity.
        let pub         = cm.identity.publicIdentity
        let fingerprint = cm.identity.identityFingerprint
        let backup = SophaxBackup(
            version:             1,
            createdAt:           Date(),
            username:            pub.username,
            peers:               peers,
            messages:            messages,
            identityFingerprint: fingerprint
        )
        return try BackupManager.export(backup: backup, passphrase: passphrase)
    }

    // MARK: - Full export (identity + messages in one file)

    /// Export identity keys + full message history into a single encrypted `.sxfe` blob.
    func exportFullBackup(passphrase: String) throws -> Data {
        guard let cm = chatManager else { throw SophaxError.sessionNotInitialized }
        let store    = cm.messageStore
        let peerIDs  = store.allConversationPeerIDs()
        var messages = [String: [StoredMessage]]()
        for pid in peerIDs {
            messages[pid] = (try? store.messages(forPeer: pid)) ?? []
        }
        let pub         = cm.identity.publicIdentity
        let fingerprint = cm.identity.identityFingerprint
        let backup = SophaxBackup(
            version:             1,
            createdAt:           Date(),
            username:            pub.username,
            peers:               peers,
            messages:            messages,
            identityFingerprint: fingerprint
        )
        return try FullExportManager.export(
            identity:   cm.identity,
            backup:     backup,
            passphrase: passphrase
        )
    }

    /// Restore from a `.sxfe` full export — replaces identity keys and message history.
    func importFullBackup(data: Data, passphrase: String) throws {
        guard let cm = chatManager else { throw SophaxError.sessionNotInitialized }
        chatManager?.stop()
        chatManager = nil
        try FullExportManager.restore(
            data:         data,
            passphrase:   passphrase,
            keychain:     keychain,
            messageStore: cm.messageStore
        )
        setupChatManager(username: nil)
    }

    // MARK: - Identity backup / restore

    /// Export the local identity keypair + username as an encrypted blob (file extension `.sophaxid`).
    /// - Parameter passphrase: Must be at least 12 characters (enforced in UI).
    func exportIdentity(passphrase: String) throws -> Data {
        guard let cm = chatManager else { throw SophaxError.sessionNotInitialized }
        return try IdentityExportManager.export(identity: cm.identity, passphrase: passphrase)
    }

    /// Import an identity backup, replacing the current keypair.
    /// Stops the ChatManager, writes new keys to Keychain, restarts with the restored identity.
    /// All existing DR sessions become invalid after this call.
    func importIdentity(data: Data, passphrase: String) throws {
        chatManager?.stop()
        chatManager = nil
        try IdentityExportManager.import(data: data, passphrase: passphrase, keychain: keychain)
        setupChatManager(username: nil)
    }

    /// Restore message history and contacts from an encrypted backup blob.
    /// Does NOT replace identity keys — a new session will be needed with each contact.
    /// Throws `SophaxError.identityMismatch` (as a warning) if the backup fingerprint differs.
    func importBackup(data: Data, passphrase: String) throws {
        guard let cm = chatManager else {
            throw SophaxError.sessionNotInitialized
        }
        let backup = try BackupManager.import(data: data, passphrase: passphrase)

        // Warn if restoring from a different identity (e.g., accidental wrong backup).
        if let backupFP = backup.identityFingerprint,
           backupFP != cm.identity.identityFingerprint {
            throw SophaxError.identityMismatch
        }

        // Restore messages
        let store = cm.messageStore
        for (peerID, msgs) in backup.messages {
            for msg in msgs { try? store.append(message: msg) }
        }
        // Restore contacts (merge — don't overwrite existing)
        for peer in backup.peers where !peers.contains(where: { $0.id == peer.id }) {
            peers.append(peer)
        }
        savePeers()
    }
}

// MARK: - ChatManagerDelegate

extension AppState: @preconcurrency ChatManagerDelegate {

    func chatManager(_ manager: ChatManager, didDiscoverPeer peer: KnownPeer) {
        guard !blockedPeers.contains(peer.id) else { return }
        // Update avatar cache whenever a fresh Hello arrives
        if let avatar = peer.avatarData { peerAvatars[peer.id] = avatar }
        if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            let existing = peers[idx]
            // TOFU key-change detection: if the signing key is different from what we knew,
            // inject the old safety number into verifiedPeers so hasKeyChanged() fires in the UI.
            if existing.signingKeyPublic != peer.signingKeyPublic {
                if verifiedPeers[peer.id] == nil {
                    verifiedPeers[peer.id] = existing.safetyNumber
                    saveVerifiedPeers()
                }
                peers[idx] = peer
                savePeers()
            } else {
                peers[idx].isOnline = true
                if peer.avatarData != nil { peers[idx].avatarData = peer.avatarData }
            }
        } else {
            peers.append(peer)
            savePeers()
        }
        onlinePeers.insert(peer.id)
    }

    func chatManager(_ manager: ChatManager, peerDidDisconnect peerID: String) {
        onlinePeers.remove(peerID)
        let now = Date()
        if let idx = peers.firstIndex(where: { $0.id == peerID }) {
            peers[idx].isOnline = false
            peers[idx].lastSeen = now
        }
        if let idx = linkedDevices.firstIndex(where: { $0.id == peerID }) {
            linkedDevices[idx].isOnline = false
            linkedDevices[idx].lastSeen = now
        }
    }

    func chatManager(_ manager: ChatManager, didSendMessage message: StoredMessage, toPeer peerID: String) {
        appendMessage(message)
    }

    func chatManager(_ manager: ChatManager, didReceiveMessage message: StoredMessage, fromPeer peerID: String) {
        guard !blockedPeers.contains(peerID) else { return }
        appendMessage(message)
        unreadCounts[peerID, default: 0] += 1
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        let appState = UIApplication.shared.applicationState
        if appState == .background || appState == .inactive {
            scheduleNotification(for: message, fromPeer: peerID)
        }
    }

    func chatManager(_ manager: ChatManager, messageDelivered messageID: String, toPeer peerID: String) {
        if let idx = messages[peerID]?.firstIndex(where: { $0.id == messageID }) {
            messages[peerID]?[idx].status = .delivered
        }
    }

    func chatManager(_ manager: ChatManager, messagesRead messageIDs: [String], byPeer peerID: String) {
        for messageID in messageIDs {
            if let idx = messages[peerID]?.firstIndex(where: { $0.id == messageID }) {
                messages[peerID]?[idx].status = .read
            }
        }
    }

    func chatManager(_ manager: ChatManager, didUpdateReactions reactions: [String: String], onMessageID messageID: String, peerID: String) {
        if let idx = messages[peerID]?.firstIndex(where: { $0.id == messageID }) {
            messages[peerID]?[idx].reactions = reactions.isEmpty ? nil : reactions
        }
    }

    func chatManager(_ manager: ChatManager, peerDidUpdateTyping peerID: String, isTyping: Bool) {
        guard !blockedPeers.contains(peerID) else { return }
        typingTimeouts[peerID]?.cancel()
        if isTyping {
            typingPeers.insert(peerID)
            // Auto-clear after 8 seconds in case the stop signal is lost
            typingTimeouts[peerID] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.typingPeers.remove(peerID)
                self?.typingTimeouts.removeValue(forKey: peerID)
            }
        } else {
            typingPeers.remove(peerID)
            typingTimeouts.removeValue(forKey: peerID)
        }
    }

    func chatManager(_ manager: ChatManager, sessionEstablishedWithPeer peerID: String, usedOPK: Bool) {
        if !usedOPK {
            noOPKSessions.insert(peerID)
        }
    }

    func chatManager(_ manager: ChatManager, peerDidReconnect peer: KnownPeer) {
        reconnectedPeer = peer
        // Auto-clear after 4 seconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.reconnectedPeer?.id == peer.id {
                self?.reconnectedPeer = nil
            }
        }
    }

    func chatManager(_ manager: ChatManager, didUpdateGroupReactions reactions: [String: String],
                     onMessageID messageID: String, groupID: String) {
        let convID = "group.\(groupID)"
        if let idx = messages[convID]?.firstIndex(where: { $0.id == messageID }) {
            messages[convID]?[idx].reactions = reactions.isEmpty ? nil : reactions
        }
    }

    func chatManager(_ manager: ChatManager, peer leavingPeerID: String,
                     leftGroupID groupID: String, remainingMemberIDs: [String]) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let old = groups[idx]
        groups[idx] = GroupInfo(
            id:        old.id,
            name:      old.name,
            memberIDs: remainingMemberIDs,
            creatorID: old.creatorID
        )
        saveGroups()
    }

    func chatManager(_ manager: ChatManager, didJoinGroup group: GroupInfo) {
        if !groups.contains(where: { $0.id == group.id }) {
            groups.append(group)
            saveGroups()
        }
    }

    func chatManager(_ manager: ChatManager, didReceiveGroupMessage message: StoredMessage, inGroup groupID: String) {
        appendMessage(message)
        let convID = "group.\(groupID)"
        unreadCounts[convID, default: 0] += message.direction == .received ? 1 : 0
        if message.direction == .received {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            let appStatus = UIApplication.shared.applicationState
            if appStatus == .background || appStatus == .inactive {
                scheduleGroupNotification(for: message, groupID: groupID)
            }
        }
    }

    func chatManager(_ manager: ChatManager, didEncounterError error: Error) {
        if case SophaxError.decryptionFailed = error { return }
        errorMessage = error.localizedDescription
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if errorMessage == error.localizedDescription {
                errorMessage = nil
            }
        }
    }

    func chatManager(_ manager: ChatManager, didDiscoverChannel announcement: ChannelAnnouncement) {
        // Only show groups the local user is not already a member of
        let myID = manager.identity.publicIdentity.peerID
        let alreadyMember = groups.contains { $0.id == announcement.groupID }
        guard !alreadyMember, announcement.creatorID != myID else { return }
        discoveredChannels[announcement.groupID] = announcement
    }

    func chatManager(_ manager: ChatManager, groupMessageDelivered messageID: String,
                     inGroup groupID: String, byPeer peerID: String, isRead: Bool) {
        let convID = "group.\(groupID)"
        guard var msgs = messages[convID],
              let idx  = msgs.firstIndex(where: { $0.id == messageID }) else { return }
        if isRead {
            var set = msgs[idx].readBy ?? []
            guard !set.contains(peerID) else { return }
            set.append(peerID)
            msgs[idx].readBy = set
        } else {
            var set = msgs[idx].deliveredBy ?? []
            guard !set.contains(peerID) else { return }
            set.append(peerID)
            msgs[idx].deliveredBy = set
        }
        messages[convID] = msgs
    }

    func chatManager(_ manager: ChatManager, didReceiveEditedMessage messageID: String,
                     newBody: String, editedAt: Date, peerID: String) {
        if let idx = messages[peerID]?.firstIndex(where: { $0.id == messageID }) {
            messages[peerID]?[idx].body     = newBody
            messages[peerID]?[idx].isEdited = true
            messages[peerID]?[idx].editedAt = editedAt
        }
    }

    func chatManager(_ manager: ChatManager, didReceiveEditedGroupMessage messageID: String,
                     newBody: String, editedAt: Date, groupID: String) {
        let convID = "group.\(groupID)"
        if let idx = messages[convID]?.firstIndex(where: { $0.id == messageID }) {
            messages[convID]?[idx].body     = newBody
            messages[convID]?[idx].isEdited = true
            messages[convID]?[idx].editedAt = editedAt
        }
    }

    func sendGroupEditMessage(messageID: String, newBody: String, group: GroupInfo) {
        guard let cm = chatManager else { return }
        if group.cryptoVersion == .mls {
            cm.sendMLSGroupEditMessage(messageID: messageID, newBody: newBody, group: group)
        } else {
            cm.sendEditGroupMessage(messageID: messageID, newBody: newBody,
                                    groupID: group.id, members: group.memberIDs)
        }
    }

    func chatManager(_ manager: ChatManager, didDetectKeyChange forPeerID: String) {
        guard !keyChangeAlerts.contains(forPeerID) else { return }
        keyChangeAlerts.append(forPeerID)
    }

    func chatManager(_ manager: ChatManager, didRotateSenderKey forGroupID: String) {
        // No persistent state update needed — rotation is confirmed by the Keychain write in ChatManager.
    }

    func chatManager(_ manager: ChatManager, groupDeletedWithID groupID: String) {
        let convID = "group.\(groupID)"
        groups.removeAll { $0.id == groupID }
        saveGroups()
        messages.removeValue(forKey: convID)
        unreadCounts.removeValue(forKey: convID)
    }

    func chatManager(_ manager: ChatManager, didReceiveAvatarData data: Data, fromPeerID peerID: String) {
        peerAvatars[peerID] = data
    }

    func chatManager(_ manager: ChatManager, didUpdateCoordinator newCoordinatorID: String, inGroupID groupID: String) {
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups[idx].currentCoordinatorID = newCoordinatorID
            saveGroups()
        }
    }

    func chatManager(_ manager: ChatManager, didLinkDevice peer: KnownPeer) {
        guard !linkedDevices.contains(where: { $0.id == peer.id }) else { return }
        linkedDevices.append(peer)
    }

    func chatManager(_ manager: ChatManager, didReceiveSyncedMessage message: StoredMessage, conversationID: String) {
        appendMessage(message)
        // Don't increment unread or schedule a notification — this is our own message on another device
    }

    func chatManager(_ manager: ChatManager, didReceiveContactRequest peer: KnownPeer) {
        guard !blockedPeers.contains(peer.id) else { return }
        guard !pendingContactRequests.contains(where: { $0.id == peer.id }) else { return }
        pendingContactRequests.append(peer)
        savePendingRequests()
        postNotification(
            id: "req_\(peer.id)",
            title: "Contact Request",
            body: "\(peer.username) wants to connect",
            threadKey: "requests"
        )
    }
}
