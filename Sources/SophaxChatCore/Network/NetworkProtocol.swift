// NetworkProtocol.swift
// SophaxChatCore
//
// All messages exchanged over the P2P mesh network.
//
// Protocol flow:
//
//   [Discovery]
//     Peers discover each other via MCNearbyServiceBrowser.
//
//   [Handshake — immediately on MPC connection]
//     A → B: .hello  (A's PreKeyBundle)
//     B → A: .hello  (B's PreKeyBundle)
//
//   [Session Initiation — A sends first encrypted message to B]
//     A → B: .initiateSession  (EK_A, used prekey IDs, first Double Ratchet message)
//
//   [Normal messages — after session established]
//     A ↔ B: .message  (Double Ratchet encrypted)
//
//   [Delivery confirmation]
//     B → A: .ack
//
//   [Multihop relay — A and B not directly connected]
//     A → C: .relay (RelayEnvelope targeting B, TTL=5)
//     C → B: .relay (RelayEnvelope, TTL=4)   [C forwards after checking target]
//     B processes the inner message

import Foundation
import CryptoKit

// MARK: - Wire Message Envelope

/// Top-level wrapper for all network messages.
/// Every WireMessage is signed with the sender's Ed25519 identity key.
public struct WireMessage: Codable, Sendable {
    public let type:      WireMessageType
    public let payload:   Data        // JSON-encoded inner message
    public let senderID:  String      // Sender's peerID (deterministic hash of identity keys)
    public let timestamp: Date        // Fixed at build time — same value in signingBytes()
    public let signature: Data        // Ed25519(type || payload || senderID || timestamp)

    /// Use WireMessageBuilder.build() to construct — do NOT call directly.
    /// The timestamp parameter must be passed by the builder so signing bytes
    /// and the final message share the EXACT SAME timestamp.
    public init(
        type:      WireMessageType,
        payload:   Data,
        senderID:  String,
        timestamp: Date,              // ← explicit, not Date() here
        signature: Data
    ) {
        self.type      = type
        self.payload   = payload
        self.senderID  = senderID
        self.timestamp = timestamp
        self.signature = signature
    }

    /// Cached formatter — `ISO8601DateFormatter` is expensive to allocate and is
    /// called on every sign/verify path. Shared across all WireMessage instances.
    /// `nonisolated(unsafe)`: ISO8601DateFormatter.string(from:) is thread-safe
    /// for concurrent reads when the formatter's own properties are never mutated
    /// after initialization — which is the case here.
    private nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()

    /// Canonical byte representation that is signed/verified.
    /// MUST be deterministic — no Date() call here.
    public func signingBytes() -> Data {
        var data = Data()
        data.append(contentsOf: type.rawValue.utf8)
        data.append(payload)
        data.append(contentsOf: senderID.utf8)
        data.append(contentsOf: WireMessage.iso8601.string(from: timestamp).utf8)
        return data
    }
}

// MARK: - Message Types

public enum WireMessageType: String, Codable, Sendable {
    /// Initial handshake — contains the sender's PreKeyBundle.
    case hello
    /// X3DH session initiation — contains EK_A and the first Double Ratchet message.
    case initiateSession
    /// Normal Double Ratchet–encrypted message.
    case message
    /// Delivery acknowledgment.
    case ack
    /// Relay envelope for multihop delivery.
    case relay
    /// Typing indicator (unencrypted, metadata-only).
    case typing
    /// Sealed sender — wraps an encrypted WireMessage so relay nodes cannot read the inner type or payload.
    case sealed
    /// Read receipt — tells the sender that we have read their messages.
    case readReceipt
    /// Emoji reaction on a specific message.
    case reaction
    /// Group chat message encrypted with the shared group symmetric key.
    case groupMessage
    /// Emoji reaction on a specific group message.
    case groupReaction
    /// A member voluntarily left a group — triggers sender-key rotation in remaining members.
    case groupMemberLeft
    /// The group creator is dissolving the group for all members.
    case groupDeleted
    /// Read receipt for a specific group message — unicast from receiver to original sender.
    case groupReadReceipt
    /// Request a directly-connected relay peer to hold a sealed message for an offline target.
    case storeAndForward
    /// Relay peer delivers stored messages when the target peer comes online.
    case storeAndForwardDelivery
    /// Channel discovery — broadcast by a group creator to announce a group to nearby peers.
    /// Unsigned broadcast; recipients may request a group invite from the creator.
    case channelAnnouncement
    /// Dead drop — sealed message flooded over the mesh for a specific recipient.
    /// Relay nodes cannot read the content (sealed). Stored for 12h at each node.
    case deadDrop
    /// Edit a previously sent message — replaces the body text in-place.
    case editMessage
    /// Request a peer to re-send their SenderKeyDistributionMessage for a specific group.
    /// Sent when the receiver has no key for that sender or the stored key is stale.
    case senderKeyRequest

    // MARK: MLS (Group v3 — RFC 9420)

