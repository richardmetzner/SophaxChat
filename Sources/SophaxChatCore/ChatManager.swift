// ChatManager.swift
// SophaxChatCore
//
// High-level coordinator — the single entry point for the app layer.
//
// Session lifecycle:
//   1. Peer connects (MPC) → Hello exchanged immediately → PreKeyBundle stored
//   2. First sendMessage → X3DH sender-side → .initiateSession wire message
//   3. Subsequent messages → .message wire message (Double Ratchet)
//   4. Relay: peer not directly connected → wrap in RelayEnvelope, broadcast
//   5. Offline: no connected peers → queue message, drain on next connect/hello
//
// Threading:
//   All MeshManagerDelegate callbacks are dispatched through an internal
//   DispatchQueue by MeshManager, then delegate calls are re-dispatched to
//   main. ChatManager is @unchecked Sendable — the caller must not call
//   public methods concurrently from different threads.

import Foundation
import CryptoKit

// MARK: - Sealed sender helpers (file-private)

private func sealWireMessage(_ wire: WireMessage, recipientDHPublicKey: Data) throws -> SealedMessage {
    // Generate ephemeral key pair
    let ephPair   = DHKeyPair()
    let recipKey  = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientDHPublicKey)
    let shared    = try ephPair.privateKey.sharedSecretFromKeyAgreement(with: recipKey)

    // Derive sealing key
    var ikmData = Data()
    shared.withUnsafeBytes { ikmData.append(contentsOf: $0) }
    let sealingKey = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: ikmData),
        info: CryptoConstants.sealedSenderInfo,
        outputByteCount: 32
    )

    let wireJSON  = try JSONEncoder().encode(wire)
    let nonce     = ChaChaPoly.Nonce()
    let sealed    = try ChaChaPoly.seal(wireJSON, using: sealingKey, nonce: nonce, authenticating: Data())
    return SealedMessage(ephemeralPublicKey: ephPair.publicKeyData, encryptedPayload: sealed.combined)
}

private func unsealMessage(_ sealed: SealedMessage, recipientDHPrivateKey: Curve25519.KeyAgreement.PrivateKey) throws -> WireMessage {
    let ephKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sealed.ephemeralPublicKey)
    let shared = try recipientDHPrivateKey.sharedSecretFromKeyAgreement(with: ephKey)

    var ikmData = Data()
    shared.withUnsafeBytes { ikmData.append(contentsOf: $0) }
    let sealingKey = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: ikmData),
        info: CryptoConstants.sealedSenderInfo,
        outputByteCount: 32
    )

    do {
        let box      = try ChaChaPoly.SealedBox(combined: sealed.encryptedPayload)
        let wireJSON = try ChaChaPoly.open(box, using: sealingKey, authenticating: Data())
        return try JSONDecoder().decode(WireMessage.self, from: wireJSON)
    } catch {
        throw SophaxError.decryptionFailed
    }
}

// MARK: - Delegate

public protocol ChatManagerDelegate: AnyObject {
    /// A peer came online and their identity has been verified.
    func chatManager(_ manager: ChatManager, didDiscoverPeer peer: KnownPeer)
    /// A peer is no longer reachable (direct or relay).
    func chatManager(_ manager: ChatManager, peerDidDisconnect peerID: String)
    /// A new inbound message was decrypted and stored.
    func chatManager(_ manager: ChatManager, didReceiveMessage message: StoredMessage, fromPeer peerID: String)
    /// A message was sent (or queued) successfully by the local user.
    func chatManager(_ manager: ChatManager, didSendMessage message: StoredMessage, toPeer peerID: String)
    /// A sent message was acknowledged by the recipient.
    func chatManager(_ manager: ChatManager, messageDelivered messageID: String, toPeer peerID: String)
    /// A non-fatal error occurred (logged; caller may display or ignore).
    func chatManager(_ manager: ChatManager, didEncounterError error: Error)
    /// The remote peer's typing state changed.
    func chatManager(_ manager: ChatManager, peerDidUpdateTyping peerID: String, isTyping: Bool)
    /// The remote peer has read one or more messages we sent.
    func chatManager(_ manager: ChatManager, messagesRead messageIDs: [String], byPeer peerID: String)
    /// A peer updated their emoji reaction on a specific message.
    func chatManager(_ manager: ChatManager, didUpdateReactions reactions: [String: String], onMessageID messageID: String, peerID: String)
    /// The local user was added to a new group (created locally or invited by another peer).
    func chatManager(_ manager: ChatManager, didJoinGroup group: GroupInfo)
    /// A group chat message was decrypted and stored.
    func chatManager(_ manager: ChatManager, didReceiveGroupMessage message: StoredMessage, inGroup groupID: String)
    /// An X3DH session was established WITHOUT a one-time prekey (reduced entropy window).
    func chatManager(_ manager: ChatManager, sessionEstablishedWithPeer peerID: String, usedOPK: Bool)
    /// A previously-known peer has come back online after being offline.
    func chatManager(_ manager: ChatManager, peerDidReconnect peer: KnownPeer)
    /// Emoji reactions on a group message were updated.
    func chatManager(_ manager: ChatManager, didUpdateGroupReactions reactions: [String: String],
                     onMessageID messageID: String, groupID: String)
    /// A member left a group. The delegate should update stored membership to `remainingMemberIDs`.
    func chatManager(_ manager: ChatManager, peer leavingPeerID: String,
                     leftGroupID groupID: String, remainingMemberIDs: [String])
    /// A nearby peer is advertising a group that the local user is not a member of.
    /// The delegate can surface this in a "Nearby channels" list.
    func chatManager(_ manager: ChatManager, didDiscoverChannel announcement: ChannelAnnouncement)
    /// A group message we sent was acknowledged by `peerID`. `isRead` = true means the user
    /// has viewed the message; false means delivery-only confirmation.
    func chatManager(_ manager: ChatManager, groupMessageDelivered messageID: String,
                     inGroup groupID: String, byPeer peerID: String, isRead: Bool)
    /// A received message was edited by its sender. The delegate should update local state.
    func chatManager(_ manager: ChatManager, didReceiveEditedMessage messageID: String,
                     newBody: String, editedAt: Date, peerID: String)
    /// A group message was edited. The delegate should update local state.
    func chatManager(_ manager: ChatManager, didReceiveEditedGroupMessage messageID: String,
                     newBody: String, editedAt: Date, groupID: String)
    /// A peer's identity keys changed from a previously stored value.
    /// This may indicate a legitimate re-install or a potential MITM.
    func chatManager(_ manager: ChatManager, didDetectKeyChange forPeerID: String)
    /// The local user's sender key for a group was rotated (break-in recovery).
    func chatManager(_ manager: ChatManager, didRotateSenderKey forGroupID: String)
    /// The group creator dissolved the group; local user and all members must drop it.
    func chatManager(_ manager: ChatManager, groupDeletedWithID groupID: String)
    /// A group message carried avatar data for a peer not yet in peerAvatars.
    func chatManager(_ manager: ChatManager, didReceiveAvatarData data: Data, fromPeerID peerID: String)
    /// The MLS commit coordinator for a group was updated via a handoff message.
    func chatManager(_ manager: ChatManager, didUpdateCoordinator newCoordinatorID: String, inGroupID groupID: String)
    /// A new peer sent a Hello but has not yet been accepted — show accept/reject UI.
    func chatManager(_ manager: ChatManager, didReceiveContactRequest peer: KnownPeer)
    /// A device was successfully linked (via QR scan or incoming link request). UI should refresh the linked devices list.
    func chatManager(_ manager: ChatManager, didLinkDevice peer: KnownPeer)
    /// A linked device forwarded a message copy. Delegate should store and display it.
    func chatManager(_ manager: ChatManager, didReceiveSyncedMessage message: StoredMessage, conversationID: String)
    /// A contact sent us one of their SSS backup shares to hold. UI should confirm acceptance.
    func chatManager(_ manager: ChatManager, didReceiveSSSShare shareID: String,
                     fromPeerID: String, threshold: Int, total: Int)
    /// SSS recovery succeeded — `secret` is 64 bytes (Ed25519 || X25519 private keys).
    /// Caller is responsible for zeroing `secret` after use.
    func chatManager(_ manager: ChatManager, didRecoverSSSSecret secret: Data, shareID: String)

    /// Called when a trusted peer requests remote account wipe.
    func chatManagerDidReceiveRemoteWipeRequest(_ manager: ChatManager)
}

// MARK: - ChatManager

public final class ChatManager: @unchecked Sendable {

    // MARK: - Sub-components

    public let identity:        IdentityManager
    public let preKeys:         PreKeyManager
    public let mesh:            MeshManager
    public let messageStore:    MessageStore
    public let attachmentStore: AttachmentStore

    private let keychain:       KeychainManager
    let wireBuilder:    WireMessageBuilder
    private let relayRouter:    RelayRouter

    /// MLS group manager (Group v3). Nil until first use — initialised lazily on first
    /// MLS group create/join so non-MLS builds don't pay the Rust init cost.
    private var mlsManager: MLSGroupManager?

    /// Persistent log of observed peer identity keys for auditability.
    public let keyLog: KeyTransparencyLog

    // MARK: - State

    /// Active Double Ratchet sessions keyed by application-level peerID.
    /// Always access through withSession(_:) to guarantee mutual exclusion.
    private var sessions: [String: DoubleRatchet] = [:]

    /// Serialises every load → mutate → persist cycle on a single session.
    /// DoubleRatchet is a class whose encrypt/decrypt methods mutate internal
    /// state; concurrent access to the same session would corrupt the chain.
    private let sessionLock = NSLock()

    /// Peers whose identity we've cryptographically verified, keyed by peerID.
    private var knownPeers: [String: KnownPeer] = [:]

    /// PreKeyBundles keyed by peerID — populated on Hello, used for X3DH initiation.
    var peerBundles: [String: PreKeyBundle] = [:]

    /// Outbound messages queued for peers not currently reachable.
    /// Drained as soon as a path (direct or relay) becomes available.
    private var pendingQueue: [String: [(wire: WireMessage, messageID: String)]] = [:]

    /// Codable wrapper so pending queue items can be persisted to disk.
    private struct PendingQueueItem: Codable {
        let wire:      WireMessage
        let messageID: String
    }

    private let pendingQueueFileName = "pending_queue"

    /// In-memory cache of message keys for group messages that arrived out of order.
    /// Key: "groupID/senderPeerID" → (senderKeyIteration → messageKey)
    /// Bounded to `maxSkippedKeysCacheSize` entries per sender; oldest are evicted first.
    private var skippedGroupMessageKeys: [String: [UInt32: SymmetricKey]] = [:]
    /// Parallel timestamp map for Keychain persistence (entry age → eviction after 7 days).
    private var skippedGroupMessageKeyDates: [String: [UInt32: Date]] = [:]
    private static let maxSkippedKeysCacheSize               = 200
    private static let senderKeyRotationMessageLimit: UInt32 = 500
    private static let senderKeyRotationAgeLimit: TimeInterval = 7 * 24 * 3600
    private static let senderKeyRequestCooldown: TimeInterval  = 60
    private static let senderKeyStaleThreshold: TimeInterval   = 30 * 24 * 3600

    /// Last time we sent a senderKeyRequest for a given "groupID/peerID".
    /// Prevents request spam from peers who repeatedly send undecryptable messages.
    private var lastSenderKeyRequestSent: [String: Date] = [:]
    /// Last time we responded to a senderKeyRequest from a given "groupID/peerID".
    private var lastSenderKeyRequestResponded: [String: Date] = [:]

    /// Known group membership keyed by groupID. Populated on create/join, cleared on leave.
    /// Used to reject messages from peers not in the group.
    var joinedGroups: [String: Set<String>] = [:]

    /// Creator peerID for each joined group — used to verify group-delete authority.
    var groupCreators: [String: String] = [:]

    /// Current MLS commit coordinator per group. Starts as creatorID; updated on handoff.
    var groupCoordinators: [String: String] = [:]

    /// Crypto version per group — used to skip sealed-sender double-wrap for MLS groups.
    var groupCryptoVersions: [String: GroupCryptoVersion] = [:]

    /// PeerIDs of devices linked to this account (same person, different device).
    /// Inbound messages are forwarded to linked devices; they forward back via deviceSyncMessage.
    private var linkedDevicePeerIDs: Set<String> = []

    /// Human-readable label for this device shown to the pairing partner (e.g. "iPhone 16 Pro").
    public var deviceLabel: String = "Device"

    /// Messages stored on behalf of offline peers (relay-store role).
    private struct StoredForwardItem: Codable {
        let targetPeerID: String
        let messageID:    String
        let sealed:       SealedMessage
        let expiresAt:    Date
    }
    private var storedForwardItems: [StoredForwardItem] = []
    private static let maxStoredForwardItems    = 300
    private static let maxStoredForwardPerPeer  = 30    // prevents single-peer DoS
    private static let storeAndForwardTTL: TimeInterval = 48 * 60 * 60   // 48 hours
    private let storedForwardFileName = "stored_forward_items"

    /// Dead drops stored at this node — re-broadcast when target peer appears.
    private var deadDrops: [DeadDropEnvelope] = []
    private static let maxDeadDrops: Int              = 100
    private static let deadDropDedupeWindow: TimeInterval = 60   // seconds
    private var seenDeadDropIDs: [String: Date]       = [:]      // id → receivedAt

    // MARK: - SSS recovery accumulator

    /// Shares collected during an active recovery session: shareID → [SSSShare].
    /// When count ≥ threshold the secret is reconstructed.
    private var pendingRecoveryShares: [String: [SSSShare]] = [:]

    // MARK: - Per-peer rate limiter (typing + reaction)

    /// Token bucket: allow up to `capacity` events per `windowSeconds`, refilled continuously.
    private struct TokenBucket {
        let capacity: Double
        let windowSeconds: Double
        var tokens: Double
        var lastRefill: Date

        init(capacity: Double, windowSeconds: Double) {
            self.capacity = capacity
            self.windowSeconds = windowSeconds
            self.tokens = capacity
            self.lastRefill = Date()
        }

        /// Returns true if the event is allowed; false if rate-limited.
        mutating func consume() -> Bool {
            let now = Date()
            let elapsed = now.timeIntervalSince(lastRefill)
            tokens = min(capacity, tokens + elapsed * (capacity / windowSeconds))
            lastRefill = now
            if tokens >= 1 {
                tokens -= 1
                return true
            }
            return false
        }
    }

    /// Per-peer buckets for `.typing` (10 per 10 s) and `.reaction` (20 per 10 s).
    private var typingRateLimiters:   [String: TokenBucket] = [:]
    private var reactionRateLimiters: [String: TokenBucket] = [:]

    /// Fires every 60 seconds to purge messages whose expiresAt has passed.
    private var expiryTimer: Timer?

    // MARK: - DHT peer discovery

    private var dhtEngine:  DHTEngine?
    private var dhtStorage: DHTStorage?
    /// DHT messages queued for peers not yet TCP-connected.
    /// Keyed by "host.onion:port" — flushed in tcpTransport(_:didConnectToPeer:address:).
    private var pendingDHTMessages: [String: [WireMessage]] = [:]
    /// Rate limiter: max 30 DHT requests/min per sender.
    private var dhtRateLimiters: [String: TokenBucket] = [:]

    public weak var delegate: ChatManagerDelegate?

    // MARK: - TCP transport (optional internet layer)

    /// Set before calling `start()` — or swap at runtime via `startTCP` / `stopTCP`.
    /// Nil means local BLE/WiFi mesh only.
    public var tcpTransport: TCPTransport?

    /// Our TCP address advertised in Hello bundles ("host:port"), set by AppState.
    public var myTCPAddress: String?

    // MARK: - LAN discovery (mDNS/Bonjour — enables iOS ↔ Android on same WiFi)

    private var lanDiscovery: LanDiscovery?

    // MARK: - Init

    public init(
        identity:        IdentityManager,
        preKeys:         PreKeyManager,
        mesh:            MeshManager,
        messageStore:    MessageStore,
        attachmentStore: AttachmentStore,
        keychain:        KeychainManager
    ) {
        self.identity        = identity
        self.preKeys         = preKeys
        self.mesh            = mesh
        self.messageStore    = messageStore
        self.attachmentStore = attachmentStore
        self.keychain        = keychain
        self.keyLog          = KeyTransparencyLog(keychain: keychain)
        self.wireBuilder     = WireMessageBuilder(identity: identity)
        self.relayRouter     = RelayRouter()
        mesh.delegate        = self
    }

    // MARK: - MLS lazy init

    /// Returns the shared MLSGroupManager, creating it on first call.
    /// Throws if the signing key is unavailable (should never happen post-onboarding).
    func requireMLSManager() throws -> MLSGroupManager {
        if let m = mlsManager { return m }
        let signingKeyBytes = try identity.signingPrivateKeyData()
        let m = try MLSGroupManager(
            peerID: identity.publicIdentity.peerID,
            signingKeyBytes: signingKeyBytes,
            keychain: keychain
        )
        mlsManager = m
        return m
    }

    // MARK: - Public API

    /// Start advertising and browsing on the P2P mesh (and TCP if configured).
    public func start() {
        mesh.start()
        if let tcp = tcpTransport {
            tcp.helloProvider = { [weak self] in self?.makeTCPHello() }
            tcp.delegate = self
            tcp.start()
        }
        // mDNS discovery — auto-connects to iOS and Android peers on the same WiFi
        let lan = LanDiscovery()
        lan.delegate = self
        lan.start(peerID: identity.publicIdentity.peerID)
        lanDiscovery = lan
        try? preKeys.rotateIfNeeded()
        scheduleExpiryTimer()
        loadPersistedQueue()
        loadPersistedForwardItems()
        loadSkippedGroupKeyCache()
        loadLinkedDevices()
        seenWipeRequestIDs = keychain.loadSeenWipeRequestIDs()
    }

    /// Stop the mesh and TCP transport (call on app background / termination).
    public func stop() {
        mesh.stop()
        tcpTransport?.stop()
        lanDiscovery?.stop()
        lanDiscovery = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        persistQueue()
        persistForwardItems()
    }

    /// Permanently wipe all data — keys, messages, attachments.
    /// Call `stop()` before this. After returning, the caller should release this instance.
    public func wipeAllData() throws {
        stop()
        try keychain.wipeAll()
        keychain.deleteAllSSSData()
        try messageStore.wipeAll()
        try attachmentStore.wipeAll()
        // KeyTransparencyLog is stored in UserDefaults — cleared by the caller (AppState)
        // along with all other com.sophax.* UserDefaults keys.
    }

    /// Attach a TCP transport at runtime and start it immediately.
    public func startTCP(_ transport: TCPTransport) {
        tcpTransport?.stop()
        tcpTransport = transport
        transport.helloProvider = { [weak self] in self?.makeTCPHello() }
        transport.delegate = self
        transport.start()
    }

