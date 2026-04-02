// GroupTypes.swift
// SophaxChatCore
//
// Types for end-to-end encrypted group messaging.
//
// Crypto: Signal-style Sender Keys — each member has their own KDF chain,
//         providing per-message forward secrecy and break-in recovery.
//         (v1 shared-key path removed; all groups use v2 only.)

import Foundation

// MARK: - GroupCryptoVersion

/// Identifies which group crypto protocol a GroupInfo uses.
/// Stored as a raw String in JSON so existing records decode without a key present
/// (Swift synthesised Codable decoding uses the init default).
public enum GroupCryptoVersion: String, Codable, Sendable {
    /// Signal-style Sender Keys v2 — original SophaxChat protocol.
    case senderKeysV2 = "skv2"
    /// RFC 9420 MLS — Group v3, post-compromise security per epoch.
    case mls = "mls"
}

// MARK: - GroupInfo

/// A persisted group conversation.
public struct GroupInfo: Codable, Identifiable, Sendable {
    /// Stable UUID assigned by the creator.
    public let id:                   String
    public let name:                 String
    /// All member peerIDs including the creator.
    public let memberIDs:            [String]
    /// PeerID of the group creator. Immutable — used to verify delete authority.
    public let creatorID:            String
    /// Which crypto protocol this group uses. Absent in legacy JSON → decoded as .senderKeysV2.
    public let cryptoVersion:        GroupCryptoVersion
    /// PeerID of the current MLS commit coordinator. Defaults to creatorID; updated on handoff.
    /// Absent in legacy JSON → defaults to creatorID (backward-compatible).
    public var currentCoordinatorID: String

    public init(
        id:                   String             = UUID().uuidString,
        name:                 String,
        memberIDs:            [String],
        creatorID:            String,
        cryptoVersion:        GroupCryptoVersion = .senderKeysV2,
        currentCoordinatorID: String?            = nil
    ) {
        self.id                   = id
        self.name                 = name
        self.memberIDs            = memberIDs
        self.creatorID            = creatorID
        self.cryptoVersion        = cryptoVersion
        self.currentCoordinatorID = currentCoordinatorID ?? creatorID
    }

    // Custom decode: default both optional fields when absent (backward compatibility).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(String.self, forKey: .id)
        name          = try c.decode(String.self, forKey: .name)
        memberIDs     = try c.decode([String].self, forKey: .memberIDs)
        creatorID     = try c.decode(String.self, forKey: .creatorID)
        cryptoVersion = try c.decodeIfPresent(GroupCryptoVersion.self, forKey: .cryptoVersion) ?? .senderKeysV2
        currentCoordinatorID = try c.decodeIfPresent(String.self, forKey: .currentCoordinatorID) ?? creatorID
    }

    /// The key used in MessageStore for this group's conversation.
    public var conversationID: String { "group.\(id)" }
}

// MARK: - GroupInvitePayload

/// Embedded in a Double Ratchet–encrypted MessageContent (type = .groupInvite)
/// so only the intended recipient can read the group credentials.
///
/// v2 (only): senderChainKey + senderIteration carry the creator's Sender Key state.
public struct GroupInvitePayload: Codable, Sendable {
    public let groupID:         String
    public let groupName:       String
    public let memberIDs:       [String]
    public let creatorID:       String
    /// Creator's KDF chain key seed (32 bytes, HMAC-SHA256 based).
    public let senderChainKey:  Data
    /// Chain iteration at time of invite (0 for a fresh group).
    public let senderIteration: UInt32

    public init(
        groupID:         String,
        groupName:       String,
        memberIDs:       [String],
        creatorID:       String,
        senderChainKey:  Data,
        senderIteration: UInt32 = 0
    ) {
        self.groupID         = groupID
        self.groupName       = groupName
        self.memberIDs       = memberIDs
        self.creatorID       = creatorID
        self.senderChainKey  = senderChainKey
        self.senderIteration = senderIteration
    }
}

// MARK: - SenderKeyState

/// One sender's KDF chain state for a specific group.
/// Stored per (groupID, senderPeerID) in the Keychain.
///
/// Signal-style sender key ratchet:
///   messageKey_n   = HMAC-SHA256(chainKey_n, 0x01)  — used to encrypt one message
///   chainKey_{n+1} = HMAC-SHA256(chainKey_n, 0x02)  — replaces chainKey for next message
///
/// `iteration` tracks how many steps have been consumed.  Out-of-order messages
/// are handled by fast-forwarding the chain (up to MAX_SKIP = 100 steps); any
/// skipped message keys are discarded (those messages become unrecoverable).
public struct SenderKeyState: Codable, Sendable {
    /// Current 32-byte KDF chain key.
    public let chainKey:     Data
    /// Number of steps already consumed from this chain.
    public let iteration:    UInt32
    /// Messages sent since the last rotation (own state only; nil = not yet tracked).
    public let messageCount: UInt32?
    /// Wall-clock time this chain was first generated (own state only).
    public let createdAt:    Date?
    /// When we stored this peer's key (peer state only; nil on own state).
    public let receivedAt:   Date?

    public init(
        chainKey:     Data,
        iteration:    UInt32 = 0,
        messageCount: UInt32? = nil,
        createdAt:    Date?   = nil,
        receivedAt:   Date?   = nil
    ) {
        self.chainKey     = chainKey
        self.iteration    = iteration
        self.messageCount = messageCount
        self.createdAt    = createdAt
        self.receivedAt   = receivedAt
    }
}

// MARK: - SenderKeyDistributionMessage

/// Sent over the existing DR-encrypted channel to share a member's sender key
/// with all other group members.  Sent when:
///   • A new member accepts a group invite.
///   • A member resets their chain (key compromise recovery).
public struct SenderKeyDistributionMessage: Codable, Sendable {
    public let groupID:   String
    public let chainKey:  Data
    public let iteration: UInt32

    public init(groupID: String, chainKey: Data, iteration: UInt32 = 0) {
        self.groupID   = groupID
        self.chainKey  = chainKey
        self.iteration = iteration
    }
}