    /// MLS Welcome for a new group member — unicast, DR-encrypted.
    case mlsWelcome
    /// MLS Commit broadcast from the group coordinator.
    case mlsCommit
    /// MLS application message (replaces groupMessage for MLS groups).
    case mlsMessage
    /// Non-coordinator member requesting the coordinator to issue a Commit — DR-encrypted unicast.
    case mlsCommitRequest
    /// MLS-encrypted emoji reaction on a group message.
    case mlsReaction
    /// Current MLS coordinator transfers commit authority to another member — broadcast unicast.
    case mlsCoordinatorHandoff
    /// QR-based device link invite from an existing device to a new device.
    case deviceLinkRequest
    /// Forwarded copy of a message from the primary device to a linked device.
    case deviceSyncMessage
}

// MARK: - MLS Wire Messages

/// Sent to a new MLS group member via DR-encrypted unicast (.mlsWelcome).
public struct MLSWelcomeMessage: Codable, Sendable {
    public let groupID:           String
    public let groupName:         String
    /// All member peerIDs at time of creation.
    public let memberIDs:         [String]
    /// PeerID of the group creator (= MLS coordinator).
    public let creatorID:         String
    /// Raw mls-rs Welcome bytes — pass directly to MLSGroupManager.processWelcome.
    public let welcomeBytes:      Data
    /// Ratchet tree bytes — required to join without the ratchet_tree extension.
    public let ratchetTreeBytes:  Data
    /// Always .mls — carried so the receiver can dispatch correctly.
    public let cryptoVersion:     GroupCryptoVersion

    public init(
        groupID: String, groupName: String, memberIDs: [String], creatorID: String,
        welcomeBytes: Data, ratchetTreeBytes: Data
    ) {
        self.groupID          = groupID
        self.groupName        = groupName
        self.memberIDs        = memberIDs
        self.creatorID        = creatorID
        self.welcomeBytes     = welcomeBytes
        self.ratchetTreeBytes = ratchetTreeBytes
        self.cryptoVersion    = .mls
    }
}

/// Broadcast by the MLS coordinator after every Commit (.mlsCommit).
/// Recipients MUST verify senderID == group.creatorID before processing.
public struct MLSCommitMessage: Codable, Sendable {
    public let groupID:       String
    /// MLS epoch after this commit — used for ordering / dedup.
    public let epoch:         UInt64
    /// Raw mls-rs Commit bytes — pass to MLSGroupManager.processCommit.
    public let commitBytes:   Data
    /// peerID of the coordinator — receivers drop the message if this != group.creatorID.
    public let coordinatorID: String
}

/// Encrypted group message for MLS groups (.mlsMessage).
/// The `ciphertext` is the output of MLSGroupManager.encrypt — an opaque mls-rs blob.
public struct MLSApplicationMessage: Codable, Sendable {
    public let groupID:              String
    public let messageID:            String
    public let senderPeerID:         String
    public let senderUsername:       String
    public let timestamp:            Date
    /// MLS-encrypted body (caption text; empty string for attachment-only messages).
    public let ciphertext:           Data
    /// Auto-delete deadline (nil = persistent).
    public let expiresAt:            Date?
    /// MessageID of the message being replied to.
    public let replyToID:            String?
    /// MLS-encrypted attachment bytes (image / audio). nil = text-only message.
    public let attachmentCiphertext: Data?
    /// MIME type of the attachment (e.g. "image/jpeg", "audio/m4a"). nil = text-only.
    public let mimeType:             String?
    /// Audio duration in seconds. Non-nil only for audio/m4a attachments.
    public let audioDuration:        Double?
    /// Sender's JPEG avatar (≤8 KB) for group-only contacts that haven't received a Hello.
    public let senderAvatarData:     Data?
}

/// Sent by a non-coordinator member requesting the coordinator to add or remove a peer.
/// Carried inside a DR-encrypted .mlsCommitRequest message.
public struct MLSCommitRequestMessage: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case add, remove
    }
    public let groupID:       String
    public let action:        Action
    /// For .add: the new member's MLS KeyPackage bytes.
    public let keyPackage:    Data?
    /// For .remove: the peerID to remove.
    public let targetPeerID:  String?
}

// MARK: - MLS Reaction

/// MLS-encrypted emoji reaction on a group message.
/// `ciphertext` decrypts to UTF-8 JSON: `{"emoji":"👍"}` or `{"emoji":null}` to remove.
public struct MLSReactionMessage: Codable, Sendable {
    public let groupID:          String
    public let messageID:        String   // stable ID for this reaction wire message
    public let senderPeerID:     String
    public let targetMessageID:  String   // the message being reacted to
    public let ciphertext:       Data
    public let timestamp:        Date

    public init(groupID: String, messageID: String, senderPeerID: String,
                targetMessageID: String, ciphertext: Data, timestamp: Date) {
        self.groupID         = groupID
        self.messageID       = messageID
        self.senderPeerID    = senderPeerID
        self.targetMessageID = targetMessageID
        self.ciphertext      = ciphertext
        self.timestamp       = timestamp
    }
}