    /// Stop and detach the TCP transport.
    public func stopTCP() {
        tcpTransport?.stop()
        tcpTransport = nil
        if let engine = dhtEngine {
            Task { await engine.stop() }
        }
        dhtEngine = nil
    }

    /// Start the DHT engine. Call after TCP transport is up and myTCPAddress is set.
    public func startDHT() {
        guard dhtEngine == nil else { return }
        let storage = DHTStorage(messageStore: messageStore)
        dhtStorage = storage

        let sendBlock: DHTSendBlock = { [weak self] message, contact in
            guard let self else { return }
            self.sendDHTMessage(message, to: contact)
        }

        guard let engine = try? DHTEngine(
            identity:    identity,
            wireBuilder: wireBuilder,
            send:        sendBlock
        ) else { return }
        dhtEngine = engine

        // Bootstrap priority: (1) persisted k-buckets, (2) knownPeers with TCP address,
        // (3) hardcoded bootstrap nodes.
        var bootstrapContacts = storage.load()
        let fromKnown: [DHTContact] = knownPeers.values.compactMap { peer in
            guard let addr = peer.tcpAddress else { return nil }
            let nodeIDData = peer.signingKeyPublic + peer.dhKeyPublic
            let nodeID = Data(SHA256.hash(data: nodeIDData)).hexString
            let parts  = addr.split(separator: ":").map(String.init)
            guard parts.count == 2, parts[0].hasSuffix(".onion"),
                  let port = UInt16(parts[1]) else { return nil }
            return DHTContact(nodeID: nodeID, onionAddress: parts[0], port: port)
        }
        bootstrapContacts.append(contentsOf: fromKnown)
        if bootstrapContacts.isEmpty { bootstrapContacts = DHTBootstrap.nodes }

        Task {
            await engine.start(bootstrapContacts: bootstrapContacts)
            // Publish our bundle immediately after bootstrap so peers can find us
            // without waiting for the 60s expiry-timer tick.
            self.publishDHTBundleIfNeeded()
        }

        // Schedule k-bucket snapshot every 30 minutes
        Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            Task {
                let snap = await engine.table.snapshot()
                self.dhtStorage?.save(snapshot: snap)
            }
        }
    }

    /// Initiate an outbound TCP connection to `address` ("host:port").
    public func connectViaTCP(address: String) throws {
        guard let tcp = tcpTransport else { return }
        try tcp.connect(to: address)
    }

    // MARK: - DHT send helper

    /// Sends a DHT WireMessage to a contact. Connects if not already connected;
    /// queues the message and flushes it in tcpTransport(_:didConnectToPeer:address:).
    private func sendDHTMessage(_ message: WireMessage, to contact: DHTContact) {
        guard let tcp = tcpTransport else { return }
        let address = contact.tcpAddress
        if tcp.connectedPeerIDs.contains(where: { knownPeers[$0]?.tcpAddress == address }) {
            // Already connected — find the peerID and send
            if let peerID = tcp.connectedPeerIDs.first(where: { knownPeers[$0]?.tcpAddress == address }) {
                try? tcp.send(message, toPeerID: peerID)
            }
        } else {
            // Queue and connect
            pendingDHTMessages[address, default: []].append(message)
            try? tcp.connect(to: address)
        }
    }

    // MARK: - DHT peer lookup

    /// Lookup a peer by their 16-char peerID via the DHT.
    /// Resolves their PreKeyBundle, connects TCP, and returns a KnownPeer.
    public func lookupPeer(peerID: String) async throws -> KnownPeer {
        guard let engine = dhtEngine else { throw SophaxError.invalidMessageFormat("DHT not running") }

        let (_, bundle) = try await engine.lookup(peerID: peerID)

        let safetyNumber = generateSafetyNumber(for: bundle)
        let peer = KnownPeer(from: bundle, safetyNumber: safetyNumber, trustLevel: .pending)

        knownPeers[peerID] = peer
        if let addr = bundle.tcpAddress { try? connectViaTCP(address: addr) }

        return peer
    }

    // MARK: - Public: Identity broadcast

    /// Re-broadcast our Hello (PreKeyBundle) to all currently-connected peers (mesh + TCP).
    /// Call after a username change so peers pick up the new display name.
    public func broadcastHello() {
        guard let bundle = try? preKeys.generateBundle(tcpAddress: myTCPAddress) else { return }
        let hello = HelloMessage(bundle: bundle)
        guard let wire = try? wireBuilder.build(.hello, payload: hello) else { return }
        try? mesh.broadcast(wire)
        // Also push Hello to TCP peers — they need the refreshed bundle
        if let tcp = tcpTransport {
            for peerID in tcp.connectedPeerIDs {
                try? tcp.send(wire, toPeerID: peerID)
            }
        }
    }

    // MARK: - Public: Contact requests

    /// Accept a pending contact request — promotes peer to `.accepted` and fires `didDiscoverPeer`.
    public func acceptContactRequest(peerID: String) {
        guard var peer = knownPeers[peerID], peer.trustLevel == .pending else { return }
        peer.trustLevel = .accepted
        knownPeers[peerID] = peer
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didDiscoverPeer: peer)
        }
        // Now that the peer is accepted, drain any queued messages and deliver stored items
        drainQueue(forPeerID: peerID)
        deliverStoredForwardItems(toPeerID: peerID)
    }

    /// Reject a pending contact request — removes all local state for this peer.
    public func rejectContactRequest(peerID: String) {
        guard knownPeers[peerID]?.trustLevel == .pending else { return }
        knownPeers.removeValue(forKey: peerID)
        peerBundles.removeValue(forKey: peerID)
        pendingQueue.removeValue(forKey: peerID)
    }

    /// Register a peer that was persisted in the pending state across app restarts.
    /// Does NOT fire the `didReceiveContactRequest` delegate (already shown at request time).
    public func registerPendingPeer(_ peer: KnownPeer) {
        guard peer.trustLevel == .pending else { return }
        knownPeers[peer.id] = peer
    }

    // MARK: - Public: Multi-device linking

    /// All currently linked device peerIDs.
    public var linkedDevices: [String] { Array(linkedDevicePeerIDs) }

    /// Generate a JSON blob to encode in a QR code for device linking.
    /// The other device calls `acceptDeviceLink(_:)` after scanning.
    public func generateDeviceLinkPayload(label: String) throws -> Data {
        let bundle = try preKeys.generateBundle(tcpAddress: myTCPAddress)
        let msg = DeviceLinkRequestMessage(
            deviceLabel: label,
            bundle: bundle,
            expiresAt: Date().addingTimeInterval(10 * 60)   // 10-minute window
        )
        return try JSONEncoder().encode(msg)
    }

    /// Called on the scanning device after scanning a device-link QR.
    /// Stores the scanned device's bundle, marks it as linked, and queues a reply so
    /// the other device can complete the pairing without another QR scan.
    public func acceptDeviceLink(_ data: Data) throws {
        let msg = try JSONDecoder().decode(DeviceLinkRequestMessage.self, from: data)
        if let exp = msg.expiresAt, exp < Date() {
            throw SophaxError.invalidMessageFormat("Device link QR code has expired")
        }
        let peerID = msg.bundle.peerID
        guard peerID != identity.publicIdentity.peerID else { return }
        guard try msg.bundle.verifySignedPreKey() else { throw SophaxError.invalidSignature }

        peerBundles[peerID] = msg.bundle
        linkedDevicePeerIDs.insert(peerID)
        saveLinkedDevices()

        let safetyNumber = generateSafetyNumber(for: msg.bundle)
        let peer = KnownPeer(from: msg.bundle, safetyNumber: safetyNumber, trustLevel: .accepted)
        knownPeers[peerID] = peer

        // Queue a reciprocal deviceLinkRequest so the other device learns our bundle automatically.
        let myBundle = try preKeys.generateBundle(tcpAddress: myTCPAddress)
        let reply = DeviceLinkRequestMessage(deviceLabel: deviceLabel, bundle: myBundle)
        let wire = try wireBuilder.build(.deviceLinkRequest, payload: reply)
        try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)

        // Push recent message history to the newly linked device
        backfillHistory(toPeerID: peerID)

        let peerCopy = peer
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didLinkDevice: peerCopy)
            self.delegate?.chatManager(self, didDiscoverPeer: peerCopy)
        }
    }

    /// Remove a linked device. Future messages will not be forwarded to it.
    public func unlinkDevice(peerID: String) {
        linkedDevicePeerIDs.remove(peerID)
        saveLinkedDevices()
    }

    private func saveLinkedDevices() {
        keychain.saveLinkedDevices(Array(linkedDevicePeerIDs))
    }

    private func loadLinkedDevices() {
        // Migrate from UserDefaults if present
        let defaultsKey = "com.sophax.linkedDevices"
        if let legacy = UserDefaults.standard.stringArray(forKey: defaultsKey), !legacy.isEmpty {
            linkedDevicePeerIDs = Set(legacy)
            keychain.saveLinkedDevices(legacy)
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        linkedDevicePeerIDs = Set(keychain.loadLinkedDevices())
    }

    // MARK: - Public: Group reactions

    /// Send an emoji reaction (or remove one) on a specific group message.
    public func sendGroupReaction(emoji: String?, toMessageID messageID: String, groupID: String, members: [String]) {
        let myID    = identity.publicIdentity.peerID
        let payload = GroupReactionMessage(groupID: groupID, targetMessageID: messageID, emoji: emoji)
        guard let wire = try? wireBuilder.build(.groupReaction, payload: payload) else { return }
        for peerID in members where peerID != myID {
            try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
        }
        // Apply locally
        let convID = "group.\(groupID)"
        if let reactions = applyReaction(emoji: emoji, senderID: myID, messageID: messageID, convID: convID) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.chatManager(self, didUpdateGroupReactions: reactions,
                                           onMessageID: messageID, groupID: groupID)
            }
        }
    }

    private func scheduleExpiryTimer() {
        expiryTimer?.invalidate()
        // Run on main runloop — safe since all ChatManager state is on main
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.purgeExpiredMessages()
            // Republish our DHT bundle every 24h (approx — timer fires every 60s,
            // DHTEngine.publishInterval guards the actual frequency inside the engine).
            self.publishDHTBundleIfNeeded()
        }
        // Fire once immediately to clean up any stale messages from previous sessions
        purgeExpiredMessages()
    }

    private var lastDHTPublish: Date = .distantPast
    private func publishDHTBundleIfNeeded() {
        guard let engine = dhtEngine,
              Date().timeIntervalSince(lastDHTPublish) > DHTEngine.publishInterval else { return }
        lastDHTPublish = Date()
        guard let bundle = try? preKeys.generateBundle(tcpAddress: myTCPAddress) else { return }
        Task { await engine.publishSelf(bundle: bundle) }
    }

    /// Executes a Keychain save, logging failures in debug builds.
    /// Silent discard is intentional in release — Keychain errors are transient
    /// (locked device, quota) and should not crash the app or abort message flow.
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

    private func purgeExpiredMessages() {
        messageStore.deleteExpiredMessages()
        let now = Date()
        let beforeCount = storedForwardItems.count
        storedForwardItems.removeAll { $0.expiresAt <= now }
        if storedForwardItems.count != beforeCount { persistForwardItems() }
        deadDrops.removeAll { $0.expiresAt <= now }
        seenDeadDropIDs = seenDeadDropIDs.filter { now.timeIntervalSince($0.value) < Self.deadDropDedupeWindow }
    }

    /// Maximum text message body length in UTF-8 bytes.
    public static let maxMessageBytes = 65_536       // 64 KB

    /// Maximum binary attachment size (image, audio) in bytes.
    public static let maxAttachmentBytes = 524_288   // 512 KB

    /// Maximum file attachment size in bytes (arbitrary files via file picker).
    /// 2 MB keeps the JSON-encoded WireMessage comfortably under the 4 MiB TCP frame limit.
    public static let maxFileAttachmentBytes = 2_097_152  // 2 MB

    /// Maximum number of outbound messages queued per offline peer.
    /// Prevents memory exhaustion if a peer never reconnects.
    private static let maxQueuedMessagesPerPeer = 100

    /// Maximum expiry interval accepted from inbound messages (1 year).
    /// Clamps peer-supplied expiresAt so a malicious sender cannot set
    /// an absurd far-future date to prevent local cleanup.
    private static let maxExpiryInterval: TimeInterval = 365 * 24 * 60 * 60

    /// Send a plaintext message to `peerID`.
    ///
    /// Handles all cases automatically:
    ///   - New session: performs X3DH, sends `.initiateSession`
    ///   - Existing session: sends `.message` (Double Ratchet)
    ///   - Peer reachable via relay: wraps in `RelayEnvelope`
    ///   - No connectivity: queues for later delivery
    public func sendMessage(_ text: String, toPeerID peerID: String, expiresAt: Date? = nil, replyToID: String? = nil) {
        guard !text.isEmpty, text.utf8.count <= Self.maxMessageBytes else {
            delegate?.chatManager(self, didEncounterError:
                SophaxError.invalidMessageFormat("Message must be 1–65536 bytes"))
            return
        }
        let messageID = UUID().uuidString
        let stored = StoredMessage(
            id: messageID, peerID: peerID,
            direction: .sent, body: text, status: .sending,
            replyToID: replyToID
        )
        do {
            try messageStore.append(message: stored)
        } catch {
            CrashLogManager.shared.log(error, context: "MessageStore")
            delegate?.chatManager(self, didEncounterError: error)
            return
        }

        forwardToLinkedDevices(stored)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didSendMessage: stored, toPeer: peerID)
        }

        do {
            let content = MessageContent(body: text, replyToID: replyToID, expiresAt: expiresAt)
            let wire = try buildOutboundWire(content: content, messageID: messageID, toPeerID: peerID)
            try sendOrQueue(wire, toPeerID: peerID, messageID: messageID)
        } catch SophaxError.sessionStateCorrupted {
            // Corrupt session was cleared in withSession(). Broadcast Hello so the
            // peer re-initiates X3DH; the user should retry sending after reconnection.
            CrashLogManager.shared.log("Session state corrupted on send — cleared, broadcasting Hello", context: "DR")
            try? messageStore.updateStatus(.failed, forMessageID: messageID, peerID: peerID)
            broadcastHello()
            delegate?.chatManager(self, didEncounterError: SophaxError.sessionStateCorrupted)
        } catch {
            CrashLogManager.shared.log(error, context: "MessageSend")
            try? messageStore.updateStatus(.failed, forMessageID: messageID, peerID: peerID)
            delegate?.chatManager(self, didEncounterError: error)
        }
    }

    /// Send read receipts for messages the local user has viewed.
    /// Best-effort: uses direct / relay / offline-queue routing.
    public func sendReadReceipts(messageIDs: [String], toPeerID peerID: String) {
        guard !messageIDs.isEmpty else { return }
        let payload = ReadReceiptMessage(messageIDs: messageIDs)
        guard let wire = try? wireBuilder.build(.readReceipt, payload: payload) else { return }
        try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
    }

    /// Send true read receipts for group messages the local user has viewed.
    /// Called by AppState when the user opens a group conversation.
    /// Sends unicast to each message's original sender (not broadcast to the group).
    public func sendGroupReadReceipts(messageIDs: [String], senderPeerID: String, groupID: String) {
        guard !messageIDs.isEmpty else { return }
        for messageID in messageIDs {
            let payload = GroupReadReceiptMessage(groupID: groupID, targetMessageID: messageID, isRead: true)
            guard let wire = try? wireBuilder.build(.groupReadReceipt, payload: payload) else { continue }
            try? sendOrQueue(wire, toPeerID: senderPeerID, messageID: UUID().uuidString)
        }
    }

    /// Edit a previously sent text message. Sends a Double Ratchet–encrypted edit to the peer.
    /// Also updates the local message store immediately.
    public func sendEditMessage(messageID: String, newBody: String, toPeerID peerID: String) {
        let editedAt = Date()
        let editPayload = EditMessagePayload(messageID: messageID, newBody: newBody, editedAt: editedAt)
        let content = MessageContent(body: newBody, editPayload: editPayload)
        let wireID = UUID().uuidString
        guard let wire = try? buildOutboundWire(content: content, messageID: wireID, toPeerID: peerID) else { return }
        try? sendOrQueue(wire, toPeerID: peerID, messageID: wireID)
        try? messageStore.updateMessage(id: messageID, peerID: peerID, newBody: newBody, editedAt: editedAt)
    }

    /// Edit a previously sent group (Sender Keys v2) message.
    /// Fans out a `groupEditMessage` to every member. Only the original sender can edit;
    /// edits are text-only and must occur within 5 minutes of the original send.
    public func sendEditGroupMessage(messageID: String, newBody: String, groupID: String, members: [String]) {
        guard !newBody.isEmpty, newBody.utf8.count <= Self.maxMessageBytes else { return }
        let convID = "group.\(groupID)"
        let editedAt = Date()
        // Enforce: must be our own sent message, no attachment, within 5-minute window
        guard let msgs = try? messageStore.messages(forPeer: convID),
              let existing = msgs.first(where: { $0.id == messageID }),
              existing.direction == .sent,
              existing.attachmentID == nil,
              existing.timestamp.timeIntervalSinceNow > -300 else { return }

        let payload = GroupEditMessagePayload(
            groupID:   groupID,
            messageID: messageID,
            newBody:   newBody,
            editedAt:  editedAt
        )
        guard let wire = try? wireBuilder.build(.groupEditMessage, payload: payload) else { return }
        let myID = identity.publicIdentity.peerID
        for peerID in members where peerID != myID {
            try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
        }
        try? messageStore.updateMessage(id: messageID, peerID: convID, newBody: newBody, editedAt: editedAt)

        // Forward updated message to linked devices
        if let updated = (try? messageStore.messages(forPeer: convID))?.first(where: { $0.id == messageID }) {
            forwardToLinkedDevices(updated)
        }

        let body     = newBody
        let editTime = editedAt
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveEditedGroupMessage: messageID,
                                       newBody: body, editedAt: editTime, groupID: groupID)
        }
    }

    /// Send an emoji reaction (or remove one) on a specific message.
    /// `emoji` = nil removes any existing reaction from the local user.
    public func sendReaction(emoji: String?, toMessageID messageID: String, toPeerID peerID: String) {
        let payload = ReactionMessage(targetMessageID: messageID, emoji: emoji)
        guard let wire = try? wireBuilder.build(.reaction, payload: payload) else { return }
        try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
    }

    // MARK: - Group messaging

    /// Create a new group, distribute Sender Keys to all members, and notify the delegate.
    @discardableResult
    public func createGroup(name: String, memberPeerIDs: [String]) -> GroupInfo? {
        guard !name.isEmpty, !memberPeerIDs.isEmpty else { return nil }
        let myID   = identity.publicIdentity.peerID
        let groupID = UUID().uuidString
        var seen = Set<String>()
        let allMembers = ([myID] + memberPeerIDs).filter { seen.insert($0).inserted }
        let group = GroupInfo(id: groupID, name: name, memberIDs: allMembers, creatorID: myID)

        // Generate my sender chain key (v2 — random 32-byte seed via CryptoKit)
        let tmpKey       = SymmetricKey(size: .bits256)
        let chainKeyData = tmpKey.withUnsafeBytes { Data($0) }
        let myState      = SenderKeyState(chainKey: chainKeyData, iteration: 0)
        do {
            try keychain.saveMySenderKeyState(myState, groupID: groupID)
        } catch {
            delegate?.chatManager(self, didEncounterError: error)
            return nil
        }

        let invite = GroupInvitePayload(
            groupID:         groupID,
            groupName:       name,
            memberIDs:       allMembers,
            creatorID:       myID,
            senderChainKey:  chainKeyData,
            senderIteration: 0
        )
        guard let inviteData = try? JSONEncoder().encode(invite) else { return nil }

        // Send the invite to each member via the existing DR-encrypted channel
        for peerID in memberPeerIDs {
            let content = MessageContent(body: name, type: .groupInvite,
                                         groupInviteData: inviteData)
            if let wire = try? buildOutboundWire(content: content,
                                                  messageID: UUID().uuidString,
                                                  toPeerID: peerID) {
                try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
            }
        }

        joinedGroups[groupID] = Set(allMembers)
        groupCreators[groupID] = myID
        groupCoordinators[groupID] = myID
        groupCryptoVersions[groupID] = .senderKeysV2

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didJoinGroup: group)
        }
        return group
    }

    /// Register groups that were persisted across restarts (called by the delegate on startup).
    public func registerKnownGroups(_ groups: [GroupInfo]) {
        for group in groups {
            joinedGroups[group.id] = Set(group.memberIDs)
            groupCreators[group.id] = group.creatorID
            groupCoordinators[group.id] = group.currentCoordinatorID
            groupCryptoVersions[group.id] = group.cryptoVersion
        }
    }

    /// Flood a channel announcement so nearby peers (non-members) can discover this group.
    ///
    /// Call this after `createGroup()` and whenever membership changes.
    /// The announcement contains only the group name, creator ID, and member count —
    /// no message content, no encryption keys.
    public func broadcastChannelAnnouncement(for group: GroupInfo) {
        let announcement = ChannelAnnouncement(
            groupID:     group.id,
            groupName:   group.name,
            creatorID:   identity.publicIdentity.peerID,
            memberCount: group.memberIDs.count
        )
        guard let wire = try? wireBuilder.build(.channelAnnouncement, payload: announcement) else { return }
        try? mesh.broadcast(wire)
    }

    // MARK: - Private: Channel announcement handler

    private func handleChannelAnnouncement(_ announcement: ChannelAnnouncement, fromPeer peerID: String) {
        // Discard stale announcements (older than 5 minutes)
        guard abs(announcement.timestamp.timeIntervalSinceNow) < 300 else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didDiscoverChannel: announcement)
        }
    }

    /// Send a text message to all members of a group.
    public func sendGroupMessage(_ body: String, groupID: String, members: [String], expiresAt: Date? = nil, replyToID: String? = nil) {
        guard !body.isEmpty else { return }

        let myID       = identity.publicIdentity.peerID
        let myUsername = identity.publicIdentity.username
        let messageID  = UUID().uuidString
        let timestamp  = Date()
        let convID     = "group.\(groupID)"

        // Helper: surface an encryption/storage failure to the UI.
        func fail(_ error: Error) {
            try? messageStore.updateStatus(.failed, forMessageID: messageID, peerID: convID)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.chatManager(self, didEncounterError: error)
            }
        }

        // Store locally as .sending before encryption so the bubble appears immediately.
        let stored = StoredMessage(
            id: messageID, peerID: convID,
            direction: .sent, body: body, status: .sending,
            replyToID: replyToID, expiresAt: expiresAt, senderID: myID
        )
        do {
            try messageStore.append(message: stored)
        } catch {
            delegate?.chatManager(self, didEncounterError: error)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveGroupMessage: stored, inGroup: groupID)
        }

        // Encrypt with v2 Sender Key ratchet
        guard var myState = keychain.loadMySenderKeyState(groupID: groupID) else {
            fail(SophaxError.encryptionFailed("No sender key found — group may have been left or key material deleted"))
            return
        }
        let (messageKey, nextCK) = senderKeyRatchetStep(myState.chainKey)
        let iteration            = myState.iteration
        let newCount             = (myState.messageCount ?? 0) + 1
        myState = SenderKeyState(chainKey: nextCK, iteration: iteration + 1,
                                 messageCount: newCount, createdAt: myState.createdAt ?? Date())
        keychainSave("mySenderKey:\(groupID)") { try keychain.saveMySenderKeyState(myState, groupID: groupID) }
        guard let bodyData = body.data(using: .utf8),
              let sealed   = try? ChaChaPoly.seal(bodyData, using: messageKey) else {
            fail(SophaxError.encryptionFailed("Group message body encryption failed"))
            return
        }
        let ciphertext         = sealed.combined
        let senderKeyIteration = iteration

        let wireMsg = GroupWireMessage(
            groupID:            groupID,
            messageID:          messageID,
            senderPeerID:       myID,
            senderUsername:     myUsername,
            timestamp:          timestamp,
            ciphertext:         ciphertext,
            senderKeyIteration: senderKeyIteration,
            expiresAt:          expiresAt,
            replyToID:          replyToID,
            senderAvatarData:   identity.loadAvatar()
        )

        guard let wire = try? wireBuilder.build(.groupMessage, payload: wireMsg) else {
            fail(SophaxError.encryptionFailed("Failed to build group wire message"))
            return
        }

        // Mark delivered (no per-member ACK in group), then broadcast.
        try? messageStore.updateStatus(.delivered, forMessageID: messageID, peerID: convID)

        // Broadcast to each member (excluding self).
        // For SKv2 groups, wrap each copy in sealed sender so relay nodes cannot correlate
        // the group wire with a specific recipient. MLS groups skip this — epoch keys already
        // provide per-member confidentiality.
        let useSealedSender = groupCryptoVersions[groupID] != .mls
        var sendError: Error? = nil
        for peerID in members where peerID != myID {
            do {
                if useSealedSender, let dhKey = knownPeers[peerID]?.dhKeyPublic,
                   let sealed    = try? sealWireMessage(wire, recipientDHPublicKey: dhKey),
                   let sealedWire = try? wireBuilder.build(.sealed, payload: sealed) {
                    try sendOrQueue(sealedWire, toPeerID: peerID, messageID: messageID)
                } else {
                    // Fallback: peer not yet known or DH key unavailable — send unsealed
                    try sendOrQueue(wire, toPeerID: peerID, messageID: messageID)
                }
            } catch {
                sendError = error
            }
        }
        if let err = sendError {
            delegate?.chatManager(self, didEncounterError: err)
        }
        // Check rotation threshold after broadcast — rotates chain for next message
        performSenderKeyRotationIfNeeded(groupID: groupID, members: members)
    }

    /// Send a binary attachment (image, audio, or arbitrary file) to all members of a group.
    public func sendGroupAttachment(
        _ data: Data,
        mimeType: String,
        caption: String = "",
        filename: String? = nil,
        audioDuration: Double? = nil,
        groupID: String,
        members: [String],
        expiresAt: Date? = nil,
        replyToID: String? = nil
    ) {
        let isFile = !mimeType.hasPrefix("image/") && !mimeType.hasPrefix("audio/") && !mimeType.hasPrefix("video/")
        let sizeLimit = isFile ? Self.maxFileAttachmentBytes : Self.maxAttachmentBytes
        guard data.count <= sizeLimit else {
            let limit = isFile ? "2 MB" : "512 KB"
            delegate?.chatManager(self, didEncounterError:
                SophaxError.invalidMessageFormat("Attachment exceeds \(limit) limit"))
            return
        }

        let myID         = identity.publicIdentity.peerID
        let myUsername   = identity.publicIdentity.username
        let messageID    = UUID().uuidString
        let attachmentID = UUID().uuidString
        let timestamp    = Date()
        let msgType: MessageContent.MessageType
        if mimeType.hasPrefix("image/")      { msgType = .image }
        else if mimeType.hasPrefix("audio/") { msgType = .audio }
        else if mimeType.hasPrefix("video/") { msgType = .image }
        else                                  { msgType = .file  }

        let displayBody: String
        if !caption.isEmpty       { displayBody = caption }
        else if msgType == .image  { displayBody = "📷 Photo" }
        else if msgType == .audio  { displayBody = "🎤 Voice message" }
        else                       { displayBody = "📎 \(filename ?? mimeType)" }
        let convID = "group.\(groupID)"

        // Helper: surface an encryption/storage failure to the UI.
        func fail(_ error: Error) {
            try? messageStore.updateStatus(.failed, forMessageID: messageID, peerID: convID)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.chatManager(self, didEncounterError: error)
            }
        }

        // Save attachment locally for sender's own bubble
        try? attachmentStore.save(data, id: attachmentID)

        // Store locally as .sending so the bubble appears immediately.
        let stored = StoredMessage(
            id: messageID, peerID: convID,
            direction: .sent, body: displayBody, status: .sending,
            replyToID: replyToID, expiresAt: expiresAt,
            attachmentID: attachmentID, attachmentMimeType: mimeType,
            attachmentFilename: filename,
            audioDuration: audioDuration, senderID: myID
        )
        do {
            try messageStore.append(message: stored)
        } catch {
            delegate?.chatManager(self, didEncounterError: error)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveGroupMessage: stored, inGroup: groupID)
        }

        // Encrypt body + attachment with v2 Sender Key ratchet.
        // Both use the SAME message key (one chain step = one message).
        guard var myState = keychain.loadMySenderKeyState(groupID: groupID) else {
            fail(SophaxError.encryptionFailed("No sender key found — group may have been left or key material deleted"))
            return
        }
        let (messageKey, nextCK) = senderKeyRatchetStep(myState.chainKey)
        let iteration            = myState.iteration
        let newCount             = (myState.messageCount ?? 0) + 1
        myState = SenderKeyState(chainKey: nextCK, iteration: iteration + 1,
                                 messageCount: newCount, createdAt: myState.createdAt ?? Date())
        keychainSave("mySenderKey:\(groupID)") { try keychain.saveMySenderKeyState(myState, groupID: groupID) }
        guard let bodyData   = displayBody.data(using: .utf8),
              let sealedBody = try? ChaChaPoly.seal(bodyData, using: messageKey),
              let sealedAtt  = try? ChaChaPoly.seal(data,     using: messageKey) else {
            fail(SophaxError.encryptionFailed("Group attachment encryption failed"))
            return
        }
        let bodyCiphertext     = sealedBody.combined
        let attCiphertext      = sealedAtt.combined
        let senderKeyIteration = iteration

        let wireMsg = GroupWireMessage(
            groupID:              groupID,
            messageID:            messageID,
            senderPeerID:         myID,
            senderUsername:       myUsername,
            timestamp:            timestamp,
            ciphertext:           bodyCiphertext,
            attachmentCiphertext: attCiphertext,
            attachmentMimeType:   mimeType,
            attachmentFilename:   filename,
            audioDuration:        audioDuration,
            senderKeyIteration:   senderKeyIteration,
            expiresAt:            expiresAt,
            replyToID:            replyToID,
            senderAvatarData:     identity.loadAvatar()
        )

        guard let wire = try? wireBuilder.build(.groupMessage, payload: wireMsg) else {
            fail(SophaxError.encryptionFailed("Failed to build group wire message"))
            return
        }

        // Mark delivered (no per-member ACK in group), then broadcast.
        try? messageStore.updateStatus(.delivered, forMessageID: messageID, peerID: convID)

        let useSealedSender = groupCryptoVersions[groupID] != .mls
        var sendError: Error? = nil
        for peerID in members where peerID != myID {
            do {
                if useSealedSender, let dhKey = knownPeers[peerID]?.dhKeyPublic,
                   let sealed    = try? sealWireMessage(wire, recipientDHPublicKey: dhKey),
                   let sealedWire = try? wireBuilder.build(.sealed, payload: sealed) {
                    try sendOrQueue(sealedWire, toPeerID: peerID, messageID: messageID)
                } else {
                    try sendOrQueue(wire, toPeerID: peerID, messageID: messageID)
                }
            } catch {
                sendError = error
            }
        }
        if let err = sendError {
            delegate?.chatManager(self, didEncounterError: err)
        }
        performSenderKeyRotationIfNeeded(groupID: groupID, members: members)
    }

    /// Remove the local user from a group.
    ///
    /// Broadcasts a `.groupMemberLeft` notification to all remaining members so they
    /// can update their local membership list and rotate their sender keys (ensuring
    /// the leaver cannot decrypt any future group messages).
    public func leaveGroup(_ group: GroupInfo) {
        let myID = identity.publicIdentity.peerID
        let remaining = group.memberIDs.filter { $0 != myID }

        // Notify all remaining members before deleting local crypto state
        let leaveMsg = GroupMemberLeftMessage(
            groupID:            group.id,
            leavingPeerID:      myID,
            remainingMemberIDs: remaining
        )
        if let wire = try? wireBuilder.build(.groupMemberLeft, payload: leaveMsg) {
            for peerID in remaining {
                try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
            }
        }

        // Clean up local state
        joinedGroups.removeValue(forKey: group.id)
        groupCreators.removeValue(forKey: group.id)
        groupCoordinators.removeValue(forKey: group.id)
        keychain.deleteGroupKey(groupID: group.id)               // v1 cleanup
        keychain.deleteAllSenderKeyStates(groupID: group.id)     // v2 cleanup
        if group.cryptoVersion == .mls {
            Task { try? await self.mlsManager?.deleteGroupState(groupID: group.id) }
        }
        // Remove this group's entries from the skipped-key cache
        let prefix = group.id + "/"
        skippedGroupMessageKeys.keys.filter { $0.hasPrefix(prefix) }.forEach {
            skippedGroupMessageKeys.removeValue(forKey: $0)
            skippedGroupMessageKeyDates.removeValue(forKey: $0)
        }
        persistSkippedGroupKeyCache()
        try? messageStore.deleteConversation(peerID: group.conversationID)
    }

    /// Dissolve a group — creator-only. Broadcasts `.groupDeleted` to all members,
    /// then cleans up local state identically to `leaveGroup()`.
    public func deleteGroup(_ group: GroupInfo) {
        let myID = identity.publicIdentity.peerID
        guard group.creatorID == myID else { return }

        let msg = GroupDeletedMessage(groupID: group.id, deletedByPeerID: myID)
        if let wire = try? wireBuilder.build(.groupDeleted, payload: msg) {
            for peerID in group.memberIDs where peerID != myID {
                try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
            }
        }

        // Clean up identically to leaveGroup()
        joinedGroups.removeValue(forKey: group.id)
        groupCreators.removeValue(forKey: group.id)
        groupCoordinators.removeValue(forKey: group.id)
        keychain.deleteGroupKey(groupID: group.id)
        keychain.deleteAllSenderKeyStates(groupID: group.id)
        if group.cryptoVersion == .mls {
            Task { try? await self.mlsManager?.deleteGroupState(groupID: group.id) }
        }
        let prefix = group.id + "/"
        skippedGroupMessageKeys.keys.filter { $0.hasPrefix(prefix) }.forEach {
            skippedGroupMessageKeys.removeValue(forKey: $0)
            skippedGroupMessageKeyDates.removeValue(forKey: $0)
        }
        persistSkippedGroupKeyCache()
        try? messageStore.deleteConversation(peerID: group.conversationID)
    }

    /// Remove a group from the local device only — no wire message sent.
    /// Identical crypto cleanup to `leaveGroup()` but silent: other members are
    /// not notified and continue to list this peer as a group member.
    public func deleteGroupLocally(_ group: GroupInfo) {
        joinedGroups.removeValue(forKey: group.id)
        groupCreators.removeValue(forKey: group.id)
        groupCoordinators.removeValue(forKey: group.id)
        keychain.deleteGroupKey(groupID: group.id)
        keychain.deleteAllSenderKeyStates(groupID: group.id)
        if group.cryptoVersion == .mls {
            Task { try? await self.mlsManager?.deleteGroupState(groupID: group.id) }
        }
        let prefix = group.id + "/"
        skippedGroupMessageKeys.keys.filter { $0.hasPrefix(prefix) }.forEach {
            skippedGroupMessageKeys.removeValue(forKey: $0)
            skippedGroupMessageKeyDates.removeValue(forKey: $0)
        }
        persistSkippedGroupKeyCache()
        try? messageStore.deleteConversation(peerID: group.conversationID)
    }

    // MARK: - SSS Backup — public API

    /// Split the local identity secret into N Shamir shares and send one ECDH-encrypted
    /// share to each peer in `holderPeerIDs`. Stores a manifest in Keychain so the
    /// creator can later initiate recovery by contacting the right peers.
    ///
    /// - Parameters:
    ///   - holderPeerIDs: PeerIDs of trusted contacts who will each hold one share.
    ///   - threshold:     Minimum shares needed to recover. Must be ≥ 2 and ≤ holderPeerIDs.count.
    public func distributeSSSBackup(holderPeerIDs: [String], threshold: Int) throws {
        let myID = identity.publicIdentity.peerID
        // Build 64-byte secret: Ed25519 || X25519 private keys
        var secret = try identity.signingPrivateKeyData() + identity.dhPrivateKeyData()
        defer { secret.resetBytes(in: secret.startIndex..<secret.endIndex) }

        let shares = try ShamirBackup.split(secret: secret, m: threshold, n: holderPeerIDs.count)
        let shareID = shares[0].id

        for (idx, holderID) in holderPeerIDs.enumerated() {
            guard let bundle = peerBundles[holderID] else { continue }
            let share = shares[idx]
            let (ephKey, ciphertext) = try ShamirBackup.encryptShare(
                share,
                recipientDHPublicKey: bundle.dhIdentityKeyPublic
            )
            let msg = SSSShareDeliveryMessage(
                shareID:           shareID,
                ephemeralPublicKey: ephKey,
                encryptedShare:    ciphertext,
                senderPeerID:      myID,
                threshold:         UInt8(threshold),
                total:             UInt8(holderPeerIDs.count)
            )
            if let wire = try? wireBuilder.build(.sssShareDelivery, payload: msg) {
                try? sendOrQueue(wire, toPeerID: holderID, messageID: UUID().uuidString)
            }
        }

        let manifest = SSSBackupManifest(
            shareID:       shareID,
            threshold:     threshold,
            holderPeerIDs: holderPeerIDs,
            createdAt:     Date()
        )
        keychain.saveSSSBackupManifest(manifest)
    }

    /// Initiate recovery by requesting shares from all known holders in the manifest.
    /// Collected shares are accumulated in `pendingRecoveryShares`; once M are received
    /// the delegate is called with the reconstructed secret.
    public func initiateSSSRecovery() {
        guard let manifest = keychain.loadSSSBackupManifest() else { return }
        pendingRecoveryShares[manifest.shareID] = []
        let myDHPublicKey = identity.publicIdentity.dhKeyPublic
        let req = SSSShareRequestMessage(
            shareID:              manifest.shareID,
            requesterDHPublicKey: myDHPublicKey
        )
        guard let wire = try? wireBuilder.build(.sssShareRequest, payload: req) else { return }
        for holderID in manifest.holderPeerIDs {
            try? sendOrQueue(wire, toPeerID: holderID, messageID: UUID().uuidString)
        }
    }

    // MARK: - SSS Backup — private handlers

    private func handleSSSShareDelivery(_ payload: SSSShareDeliveryMessage) {
        guard let dhPrivKey = try? keychain.loadDHIdentityKey() else { return }
        guard let share = try? ShamirBackup.decryptShare(
            ephPublicKey:   payload.ephemeralPublicKey,
            ciphertext:     payload.encryptedShare,
            myDHPrivateKey: dhPrivKey
        ) else { return }
        keychain.saveSSSShare(share)
        delegate?.chatManager(self, didReceiveSSSShare: payload.shareID,
                              fromPeerID: payload.senderPeerID,
                              threshold: Int(payload.threshold),
                              total: Int(payload.total))
    }

    private func handleSSSShareRequest(_ payload: SSSShareRequestMessage, requesterPeerID: String) {
        let allShares = keychain.loadSSSShares()
        guard let share = allShares.first(where: { $0.id == payload.shareID }) else { return }
        guard let (ephKey, ciphertext) = try? ShamirBackup.encryptShare(
            share,
            recipientDHPublicKey: payload.requesterDHPublicKey
        ) else { return }
        let resp = SSSShareResponseMessage(
            shareID:           payload.shareID,
            ephemeralPublicKey: ephKey,
            encryptedShare:    ciphertext
        )
        if let wire = try? wireBuilder.build(.sssShareResponse, payload: resp) {
            try? sendOrQueue(wire, toPeerID: requesterPeerID, messageID: UUID().uuidString)
        }
    }

    private func handleSSSShareResponse(_ payload: SSSShareResponseMessage) {
        guard let dhPrivKey = try? keychain.loadDHIdentityKey() else { return }
        guard let share = try? ShamirBackup.decryptShare(
            ephPublicKey:   payload.ephemeralPublicKey,
            ciphertext:     payload.encryptedShare,
            myDHPrivateKey: dhPrivKey
        ) else { return }

        var collected = pendingRecoveryShares[payload.shareID, default: []]
        guard !collected.contains(where: { $0.index == share.index }) else { return }
        collected.append(share)
        pendingRecoveryShares[payload.shareID] = collected

        let threshold = Int(share.threshold)
        guard collected.count >= threshold else { return }

        // Attempt reconstruction
        guard var secret = try? ShamirBackup.reconstruct(shares: collected) else { return }
        defer { secret.resetBytes(in: secret.startIndex..<secret.endIndex) }

        pendingRecoveryShares.removeValue(forKey: payload.shareID)
        delegate?.chatManager(self, didRecoverSSSSecret: secret, shareID: payload.shareID)
    }

    /// Transfer MLS commit coordinator authority to another group member.
    /// Only the current coordinator may call this. Broadcasts to all members so they
    /// update their local `groupCoordinators` record.
    public func handoffCoordinator(group: GroupInfo, newCoordinatorID: String) {
        let myID = identity.publicIdentity.peerID
        guard groupCoordinators[group.id] == myID,
              group.memberIDs.contains(newCoordinatorID) else { return }

        let msg = MLSCoordinatorHandoffMessage(
            groupID:           group.id,
            fromCoordinatorID: myID,
            newCoordinatorID:  newCoordinatorID
        )
        if let wire = try? wireBuilder.build(.mlsCoordinatorHandoff, payload: msg) {
            for peerID in group.memberIDs where peerID != myID {
                try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
            }
        }
        groupCoordinators[group.id] = newCoordinatorID
        delegate?.chatManager(self, didUpdateCoordinator: newCoordinatorID, inGroupID: group.id)
    }

    /// Rotate our sender key for a group — generates a fresh random chain key, saves it,
    /// and distributes a new SenderKeyDistributionMessage to all members.
    /// Use this for break-in recovery when a device may have been compromised.
    public func rotateSenderKey(forGroup group: GroupInfo) {
        let myID       = identity.publicIdentity.peerID
        let tmpKey     = SymmetricKey(size: .bits256)
        let newChainKey = tmpKey.withUnsafeBytes { Data($0) }
        let newState   = SenderKeyState(chainKey: newChainKey, iteration: 0)
        keychainSave("mySenderKey:\(group.id)") { try self.keychain.saveMySenderKeyState(newState, groupID: group.id) }

        let skd = SenderKeyDistributionMessage(groupID: group.id, chainKey: newChainKey, iteration: 0)
        guard let skdData = try? JSONEncoder().encode(skd) else { return }
        for memberID in group.memberIDs where memberID != myID {
            let content = MessageContent(body: "", type: .senderKeyDistribution, senderKeyData: skdData)
            if let wire = try? buildOutboundWire(content: content,
                                                  messageID: UUID().uuidString,
                                                  toPeerID: memberID) {
                try? sendOrQueue(wire, toPeerID: memberID, messageID: UUID().uuidString)
            }
        }

        let manager = self
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(manager, didRotateSenderKey: group.id)
        }
    }

    /// Send a binary attachment (image or audio) to `peerID`.
    public func sendAttachment(
        _ data: Data,
        mimeType: String,
        caption: String = "",
        filename: String? = nil,
        audioDuration: Double? = nil,
        toPeerID peerID: String,
        expiresAt: Date? = nil
    ) {
        let isFile = !mimeType.hasPrefix("image/") && !mimeType.hasPrefix("audio/") && !mimeType.hasPrefix("video/")
        let sizeLimit = isFile ? Self.maxFileAttachmentBytes : Self.maxAttachmentBytes
        guard data.count <= sizeLimit else {
            let limit = isFile ? "2 MB" : "512 KB"
            delegate?.chatManager(self, didEncounterError:
                SophaxError.invalidMessageFormat("Attachment exceeds \(limit) limit"))
            return
        }

        let messageID    = UUID().uuidString
        let attachmentID = UUID().uuidString
        let msgType: MessageContent.MessageType
        if mimeType.hasPrefix("image/")      { msgType = .image }
        else if mimeType.hasPrefix("audio/") { msgType = .audio }
        else if mimeType.hasPrefix("video/") { msgType = .image } // video treated as image for display
        else                                  { msgType = .file  }

        let displayBody: String
        if !caption.isEmpty            { displayBody = caption }
        else if msgType == .image      { displayBody = "📷 Photo" }
        else if msgType == .audio      { displayBody = "🎤 Voice message" }
        else                           { displayBody = "📎 \(filename ?? mimeType)" }

        // Save attachment locally for the sender's own bubble
        try? attachmentStore.save(data, id: attachmentID)

        let stored = StoredMessage(
            id: messageID, peerID: peerID,
            direction: .sent, body: displayBody, status: .sending,
            attachmentID: attachmentID, attachmentMimeType: mimeType,
            attachmentFilename: filename,
            audioDuration: audioDuration
        )
        do {
            try messageStore.append(message: stored)
        } catch {
            delegate?.chatManager(self, didEncounterError: error)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didSendMessage: stored, toPeer: peerID)
        }

        do {
            let content = MessageContent(
                body: caption, type: msgType, expiresAt: expiresAt,
                attachmentData: data, attachmentMimeType: mimeType,
                attachmentFilename: filename,
                audioDuration: audioDuration
            )
            let wire = try buildOutboundWire(content: content, messageID: messageID, toPeerID: peerID)
            try sendOrQueue(wire, toPeerID: peerID, messageID: messageID)
        } catch SophaxError.sessionStateCorrupted {
            CrashLogManager.shared.log("Session state corrupted on attachment send — cleared, broadcasting Hello", context: "DR")
            try? messageStore.updateStatus(.failed, forMessageID: messageID, peerID: peerID)
            broadcastHello()
            delegate?.chatManager(self, didEncounterError: SophaxError.sessionStateCorrupted)
        } catch {
            CrashLogManager.shared.log(error, context: "AttachmentSend")
            try? messageStore.updateStatus(.failed, forMessageID: messageID, peerID: peerID)
            delegate?.chatManager(self, didEncounterError: error)
        }
    }

    /// All stored messages for a conversation, oldest-first.
    public func messages(forPeer peerID: String) -> [StoredMessage] {
        (try? messageStore.messages(forPeer: peerID)) ?? []
    }

    /// Send a typing indicator to `peerID` (direct path only, best-effort — no relay, no queue).
    public func sendTypingIndicator(toPeerID peerID: String, isTyping: Bool) {
        guard mesh.isConnected(peerID: peerID) else { return }
        guard let wire = try? wireBuilder.build(.typing, payload: TypingMessage(isTyping: isTyping)) else { return }
        try? mesh.send(wire, toPeerID: peerID)
    }

    /// All peers with a verified identity (online or offline).
    public func allPeers() -> [KnownPeer] {
        Array(knownPeers.values)
    }

    /// Manually replenish the one-time prekey pool to the default target (20 keys).
    public func replenishPreKeys() {
        try? preKeys.replenishIfNeeded(target: 20)
    }

    // MARK: - Private: Build outbound wire message

    /// Encrypt `content` and return the wire message for `peerID`.
    ///
    /// - Existing session → `.message`
    /// - No session + bundle known → X3DH + `.initiateSession`
    /// - No bundle yet → throws `sessionNotInitialized` (caller queues)
    private func buildOutboundWire(
        content: MessageContent,
        messageID: String,
        toPeerID peerID: String
    ) throws -> WireMessage {
        let plaintext = try JSONEncoder().encode(content)
        let ad        = associatedData(peerID: peerID)

        // ── Case 1: existing session ──────────────────────────────────────────
        if let ratchetMsg = try withSession(peerID: peerID, { ratchet in
            try ratchet.encrypt(plaintext: plaintext, associatedData: ad)
        }) {
            let payload = ChatMessagePayload(ratchetMessage: ratchetMsg, messageID: messageID)
            return try wireBuilder.build(.message, payload: payload)
        }

        // ── Case 2: new session — need peer's PreKeyBundle for X3DH ──────────
        guard let bundle = peerBundles[peerID] else {
            throw SophaxError.sessionNotInitialized
        }

        let x3dhResult = try X3DH.initiateSender(
            senderIdentity:  identity.dhKeyPair,
            recipientBundle: bundle
        )
        let ratchet = try DoubleRatchet.initAsInitiator(
            sharedSecret:           x3dhResult.sharedSecret,
            remoteRatchetPublicKey: bundle.signedPreKeyPublic
        )
        let ratchetMsg = try ratchet.encrypt(plaintext: plaintext, associatedData: ad)
        try storeNewSession(ratchet, peerID: peerID)

        let senderBundle = try preKeys.generateBundle()
        let initPayload  = InitiateSessionMessage(
            senderBundle:        senderBundle,
            ephemeralPublicKey:  x3dhResult.ephemeralPublicKey,
            usedSignedPreKeyId:  bundle.signedPreKeyId,
            usedOneTimePreKeyId: x3dhResult.usedOneTimePreKeyId,
            initialMessage:      ratchetMsg
        )
        return try wireBuilder.build(.initiateSession, payload: initPayload)
    }

    // MARK: - Private: Routing

    /// Send a wire message: direct → relay → offline queue (in priority order).
    func sendOrQueue(
        _ wire: WireMessage,
        toPeerID peerID: String,
        messageID: String
    ) throws {
        // ── TCP direct path (internet / Tor) ──────────────────────────────────
        if let tcp = tcpTransport, tcp.isConnected(peerID: peerID) {
            try tcp.send(wire, toPeerID: peerID)
            return
        }

        if mesh.isConnected(peerID: peerID) {
            // ── BLE/WiFi direct path ──────────────────────────────────────────
            try mesh.send(wire, toPeerID: peerID)

        } else if mesh.directPeerCount > 0 {
            // ── Multihop relay: seal the inner message then flood ─────────────
            // Sealed sender hides message type and payload from relay nodes.
            // Only the intended recipient can decrypt; relay nodes see only
            // the ephemeral public key and opaque ciphertext.
            let innerWire: WireMessage
            var sealedForTarget: SealedMessage? = nil
            if let peer = knownPeers[peerID] {
                let sealed = try sealWireMessage(wire, recipientDHPublicKey: peer.dhKeyPublic)
                sealedForTarget = sealed
                innerWire = try wireBuilder.build(.sealed, payload: sealed)
            } else {
                innerWire = wire    // Unknown peer — fallback to plaintext relay
            }

            let envelope = RelayEnvelope(
                id:           UUID().uuidString,
                targetPeerID: peerID,
                originPeerID: identity.publicIdentity.peerID,
                ttl:          RelayEnvelope.maxTTL,
                hopCount:     0,
                message:      innerWire
            )
            let relayWire = try wireBuilder.build(.relay, payload: envelope)
            try mesh.broadcast(relayWire)

            // Also forward relay envelope over any connected TCP/Tor peers so the
            // message can reach nodes outside the local BLE/WiFi mesh.
            // The inner payload is already sealed for the target; TCP relay nodes
            // see only the targetPeerID in the envelope — same exposure as mesh relay.
            if let tcp = tcpTransport {
                for tcpPeerID in tcp.connectedPeerIDs {
                    try? tcp.send(relayWire, toPeerID: tcpPeerID)
                }
            }

            // ── Store-and-forward: also ask relay peers to hold the message ───
            // If the target is not currently in the mesh, at least one relay peer
            // may later encounter them. Re-uses the sealed message already produced
            // above so no extra crypto is needed.
            if let sf = sealedForTarget {
                let sfReq = StoreAndForwardRequest(
                    targetPeerID: peerID,
                    messageID:    messageID,
                    sealed:       sf,
                    expiresAt:    Date().addingTimeInterval(Self.storeAndForwardTTL)
                )
                if let sfWire = try? wireBuilder.build(.storeAndForward, payload: sfReq) {
                    try? mesh.broadcast(sfWire)
                }
            }

        } else {
            // ── No connectivity: queue for later ──────────────────────────────
            var queue = pendingQueue[peerID, default: []]
            guard queue.count < Self.maxQueuedMessagesPerPeer else {
                throw SophaxError.invalidMessageFormat("Offline message queue is full — reconnect before sending more")
            }
            queue.append((wire: wire, messageID: messageID))
            pendingQueue[peerID] = queue
            persistQueue()
        }
    }

    /// Drain queued messages for a peer that just became reachable.
    private func drainQueue(forPeerID peerID: String) {
        guard let queued = pendingQueue.removeValue(forKey: peerID),
              !queued.isEmpty else { return }
        for item in queued {
            do {
                try sendOrQueue(item.wire, toPeerID: peerID, messageID: item.messageID)
            } catch {
                try? messageStore.updateStatus(.failed, forMessageID: item.messageID, peerID: peerID)
            }
        }
    }

    // MARK: - Private: Session management

    /// Execute `body` with the session for `peerID` under `sessionLock`.
    ///
    /// Returns `nil` if no session exists (Keychain miss) — callers treat that as
    /// "needs X3DH initiation". Throws on Keychain or crypto errors.
    ///
    /// The entire sequence — load → body → persist — is held under the lock so
    /// no two calls can operate on the same DoubleRatchet concurrently.
    private func withSession<T>(
        peerID: String,
        _ body: (DoubleRatchet) throws -> T
    ) throws -> T? {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        // Load from memory; fall back to Keychain
        let ratchet: DoubleRatchet
        if let existing = sessions[peerID] {
            ratchet = existing
        } else {
            guard let data = try? keychain.loadSessionState(peerID: peerID) else {
                return nil   // No persisted session — not an error
            }
            do {
                ratchet = try DoubleRatchet.importState(data)
            } catch {
                // Persisted state is malformed or truncated (e.g. crash mid-write).
                // Delete the corrupt blob so the next outbound message triggers
                // a clean X3DH re-initiation rather than failing indefinitely.
                CrashLogManager.shared.log(error, context: "SessionLoad")
                try? keychain.deleteSessionState(peerID: peerID)
                sessions.removeValue(forKey: peerID)
                throw SophaxError.sessionStateCorrupted
            }
            sessions[peerID] = ratchet
        }

        // Run the caller's crypto operation
        let result = try body(ratchet)

        // Persist mutated ratchet state (still under lock)
        sessions[peerID] = ratchet
        try keychain.saveSessionState(data: ratchet.exportState(), peerID: peerID)

        return result
    }

    /// Store a brand-new ratchet session (after X3DH initiation or reception).
    private func storeNewSession(_ ratchet: DoubleRatchet, peerID: String) throws {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        sessions[peerID] = ratchet
        try keychain.saveSessionState(data: ratchet.exportState(), peerID: peerID)
    }

    // MARK: - Private: Message handlers

    private func handleHello(_ payload: HelloMessage) throws {
        let bundle = payload.bundle

        // Reject oversized fields to prevent memory exhaustion from malicious peers
        guard bundle.username.count <= 64 else { return }
        if let avatar = bundle.avatarData {
            guard avatar.count <= 512_000 else { return }  // 512 KB max
        }

        guard try bundle.verifySignedPreKey() else {
            throw SophaxError.invalidSignature
        }
        guard abs(bundle.timestamp.timeIntervalSinceNow) < CryptoConstants.maxPreKeyBundleAge else {
            throw SophaxError.stalePreKeyBundle
        }

        let peerID       = bundle.peerID
        let safetyNumber = generateSafetyNumber(for: bundle)

        // Preserve existing trust level; new peers default to .pending (contact request gate).
        // Linked devices are always auto-accepted — they belong to the same person.
        let existing   = knownPeers[peerID]
        let trustLevel: PeerTrustLevel = linkedDevicePeerIDs.contains(peerID)
            ? .accepted
            : (existing?.trustLevel ?? .pending)
        let peer       = KnownPeer(from: bundle, safetyNumber: safetyNumber, trustLevel: trustLevel)

        // Detect reconnect: peer was known but is now coming back online
        let wasOffline = existing.map { !$0.isOnline } ?? false

        // Record in the key transparency log; only alert if an existing peer's key changed
        let isKnown = existing != nil
        let logEntryIsNew = keyLog.record(
            peerID:     peerID,
            signingKey: bundle.signingKeyPublic,
            dhKey:      bundle.dhIdentityKeyPublic
        )
        let keyChanged = isKnown && logEntryIsNew

        knownPeers[peerID]  = peer
        peerBundles[peerID] = bundle

        // Eagerly push avatar data so group-only contacts (who never send a DM) get
        // their avatar immediately after Hello rather than waiting for a group message.
        if let avatarData = bundle.avatarData {
            let pid = peerID
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.chatManager(self, didReceiveAvatarData: avatarData, fromPeerID: pid)
            }
        }

        let reconnected    = wasOffline
        let isPending      = trustLevel == .pending && !isKnown   // fire request only once
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isPending {
                self.delegate?.chatManager(self, didReceiveContactRequest: peer)
            } else if trustLevel == .accepted {
                self.delegate?.chatManager(self, didDiscoverPeer: peer)
                if reconnected {
                    self.delegate?.chatManager(self, peerDidReconnect: peer)
                }
            }
            if keyChanged {
                self.delegate?.chatManager(self, didDetectKeyChange: peerID)
            }
        }

        // Only drain/forward for accepted peers
        if trustLevel == .accepted {
            drainQueue(forPeerID: peerID)
            deliverStoredForwardItems(toPeerID: peerID)
            deliverDeadDrops(toPeerID: peerID)
        }
    }

    private func handleInitiateSession(_ payload: InitiateSessionMessage) throws {
        let senderBundle = payload.senderBundle
        guard try senderBundle.verifySignedPreKey() else {
            throw SophaxError.invalidSignature
        }

        let peerID = senderBundle.peerID

        // Drop session initiation from peers we haven't accepted yet
        if knownPeers[peerID]?.trustLevel == .pending { return }

        // Deduplication: if an active session already exists with this peerID,
        // drop the duplicate initiateSession. This prevents replayed X3DH messages
        // from overwriting an established session.
        // A legitimate re-initiation always comes from a new peerID (new identity keys).
        if sessions[peerID] != nil || (try? keychain.loadSessionState(peerID: peerID)) != nil {
            return
        }

        peerBundles[peerID] = senderBundle

        // Retrieve and consume the one-time prekey if Alice used one,
        // then replenish the supply so future sessions have keys available.
        let usedOPKId = payload.usedOneTimePreKeyId
        var otpk: DHKeyPair? = nil
        if let id = usedOPKId {
            otpk = try preKeys.consumeOneTimePreKey(id: id)
        }
        try? preKeys.replenishIfNeeded()

        // Notify delegate so the UI can warn when no OPK was available (reduced entropy)
        let usedOPK = usedOPKId != nil
        let notifyPeerID = peerID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, sessionEstablishedWithPeer: notifyPeerID, usedOPK: usedOPK)
        }

        // X3DH: Bob (responder) side — produces the same shared secret as Alice
        let sharedSecret = try X3DH.initiateReceiver(
            recipientIdentityDH:     identity.dhKeyPair,
            recipientSignedPreKey:   preKeys.signedPreKeyPair,
            recipientOneTimePreKey:  otpk,
            senderIdentityDHKeyData: senderBundle.dhIdentityKeyPublic,
            senderEphemeralKeyData:  payload.ephemeralPublicKey
        )

        // Double Ratchet: Bob starts as responder
        let ratchet = try DoubleRatchet.initAsResponder(
            sharedSecret:      sharedSecret,
            ownRatchetKeyPair: preKeys.signedPreKeyPair
        )

        // Decrypt the initial message (Alice's first plaintext)
        let ad        = associatedData(peerID: peerID)
        let plaintext = try ratchet.decrypt(message: payload.initialMessage, associatedData: ad)
        let content   = try JSONDecoder().decode(MessageContent.self, from: plaintext)

        var attachmentID: String? = nil
        if let attachData = content.attachmentData, content.attachmentMimeType != nil {
            let id = UUID().uuidString
            try? attachmentStore.save(attachData, id: id)
            attachmentID = id
        }

        // Group invite in the initial message — unlikely but handle gracefully
        if content.type == .groupInvite {
            if let inviteData = content.groupInviteData {
                handleGroupInviteReceived(inviteData, fromPeer: peerID)
            }
            try storeNewSession(ratchet, peerID: peerID)
            return
        }

        // Sender key distribution in the initial message — handle gracefully
        if content.type == .senderKeyDistribution {
            handleSenderKeyDistribution(content, fromPeer: peerID)
            try storeNewSession(ratchet, peerID: peerID)
            return
        }

        let displayBody: String
        switch content.type {
        case .text:                  displayBody = content.body
        case .image:                 displayBody = content.body.isEmpty ? "📷 Photo" : content.body
        case .audio:                 displayBody = content.body.isEmpty ? "🎤 Voice message" : content.body
        case .file:                  displayBody = content.attachmentFilename ?? (content.body.isEmpty ? "📎 File" : content.body)
        case .groupInvite:           return                               // dead code; handled above
        case .senderKeyDistribution: return                               // dead code; handled above
        case .mlsCommitRequest:      return                               // wire-level only; never arrives as DR payload content
        }

        try storeNewSession(ratchet, peerID: peerID)

        // Register the peer
        let safetyNumber = generateSafetyNumber(for: senderBundle)
        var peer = KnownPeer(from: senderBundle, safetyNumber: safetyNumber)
        peer.isDirectlyConnected = mesh.isConnected(peerID: peerID)
        knownPeers[peerID] = peer

        let stored = StoredMessage(
            peerID:             peerID,
            direction:          .received,
            body:               displayBody,
            status:             .delivered,
            expiresAt:          clampedExpiry(content.expiresAt),
            attachmentID:       attachmentID,
            attachmentMimeType: content.attachmentMimeType,
            attachmentFilename: content.attachmentFilename,
            audioDuration:      content.audioDuration
        )
        try messageStore.append(message: stored)

        let discoveredPeer = peer
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didDiscoverPeer: discoveredPeer)
            self.delegate?.chatManager(self, didReceiveMessage: stored, fromPeer: peerID)
        }
    }

    private func handleChatMessage(
        _ payload: ChatMessagePayload,
        fromPeer peerID: String,
        hopCount: UInt8? = nil
    ) throws {
        // Drop messages from peers not yet accepted (contact request gate)
        guard knownPeers[peerID]?.trustLevel != .pending else { return }

        let ad = associatedData(peerID: peerID)

        guard let plaintext = try withSession(peerID: peerID, { ratchet in
            try ratchet.decrypt(message: payload.ratchetMessage, associatedData: ad)
        }) else {
            throw SophaxError.sessionNotInitialized
        }

        let content = try JSONDecoder().decode(MessageContent.self, from: plaintext)

        // Save attachment to local store (decrypted data is ephemeral after this)
        var attachmentID: String? = nil
        if let attachData = content.attachmentData, content.attachmentMimeType != nil {
            let id = UUID().uuidString
            try? attachmentStore.save(attachData, id: id)
            attachmentID = id
        }

        // Group invite — don't store as a chat message; process separately
        if content.type == .groupInvite {
            if let inviteData = content.groupInviteData {
                handleGroupInviteReceived(inviteData, fromPeer: peerID)
            }
            // Still ack delivery
            let ack  = AckMessage(messageID: payload.messageID, status: .delivered)
            if let wire = try? wireBuilder.build(.ack, payload: ack) {
                try? sendOrQueue(wire, toPeerID: peerID, messageID: payload.messageID)
            }
            return
        }

        // Sender key distribution — don't store as a chat message; update crypto state
        if content.type == .senderKeyDistribution {
            handleSenderKeyDistribution(content, fromPeer: peerID)
            let ack  = AckMessage(messageID: payload.messageID, status: .delivered)
            if let wire = try? wireBuilder.build(.ack, payload: ack) {
                try? sendOrQueue(wire, toPeerID: peerID, messageID: payload.messageID)
            }
            return
        }

        // Edit payload — update an existing message body; don't create a new message
        if let edit = content.editPayload {
            handleEditMessage(edit, fromPeer: peerID)
            return
        }

        let displayBody: String
        switch content.type {
        case .text:  displayBody = content.body
        case .image: displayBody = content.body.isEmpty ? "📷 Photo" : content.body
        case .audio: displayBody = content.body.isEmpty ? "🎤 Voice message" : content.body
        case .file:  displayBody = content.attachmentFilename ?? (content.body.isEmpty ? "📎 File" : content.body)
        case .groupInvite:            return  // already handled above; belt-and-suspenders guard
        case .senderKeyDistribution:  return  // already handled above; belt-and-suspenders guard
        case .mlsCommitRequest:       return  // wire-level only; never arrives as DR payload content
        }

        let stored = StoredMessage(
            id:                 payload.messageID,
            peerID:             peerID,
            direction:          .received,
            body:               displayBody,
            status:             .delivered,
            replyToID:          content.replyToID,
            expiresAt:          clampedExpiry(content.expiresAt),
            hopCount:           hopCount,
            attachmentID:       attachmentID,
            attachmentMimeType: content.attachmentMimeType,
            attachmentFilename: content.attachmentFilename,
            audioDuration:      content.audioDuration
        )
        try messageStore.append(message: stored)
        forwardToLinkedDevices(stored)

        // Acknowledge delivery — errors here are non-fatal (peer may be gone),
        // but surfaced to the delegate so they are visible in logs.
        do {
            let ack  = AckMessage(messageID: payload.messageID, status: .delivered)
            let wire = try wireBuilder.build(.ack, payload: ack)
            try sendOrQueue(wire, toPeerID: peerID, messageID: payload.messageID)
        } catch {
            delegate?.chatManager(self, didEncounterError: error)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveMessage: stored, fromPeer: peerID)
        }
    }

    private func handleAck(_ payload: AckMessage, fromPeer peerID: String) {
        try? messageStore.updateStatus(.delivered, forMessageID: payload.messageID, peerID: peerID)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, messageDelivered: payload.messageID, toPeer: peerID)
        }
    }

    private func handleReadReceipt(_ payload: ReadReceiptMessage, fromPeer peerID: String) {
        for id in payload.messageIDs {
            try? messageStore.updateStatus(.read, forMessageID: id, peerID: peerID)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, messagesRead: payload.messageIDs, byPeer: peerID)
        }
    }

    /// Handle an incoming message edit. Only accepts edits for messages we received from `peerID`.
    private func handleEditMessage(_ payload: EditMessagePayload, fromPeer peerID: String) {
        guard !payload.newBody.isEmpty, payload.newBody.utf8.count <= Self.maxMessageBytes else { return }
        // Only allow the original sender to edit their own messages.
        guard let msgs = try? messageStore.messages(forPeer: peerID),
              let existing = msgs.first(where: { $0.id == payload.messageID }),
              existing.direction == .received else { return }
        try? messageStore.updateMessage(
            id: payload.messageID, peerID: peerID,
            newBody: payload.newBody, editedAt: payload.editedAt
        )
        let messageID = payload.messageID
        let newBody   = payload.newBody
        let editedAt  = payload.editedAt
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveEditedMessage: messageID,
                                       newBody: newBody, editedAt: editedAt, peerID: peerID)
        }
    }

    /// Handle an incoming group message edit (Sender Keys v2).
    /// Validates authorship (senderID must match stored message senderID), 5-minute window,
    /// and text-only constraint before updating the store.
    private func handleGroupEditMessage(_ payload: GroupEditMessagePayload, fromPeer peerID: String) {
        guard !payload.newBody.isEmpty, payload.newBody.utf8.count <= Self.maxMessageBytes else { return }
        guard joinedGroups[payload.groupID] != nil else { return }
        let convID = "group.\(payload.groupID)"
        guard let msgs = try? messageStore.messages(forPeer: convID),
              let existing = msgs.first(where: { $0.id == payload.messageID }),
              existing.senderID == peerID,          // only the original author can edit
              existing.attachmentID == nil,          // text-only edits
              existing.timestamp.timeIntervalSinceNow > -310 else { return }   // 5 min + 10 s clock slack
        try? messageStore.updateMessage(
            id: payload.messageID, peerID: convID,
            newBody: payload.newBody, editedAt: payload.editedAt
        )
        let messageID = payload.messageID
        let newBody   = payload.newBody
        let editedAt  = payload.editedAt
        let groupID   = payload.groupID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveEditedGroupMessage: messageID,
                                       newBody: newBody, editedAt: editedAt, groupID: groupID)
        }
    }

    private func handleReaction(_ payload: ReactionMessage, fromPeer peerID: String) {
        guard let reactions = applyReaction(emoji: payload.emoji, senderID: peerID,
                                            messageID: payload.targetMessageID, convID: peerID) else { return }
        let messageID = payload.targetMessageID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didUpdateReactions: reactions, onMessageID: messageID, peerID: peerID)
        }
    }

    private func handleGroupReaction(_ payload: GroupReactionMessage, fromPeer peerID: String) {
        let convID = "group.\(payload.groupID)"
        guard let reactions = applyReaction(emoji: payload.emoji, senderID: peerID,
                                            messageID: payload.targetMessageID, convID: convID) else { return }
        let messageID = payload.targetMessageID
        let groupID   = payload.groupID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didUpdateGroupReactions: reactions,
                                       onMessageID: messageID, groupID: groupID)
        }
    }

    /// Apply an emoji reaction (or removal) to the message store and return the updated map.
    /// Returns nil if the target message was not found.
    @discardableResult
    func applyReaction(emoji: String?, senderID: String, messageID: String, convID: String) -> [String: String]? {
        guard let msgs = try? messageStore.messages(forPeer: convID),
              let idx  = msgs.firstIndex(where: { $0.id == messageID }) else { return nil }
        var reactions = msgs[idx].reactions ?? [:]
        if let e = emoji { reactions[senderID] = e } else { reactions.removeValue(forKey: senderID) }
        try? messageStore.updateReactions(reactions, forMessageID: messageID, peerID: convID)
        return reactions
    }

    // MARK: - Store-and-forward handlers

    /// A connected peer asks us to hold a sealed message for an offline third party.
    private func handleStoreAndForward(_ payload: StoreAndForwardRequest) {
        guard payload.expiresAt > Date() else { return }
        // Dedup
        guard !storedForwardItems.contains(where: { $0.messageID == payload.messageID }) else { return }

        // If target is currently connected to us, deliver immediately
        if mesh.isConnected(peerID: payload.targetPeerID) {
            let delivery = StoreAndForwardDelivery(
                items: [StoreAndForwardItem(messageID: payload.messageID, sealed: payload.sealed)]
            )
            if let wire = try? wireBuilder.build(.storeAndForwardDelivery, payload: delivery) {
                try? mesh.send(wire, toPeerID: payload.targetPeerID)
            }
            return
        }

        // Capacity management: purge expired, enforce global cap + per-peer cap
        let now = Date()
        storedForwardItems.removeAll { $0.expiresAt <= now }
        // Per-peer cap: prevents a single attacker peer from consuming all slots
        let peerCount = storedForwardItems.count(where: { $0.targetPeerID == payload.targetPeerID })
        guard peerCount < Self.maxStoredForwardPerPeer else { return }
        if storedForwardItems.count >= Self.maxStoredForwardItems {
            storedForwardItems.removeFirst()
        }

        let clampedExpiry = min(payload.expiresAt, Date().addingTimeInterval(Self.storeAndForwardTTL))
        storedForwardItems.append(StoredForwardItem(
            targetPeerID: payload.targetPeerID,
            messageID:    payload.messageID,
            sealed:       payload.sealed,
            expiresAt:    clampedExpiry
        ))
        persistForwardItems()
    }

    /// We received stored messages from a relay peer (we are the target).
    private func handleStoreAndForwardDelivery(_ payload: StoreAndForwardDelivery) {
        for item in payload.items {
            guard let inner = try? unsealMessage(
                item.sealed, recipientDHPrivateKey: identity.dhKeyPair.privateKey
            ) else { continue }
            // Reject unknown senders for non-self-authenticating message types.
            if inner.type != .hello && inner.type != .initiateSession {
                guard let peer = knownPeers[inner.senderID],
                      (try? WireMessageBuilder.verify(inner, signingKeyPublic: peer.signingKeyPublic)) == true
                else { continue }
            }
            try? processRelayedInnerMessage(inner, hopCount: 0)
        }
    }

    /// Deliver all stored-forward items to `peerID` (called when they come online).
    private func deliverStoredForwardItems(toPeerID peerID: String) {
        let pending = storedForwardItems.filter { $0.targetPeerID == peerID && $0.expiresAt > Date() }
        guard !pending.isEmpty else { return }
        let items = pending.map { StoreAndForwardItem(messageID: $0.messageID, sealed: $0.sealed) }
        let delivery = StoreAndForwardDelivery(items: items)
        if let wire = try? wireBuilder.build(.storeAndForwardDelivery, payload: delivery) {
            try? mesh.send(wire, toPeerID: peerID)
        }
        storedForwardItems.removeAll { $0.targetPeerID == peerID }
        persistForwardItems()
    }

    // MARK: - Dead Drop

    /// Send a sealed message flooded over the entire mesh.
    /// The content is invisible to relay nodes — only the target can open it.
    /// Note: Dead drops do NOT use Double Ratchet (no session needed — that's the point).
    /// They use one-shot ECDH sealing, similar to sealed sender.
    public func sendDeadDrop(toPeerID peerID: String, text: String) throws {
        guard let peer = knownPeers[peerID] else { throw SophaxError.sessionNotInitialized }
        // Build a plain wire message carrying the text as a MessageContent
        let content = MessageContent(body: text, replyToID: nil, expiresAt: nil)
        let inner   = try wireBuilder.build(.message, payload: content)
        // Seal it for the recipient's DH public key (one-shot ECDH, no session needed)
        let sealed  = try sealWireMessage(inner, recipientDHPublicKey: peer.dhKeyPublic)
        let drop    = DeadDropEnvelope(targetPeerID: peerID, sealed: sealed)
        let wire    = try wireBuilder.build(.deadDrop, payload: drop)
        // Flood over mesh — TCP intentionally excluded (dead drops are mesh-only by design)
        try mesh.broadcast(wire, excluding: nil)
        // Store locally so we can deliver if target connects to us later
        storeDeadDrop(drop)
    }

    private func handleDeadDrop(_ drop: DeadDropEnvelope) {
        // Deduplicate
        let now = Date()
        seenDeadDropIDs = seenDeadDropIDs.filter { now.timeIntervalSince($0.value) < Self.deadDropDedupeWindow }
        // Clamp expiry to prevent attackers setting expiresAt far in the future
        // to consume unbounded storage on relay nodes.
        let clampedExpiry = min(drop.expiresAt, now.addingTimeInterval(Self.storeAndForwardTTL))
        guard seenDeadDropIDs[drop.id] == nil, clampedExpiry > now else { return }
        seenDeadDropIDs[drop.id] = now

        let myPeerID = identity.publicIdentity.peerID

        // Is this drop for us?
        if drop.targetPeerID == myPeerID {
            guard let inner = try? unsealMessage(
                drop.sealed, recipientDHPrivateKey: identity.dhKeyPair.privateKey
            ) else { return }
            try? processRelayedInnerMessage(inner, hopCount: 0)
            return
        }

        // Not for us — store and re-broadcast
        storeDeadDrop(drop)
        if let wire = try? wireBuilder.build(.deadDrop, payload: drop) {
            try? mesh.broadcast(wire, excluding: nil)
        }

        // If target is directly connected, deliver immediately
        if mesh.connectedPeerIDs.contains(drop.targetPeerID) {
            if let wire = try? wireBuilder.build(.deadDrop, payload: drop) {
                try? mesh.send(wire, toPeerID: drop.targetPeerID)
            }
        }
    }

    private func storeDeadDrop(_ drop: DeadDropEnvelope) {
        guard drop.expiresAt > Date() else { return }
        guard !deadDrops.contains(where: { $0.id == drop.id }) else { return }
        if deadDrops.count >= Self.maxDeadDrops { deadDrops.removeFirst() }
        deadDrops.append(drop)
    }

    /// Deliver any stored dead drops when a peer comes online.
    private func deliverDeadDrops(toPeerID peerID: String) {
        let pending = deadDrops.filter { $0.targetPeerID == peerID && $0.expiresAt > Date() }
        guard !pending.isEmpty else { return }
        for drop in pending {
            if let wire = try? wireBuilder.build(.deadDrop, payload: drop) {
                try? mesh.send(wire, toPeerID: peerID)
            }
        }
        deadDrops.removeAll { $0.targetPeerID == peerID }
    }

    private func handleGroupMemberLeft(_ payload: GroupMemberLeftMessage, senderID: String) {
        // Only the peer who is leaving may announce their own departure.
        // Accepting announcements from arbitrary senders would allow any peer to
        // silently eject another member from the group.
        guard senderID == payload.leavingPeerID else { return }

        let myID    = identity.publicIdentity.peerID
        let groupID = payload.groupID

        // Notify the delegate so the UI can remove the leaver from the member list
        let leavingPeerID = payload.leavingPeerID
        let remaining     = payload.remainingMemberIDs
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, peer: leavingPeerID,
                                       leftGroupID: groupID, remainingMemberIDs: remaining)
        }

        // Only remaining members rotate; if we're the leaver this message is irrelevant
        guard remaining.contains(myID) else { return }

        // Remove the leaver's sender key state so we stop trying to decrypt with old material
        var states = keychain.loadPeerSenderKeyStates(groupID: groupID)
        states.removeValue(forKey: leavingPeerID)
        keychainSave("peerSenderKeys:\(groupID)") { try keychain.savePeerSenderKeyStates(states, groupID: groupID) }

        // Rotate our own sender key (fresh random seed) so the leaver's copy of our
        // old chain key is no longer valid for any future messages.
        guard keychain.loadMySenderKeyState(groupID: groupID) != nil else { return }
        let tmpKey      = SymmetricKey(size: .bits256)
        let newChainKey = tmpKey.withUnsafeBytes { Data($0) }
        keychainSave("mySenderKey:\(groupID)") {
            try keychain.saveMySenderKeyState(SenderKeyState(chainKey: newChainKey, iteration: 0), groupID: groupID)
        }

        // Re-distribute our new sender key to every remaining member (excluding self)
        let skd = SenderKeyDistributionMessage(groupID: groupID, chainKey: newChainKey, iteration: 0)
        guard let skdData = try? JSONEncoder().encode(skd) else { return }
        for memberID in remaining where memberID != myID {
            let content = MessageContent(body: "", type: .senderKeyDistribution, senderKeyData: skdData)
            if let wire = try? buildOutboundWire(content: content,
                                                  messageID: UUID().uuidString,
                                                  toPeerID: memberID) {
                try? sendOrQueue(wire, toPeerID: memberID, messageID: UUID().uuidString)
            }
        }
    }

    private func handleGroupDeleted(_ payload: GroupDeletedMessage, senderID: String) {
        let groupID = payload.groupID
        // Only accept from the known group creator.
        guard joinedGroups[groupID] != nil,
              let creatorID = groupCreators[groupID],
              senderID == creatorID else { return }

        // Notify delegate so the UI removes the group
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, groupDeletedWithID: groupID)
        }

        joinedGroups.removeValue(forKey: groupID)
        groupCreators.removeValue(forKey: groupID)
        groupCoordinators.removeValue(forKey: groupID)
        keychain.deleteGroupKey(groupID: groupID)
        keychain.deleteAllSenderKeyStates(groupID: groupID)
        Task { try? await self.mlsManager?.deleteGroupState(groupID: groupID) }
        let prefix = groupID + "/"
        skippedGroupMessageKeys.keys.filter { $0.hasPrefix(prefix) }.forEach {
            skippedGroupMessageKeys.removeValue(forKey: $0)
            skippedGroupMessageKeyDates.removeValue(forKey: $0)
        }
        persistSkippedGroupKeyCache()
        try? messageStore.deleteConversation(peerID: "group.\(groupID)")
    }

    func handleCoordinatorHandoff(_ msg: MLSCoordinatorHandoffMessage, senderID: String) {
        let groupID = msg.groupID
        guard joinedGroups[groupID] != nil,
              groupCoordinators[groupID] == senderID,          // sender must be current coordinator
              senderID == msg.fromCoordinatorID else { return } // consistency check
        groupCoordinators[groupID] = msg.newCoordinatorID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didUpdateCoordinator: msg.newCoordinatorID, inGroupID: groupID)
        }
    }

    private func handleGroupInviteReceived(_ inviteData: Data, fromPeer peerID: String) {
        guard let invite = try? JSONDecoder().decode(GroupInvitePayload.self, from: inviteData) else { return }
        // The creatorID inside the payload must match the verified DR sender — prevents a peer
        // with an established session from forwarding a fabricated invite on someone else's behalf.
        guard invite.creatorID == peerID else { return }
        // Cap member list to prevent memory DoS from a malformed or malicious invite;
        // also validate individual ID lengths to prevent oversized string allocations.
        guard invite.memberIDs.count <= 100,
              invite.groupID.count   <= 64,
              invite.creatorID.count <= 64,
              invite.memberIDs.allSatisfy({ $0.count <= 64 }) else { return }
        let myID = identity.publicIdentity.peerID

        // Store creator's sender key state
        var states = keychain.loadPeerSenderKeyStates(groupID: invite.groupID)
        states[invite.creatorID] = SenderKeyState(
            chainKey:   invite.senderChainKey,
            iteration:  invite.senderIteration,
            receivedAt: Date()
        )
        keychainSave("peerSenderKeys:\(invite.groupID)") { try keychain.savePeerSenderKeyStates(states, groupID: invite.groupID) }

        // Generate my own sender key and store it
        let tmpKey       = SymmetricKey(size: .bits256)
        let chainKeyData = tmpKey.withUnsafeBytes { Data($0) }
        let myState      = SenderKeyState(chainKey: chainKeyData, iteration: 0,
                                          messageCount: 0, createdAt: Date())
        keychainSave("mySenderKey:\(invite.groupID)") { try keychain.saveMySenderKeyState(myState, groupID: invite.groupID) }

        // Distribute my sender key to all other members via DR
        let skd = SenderKeyDistributionMessage(groupID: invite.groupID, chainKey: chainKeyData)
        if let skdData = try? JSONEncoder().encode(skd) {
            for memberID in invite.memberIDs where memberID != myID {
                let content = MessageContent(body: "", type: .senderKeyDistribution,
                                             senderKeyData: skdData)
                if let wire = try? buildOutboundWire(content: content,
                                                     messageID: UUID().uuidString,
                                                     toPeerID: memberID) {
                    try? sendOrQueue(wire, toPeerID: memberID, messageID: UUID().uuidString)
                }
            }
        }

        let dedupedMembers = Array(Set(invite.memberIDs))
        let group = GroupInfo(
            id:        invite.groupID,
            name:      invite.groupName,
            memberIDs: dedupedMembers,
            creatorID: invite.creatorID
        )
        joinedGroups[invite.groupID] = Set(dedupedMembers)
        groupCreators[invite.groupID] = invite.creatorID
        groupCoordinators[invite.groupID] = invite.creatorID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didJoinGroup: group)
        }
    }

    private func handleGroupMessage(_ payload: GroupWireMessage) {
        // Validate field lengths before any further processing to prevent large
        // in-memory allocations from malicious peers (e.g. 10 MB senderUsername).
        guard payload.senderPeerID.count  <= 64,
              payload.senderUsername.count <= 64,
              payload.groupID.count        <= 64 else { return }

        // Reject messages from peers who are not in this group.
        // Guard (not if-let) so that an unknown groupID is also rejected — prevents
        // injection into a group whose member list hasn't been cached yet.
        guard let members = joinedGroups[payload.groupID],
              members.contains(payload.senderPeerID) else { return }

        // Reject messages with timestamps too far in the past (>5 min) or future (>30 s)
        // — same window applied to direct messages — to prevent replay and backdating.
        let msgAge = Date().timeIntervalSince(payload.timestamp)
        guard msgAge < 300, msgAge > -30 else { return }

        let body:            String
        var attachDecryptKey: SymmetricKey? = nil

        guard let iteration = payload.senderKeyIteration else { return }

        // ── Sender Key ratchet ────────────────────────────────────────────
        let MAX_SKIP: UInt32 = 100
        let cacheKey = "\(payload.groupID)/\(payload.senderPeerID)"

            // ── Fast path: out-of-order delivery via skipped-key cache ─────────
            if let cachedKey = skippedGroupMessageKeys[cacheKey]?[iteration] {
                guard let sealedBox = try? ChaChaPoly.SealedBox(combined: payload.ciphertext),
                      let bodyData  = try? ChaChaPoly.open(sealedBox, using: cachedKey),
                      let decoded   = String(data: bodyData, encoding: .utf8) else { return }
                body             = decoded
                attachDecryptKey = cachedKey
                // Consume the cached key so it cannot be replayed
                skippedGroupMessageKeys[cacheKey]?.removeValue(forKey: iteration)
                skippedGroupMessageKeyDates[cacheKey]?.removeValue(forKey: iteration)
                if skippedGroupMessageKeys[cacheKey]?.isEmpty == true {
                    skippedGroupMessageKeys.removeValue(forKey: cacheKey)
                    skippedGroupMessageKeyDates.removeValue(forKey: cacheKey)
                }
                persistSkippedGroupKeyCache()
            } else {
                // ── Normal path: advance the chain ───────────────────────────
                var states = keychain.loadPeerSenderKeyStates(groupID: payload.groupID)
                guard var senderState = states[payload.senderPeerID] else {
                    // No key yet — request one and drop; it may arrive shortly after
                    sendSenderKeyRequest(groupID: payload.groupID, fromPeer: payload.senderPeerID)
                    return
                }

                // If the stored key is stale (>30 days old), request a fresh one.
                // Still attempt decryption in case it works — dropping is worse than trying.
                if let received = senderState.receivedAt,
                   Date().timeIntervalSince(received) > Self.senderKeyStaleThreshold {
                    sendSenderKeyRequest(groupID: payload.groupID, fromPeer: payload.senderPeerID)
                }
                guard iteration >= senderState.iteration,
                      iteration - senderState.iteration <= MAX_SKIP else { return }

                // Fast-forward to the target iteration, caching skipped message keys
                // so out-of-order messages that arrive later can still be decrypted.
                var cached      = skippedGroupMessageKeys[cacheKey] ?? [:]
                var cachedDates = skippedGroupMessageKeyDates[cacheKey] ?? [:]
                let now = Date()
                while senderState.iteration < iteration {
                    let (msgKey, nextCK) = senderKeyRatchetStep(senderState.chainKey)
                    cached[senderState.iteration]      = msgKey
                    cachedDates[senderState.iteration] = now
                    senderState = SenderKeyState(chainKey: nextCK, iteration: senderState.iteration + 1)
                }
                // Evict oldest entries if the cache grows too large
                if cached.count > Self.maxSkippedKeysCacheSize {
                    let toEvict = cached.keys.sorted().prefix(cached.count - Self.maxSkippedKeysCacheSize)
                    toEvict.forEach { cached.removeValue(forKey: $0); cachedDates.removeValue(forKey: $0) }
                }
                skippedGroupMessageKeys[cacheKey]     = cached.isEmpty ? nil : cached
                skippedGroupMessageKeyDates[cacheKey] = cachedDates.isEmpty ? nil : cachedDates
                if !cached.isEmpty { persistSkippedGroupKeyCache() }

                let (messageKey, nextCK) = senderKeyRatchetStep(senderState.chainKey)
                guard let sealedBox = try? ChaChaPoly.SealedBox(combined: payload.ciphertext),
                      let bodyData  = try? ChaChaPoly.open(sealedBox, using: messageKey),
                      let decoded   = String(data: bodyData, encoding: .utf8) else { return }
                body             = decoded
                attachDecryptKey = messageKey

                states[payload.senderPeerID] = SenderKeyState(chainKey: nextCK, iteration: iteration + 1,
                                                              receivedAt: states[payload.senderPeerID]?.receivedAt)
                keychainSave("peerSenderKeys:\(payload.groupID)") { try keychain.savePeerSenderKeyStates(states, groupID: payload.groupID) }
            }

        // Decrypt attachment if present
        var attachmentID: String? = nil
        if let attCiphertext = payload.attachmentCiphertext,
           payload.attachmentMimeType != nil,
           let key      = attachDecryptKey,
           let sealedAtt = try? ChaChaPoly.SealedBox(combined: attCiphertext),
           let attData  = try? ChaChaPoly.open(sealedAtt, using: key) {
            let id = UUID().uuidString
            try? attachmentStore.save(attData, id: id)
            attachmentID = id
        }

        let convID = "group.\(payload.groupID)"
        let stored = StoredMessage(
            id:                 payload.messageID,
            peerID:             convID,
            direction:          .received,
            body:               body,
            timestamp:          payload.timestamp,
            status:             .delivered,
            replyToID:          payload.replyToID,
            expiresAt:          clampedExpiry(payload.expiresAt),
            attachmentID:       attachmentID,
            attachmentMimeType: payload.attachmentMimeType,
            attachmentFilename: payload.attachmentFilename,
            audioDuration:      payload.audioDuration,
            senderID:           payload.senderPeerID,
            receivedAt:         Date()
        )
        try? messageStore.append(message: stored)

        // Cache sender avatar if this is a group-only contact (no Hello received yet)
        if let avatarData = payload.senderAvatarData,
           !avatarData.isEmpty, avatarData.count <= 8_192,
           peerBundles[payload.senderPeerID]?.avatarData == nil {
            let senderID = payload.senderPeerID
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.chatManager(self, didReceiveAvatarData: avatarData, fromPeerID: senderID)
            }
        }

        // Send a delivery receipt back to the original sender so they can track delivery.
        // Best-effort: if we have no path to the sender yet, the receipt is silently dropped.
        let receiptPayload = GroupReadReceiptMessage(groupID: payload.groupID, targetMessageID: payload.messageID, isRead: false)
        if let receipt = try? wireBuilder.build(.groupReadReceipt, payload: receiptPayload) {
            try? sendOrQueue(receipt, toPeerID: payload.senderPeerID, messageID: UUID().uuidString)
        }

        let groupID = payload.groupID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveGroupMessage: stored, inGroup: groupID)
        }
    }

    private func handleGroupReadReceipt(_ payload: GroupReadReceiptMessage, fromPeer peerID: String) {
        let convID = "group.\(payload.groupID)"
        if payload.isRead == true {
            try? messageStore.addReadBy(peerID, forMessageID: payload.targetMessageID, convID: convID)
        } else {
            try? messageStore.addDeliveredBy(peerID, forMessageID: payload.targetMessageID, convID: convID)
        }
        let messageID  = payload.targetMessageID
        let groupID    = payload.groupID
        let isRead     = payload.isRead == true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, groupMessageDelivered: messageID,
                                       inGroup: groupID, byPeer: peerID, isRead: isRead)
        }
    }

    /// Handle a RelayEnvelope arriving from a directly-connected peer.
    private func handleRelay(_ envelope: RelayEnvelope, fromRelayPeer relayPeerID: String) throws {
        let myPeerID = identity.publicIdentity.peerID

        if envelope.targetPeerID == myPeerID {
            // ── Destination reached — process the inner message ───────────────
            let inner = envelope.message

            // Reject unknown senders for non-self-authenticating types. processRelayedInnerMessage
            // already enforces this, but checking here avoids unnecessary decryption work.
            if inner.type != .hello && inner.type != .initiateSession {
                guard let peer = knownPeers[inner.senderID] else { return }
                guard (try? WireMessageBuilder.verify(inner, signingKeyPublic: peer.signingKeyPublic)) == true else {
                    return
                }
            }

            try processRelayedInnerMessage(inner, hopCount: envelope.hopCount)

        } else {
            // ── Not for me — check dedup cache and forward if still alive ─────
            guard !relayRouter.isRateLimited(senderID: relayPeerID) else { return }
            guard relayRouter.shouldProcess(envelope) else { return }

            let forwarded = envelope.forwarded()
            let relayWire = try wireBuilder.build(.relay, payload: forwarded)
            // Exclude the peer who sent us this envelope to avoid looping
            try mesh.broadcast(relayWire, excluding: relayPeerID)
        }
    }

    /// Dispatch a WireMessage that arrived via the relay system.
    /// `depth` prevents recursive sealed message processing (stack overflow / DoS).
    private func processRelayedInnerMessage(_ message: WireMessage, hopCount: UInt8, depth: Int = 0) throws {
        // .hello and .initiateSession are self-authenticating — the signing key is embedded
        // in the payload itself (PreKeyBundle / senderBundle). All other message types must
        // come from a known peer whose key we have already verified.
        //
        // Without this check, a known relay peer could forward messages on behalf of an
        // unknown third party: the outer relay message passes the knownPeers guard in
        // handleIncomingMessage(), but the inner senderID could be anyone — allowing
        // unauthenticated reactions, read receipts, and group messages to reach the UI.
        if message.type != .hello && message.type != .initiateSession {
            guard let peer = knownPeers[message.senderID] else { return }
            do {
                guard try WireMessageBuilder.verify(message, signingKeyPublic: peer.signingKeyPublic) else {
                    return
                }
            } catch {
                #if DEBUG
                print("[ChatManager] ⚠️ Sig verify error from \(message.senderID.prefix(8)): \(error)")
                #endif
                return
            }
        }

        switch message.type {

        case .hello:
            let payload = try wireBuilder.decodePayload(HelloMessage.self, from: message)
            // Verify using the signing key that's inside the bundle itself
            guard try WireMessageBuilder.verify(
                message, signingKeyPublic: payload.bundle.signingKeyPublic
            ) else { throw SophaxError.invalidSignature }
            // Reject if the claimed senderID doesn't match the bundle-derived peerID
            guard message.senderID == payload.bundle.peerID else { throw SophaxError.invalidSignature }
            try handleHello(payload)

        case .initiateSession:
            let payload = try wireBuilder.decodePayload(InitiateSessionMessage.self, from: message)
            // Self-authenticating: verify outer WireMessage signature using the key
            // embedded in the sender's bundle. This prevents a relay node from
            // substituting its own X25519 keys into the X3DH handshake (MITM).
            guard try WireMessageBuilder.verify(
                message, signingKeyPublic: payload.senderBundle.signingKeyPublic
            ) else { throw SophaxError.invalidSignature }
            try handleInitiateSession(payload)

        case .message:
            let payload = try wireBuilder.decodePayload(ChatMessagePayload.self, from: message)
            try handleChatMessage(payload, fromPeer: message.senderID, hopCount: hopCount)

        case .ack:
            let payload = try wireBuilder.decodePayload(AckMessage.self, from: message)
            handleAck(payload, fromPeer: message.senderID)

        case .readReceipt:
            let payload = try wireBuilder.decodePayload(ReadReceiptMessage.self, from: message)
            handleReadReceipt(payload, fromPeer: message.senderID)

        case .reaction:
            let payload = try wireBuilder.decodePayload(ReactionMessage.self, from: message)
            handleReaction(payload, fromPeer: message.senderID)

        case .editMessage:
            let payload = try wireBuilder.decodePayload(EditMessagePayload.self, from: message)
            handleEditMessage(payload, fromPeer: message.senderID)

        case .groupEditMessage:
            if let payload = try? wireBuilder.decodePayload(GroupEditMessagePayload.self, from: message) {
                handleGroupEditMessage(payload, fromPeer: message.senderID)
            }

        case .groupMessage:
            let payload = try wireBuilder.decodePayload(GroupWireMessage.self, from: message)
            handleGroupMessage(payload)

        case .sealed:
            // Reject nested sealed messages to prevent recursive DoS (stack overflow / CPU exhaustion).
            guard depth == 0 else { return }
            let sealed = try wireBuilder.decodePayload(SealedMessage.self, from: message)
            let inner  = try unsealMessage(sealed, recipientDHPrivateKey: identity.dhKeyPair.privateKey)
            // Reject sealed messages from unknown senders — we cannot verify their signature.
            // Self-authenticating types (.hello, .initiateSession) are handled in the recursive
            // call's own guard block above, so they still work for new peer discovery.
            if inner.type != .hello && inner.type != .initiateSession {
                guard let peer = knownPeers[inner.senderID] else { return }
                do {
                    guard try WireMessageBuilder.verify(inner, signingKeyPublic: peer.signingKeyPublic) else { return }
                } catch { return }
            }
            try processRelayedInnerMessage(inner, hopCount: hopCount, depth: depth + 1)

        case .groupReaction:
            let payload = try wireBuilder.decodePayload(GroupReactionMessage.self, from: message)
            handleGroupReaction(payload, fromPeer: message.senderID)

        case .groupMemberLeft:
            let payload = try wireBuilder.decodePayload(GroupMemberLeftMessage.self, from: message)
            handleGroupMemberLeft(payload, senderID: message.senderID)

        case .groupDeleted:
            if let payload = try? wireBuilder.decodePayload(GroupDeletedMessage.self, from: message) {
                handleGroupDeleted(payload, senderID: message.senderID)
            }

        case .groupReadReceipt:
            let payload = try wireBuilder.decodePayload(GroupReadReceiptMessage.self, from: message)
            handleGroupReadReceipt(payload, fromPeer: message.senderID)

        case .senderKeyRequest:
            if let payload = try? wireBuilder.decodePayload(SenderKeyRequestMessage.self, from: message) {
                handleSenderKeyRequest(payload, fromPeer: message.senderID)
            }

        case .storeAndForward, .storeAndForwardDelivery:
            break   // S&F is direct-only; relay nodes must not forward these

        case .relay, .typing:
            break   // No relay-of-relay; typing over relay has no value

        case .channelAnnouncement:
            break   // Channel announcements are broadcast-only; not forwarded via relay

        case .deadDrop:
            if let drop = try? wireBuilder.decodePayload(DeadDropEnvelope.self, from: message) {
                handleDeadDrop(drop)
            }

        case .mlsWelcome, .mlsCommit, .mlsMessage, .mlsCommitRequest, .mlsReaction, .mlsCoordinatorHandoff, .mlsGroupEditMessage:
            dispatchMLSMessage(message)

        case .deviceLinkRequest:
            if let payload = try? wireBuilder.decodePayload(DeviceLinkRequestMessage.self, from: message) {
                handleDeviceLinkRequest(payload, senderID: message.senderID)
            }

        case .deviceSyncMessage:
            if let payload = try? wireBuilder.decodePayload(DeviceSyncMessage.self, from: message) {
                handleDeviceSyncMessage(payload, fromPeer: message.senderID)
            }

        case .sssShareDelivery:
            if let payload = try? wireBuilder.decodePayload(SSSShareDeliveryMessage.self, from: message) {
                handleSSSShareDelivery(payload)
            }

        case .sssShareRequest:
            if let payload = try? wireBuilder.decodePayload(SSSShareRequestMessage.self, from: message) {
                handleSSSShareRequest(payload, requesterPeerID: message.senderID)
            }

        case .sssShareResponse:
            if let payload = try? wireBuilder.decodePayload(SSSShareResponseMessage.self, from: message) {
                handleSSSShareResponse(payload)
            }

        case .remoteWipe:
            if let payload = try? wireBuilder.decodePayload(RemoteWipeRequest.self, from: message) {
                handleRemoteWipe(payload, fromPeer: message.senderID)
            }

        case .dhtPing, .dhtPong, .dhtFindNode, .dhtFindNodeResp,
             .dhtStore, .dhtFindValue, .dhtFindValueResp:
            if dhtRateLimiters[message.senderID] == nil {
                dhtRateLimiters[message.senderID] = TokenBucket(capacity: 30, windowSeconds: 60)
            }
            guard dhtRateLimiters[message.senderID]!.consume() else { break }
            Task { [weak self] in
                guard let self else { return }
                await self.dhtEngine?.handleMessage(message, fromPeer: message.senderID)
            }
        }
    }

    // MARK: - Private: Remote Wipe
    // Persisted to Keychain so replayed wipe requests are rejected across app restarts.
    // Capped at 200 entries; oldest are pruned when the cap is exceeded.

    private static let maxSeenWipeIDs = 200

    private var seenWipeRequestIDs: Set<String> = []

    public func sendRemoteWipe(toPeerID: String) {
        let payload = RemoteWipeRequest()
        guard let wire = try? wireBuilder.build(.remoteWipe, payload: payload) else { return }
        try? sendOrQueue(wire, toPeerID: toPeerID, messageID: payload.requestID)
    }

    public func addTrustedWipePeer(_ peerID: String) {
        var peers = trustedWipePeers
        peers.insert(peerID)
        keychain.saveTrustedWipePeers(Array(peers))
    }

    public func removeTrustedWipePeer(_ peerID: String) {
        var peers = trustedWipePeers
        peers.remove(peerID)
        keychain.saveTrustedWipePeers(Array(peers))
    }

    public var trustedWipePeers: Set<String> {
        Set(keychain.loadTrustedWipePeers())
    }

    private func handleRemoteWipe(_ req: RemoteWipeRequest, fromPeer senderID: String) {
        // 1. Sender must be a trusted wipe peer
        guard trustedWipePeers.contains(senderID) else { return }
        // 2. Dedup — reject replays including across app restarts
        guard !seenWipeRequestIDs.contains(req.requestID) else { return }
        seenWipeRequestIDs.insert(req.requestID)
        // Cap to prevent unbounded Keychain growth (oldest UUIDs are pruned arbitrarily)
        if seenWipeRequestIDs.count > Self.maxSeenWipeIDs {
            seenWipeRequestIDs = Set(seenWipeRequestIDs.dropFirst(seenWipeRequestIDs.count - Self.maxSeenWipeIDs))
        }
        keychain.saveSeenWipeRequestIDs(seenWipeRequestIDs)
        // 3. Notify delegate on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManagerDidReceiveRemoteWipeRequest(self)
        }
    }

    // MARK: - Private: Multi-device handlers

    private func handleDeviceLinkRequest(_ payload: DeviceLinkRequestMessage, senderID: String) {
        // Bundle peerID must match the outer wire senderID to prevent spoofing
        guard payload.bundle.peerID == senderID else { return }
        guard senderID != identity.publicIdentity.peerID else { return }
        // Reject expired QR payloads (nil expiresAt = reciprocal reply, no expiry needed)
        if let exp = payload.expiresAt, exp < Date() { return }
        guard (try? payload.bundle.verifySignedPreKey()) == true else { return }

        peerBundles[senderID] = payload.bundle
        linkedDevicePeerIDs.insert(senderID)
        saveLinkedDevices()

        let safetyNumber = generateSafetyNumber(for: payload.bundle)
        let peer = KnownPeer(from: payload.bundle, safetyNumber: safetyNumber, trustLevel: .accepted)
        knownPeers[senderID] = peer

        // Push recent history to the peer that initiated the link (so both sides backfill each other)
        backfillHistory(toPeerID: senderID)

        let peerCopy = peer
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didLinkDevice: peerCopy)
            self.delegate?.chatManager(self, didDiscoverPeer: peerCopy)
        }
    }

    private func handleDeviceSyncMessage(_ payload: DeviceSyncMessage, fromPeer peerID: String) {
        // Only accept synced messages from devices we explicitly linked
        guard linkedDevicePeerIDs.contains(peerID) else { return }
        guard let msg = try? JSONDecoder().decode(StoredMessage.self, from: payload.messageJSON) else { return }
        // Dedup: skip if we already stored this message (could happen if both devices are online)
        if let existing = try? messageStore.messages(forPeer: msg.peerID),
           existing.contains(where: { $0.id == msg.id }) { return }
        try? messageStore.append(message: msg)
        let convID = payload.conversationID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveSyncedMessage: msg, conversationID: convID)
        }
    }

    /// Send the last 100 messages from every conversation to a newly linked device.
    /// Attachment bytes are not included — only message metadata and body text.
    private func backfillHistory(toPeerID peerID: String) {
        let convIDs = messageStore.allConversationPeerIDs()
        for convID in convIDs {
            // Skip conversations that ARE this device (would create a sync loop)
            guard convID != peerID else { continue }
            guard let msgs = try? messageStore.messages(forPeer: convID) else { continue }
            // Cap at the last 100 messages per conversation
            for stored in msgs.suffix(100) {
                guard let messageJSON = try? JSONEncoder().encode(stored) else { continue }
                let direction = stored.direction == .sent ? "sent" : "received"
                let sync = DeviceSyncMessage(
                    conversationID: convID,
                    messageJSON:    messageJSON,
                    direction:      direction
                )
                guard let wire = try? wireBuilder.build(.deviceSyncMessage, payload: sync) else { continue }
                try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
            }
        }
    }

    /// Forward a stored message to all linked devices as a `deviceSyncMessage`.
    /// Skips forwarding if this message itself came from a linked device (breaks sync loops).
    private func forwardToLinkedDevices(_ stored: StoredMessage) {
        guard !linkedDevicePeerIDs.isEmpty else { return }
        // Don't forward messages whose peerID is a linked device — they're already synced
        guard !linkedDevicePeerIDs.contains(stored.peerID) else { return }
        // Note to Self is local-only — never sync to linked devices
        guard stored.peerID != "__note_to_self__" else { return }
        guard let messageJSON = try? JSONEncoder().encode(stored) else { return }
        let direction = stored.direction == .sent ? "sent" : "received"
        let sync = DeviceSyncMessage(
            conversationID: stored.peerID,
            messageJSON:    messageJSON,
            direction:      direction
        )
        guard let wire = try? wireBuilder.build(.deviceSyncMessage, payload: sync) else { return }
        for devicePeerID in linkedDevicePeerIDs {
            try? sendOrQueue(wire, toPeerID: devicePeerID, messageID: UUID().uuidString)
        }
    }

    // MARK: - Private: Persistent queue

    private func persistQueue() {
        let serializable: [String: [PendingQueueItem]] = pendingQueue.mapValues { items in
            items.map { PendingQueueItem(wire: $0.wire, messageID: $0.messageID) }
        }
        guard let data = try? JSONEncoder().encode(serializable) else { return }
        try? messageStore.saveEncryptedBlob(data, fileName: pendingQueueFileName)
    }

    private func loadPersistedQueue() {
        guard let data = messageStore.loadEncryptedBlob(fileName: pendingQueueFileName),
              let decoded = try? JSONDecoder().decode([String: [PendingQueueItem]].self, from: data) else { return }
        pendingQueue = decoded.mapValues { items in
            items.map { (wire: $0.wire, messageID: $0.messageID) }
        }
    }

    private func persistForwardItems() {
        guard let data = try? JSONEncoder().encode(storedForwardItems) else { return }
        try? messageStore.saveEncryptedBlob(data, fileName: storedForwardFileName)
    }

    private func loadPersistedForwardItems() {
        guard let data = messageStore.loadEncryptedBlob(fileName: storedForwardFileName),
              let decoded = try? JSONDecoder().decode([StoredForwardItem].self, from: data) else { return }
        storedForwardItems = decoded.filter { $0.expiresAt > Date() }
    }

    /// Load persisted skipped-message-key cache from Keychain into memory.
    /// Called once during `start()`.
    private func loadSkippedGroupKeyCache() {
        let saved = keychain.loadSkippedGroupKeys()
        for (cacheKey, entries) in saved {
            var keys:  [UInt32: SymmetricKey] = [:]
            var dates: [UInt32: Date]         = [:]
            for (iterStr, entry) in entries {
                guard let iter = UInt32(iterStr) else { continue }
                keys[iter]  = SymmetricKey(data: entry.keyData)
                dates[iter] = entry.storedAt
            }
            if !keys.isEmpty {
                skippedGroupMessageKeys[cacheKey]     = keys
                skippedGroupMessageKeyDates[cacheKey] = dates
            }
        }
    }

    /// Persist the current in-memory skipped-key cache to Keychain.
    private func persistSkippedGroupKeyCache() {
        var entries: [String: [String: KeychainManager.SkippedKeyEntry]] = [:]
        for (cacheKey, keys) in skippedGroupMessageKeys {
            entries[cacheKey] = Dictionary(uniqueKeysWithValues: keys.map { iter, key in
                let keyData  = key.withUnsafeBytes { Data($0) }
                let storedAt = skippedGroupMessageKeyDates[cacheKey]?[iter] ?? Date()
                return (String(iter), KeychainManager.SkippedKeyEntry(keyData: keyData, storedAt: storedAt))
            })
        }
        keychainSave("skippedGroupKeyCache") { try self.keychain.saveSkippedGroupKeys(entries) }
    }

    // MARK: - Private: Helpers

    /// Associated data for Double Ratchet AEAD operations.
    /// Binds the session cryptographically to the specific pair of identities.
    /// The IDs are sorted so the value is the same on both sides regardless of
    /// who initiated the session.
    private func associatedData(peerID: String) -> Data {
        let localID   = identity.publicIdentity.peerID
        let sortedIDs = [localID, peerID].sorted()
        return Data((sortedIDs.joined() + CryptoConstants.appVersion).utf8)
    }

    /// 60-digit safety number (12 groups of 5 digits) for out-of-band
    /// identity verification, derived from SHA-512 of both identity keys.
    private func generateSafetyNumber(for bundle: PreKeyBundle) -> String {
        let combined = bundle.signingKeyPublic + bundle.dhIdentityKeyPublic
        let hash     = SHA512.hash(data: combined)
        let hashData = Data(hash)
        var groups: [String] = []
        for i in stride(from: 0, to: 30, by: 5) {
            let chunk = hashData[i..<(i + 5)]
            let value = chunk.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 100_000
            groups.append(String(format: "%05d", value))
        }
        return groups.joined(separator: " ")
    }
}

