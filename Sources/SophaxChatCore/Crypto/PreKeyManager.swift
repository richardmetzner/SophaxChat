// PreKeyManager.swift
// SophaxChatCore
//
// Manages X3DH prekeys for the local user.
//
// Prekey types:
//   - Signed Prekey (SPK): medium-term X25519 key, rotated every ~7 days
//     Signed by the identity signing key to prove authenticity.
//   - One-Time Prekeys (OPKs): short-term X25519 keys, each used exactly once
//     Provide "break-in recovery" / future secrecy for session establishment.
//
// Reference: https://signal.org/docs/specifications/x3dh/

import Foundation
import CryptoKit

// MARK: - Prekey Bundle (shared with peers)

/// Published by a user to allow others to initiate X3DH sessions.
/// Shared over the mesh when a peer requests to start a session.
public struct PreKeyBundle: Codable, Sendable {
    // Identity keys
    public let signingKeyPublic: Data      // Ed25519 identity signing public key
    public let dhIdentityKeyPublic: Data   // X25519 identity DH public key

    // Signed Prekey (SPK)
    public let signedPreKeyPublic: Data    // X25519 SPK public key
    public let signedPreKeySignature: Data // Ed25519 signature of SPK by identity signing key
    public let signedPreKeyId: UInt32

    // One-Time Prekey (OPK) — optional, included when available
    public let oneTimePreKeyPublic: Data?
    public let oneTimePreKeyId: UInt32?

    // User info
    public let username: String

    // Timestamp — peers reject bundles older than CryptoConstants.maxPreKeyBundleAge
    public let timestamp: Date

    /// Optional "host:port" TCP address — if present, the peer is reachable over the internet
    /// at this address (direct TCP or via SOCKS5/Tor).  Nil means BLE/WiFi-local only.
    /// Propagated in Hello messages so nearby peers automatically learn internet addresses.
    public let tcpAddress: String?

    /// Optional JPEG avatar (64×64, ≤8 KB). nil = no avatar set.
    /// Propagated in Hello messages so contacts see the sender's photo.
    public let avatarData: Data?

    /// MLS KeyPackage for this peer (serialised mls-rs bytes). nil = peer does not support MLS.
    /// Group coordinators use this to add the peer to an MLS group via Welcome.
    public let mlsKeyPackage: Data?

    public init(
        signingKeyPublic:      Data,
        dhIdentityKeyPublic:   Data,
        signedPreKeyPublic:    Data,
        signedPreKeySignature: Data,
        signedPreKeyId:        UInt32,
        oneTimePreKeyPublic:   Data?   = nil,
        oneTimePreKeyId:       UInt32? = nil,
        username:              String,
        timestamp:             Date,
        tcpAddress:            String? = nil,
        avatarData:            Data?   = nil,
        mlsKeyPackage:         Data?   = nil
    ) {
        self.signingKeyPublic      = signingKeyPublic
        self.dhIdentityKeyPublic   = dhIdentityKeyPublic
        self.signedPreKeyPublic    = signedPreKeyPublic
        self.signedPreKeySignature = signedPreKeySignature
        self.signedPreKeyId        = signedPreKeyId
        self.oneTimePreKeyPublic   = oneTimePreKeyPublic
        self.oneTimePreKeyId       = oneTimePreKeyId
        self.username              = username
        self.timestamp             = timestamp
        self.tcpAddress            = tcpAddress
        self.avatarData            = avatarData
        self.mlsKeyPackage         = mlsKeyPackage
    }

    /// Verifies the signed prekey signature against the identity key.
    /// MUST be called before using the bundle.
    ///
    /// The signature covers `signedPreKeyPublic ‖ spkTimestampData(timestamp)` so that
    /// an adversary cannot substitute a freshly minted timestamp onto a captured bundle
    /// without invalidating the Ed25519 tag.
    public func verifySignedPreKey() throws -> Bool {
        // Explicit length checks before passing to CryptoKit — gives a clear error
        // and prevents library-specific exception messages from leaking algorithm details.
        guard signingKeyPublic.count      == 32,
              dhIdentityKeyPublic.count   == 32,
              signedPreKeyPublic.count    == 32,
              signedPreKeySignature.count == 64 else {
            throw SophaxError.invalidMessageFormat("Invalid prekey bundle key dimensions")
        }
        let identityKey  = try Curve25519.Signing.PublicKey(rawRepresentation: signingKeyPublic)
        let signedData   = signedPreKeyPublic + spkTimestampData(timestamp)
        return identityKey.isValidSignature(signedPreKeySignature, for: signedData)
    }

    /// Unique peer identifier derived from identity keys.
    public var peerID: String {
        let combined = signingKeyPublic + dhIdentityKeyPublic
        let hash = SHA256.hash(data: combined)
        return Data(hash).prefix(16).hexString
    }
}

// MARK: - Helpers

/// Canonical 8-byte little-endian representation of a Date's TimeInterval.
/// Used to include the SPK bundle timestamp in the Ed25519 signed data so that
/// the timestamp field cannot be silently modified without invalidating the signature.
///
/// Choosing a raw TimeInterval (Double, 8 bytes) rather than an ISO8601 string avoids
/// locale, formatter-version, and string-encoding ambiguity.
private func spkTimestampData(_ date: Date) -> Data {
    var ti = date.timeIntervalSinceReferenceDate
    return Data(bytes: &ti, count: MemoryLayout<Double>.size)
}