/// Current coordinator transfers commit authority to another group member (.mlsCoordinatorHandoff).
/// Broadcast as DR-encrypted unicast to every member so they update their local coordinator record.
public struct MLSCoordinatorHandoffMessage: Codable, Sendable {
    /// Identifies the group.
    public let groupID:            String
    /// PeerID of the sender — must match the current coordinator; verified by recipients.
    public let fromCoordinatorID:  String
    /// PeerID of the member taking over as coordinator.
    public let newCoordinatorID:   String

    public init(groupID: String, fromCoordinatorID: String, newCoordinatorID: String) {
        self.groupID           = groupID
        self.fromCoordinatorID = fromCoordinatorID
        self.newCoordinatorID  = newCoordinatorID
    }
}

// MARK: - Multi-Device Linking

/// QR payload: device A broadcasts its PreKeyBundle so device B can open a DR session.
/// Transmitted via the `deviceLinkRequest` wire message type.
public struct DeviceLinkRequestMessage: Codable, Sendable {
    /// Human-readable label for device A (e.g. "iPhone 16 Pro").
    public let deviceLabel: String
    /// The PreKeyBundle of device A — device B uses this to initiate X3DH.
    public let bundle: PreKeyBundle
    /// When this QR payload expires. nil = no expiry (reciprocal replies and legacy QR codes).
    public let expiresAt: Date?

    public init(deviceLabel: String, bundle: PreKeyBundle, expiresAt: Date? = nil) {
        self.deviceLabel = deviceLabel
        self.bundle      = bundle
        self.expiresAt   = expiresAt
    }
}

/// Forwarded message copy sent from the primary device to each linked device.
/// Re-encrypted inside a DR session so only the linked device can read it.
public struct DeviceSyncMessage: Codable, Sendable {
    /// Conversation identifier: peerID for 1-to-1, "group.<groupID>" for groups.
    public let conversationID: String
    /// JSON-encoded `StoredMessage` re-encrypted for the linked device.
    public let messageJSON:    Data
    /// Direction as seen by the primary device ("sent" | "received").
    public let direction:      String

    public init(conversationID: String, messageJSON: Data, direction: String) {
        self.conversationID = conversationID
        self.messageJSON    = messageJSON
        self.direction      = direction
    }
}

// MARK: - Sender Key Request

/// Sent to a group member whose sender key is missing or stale.
/// The recipient responds by re-sending their current SenderKeyDistributionMessage.
public struct SenderKeyRequestMessage: Codable, Sendable {
    /// The group for which the sender key is needed.
    public let groupID:      String
    /// PeerID of the member being asked to re-send their SKD (always == recipient).
    public let targetPeerID: String

    public init(groupID: String, targetPeerID: String) {
        self.groupID      = groupID
        self.targetPeerID = targetPeerID
    }
}

// MARK: - Edit Message

/// Sent when the author edits a previously sent message.
/// Encrypted with Double Ratchet. Only the original sender can edit.
public struct EditMessagePayload: Codable, Sendable {
    /// Stable ID of the message being edited.
    public let messageID: String
    /// Replacement body text.
    public let newBody:   String
    /// Wall-clock time of the edit (set by sender).
    public let editedAt:  Date

    public init(messageID: String, newBody: String, editedAt: Date = Date()) {
        self.messageID = messageID
        self.newBody   = newBody
        self.editedAt  = editedAt
    }
}

// MARK: - Hello (Handshake)

/// Sent immediately after an MPC connection is established.
/// Contains the sender's full PreKeyBundle so the recipient can initiate X3DH.
public struct HelloMessage: Codable, Sendable {
    public let bundle: PreKeyBundle
}

// MARK: - Session Initiation (X3DH)

/// Sent by Alice to initiate a new encrypted session with Bob.
/// Contains everything Bob needs to:
///   1. Reproduce the X3DH shared secret
///   2. Initialise the Double Ratchet as responder
///   3. Decrypt the first message
public struct InitiateSessionMessage: Codable, Sendable {
    /// Alice's full PreKeyBundle — Bob stores this for future verification.
    public let senderBundle:        PreKeyBundle
    /// Alice's ephemeral public key (EK_A) from X3DH.
    public let ephemeralPublicKey:  Data
    /// Which of Bob's signed prekeys Alice used.
    public let usedSignedPreKeyId:  UInt32
    /// Which of Bob's one-time prekeys Alice used (nil if none available).
    public let usedOneTimePreKeyId: UInt32?
    /// First Double Ratchet encrypted message.
    public let initialMessage:      RatchetMessage
}

// MARK: - Chat Message Payload

/// Carries a Double Ratchet–encrypted message after session establishment.
public struct ChatMessagePayload: Codable, Sendable {
    public let ratchetMessage: RatchetMessage
    /// Stable UUID for deduplication and ACK correlation.
    public let messageID:      String
}