// MARK: - MeshManagerDelegate

extension ChatManager: MeshManagerDelegate {

    public func meshManager(
        _ manager: MeshManager, didDiscoverPeer peerID: String, withName displayName: String
    ) {
        // Nothing yet — wait for the Hello message to learn their crypto identity
    }

    public func meshManager(_ manager: MeshManager, didLosePeer peerID: String) {
        knownPeers[peerID]?.isOnline            = false
        knownPeers[peerID]?.isDirectlyConnected = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, peerDidDisconnect: peerID)
        }
    }

    public func meshManager(_ manager: MeshManager, didConnectToPeer mcPeerID: String) {
        // Send our PreKeyBundle immediately so the peer can initiate X3DH.
        // Include tcpAddress so the peer can also reach us over Tor/TCP.
        // Called on the main thread by MeshManager — all operations here are synchronous
        // and non-blocking (pure in-memory crypto + MCSession.send which is thread-safe).
        do {
            let bundle = try preKeys.generateBundle(tcpAddress: myTCPAddress)
            let hello  = HelloMessage(bundle: bundle)
            let wire   = try wireBuilder.build(.hello, payload: hello)
            try mesh.send(wire, toPeerID: mcPeerID)
        } catch {
            delegate?.chatManager(self, didEncounterError: error)
        }
        // Note: drainQueue is called from handleHello once the peer's real peerID is known
    }

    public func meshManager(_ manager: MeshManager, didDisconnectFromPeer peerID: String) {
        knownPeers[peerID]?.isOnline            = false
        knownPeers[peerID]?.isDirectlyConnected = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, peerDidDisconnect: peerID)
        }
    }

    public func meshManager(
        _ manager: MeshManager, didReceiveMessage message: WireMessage, fromPeer mcPeerID: String
    ) {
        handleIncomingMessage(message)
    }

    public func meshManager(
        _ manager: MeshManager, sendDidFailForPeer peerID: String, error: Error
    ) {
        delegate?.chatManager(self, didEncounterError: error)
    }

    // MARK: - Private helpers

    /// Shared message dispatch — called from both MeshManagerDelegate and TCPTransportDelegate.
    /// Verifies signatures and routes to the appropriate handler.
    private func handleIncomingMessage(_ message: WireMessage) {
        // Reject messages with timestamps too far from now.
        // Relay envelopes get a wider window (10 min) to tolerate multi-hop latency;
        // all other types use a strict 5-minute window.
        // Directional validation: reject messages too far in the past OR more than 30s in the future.
        // Using abs() previously allowed future-dated messages up to maxAge seconds ahead.
        let offset: TimeInterval = message.timestamp.timeIntervalSinceNow // positive = future
        let maxAge: TimeInterval = message.type == .relay ? 600 : 300
        guard offset > -maxAge, offset < 30 else { return }

        // Signature verification:
        //   • .hello          — self-verifying (signing key inside bundle); handled below.
        //   • .initiateSession — self-verifying (signing key inside sender bundle); handled below.
        //   • everything else — MUST come from a known peer with a verified signature.
        //     Unknown senders cannot send arbitrary message types; we drop silently.
        if message.type != .hello && message.type != .initiateSession {
            guard let peer = knownPeers[message.senderID] else {
                #if DEBUG
                print("[ChatManager] ⚠️ Unknown sender: type=\(message.type.rawValue) sender=\(message.senderID.prefix(8))")
                #endif
                return
            }
            do {
                guard try WireMessageBuilder.verify(message, signingKeyPublic: peer.signingKeyPublic) else {
                    #if DEBUG
                    print("[ChatManager] ⚠️ Invalid signature: type=\(message.type.rawValue) sender=\(message.senderID.prefix(8))")
                    #endif
                    return
                }
            } catch {
                #if DEBUG
                print("[ChatManager] ⚠️ Sig verify error: type=\(message.type.rawValue) sender=\(message.senderID.prefix(8)) error=\(error)")
                #endif
                return
            }
        }

        do {
            switch message.type {

            case .hello:
                let payload = try wireBuilder.decodePayload(HelloMessage.self, from: message)
                // Self-verifying: use the key inside the bundle
                guard try WireMessageBuilder.verify(
                    message, signingKeyPublic: payload.bundle.signingKeyPublic
                ) else { throw SophaxError.invalidSignature }
                // Reject if the claimed senderID doesn't match the bundle-derived peerID
                guard message.senderID == payload.bundle.peerID else { throw SophaxError.invalidSignature }
                try handleHello(payload)

            case .initiateSession:
                let payload = try wireBuilder.decodePayload(InitiateSessionMessage.self, from: message)
                // Self-authenticating: verify using the key embedded in the sender's bundle.
                // The outer signature check above skips unknown senders, so
                // initiateSession must ALWAYS verify itself — same as hello.
                guard try WireMessageBuilder.verify(
                    message, signingKeyPublic: payload.senderBundle.signingKeyPublic
                ) else { throw SophaxError.invalidSignature }
                try handleInitiateSession(payload)

            case .message:
                let payload = try wireBuilder.decodePayload(ChatMessagePayload.self, from: message)
                try handleChatMessage(payload, fromPeer: message.senderID)

            case .ack:
                let payload = try wireBuilder.decodePayload(AckMessage.self, from: message)
                handleAck(payload, fromPeer: message.senderID)

            case .readReceipt:
                let payload = try wireBuilder.decodePayload(ReadReceiptMessage.self, from: message)
                handleReadReceipt(payload, fromPeer: message.senderID)

            case .reaction:
                let reactionSenderID = message.senderID
                if reactionRateLimiters[reactionSenderID] == nil {
                    reactionRateLimiters[reactionSenderID] = TokenBucket(capacity: 20, windowSeconds: 10)
                }
                guard reactionRateLimiters[reactionSenderID]!.consume() else { break }
                let payload = try wireBuilder.decodePayload(ReactionMessage.self, from: message)
                handleReaction(payload, fromPeer: reactionSenderID)

            case .editMessage:
                let payload = try wireBuilder.decodePayload(EditMessagePayload.self, from: message)
                handleEditMessage(payload, fromPeer: message.senderID)

            case .groupEditMessage:
                if let payload = try? wireBuilder.decodePayload(GroupEditMessagePayload.self, from: message) {
                    handleGroupEditMessage(payload, fromPeer: message.senderID)
                }

            case .groupMessage:
                let payload = try wireBuilder.decodePayload(GroupWireMessage.self, from: message)
                handleGroupMessage(payload)

            case .groupReaction:
                let payload = try wireBuilder.decodePayload(GroupReactionMessage.self, from: message)
                handleGroupReaction(payload, fromPeer: message.senderID)

            case .groupMemberLeft:
                let payload = try wireBuilder.decodePayload(GroupMemberLeftMessage.self, from: message)
                handleGroupMemberLeft(payload, senderID: message.senderID)

            case .groupDeleted:
                if let payload = try? wireBuilder.decodePayload(GroupDeletedMessage.self, from: message) {
                    handleGroupDeleted(payload, senderID: message.senderID)
                }

            case .groupReadReceipt:
                let payload = try wireBuilder.decodePayload(GroupReadReceiptMessage.self, from: message)
                handleGroupReadReceipt(payload, fromPeer: message.senderID)

            case .senderKeyRequest:
                if let payload = try? wireBuilder.decodePayload(SenderKeyRequestMessage.self, from: message) {
                    handleSenderKeyRequest(payload, fromPeer: message.senderID)
                }

            case .storeAndForward:
                let payload = try wireBuilder.decodePayload(StoreAndForwardRequest.self, from: message)
                handleStoreAndForward(payload)

            case .storeAndForwardDelivery:
                let payload = try wireBuilder.decodePayload(StoreAndForwardDelivery.self, from: message)
                handleStoreAndForwardDelivery(payload)

            case .channelAnnouncement:
                // Channel announcements are direct-broadcast only (1 hop).
                // They are signed so we can verify the creator's identity.
                let payload = try wireBuilder.decodePayload(ChannelAnnouncement.self, from: message)
                handleChannelAnnouncement(payload, fromPeer: message.senderID)

            case .relay:
                let envelope = try wireBuilder.decodePayload(RelayEnvelope.self, from: message)
                try handleRelay(envelope, fromRelayPeer: message.senderID)

            case .sealed:
                // Sealed sender arriving on a direct connection (unusual but valid)
                let sealed = try wireBuilder.decodePayload(SealedMessage.self, from: message)
                let inner  = try unsealMessage(sealed, recipientDHPrivateKey: identity.dhKeyPair.privateKey)
                // Reject unknown senders (non-self-authenticating types).
                if inner.type != .hello && inner.type != .initiateSession {
                    guard let peer = knownPeers[inner.senderID],
                          (try? WireMessageBuilder.verify(inner, signingKeyPublic: peer.signingKeyPublic)) == true
                    else { break }
                }
                try processRelayedInnerMessage(inner, hopCount: 0)

            case .typing:
                let typingSenderID = message.senderID
                if typingRateLimiters[typingSenderID] == nil {
                    typingRateLimiters[typingSenderID] = TokenBucket(capacity: 10, windowSeconds: 10)
                }
                guard typingRateLimiters[typingSenderID]!.consume() else { break }
                let payload = try wireBuilder.decodePayload(TypingMessage.self, from: message)
                let isTyping = payload.isTyping
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.chatManager(self, peerDidUpdateTyping: typingSenderID, isTyping: isTyping)
                }

            case .deadDrop:
                let payload = try wireBuilder.decodePayload(DeadDropEnvelope.self, from: message)
                handleDeadDrop(payload)

            case .mlsWelcome, .mlsCommit, .mlsMessage, .mlsCommitRequest, .mlsReaction, .mlsCoordinatorHandoff, .mlsGroupEditMessage:
                dispatchMLSMessage(message)

            case .deviceLinkRequest:
                if let payload = try? wireBuilder.decodePayload(DeviceLinkRequestMessage.self, from: message) {
                    handleDeviceLinkRequest(payload, senderID: message.senderID)
                }

            case .deviceSyncMessage:
                if let payload = try? wireBuilder.decodePayload(DeviceSyncMessage.self, from: message) {
                    handleDeviceSyncMessage(payload, fromPeer: message.senderID)
                }

            case .sssShareDelivery:
                if let payload = try? wireBuilder.decodePayload(SSSShareDeliveryMessage.self, from: message) {
                    handleSSSShareDelivery(payload)
                }

            case .sssShareRequest:
                if let payload = try? wireBuilder.decodePayload(SSSShareRequestMessage.self, from: message) {
                    handleSSSShareRequest(payload, requesterPeerID: message.senderID)
                }

            case .sssShareResponse:
                if let payload = try? wireBuilder.decodePayload(SSSShareResponseMessage.self, from: message) {
                    handleSSSShareResponse(payload)
                }

            case .remoteWipe:
                if let payload = try? wireBuilder.decodePayload(RemoteWipeRequest.self, from: message) {
                    handleRemoteWipe(payload, fromPeer: message.senderID)
                }

            case .dhtPing, .dhtPong, .dhtFindNode, .dhtFindNodeResp,
                 .dhtStore, .dhtFindValue, .dhtFindValueResp:
                // Routed to DHTEngine — handled in Fáze 5.
                break
            }
        } catch SophaxError.sessionStateCorrupted {
            // The persisted DR session blob was malformed (e.g. crashed mid-write).
            // The corrupt state has already been purged from Keychain in withSession().
            // Re-broadcast our Hello so the sender's next message triggers a fresh
            // X3DH handshake from their side, restoring the session automatically.
            CrashLogManager.shared.log("Session state corrupted on receive — broadcasting Hello", context: "DR")
            broadcastHello()
            delegate?.chatManager(self, didEncounterError: SophaxError.sessionStateCorrupted)
        } catch {
            CrashLogManager.shared.log(error, context: "MessageReceive")
            #if DEBUG
            print("[ChatManager] ❌ Error: \(error) | type=\(message.type.rawValue)")
            #endif
            delegate?.chatManager(self, didEncounterError: error)
        }
    }

    /// Clamps a peer-supplied expiry date to at most `maxExpiryInterval` from now.
    /// Prevents a malicious sender from setting expiresAt = year 9999 to block cleanup.
    private func clampedExpiry(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let maxDate = Date().addingTimeInterval(Self.maxExpiryInterval)
        return min(date, maxDate)
    }

    // MARK: - Sender Key KDF chain (v2 group messaging)

    /// One step of the Signal-style sender key KDF chain.
    ///
    ///   messageKey_n   = HMAC-SHA256(chainKey_n, 0x01)
    ///   chainKey_{n+1} = HMAC-SHA256(chainKey_n, 0x02)
    ///
    /// The `messageKey` is used to encrypt/decrypt exactly one message.
    /// The `nextChainKey` replaces `chainKey` for subsequent messages.
    private func senderKeyRatchetStep(
        _ chainKey: Data
    ) -> (messageKey: SymmetricKey, nextChainKey: Data) {
        let ck         = SymmetricKey(data: chainKey)
        let messageKey = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: ck))
        let nextCK     = Data(HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: ck))
        return (SymmetricKey(data: messageKey), nextCK)
    }

    /// Store a peer's sender key distribution and update Keychain.
    private func handleSenderKeyDistribution(_ content: MessageContent, fromPeer peerID: String) {
        guard let skdData = content.senderKeyData,
              let skd     = try? JSONDecoder().decode(SenderKeyDistributionMessage.self, from: skdData)
        else { return }

        // Reject sender key from a peer who is not in the group
        if let members = joinedGroups[skd.groupID] {
            guard members.contains(peerID) else { return }
        }

        var states = keychain.loadPeerSenderKeyStates(groupID: skd.groupID)
        // Reject non-monotonic distributions — a peer must never lower their iteration.
        // An attacker who replays an old SKD or sends iteration=0 would reset the chain
        // and break decryption for all subsequent group messages (DoS).
        if let existing = states[peerID], skd.iteration < existing.iteration { return }

        // Bidirectional exchange: if this is the first time we see this sender in this
        // group, send back our own SKD so they can decrypt our messages immediately.
        // This ensures a newly joined member converges to having all members' keys
        // without requiring a separate Welcome message flow.
        let isNewSender = states[peerID] == nil
        states[peerID] = SenderKeyState(chainKey: skd.chainKey, iteration: skd.iteration,
                                        receivedAt: Date())
        keychainSave("peerSenderKeys:\(skd.groupID)") { try keychain.savePeerSenderKeyStates(states, groupID: skd.groupID) }

        if isNewSender, sessions[peerID] != nil,
           let myState = keychain.loadMySenderKeyState(groupID: skd.groupID) {
            let reply = SenderKeyDistributionMessage(
                groupID:   skd.groupID,
                chainKey:  myState.chainKey,
                iteration: myState.iteration
            )
            if let replyData = try? JSONEncoder().encode(reply) {
                let replyContent = MessageContent(body: "", type: .senderKeyDistribution, senderKeyData: replyData)
                if let wire = try? buildOutboundWire(content: replyContent,
                                                      messageID: UUID().uuidString,
                                                      toPeerID: peerID) {
                    try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
                }
            }
        }
    }

    // MARK: - Private: Sender key request

    /// Request a peer to re-send their SenderKeyDistributionMessage.
    /// Rate-limited to once per 60 s per (group, peer) pair.
    private func sendSenderKeyRequest(groupID: String, fromPeer peerID: String) {
        let key = "\(groupID)/\(peerID)"
        if let last = lastSenderKeyRequestSent[key],
           Date().timeIntervalSince(last) < Self.senderKeyRequestCooldown { return }
        lastSenderKeyRequestSent[key] = Date()

        let req = SenderKeyRequestMessage(groupID: groupID, targetPeerID: peerID)
        guard let wire = try? wireBuilder.build(.senderKeyRequest, payload: req) else { return }
        try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
    }

    /// Handle an incoming senderKeyRequest — respond by re-sending our current SKD.
    /// Rate-limited to once per 60 s per (group, requester) pair.
    private func handleSenderKeyRequest(_ payload: SenderKeyRequestMessage, fromPeer peerID: String) {
        guard payload.groupID.count      <= 64,
              payload.targetPeerID.count <= 64 else { return }
        // Only respond if: (a) we are in this group, (b) sender is a member,
        // (c) they are asking for OUR key (not spoofing another member's peerID).
        guard let members = joinedGroups[payload.groupID],
              members.contains(peerID),
              payload.targetPeerID == identity.publicIdentity.peerID else { return }

        let key = "\(payload.groupID)/\(peerID)"
        if let last = lastSenderKeyRequestResponded[key],
           Date().timeIntervalSince(last) < Self.senderKeyRequestCooldown { return }
        lastSenderKeyRequestResponded[key] = Date()

        guard let myState = keychain.loadMySenderKeyState(groupID: payload.groupID) else { return }
        let skd = SenderKeyDistributionMessage(groupID: payload.groupID,
                                               chainKey: myState.chainKey,
                                               iteration: myState.iteration)
        guard let skdData = try? JSONEncoder().encode(skd) else { return }
        let content = MessageContent(body: "", type: .senderKeyDistribution, senderKeyData: skdData)
        if let wire = try? buildOutboundWire(content: content,
                                              messageID: UUID().uuidString,
                                              toPeerID: peerID) {
            try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
        }
    }

    // MARK: - Private: Sender key rotation

    /// Rotate own sender key if message count OR age threshold is exceeded.
    /// Generates a fresh random chain, saves it, and broadcasts a new
    /// SenderKeyDistributionMessage to all current group members.
    private func performSenderKeyRotationIfNeeded(groupID: String, members: [String]) {
        guard var myState = keychain.loadMySenderKeyState(groupID: groupID) else { return }
        let count     = myState.messageCount ?? 0
        let createdAt = myState.createdAt ?? Date()
        let age       = Date().timeIntervalSince(createdAt)

        guard count >= Self.senderKeyRotationMessageLimit ||
              age   >= Self.senderKeyRotationAgeLimit else { return }

        let newChainKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        myState = SenderKeyState(chainKey: newChainKey, iteration: 0,
                                 messageCount: 0, createdAt: Date())
        keychainSave("mySenderKey:\(groupID)") { try keychain.saveMySenderKeyState(myState, groupID: groupID) }

        let skd = SenderKeyDistributionMessage(groupID: groupID, chainKey: newChainKey, iteration: 0)
        guard let skdData = try? JSONEncoder().encode(skd) else { return }
        let myID = identity.publicIdentity.peerID
        for memberID in members where memberID != myID {
            let content = MessageContent(body: "", type: .senderKeyDistribution, senderKeyData: skdData)
            if let wire = try? buildOutboundWire(content: content,
                                                  messageID: UUID().uuidString,
                                                  toPeerID: memberID) {
                try? sendOrQueue(wire, toPeerID: memberID, messageID: UUID().uuidString)
            }
        }
    }

    // MARK: - Private: TCP helpers

    /// Build a signed Hello WireMessage to send on new TCP connections.
    private func makeTCPHello() -> WireMessage? {
        guard let bundle = try? preKeys.generateBundle(tcpAddress: myTCPAddress),
              let hello  = try? wireBuilder.build(.hello, payload: HelloMessage(bundle: bundle))
        else { return nil }
        return hello
    }
}