// MARK: - Prekey Manager

// Threading contract: all calls must be made from a single thread or under external
// mutual exclusion. ChatManager owns the single instance and accesses it on its
// serial dispatch queue.
public final class PreKeyManager: @unchecked Sendable {

    private let keychain: KeychainManager
    private let identity: IdentityManager

    private var signedPreKey: DHKeyPair
    private var signedPreKeyId: UInt32
    private var oneTimePreKeys: [UInt32: DHKeyPair] = [:]

    // MARK: - Init

    public init(identity: IdentityManager, keychain: KeychainManager) throws {
        self.identity = identity
        self.keychain = keychain

        // Load or generate signed prekey
        if let (id, key) = try? keychain.loadSignedPreKey() {
            self.signedPreKey   = DHKeyPair(privateKey: key)
            self.signedPreKeyId = id
        } else {
            let pair = DHKeyPair()
            let id   = UInt32.random(in: 1...UInt32.max)
            try keychain.saveSignedPreKey(id: id, key: pair.privateKey)
            try keychain.saveSignedPreKeyDate(Date())
            self.signedPreKey   = pair
            self.signedPreKeyId = id
        }

        // Generate one-time prekeys
        try generateOneTimePreKeys(count: 20)
    }

    // MARK: - Public API

    /// Number of one-time prekeys currently available in the local pool.
    public var opkCount: Int { oneTimePreKeys.count }

    /// Generates a PreKeyBundle ready to share with a peer.
    /// - Parameter tcpAddress: Optional "host:port" to include so peers learn our TCP address.
    public func generateBundle(tcpAddress: String? = nil) throws -> PreKeyBundle {
        let spkData  = signedPreKey.publicKeyData
        // Capture timestamp before signing so the exact same value ends up in both the
        // signed data and the bundle field — verifySignedPreKey() reconstructs the signed
        // data from bundle.timestamp, so they must match to the millisecond.
        let timestamp    = Date()
        let signedData   = spkData + spkTimestampData(timestamp)
        let spkSignature = try identity.sign(signedData)
        let otp = oneTimePreKeys.randomElement()
        let pub = identity.publicIdentity

        return PreKeyBundle(
            signingKeyPublic:      pub.signingKeyPublic,
            dhIdentityKeyPublic:   pub.dhKeyPublic,
            signedPreKeyPublic:    spkData,
            signedPreKeySignature: spkSignature,
            signedPreKeyId:        signedPreKeyId,
            oneTimePreKeyPublic:   otp?.value.publicKeyData,
            oneTimePreKeyId:       otp?.key,
            username:              pub.username,
            timestamp:             timestamp,
            tcpAddress:            tcpAddress,
            avatarData:            identity.loadAvatar()
        )
    }

    /// Returns and removes a one-time prekey by ID.
    /// Call this when Bob processes an incoming session initiation message.
    /// Deletes from Keychain first to ensure the key is permanently gone even
    /// if the process crashes between the two operations.
    public func consumeOneTimePreKey(id: UInt32) throws -> DHKeyPair? {
        guard let pair = oneTimePreKeys[id] else { return nil }
        // Delete from Keychain before removing from memory. If the Keychain delete
        // fails, we do NOT consume the key — better to allow retrying than to silently
        // leave stale key material that can never be cleaned up.
        try keychain.deleteOneTimePreKey(id: id)
        oneTimePreKeys.removeValue(forKey: id)
        return pair
    }

    /// The current signed prekey pair (Bob's initial ratchet key in X3DH).
    public var signedPreKeyPair: DHKeyPair { signedPreKey }

    /// Rotate the signed prekey unconditionally.
    public func rotateSignedPreKey() throws {
        let pair = DHKeyPair()
        let id   = UInt32.random(in: 1...UInt32.max)
        try keychain.saveSignedPreKey(id: id, key: pair.privateKey)
        try keychain.saveSignedPreKeyDate(Date())
        signedPreKey   = pair
        signedPreKeyId = id
    }

    /// Rotate only if the current signed prekey is older than `maxAge` seconds (default 7 days).
    public func rotateIfNeeded(maxAge: TimeInterval = 7 * 24 * 3600) throws {
        let createdAt = (try? keychain.loadSignedPreKeyDate()) ?? .distantPast
        guard Date().timeIntervalSince(createdAt) > maxAge else { return }
        try rotateSignedPreKey()
    }

    /// Generate additional one-time prekeys if the supply is below `target / 2`.
    /// Call this after consuming a one-time prekey to keep the pool healthy.
    public func replenishIfNeeded(target: Int = 20) throws {
        let current = oneTimePreKeys.count
        guard current < target / 2 else { return }
        try generateOneTimePreKeys(count: target - current)
    }

    // MARK: - Private

    private func generateOneTimePreKeys(count: Int) throws {
        // Mutable set tracks both pre-existing and newly generated IDs within this
        // batch to prevent (rare) collisions that would silently overwrite a prekey.
        var usedIDs = Set(oneTimePreKeys.keys)
        for _ in 0..<count {
            var id: UInt32
            repeat { id = UInt32.random(in: 1...UInt32.max) } while usedIDs.contains(id)
            usedIDs.insert(id)
            let pair = DHKeyPair()
            oneTimePreKeys[id] = pair
            try keychain.saveOneTimePreKey(id: id, key: pair.privateKey)
        }
    }
}