/// Plaintext content encrypted inside the Double Ratchet ciphertext.
/// This is the ONLY place where message text lives unencrypted — in memory during processing.
public struct MessageContent: Codable, Sendable {
    public let body:               String
    public let type:               MessageType
    public let replyToID:          String?
    public let timestamp:          Date
    /// nil = persistent; Date = auto-delete after this point
    public let expiresAt:          Date?
    /// Binary attachment (JPEG image or M4A audio). Encrypted with the Double Ratchet.
    public let attachmentData:     Data?
    /// MIME type: "image/jpeg" | "audio/m4a"
    public let attachmentMimeType: String?
    /// Audio duration in seconds (nil for non-audio).
    public let audioDuration:      Double?
    /// JSON-encoded GroupInvitePayload — only set when type == .groupInvite.
    public let groupInviteData:    Data?

    public enum MessageType: String, Codable, Sendable {
        case text
        case image
        case audio
        /// Group invite — body is the group name; groupInviteData carries GroupInvitePayload JSON.
        case groupInvite
        /// Sender key distribution (v2 groups) — senderKeyData carries SenderKeyDistributionMessage JSON.
        case senderKeyDistribution
        /// MLS commit request — non-coordinator asks coordinator to add/remove a peer.
        /// Body is empty; mlsCommitRequestData carries MLSCommitRequestMessage JSON.
        case mlsCommitRequest
    }

    /// JSON-encoded SenderKeyDistributionMessage — only set when type == .senderKeyDistribution.
    public let senderKeyData: Data?

    /// Populated when type == .edit — carries the edit payload.
    public let editPayload: EditMessagePayload?

    /// JSON-encoded MLSCommitRequestMessage — only set when type == .mlsCommitRequest.
    public let mlsCommitRequestData: Data?

    public init(
        body:               String,
        type:               MessageType = .text,
        replyToID:          String?     = nil,
        expiresAt:          Date?       = nil,
        attachmentData:     Data?       = nil,
        attachmentMimeType: String?     = nil,
        audioDuration:      Double?     = nil,
        groupInviteData:         Data?       = nil,
        senderKeyData:           Data?       = nil,
        editPayload:             EditMessagePayload? = nil,
        mlsCommitRequestData:    Data?       = nil
    ) {
        self.body                 = body
        self.type                 = type
        self.replyToID            = replyToID
        self.timestamp            = Date()
        self.expiresAt            = expiresAt
        self.attachmentData       = attachmentData
        self.attachmentMimeType   = attachmentMimeType
        self.audioDuration        = audioDuration
        self.groupInviteData      = groupInviteData
        self.senderKeyData        = senderKeyData
        self.editPayload          = editPayload
        self.mlsCommitRequestData = mlsCommitRequestData
    }
}

// MARK: - Multihop Relay

/// Wraps any WireMessage for relay delivery through intermediate peers.
///
/// Flow:
///   Alice → Charlie: RelayEnvelope(target=Bob, ttl=5, message=chatMsg)
///   Charlie checks: Am I Bob? No → decrement TTL → forward to all peers except Alice
///   Bob receives:   Am I Bob? Yes → process inner message
public struct RelayEnvelope: Codable, Sendable {
    /// UUID — relay nodes use this to deduplicate (drop already-seen envelopes).
    public let id:           String
    /// Final destination peerID.
    public let targetPeerID: String
    /// Original sender peerID (for reply routing).
    public let originPeerID: String
    /// Decremented at every hop; dropped when it reaches 0.
    public let ttl:          UInt8
    /// Number of hops already taken (for UI display and analytics).
    public let hopCount:     UInt8
    /// The actual message for the target peer.
    public let message:      WireMessage

    public static let maxTTL: UInt8 = 6

    /// Returns a new envelope with TTL decremented and hopCount incremented.
    public func forwarded() -> RelayEnvelope {
        RelayEnvelope(
            id:           id,
            targetPeerID: targetPeerID,
            originPeerID: originPeerID,
            ttl:          ttl > 0 ? ttl - 1 : 0,
            hopCount:     hopCount + 1,
            message:      message
        )
    }
}

// MARK: - Ack

public struct AckMessage: Codable, Sendable {
    public let messageID: String
    public let status:    AckStatus

    public enum AckStatus: String, Codable, Sendable {
        case delivered
        case failed
    }
}

// MARK: - Typing

public struct TypingMessage: Codable, Sendable {
    public let isTyping: Bool
}

// MARK: - Read Receipt

/// Sent when the local user views messages from a peer.
/// Allows the sender to upgrade their delivery tick to a "read" indicator.
public struct ReadReceiptMessage: Codable, Sendable {
    /// IDs of the received messages being acknowledged as read.
    public let messageIDs: [String]

    public init(messageIDs: [String]) {
        self.messageIDs = messageIDs
    }
}