// MARK: - TCPTransportDelegate

extension ChatManager: TCPTransportDelegate {

    public func tcpTransport(
        _ transport: TCPTransport, didConnectToPeer peerID: String, address: String
    ) {
        // Flush any DHT messages queued for this address
        if let queued = pendingDHTMessages.removeValue(forKey: address) {
            for msg in queued { try? transport.send(msg, toPeerID: peerID) }
        }

        // Mark TCP address for this peer if we know them
        knownPeers[peerID]?.tcpAddress       = address
        knownPeers[peerID]?.isOnline          = true
        knownPeers[peerID]?.isDirectlyConnected = true
        // Send our Hello so the remote peer gets our current bundle (incl. avatar).
        // TCP connections do not go through the mesh Hello exchange, so we do it here.
        if let bundle = try? preKeys.generateBundle(tcpAddress: myTCPAddress),
           let wire   = try? wireBuilder.build(.hello, payload: HelloMessage(bundle: bundle)) {
            try? transport.send(wire, toPeerID: peerID)
        }
        drainQueue(forPeerID: peerID)
        if let peer = knownPeers[peerID] {
            let p = peer
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.chatManager(self, peerDidReconnect: p)
            }
        }
    }

    public func tcpTransport(
        _ transport: TCPTransport, didDisconnectFromPeer peerID: String
    ) {
        knownPeers[peerID]?.isOnline            = false
        knownPeers[peerID]?.isDirectlyConnected = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, peerDidDisconnect: peerID)
        }
    }

    public func tcpTransport(
        _ transport: TCPTransport, didReceiveMessage message: WireMessage, fromPeer peerID: String
    ) {
        // Route through the same dispatch logic as the mesh path.
        handleIncomingMessage(message)
    }

    public func tcpTransport(
        _ transport: TCPTransport, sendDidFailForPeer peerID: String, error: Error
    ) {
        delegate?.chatManager(self, didEncounterError: error)
    }

    public func tcpTransportDidStartListening(
        _ transport: TCPTransport, onPort port: UInt16
    ) {
        #if DEBUG
        print("[ChatManager] TCP listening on port \(port)")
        #endif
    }
}

// MARK: - LanDiscoveryDelegate

extension ChatManager: LanDiscoveryDelegate {

    /// mDNS resolved a peer's address — initiate a TCP connection.
    /// sendOrRoute() will automatically prefer TCP once the Hello handshake completes.
    public func lanDiscovery(didFind address: String) {
        try? connectViaTCP(address: address)
    }
}