// MARK: - Group Message

/// Wire message for a group chat message.
///
/// Encryption:
///   v1 (nil senderKeyIteration): ChaChaPoly with the shared group symmetric key.
///   v2 (non-nil senderKeyIteration): ChaChaPoly with a per-message key derived from
///     the sender's KDF chain at the given iteration (Signal-style Sender Keys).
///
/// Sent individually to each group member (via direct/relay/queue routing).
public struct GroupWireMessage: Codable, Sendable {
    public let groupID:              String
    public let messageID:            String
    public let senderPeerID:         String
    public let senderUsername:       String
    public let timestamp:            Date
    /// ChaChaPoly.combined = nonce(12 B) + body ciphertext + tag(16 B)
    public let ciphertext:           Data
    /// ChaChaPoly.combined for the binary attachment (nil = text-only message).
    public let attachmentCiphertext: Data?
    /// "image/jpeg" | "audio/m4a" — nil when no attachment.
    public let attachmentMimeType:   String?
    /// Audio duration in seconds (nil for non-audio).
    public let audioDuration:        Double?
    /// v2 Sender Keys: which KDF chain iteration produced the message key.
    /// nil → v1 shared-key message (backward compat).
    public let senderKeyIteration:   UInt32?
    /// Disappearing message: auto-delete at this point; nil = persistent.
    public let expiresAt:            Date?
    /// Message ID this message is replying to (nil = not a reply).
    public let replyToID:            String?
    /// Sender's JPEG avatar (≤8 KB). Included so group-only contacts (no direct Hello)
    /// can display an avatar. Nil once the receiver has already cached it.
    public let senderAvatarData:     Data?

    public init(
        groupID:              String,
        messageID:            String,
        senderPeerID:         String,
        senderUsername:       String,
        timestamp:            Date,
        ciphertext:           Data,
        attachmentCiphertext: Data?   = nil,
        attachmentMimeType:   String? = nil,
        audioDuration:        Double? = nil,
        senderKeyIteration:   UInt32? = nil,
        expiresAt:            Date?   = nil,
        replyToID:            String? = nil,
        senderAvatarData:     Data?   = nil
    ) {
        self.groupID              = groupID
        self.messageID            = messageID
        self.senderPeerID         = senderPeerID
        self.senderUsername       = senderUsername
        self.timestamp            = timestamp
        self.ciphertext           = ciphertext
        self.attachmentCiphertext = attachmentCiphertext
        self.attachmentMimeType   = attachmentMimeType
        self.audioDuration        = audioDuration
        self.senderKeyIteration   = senderKeyIteration
        self.expiresAt            = expiresAt
        self.replyToID            = replyToID
        self.senderAvatarData     = senderAvatarData
    }
}

// MARK: - Group Reaction

/// Sent when a peer reacts to (or removes a reaction from) a group message.
public struct GroupReactionMessage: Codable, Sendable {
    public let groupID:          String
    public let targetMessageID:  String
    /// The emoji string, or nil to clear the reaction.
    public let emoji:            String?

    public init(groupID: String, targetMessageID: String, emoji: String?) {
        self.groupID         = groupID
        self.targetMessageID = targetMessageID
        self.emoji           = emoji
    }
}

// MARK: - Group Read Receipt

/// Unicast from a group message recipient back to the original sender.
/// Lets the sender track delivery (isRead = false/nil) and true read state (isRead = true).
public struct GroupReadReceiptMessage: Codable, Sendable {
    public let groupID:          String
    public let targetMessageID:  String
    /// True = user has viewed the message; false/nil = delivery-only signal (backward compat).
    public let isRead:           Bool?

    public init(groupID: String, targetMessageID: String, isRead: Bool? = nil) {
        self.groupID         = groupID
        self.targetMessageID = targetMessageID
        self.isRead          = isRead
    }
}

// MARK: - Reaction

/// Sent when a peer reacts to (or removes a reaction from) one of your messages.
/// `emoji` is nil to remove a previously set reaction.
public struct ReactionMessage: Codable, Sendable {
    /// ID of the message being reacted to.
    public let targetMessageID: String
    /// The emoji string, or nil to clear the reaction.
    public let emoji: String?

    public init(targetMessageID: String, emoji: String?) {
        self.targetMessageID = targetMessageID
        self.emoji           = emoji
    }
}

// MARK: - Sealed Sender

/// Wraps a WireMessage so that relay nodes cannot see the inner message type or payload.
///
/// Encryption scheme:
///   1. Sender generates an ephemeral Curve25519 key pair (EK_s)
///   2. sharedSecret = ECDH(EK_s_private, recipient_DH_public)
///   3. sealingKey = HKDF-SHA256(sharedSecret, info="SophaxChat_SealedSender_v1", len=32)
///   4. encryptedPayload = ChaCha20-Poly1305(sealingKey, JSON(innerWireMessage))
///
/// Only the intended recipient (who knows their DH private key) can decrypt.
/// Relay nodes see only: origin, target, an ephemeral public key, and ciphertext.
public struct SealedMessage: Codable, Sendable {
    /// Sender's ephemeral Curve25519 public key (32 bytes) — one per sealed message.
    public let ephemeralPublicKey: Data
    /// ChaCha20-Poly1305 ciphertext: nonce(12B) + encrypted WireMessage JSON + tag(16B).
    public let encryptedPayload: Data
}

// MARK: - Channel Discovery

/// Broadcast by a group creator to advertise a group to nearby peers who are NOT yet members.
///
/// This message is signed (via WireMessageBuilder) so recipients can verify the creator's identity.
/// It is flooded over the mesh so peers beyond direct range can discover groups.
/// A peer who discovers a channel can initiate a DM with the creator to request an invite.
///
/// Security properties:
/// - Does NOT contain any message content or encryption keys.
/// - Group membership and message content remain fully encrypted.
/// - A peer who sees this message knows only: the group name, creator, and approximate size.
public struct ChannelAnnouncement: Codable, Sendable {
    /// Stable group UUID.
    public let groupID:     String
    /// Human-readable group name (as set by the creator).
    public let groupName:   String
    /// peerID of the group creator — the peer to contact to request an invite.
    public let creatorID:   String
    /// Approximate member count — lets prospective joiners gauge group size.
    public let memberCount: Int
    /// When this announcement was generated — used to discard stale entries.
    public let timestamp:   Date

    public init(groupID: String, groupName: String, creatorID: String, memberCount: Int) {
        self.groupID     = groupID
        self.groupName   = groupName
        self.creatorID   = creatorID
        self.memberCount = memberCount
        self.timestamp   = Date()
    }
}

// MARK: - Dead Drop

/// A sealed message flooded over the entire mesh for a specific recipient.
///
/// Security properties:
/// - Content is sealed (ChaCha20-Poly1305) — relay nodes see only the target peerID and expiry.
/// - Any node that receives it re-broadcasts it and stores it locally for 12 hours.
/// - When the target peer appears in the mesh, any node that has the drop delivers it.
/// - `id` is a UUID used for deduplication across hops (same as RelayEnvelope pattern).
///
/// Use case: "I want to send you a message even though you're not online right now,
/// without any server involved."
public struct DeadDropEnvelope: Codable, Sendable {
    /// Unique ID for deduplication — same across all hops.
    public let id:           String
    /// peerID of the intended recipient.
    public let targetPeerID: String
    /// Sealed (encrypted for recipient's DH key) inner WireMessage.
    public let sealed:       SealedMessage
    /// When this drop expires — nodes discard it after this time.
    public let expiresAt:    Date

    public init(targetPeerID: String, sealed: SealedMessage, ttl: TimeInterval = 12 * 3600) {
        self.id           = UUID().uuidString
        self.targetPeerID = targetPeerID
        self.sealed       = sealed
        self.expiresAt    = Date().addingTimeInterval(ttl)
    }
}

// MARK: - WireMessage Builder

/// Creates and verifies signed WireMessages.
public struct WireMessageBuilder {
    private let identity: IdentityManager

    public init(identity: IdentityManager) {
        self.identity = identity
    }

    /// Build a signed WireMessage.
    /// Uses a single `Date()` snapshot so signing bytes and the final
    /// message carry the SAME timestamp — avoiding the previous bug where
    /// two separate `init` calls produced two different timestamps.
    public func build<T: Codable>(_ type: WireMessageType, payload: T) throws -> WireMessage {
        let payloadData = try JSONEncoder().encode(payload)
        let senderID    = identity.publicIdentity.peerID
        let timestamp   = Date()   // ← captured ONCE

        // Construct unsigned message to compute the canonical bytes to sign
        let unsigned = WireMessage(
            type: type, payload: payloadData,
            senderID: senderID, timestamp: timestamp, signature: Data()
        )
        let signature = try identity.sign(unsigned.signingBytes())

        // Return the final message with the same timestamp
        return WireMessage(
            type: type, payload: payloadData,
            senderID: senderID, timestamp: timestamp, signature: signature
        )
    }

    /// Verify the Ed25519 signature on a received WireMessage.
    public static func verify(_ message: WireMessage, signingKeyPublic: Data) throws -> Bool {
        let bytes = message.signingBytes()
        return try IdentityManager.verify(
            signature: message.signature,
            for: bytes,
            signingKeyPublic: signingKeyPublic
        )
    }

    public func decodePayload<T: Codable>(_ type: T.Type, from message: WireMessage) throws -> T {
        try JSONDecoder().decode(type, from: message.payload)
    }
}

// MARK: - Stored Message

/// A message persisted in the local encrypted store.
public struct StoredMessage: Codable, Identifiable, Sendable {
    public let id:                 String
    public let peerID:             String
    public let direction:          Direction
    public let body:               String
    public let timestamp:          Date
    public var status:             MessageStatus
    public let replyToID:          String?
    public let expiresAt:          Date?
    /// Nil = delivered directly; >0 = relayed through N hops
    public let hopCount:           UInt8?
    /// Local file ID in AttachmentStore — nil means no attachment.
    public let attachmentID:       String?
    /// "image/jpeg" | "audio/m4a" — mirrors MessageContent.attachmentMimeType
    public let attachmentMimeType: String?
    /// Audio duration in seconds (nil for non-audio).
    public let audioDuration:      Double?
    /// Emoji reactions on this message, keyed by peerID. nil = no reactions.
    /// Declared optional for backward-compatibility (old stored messages lack this key).
    public var reactions:          [String: String]?
    /// For group messages: the actual sender's peerID. nil for direct messages.
    public let senderID:           String?
    /// Wall-clock time when this device received/decrypted the message.
    /// Used for display ordering instead of sender-supplied `timestamp` (which can be spoofed).
    /// Nil for messages stored before this field was added (backward compat).
    public let receivedAt:         Date?
    /// Group messages only: peerIDs that have sent a groupReadReceipt back to us.
    /// Nil for direct messages and for messages received before this field was added.
    public var deliveredBy:        [String]?
    /// Group messages only: peerIDs that have sent a true read receipt (viewed, not just received).
    /// Nil for direct messages and legacy stored messages.
    public var readBy:             [String]?
    /// True if the message body was edited after initial delivery.
    /// Backward-compatible: old stored messages decode this as false (missing key).
    public var isEdited:           Bool
    /// When the message was last edited. Nil for unedited messages.
    public var editedAt:           Date?

    public enum Direction: String, Codable, Sendable {
        case sent, received
    }

    public enum MessageStatus: String, Codable, Sendable {
        case sending, delivered, failed, read
    }

    public init(
        id:                 String          = UUID().uuidString,
        peerID:             String,
        direction:          Direction,
        body:               String,
        timestamp:          Date            = Date(),
        status:             MessageStatus   = .sending,
        replyToID:          String?         = nil,
        expiresAt:          Date?           = nil,
        hopCount:           UInt8?          = nil,
        attachmentID:       String?         = nil,
        attachmentMimeType: String?         = nil,
        audioDuration:      Double?         = nil,
        reactions:          [String: String]? = nil,
        senderID:           String?         = nil,
        receivedAt:         Date?           = nil,
        deliveredBy:        [String]?       = nil,
        readBy:             [String]?       = nil,
        isEdited:           Bool            = false,
        editedAt:           Date?           = nil
    ) {
        self.id                 = id
        self.peerID             = peerID
        self.direction          = direction
        self.body               = body
        self.timestamp          = timestamp
        self.status             = status
        self.replyToID          = replyToID
        self.expiresAt          = expiresAt
        self.hopCount           = hopCount
        self.attachmentID       = attachmentID
        self.attachmentMimeType = attachmentMimeType
        self.audioDuration      = audioDuration
        self.reactions          = reactions
        self.senderID           = senderID
        self.receivedAt         = receivedAt
        self.deliveredBy        = deliveredBy
        self.readBy             = readBy
        self.isEdited           = isEdited
        self.editedAt           = editedAt
    }
}

// MARK: - Group Member Left

/// Broadcast by a member who is voluntarily leaving a group.
/// Recipients use this to update their local member list and rotate their sender keys
/// so the leaver cannot decrypt future messages.
public struct GroupMemberLeftMessage: Codable, Sendable {
    public let groupID:           String
    public let leavingPeerID:     String
    /// Remaining member peerIDs (does NOT include the leaver).
    public let remainingMemberIDs: [String]

    public init(groupID: String, leavingPeerID: String, remainingMemberIDs: [String]) {
        self.groupID            = groupID
        self.leavingPeerID      = leavingPeerID
        self.remainingMemberIDs = remainingMemberIDs
    }
}

// MARK: - Group Deleted

/// Broadcast by the group creator when dissolving a group for all members.
/// Recipients must verify `deletedByPeerID == group.creatorID` before acting.
public struct GroupDeletedMessage: Codable, Sendable {
    public let groupID:         String
    public let deletedByPeerID: String

    public init(groupID: String, deletedByPeerID: String) {
        self.groupID         = groupID
        self.deletedByPeerID = deletedByPeerID
    }
}

// MARK: - Store-and-Forward

/// Sent by Alice to a directly-connected relay peer Bob: "Please hold this sealed
/// message for Carol until she connects to you."
///
/// The inner message is sealed (ChaCha20-Poly1305) for Carol's DH key, so Bob
/// cannot read it. Bob stores it until Carol's peerID appears in a Hello handshake,
/// then delivers via `.storeAndForwardDelivery`.
public struct StoreAndForwardRequest: Codable, Sendable {
    /// The final recipient's peerID.
    public let targetPeerID: String
    /// Stable dedup ID (same as the inner WireMessage's correlation ID).
    public let messageID: String
    /// Pre-sealed WireMessage addressed to `targetPeerID`.
    public let sealed: SealedMessage
    /// Relay peer drops this item after `expiresAt` to bound storage use.
    public let expiresAt: Date

    public init(targetPeerID: String, messageID: String, sealed: SealedMessage, expiresAt: Date) {
        self.targetPeerID = targetPeerID
        self.messageID    = messageID
        self.sealed       = sealed
        self.expiresAt    = expiresAt
    }
}

/// Sent by a relay peer Bob to Carol once she connects: delivers all stored items.
public struct StoreAndForwardDelivery: Codable, Sendable {
    public let items: [StoreAndForwardItem]

    public init(items: [StoreAndForwardItem]) { self.items = items }
}

public struct StoreAndForwardItem: Codable, Sendable {
    public let messageID: String
    public let sealed: SealedMessage

    public init(messageID: String, sealed: SealedMessage) {
        self.messageID = messageID
        self.sealed    = sealed
    }
}

// MARK: - Peer Trust Level

/// Whether the local user has accepted this peer.
/// Absent in legacy JSON (peers stored before this field) → `.accepted` for backward compatibility.
public enum PeerTrustLevel: String, Codable, Sendable {
    case pending   // received Hello; awaiting user decision
    case accepted  // user tapped Accept (or legacy peer — defaults to accepted)
}

// MARK: - Known Peer

/// A peer whose identity keys we've received and cryptographically verified.
public struct KnownPeer: Codable, Identifiable, Sendable {
    public let id:               String
    public let username:         String
    public let signingKeyPublic: Data
    public let dhKeyPublic:      Data
    public let safetyNumber:     String
    public var lastSeen:         Date?
    public var isOnline:         Bool
    public var isDirectlyConnected: Bool    // false = reachable only via relay
    /// "host:port" if the peer advertises a TCP address in their PreKeyBundle; nil otherwise.
    public var tcpAddress:       String?
    /// JPEG avatar data received from the peer's PreKeyBundle. nil = no avatar set.
    public var avatarData:       Data?
    /// Accept/reject gate. Absent in legacy JSON → `.accepted` (backward compatible).
    public var trustLevel:       PeerTrustLevel

    public init(from bundle: PreKeyBundle, safetyNumber: String, trustLevel: PeerTrustLevel = .pending) {
        self.id                  = bundle.peerID
        self.username            = bundle.username
        self.signingKeyPublic    = bundle.signingKeyPublic
        self.dhKeyPublic         = bundle.dhIdentityKeyPublic
        self.safetyNumber        = safetyNumber
        self.lastSeen            = Date()
        self.isOnline            = true
        self.isDirectlyConnected = true
        self.tcpAddress          = bundle.tcpAddress
        self.avatarData          = bundle.avatarData
        self.trustLevel          = trustLevel
    }

    /// Construct a KnownPeer directly (used when importing contacts via invite link).
    public init(
        id:                  String,
        username:            String,
        signingKeyPublic:    Data,
        dhKeyPublic:         Data,
        safetyNumber:        String,
        lastSeen:            Date?,
        isOnline:            Bool,
        isDirectlyConnected: Bool,
        tcpAddress:          String?        = nil,
        avatarData:          Data?          = nil,
        trustLevel:          PeerTrustLevel = .accepted
    ) {
        self.id                  = id
        self.username            = username
        self.signingKeyPublic    = signingKeyPublic
        self.dhKeyPublic         = dhKeyPublic
        self.safetyNumber        = safetyNumber
        self.lastSeen            = lastSeen
        self.isOnline            = isOnline
        self.isDirectlyConnected = isDirectlyConnected
        self.tcpAddress          = tcpAddress
        self.avatarData          = avatarData
        self.trustLevel          = trustLevel
    }

    // Custom decoder: default trustLevel to .accepted when absent (legacy peers are all accepted)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                  = try c.decode(String.self,  forKey: .id)
        username            = try c.decode(String.self,  forKey: .username)
        signingKeyPublic    = try c.decode(Data.self,    forKey: .signingKeyPublic)
        dhKeyPublic         = try c.decode(Data.self,    forKey: .dhKeyPublic)
        safetyNumber        = try c.decode(String.self,  forKey: .safetyNumber)
        lastSeen            = try c.decodeIfPresent(Date.self,   forKey: .lastSeen)
        isOnline            = try c.decodeIfPresent(Bool.self,   forKey: .isOnline)            ?? false
        isDirectlyConnected = try c.decodeIfPresent(Bool.self,   forKey: .isDirectlyConnected) ?? false
        tcpAddress          = try c.decodeIfPresent(String.self, forKey: .tcpAddress)
        avatarData          = try c.decodeIfPresent(Data.self,   forKey: .avatarData)
        trustLevel          = try c.decodeIfPresent(PeerTrustLevel.self, forKey: .trustLevel) ?? .accepted
    }
}
