// KeychainManager.swift
// SophaxChatCore
//
// Secure storage for cryptographic keys using the iOS Keychain.
// All keys are stored with kSecAttrAccessibleWhenUnlockedThisDeviceOnly
// — they are not backed up to iCloud and are wiped on device restore.

import Foundation
import Security
import CryptoKit
import CommonCrypto

public final class KeychainManager {

    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.sophax.SophaxChat", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - Identity Signing Key (Ed25519)

    public func saveSigningKey(_ key: Curve25519.Signing.PrivateKey) throws {
        try save(data: key.rawRepresentation, account: "identity.signing")
    }

    public func loadSigningKey() throws -> Curve25519.Signing.PrivateKey {
        let data = try load(account: "identity.signing")
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    // MARK: - Identity DH Key (X25519)

    public func saveDHIdentityKey(_ key: Curve25519.KeyAgreement.PrivateKey) throws {
        try save(data: key.rawRepresentation, account: "identity.dh")
    }

    public func loadDHIdentityKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        let data = try load(account: "identity.dh")
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    // MARK: - Signed Prekey

    public func saveSignedPreKey(id: UInt32, key: Curve25519.KeyAgreement.PrivateKey) throws {
        try save(data: key.rawRepresentation, account: "spk.\(id)")
        try save(data: Data(withUnsafeBytes(of: id) { Data($0) }), account: "spk.current_id")
    }

    public func loadSignedPreKey() throws -> (id: UInt32, key: Curve25519.KeyAgreement.PrivateKey) {
        let idData = try load(account: "spk.current_id")
        guard idData.count == 4 else { throw SophaxError.keychainError(errSecItemNotFound) }
        let id = idData.withUnsafeBytes { $0.load(as: UInt32.self) }
        let keyData = try load(account: "spk.\(id)")
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
        return (id, key)
    }

    // MARK: - Signed Prekey Creation Date

    /// Stores the Date the current signed prekey was generated.
    /// Used to trigger rotation after 7 days.
    public func saveSignedPreKeyDate(_ date: Date) throws {
        var ti = date.timeIntervalSinceReferenceDate
        let data = Data(bytes: &ti, count: MemoryLayout<Double>.size)
        try save(data: data, account: "spk.created_at")
    }

    public func loadSignedPreKeyDate() throws -> Date {
        let data = try load(account: "spk.created_at")
        guard data.count == MemoryLayout<Double>.size else {
            throw SophaxError.keychainError(errSecItemNotFound)
        }
        let ti = data.withUnsafeBytes { $0.load(as: Double.self) }
        return Date(timeIntervalSinceReferenceDate: ti)
    }

    // MARK: - One-Time Prekeys

    public func saveOneTimePreKey(id: UInt32, key: Curve25519.KeyAgreement.PrivateKey) throws {
        try save(data: key.rawRepresentation, account: "otpk.\(id)")
    }

    public func loadOneTimePreKey(id: UInt32) throws -> Curve25519.KeyAgreement.PrivateKey {
        let data = try load(account: "otpk.\(id)")
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    public func deleteOneTimePreKey(id: UInt32) throws {
        try delete(account: "otpk.\(id)")
    }

    // MARK: - Session MAC Key (for HMAC-wrapping session state blobs)

    /// Returns the device-specific session MAC key, creating one if absent.
    /// Used to detect session-state tampering or cross-device replay attacks.
    private func loadOrCreateSessionMACKey() throws -> SymmetricKey {
        if let data = try? load(account: "session.mac_key") {
            return SymmetricKey(data: data)
        }
        let key     = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try save(data: keyData, account: "session.mac_key")
        return key
    }

    // MARK: - Session State

    /// Persist ratchet session state wrapped with a 32-byte HMAC prefix.
    /// Format: HMAC-SHA256(macKey, data) || data
    public func saveSessionState(data: Data, peerID: String) throws {
        let macKey = try loadOrCreateSessionMACKey()
        let mac    = Data(HMAC<SHA256>.authenticationCode(for: data, using: macKey))
        try save(data: mac + data, account: "session.\(peerID)")
    }

    /// Load and verify session state. Throws `SophaxError.sessionStateCorrupted` on HMAC mismatch.
    public func loadSessionState(peerID: String) throws -> Data {
        let raw    = try load(account: "session.\(peerID)")
        guard raw.count > 32 else { throw SophaxError.sessionStateCorrupted }
        let mac    = raw.prefix(32)
        let data   = raw.dropFirst(32)
        let macKey = try loadOrCreateSessionMACKey()
        // Constant-time verification — avoids timing side-channel from Data's short-circuit ==
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: macKey) else {
            throw SophaxError.sessionStateCorrupted
        }
        return data
    }

    public func deleteSessionState(peerID: String) throws {
        try delete(account: "session.\(peerID)")
    }

    // MARK: - Message Storage Key

    public func saveStorageKey(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        try save(data: data, account: "storage.master")
    }

    public func loadStorageKey() throws -> SymmetricKey {
        let data = try load(account: "storage.master")
        return SymmetricKey(data: data)
    }

    // MARK: - Username

    public func saveUsername(_ username: String) throws {
        guard let data = username.data(using: .utf8) else {
            throw SophaxError.invalidMessageFormat("Username not UTF-8 encodable")
        }
        try save(data: data, account: "user.username")
    }

    public func loadUsername() throws -> String {
        let data = try load(account: "user.username")
        guard let username = String(data: data, encoding: .utf8) else {
            throw SophaxError.invalidMessageFormat("Username not UTF-8 decodable")
        }
        return username
    }

    // MARK: - Avatar

    public func saveAvatar(_ data: Data) throws {
        try save(data: data, account: "identity.avatar")
    }

    public func loadAvatar() -> Data? {
        try? load(account: "identity.avatar")
    }

    public func deleteAvatar() {
        try? delete(account: "identity.avatar")
    }

    // MARK: - App Lock (Keychain-backed, excluded from iCloud backup)

    public func saveAppLockEnabled(_ enabled: Bool) throws {
        let data = Data([enabled ? 1 : 0])
        try save(data: data, account: "settings.applock")
    }

    public func loadAppLockEnabled() -> Bool {
        guard let data = try? load(account: "settings.applock"), data.count == 1 else { return false }
        return data[0] == 1
    }

    // MARK: - Unlock Attempt Tracking (rate-limiting brute force)
    // Format: UInt32 attempts (4B) || Double lockoutTimestamp (8B, 0.0 = no lockout)

    public func saveUnlockAttempts(_ count: Int, lockedUntil: Date?) {
        var buf = Data(count: 12)
        let c = UInt32(min(count, Int(UInt32.max)))
        let t = lockedUntil?.timeIntervalSince1970 ?? 0.0
        buf.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: c.bigEndian, toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: t,           toByteOffset: 4, as: Double.self)
        }
        try? save(data: buf, account: "settings.unlock_attempts")
    }

    public func loadUnlockAttempts() -> (count: Int, lockedUntil: Date?) {
        guard let buf = try? load(account: "settings.unlock_attempts"), buf.count == 12 else {
            return (0, nil)
        }
        let c = buf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian }
        let t = buf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Double.self) }
        let locked: Date? = t > 0 ? Date(timeIntervalSince1970: t) : nil
        return (Int(c), locked)
    }

    // MARK: - Group Keys (v1 legacy — only used for cleanup during leave/wipe)

    public func saveGroupKey(_ key: SymmetricKey, groupID: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        try save(data: data, account: "group.key.\(groupID)")
    }

    public func loadGroupKey(groupID: String) throws -> SymmetricKey {
        let data = try load(account: "group.key.\(groupID)")
        return SymmetricKey(data: data)
    }

    public func deleteGroupKey(groupID: String) {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  "group.key.\(groupID)"
        ]
        let status = SecItemDelete(query as CFDictionary)
        #if DEBUG
        if status != errSecSuccess && status != errSecItemNotFound {
            print("[Keychain] deleteGroupKey failed: \(status)")
        }
        #endif
    }

    // MARK: - Sender Key States (v2 group messaging)

    /// Save all peer sender key states for a group as a single JSON blob.
    /// Key: peerID → SenderKeyState.
    public func savePeerSenderKeyStates(_ states: [String: SenderKeyState], groupID: String) throws {
        try saveJSON(states, account: "skd.peers.\(groupID)")
    }

    /// Load peer sender key states; returns empty dict if none stored yet.
    public func loadPeerSenderKeyStates(groupID: String) -> [String: SenderKeyState] {
        loadJSON([String: SenderKeyState].self, account: "skd.peers.\(groupID)") ?? [:]
    }

    public func saveMySenderKeyState(_ state: SenderKeyState, groupID: String) throws {
        try saveJSON(state, account: "skd.mine.\(groupID)")
    }

    /// Returns nil if no sender key has been generated for this group yet.
    public func loadMySenderKeyState(groupID: String) -> SenderKeyState? {
        loadJSON(SenderKeyState.self, account: "skd.mine.\(groupID)")
    }

    // MARK: - Skipped group message keys (out-of-order persistence)

    /// A single cached message key together with when it was stored.
    /// Used to evict old entries on load without tracking timestamps in memory.
    public struct SkippedKeyEntry: Codable, Sendable {
        public let keyData:   Data
        public let storedAt:  Date
    }

    /// Persist the full skipped-message-key cache to Keychain.
    /// `entries` maps cacheKey ("groupID/senderPeerID") → (iteration → entry).
    /// Iteration keys are stored as strings because JSON requires string keys.
    public func saveSkippedGroupKeys(_ entries: [String: [String: SkippedKeyEntry]]) throws {
        if entries.isEmpty {
            try? delete(account: "skd.skipped.all")
            return
        }
        try saveJSON(entries, account: "skd.skipped.all")
    }

    /// Load the skipped-message-key cache, discarding entries older than 7 days.
    public func loadSkippedGroupKeys() -> [String: [String: SkippedKeyEntry]] {
        guard let decoded = loadJSON([String: [String: SkippedKeyEntry]].self, account: "skd.skipped.all") else { return [:] }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return decoded.mapValues { inner in
            inner.filter { $0.value.storedAt > cutoff }
        }.filter { !$0.value.isEmpty }
    }

    /// Delete all sender key material for a group (called on leave).
    public func deleteAllSenderKeyStates(groupID: String) {
        let q1: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                   kSecAttrService: service,
                                   kSecAttrAccount: "skd.peers.\(groupID)"]
        let s1 = SecItemDelete(q1 as CFDictionary)
        let q2: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                   kSecAttrService: service,
                                   kSecAttrAccount: "skd.mine.\(groupID)"]
        let s2 = SecItemDelete(q2 as CFDictionary)
        #if DEBUG
        for (label, status) in [("peers", s1), ("mine", s2)] where
            status != errSecSuccess && status != errSecItemNotFound {
            print("[Keychain] deleteAllSenderKeyStates(\(label)) failed: \(status)")
        }
        #endif
    }

    // MARK: - Verified Peers (Safety Number pinning)

    /// Persist the peerID → safetyNumber map in the Keychain so verification
    /// state survives app restarts without being readable from UserDefaults backups.
    public func saveVerifiedPeers(_ peers: [String: String]) throws {
        try saveJSON(peers, account: "verified.peers")
    }

    /// Returns the persisted peerID → safetyNumber map, or [:] if none stored yet.
    public func loadVerifiedPeers() -> [String: String] {
        loadJSON([String: String].self, account: "verified.peers") ?? [:]
    }

    // MARK: - Pinned Messages (conversationID → messageID)

    /// Persist the conversationID → pinned messageID map in the Keychain.
    public func savePinnedMessages(_ map: [String: String]) throws {
        try saveJSON(map, account: "pinned.messages")
    }

    /// Returns the persisted conversationID → pinned messageID map, or [:] if none stored.
    public func loadPinnedMessages() -> [String: String] {
        loadJSON([String: String].self, account: "pinned.messages") ?? [:]
    }

    // MARK: - Peer Aliases (user-assigned contact nicknames)
    // Moved from UserDefaults to Keychain to exclude from iCloud/iTunes backups.

    public func savePeerAliases(_ aliases: [String: String]) throws {
        try saveJSON(aliases, account: "peer.aliases")
    }

    public func loadPeerAliases() -> [String: String] {
        loadJSON([String: String].self, account: "peer.aliases") ?? [:]
    }

    // MARK: - Blocked Peers
    // Moved from UserDefaults to Keychain to exclude from iCloud/iTunes backups.

    private struct BlockedPeersPayload: Codable {
        let ids:   [String]
        let names: [String: String]
    }

    public func saveBlockedPeers(_ ids: Set<String>, names: [String: String]) throws {
        try saveJSON(BlockedPeersPayload(ids: Array(ids), names: names), account: "blocked.peers")
    }

    public func loadBlockedPeers() -> (ids: Set<String>, names: [String: String]) {
        guard let data = try? load(account: "blocked.peers") else { return ([], [:]) }
        // Try new format first
        if let payload = try? JSONDecoder().decode(BlockedPeersPayload.self, from: data) {
            return (Set(payload.ids), payload.names)
        }
        // Migrate from legacy parallel-array format
        if let raw   = try? JSONDecoder().decode([String: [String]].self, from: data),
           let ids   = raw["ids"],
           let keys  = raw["names_keys"],
           let vals  = raw["names_vals"],
           keys.count == vals.count {
            let names = Dictionary(uniqueKeysWithValues: zip(keys, vals))
            try? saveBlockedPeers(Set(ids), names: names)
            return (Set(ids), names)
        }
        return ([], [:])
    }

    // MARK: - MLS Group State (Phase 2 — raw binary blob from mls-rs)

    /// Persist serialised MLS group state for a group.
    /// State is a raw binary blob produced by mls-rs — stored as-is (no JSON wrapper).
    public func saveMlsGroupState(_ state: Data, groupID: String) throws {
        try save(data: state, account: "mls.state.\(groupID)")
    }

    /// Returns the stored MLS group state, or nil if the group has never been joined.
    public func loadMlsGroupState(groupID: String) -> Data? {
        try? load(account: "mls.state.\(groupID)")
    }

    /// Remove the MLS group state for a group (called on leave or wipe).
    public func deleteMlsGroupState(groupID: String) throws {
        try delete(account: "mls.state.\(groupID)")
    }

    // MARK: - SSS Backup (Shamir's Secret Sharing)

    /// Store a plaintext SSS share received from a backup creator (holder role).
    /// Appends to the list of all held shares; safe to call for multiple creators.
    public func saveSSSShare(_ share: SSSShare) {
        var shares = loadSSSShares()
        shares.removeAll { $0.id == share.id }   // replace if re-sent
        shares.append(share)
        try? saveJSON(shares, account: "sss.shares")
    }

    /// All SSS shares currently held for other users' backup recovery.
    public func loadSSSShares() -> [SSSShare] {
        loadJSON([SSSShare].self, account: "sss.shares") ?? []
    }

    /// Remove a specific share after the creator has confirmed recovery is complete.
    public func deleteSSSShare(shareID: String) {
        var shares = loadSSSShares()
        shares.removeAll { $0.id == shareID }
        try? saveJSON(shares, account: "sss.shares")
    }

    /// Store the creator's backup manifest (which contacts hold which shares).
    public func saveSSSBackupManifest(_ manifest: SSSBackupManifest) {
        try? saveJSON(manifest, account: "sss.manifest")
    }

    public func loadSSSBackupManifest() -> SSSBackupManifest? {
        loadJSON(SSSBackupManifest.self, account: "sss.manifest")
    }

    /// Delete all SSS data — called by wipeAllData().
    public func deleteAllSSSData() {
        try? delete(account: "sss.shares")
        try? delete(account: "sss.manifest")
    }

    // MARK: - Key Transparency Log MAC Key

    /// Load or create a stable 256-bit HMAC key used to authenticate the key transparency log.
    /// Stored in Keychain so it is device-local and inaccessible while locked.
    public func loadOrCreateLogMACKey() -> SymmetricKey {
        if let data = try? load(account: "keylog.mac"),
           data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        _ = try? key.withUnsafeBytes { try save(data: Data($0), account: "keylog.mac") }
        return key
    }

    // MARK: - PQ Identity Key (ML-KEM-768, iOS 18+ / macOS 15+)
    // Stored as raw seed bytes (platform-specific length).
    // The caller is responsible for availability guards — this layer is version-agnostic.

    public func savePQIdentityKey(_ data: Data) throws {
        try save(data: data, account: "identity.pq")
    }

    public func loadPQIdentityKey() -> Data? {
        try? load(account: "identity.pq")
    }

    public func deletePQIdentityKey() {
        try? delete(account: "identity.pq")
    }

    // MARK: - ML-DSA-65 Identity Key (post-quantum signing, iOS 19+ / macOS 26+)
    // Stored as raw representation bytes.
    // The caller is responsible for availability guards — this layer is version-agnostic.

    public func saveMLDSAIdentityKey(_ data: Data) throws {
        try save(data: data, account: "identity.mldsa")
    }

    public func loadMLDSAIdentityKey() -> Data? {
        try? load(account: "identity.mldsa")
    }

    public func deleteMLDSAIdentityKey() {
        try? delete(account: "identity.mldsa")
    }

    // MARK: - PQ Signed Prekey (ML-KEM-768, rotating — separate from identity.pq)
    // Rotates weekly alongside the classical signed prekey for forward secrecy.

    public func savePQSignedPreKey(id: UInt32, data: Data) throws {
        try save(data: data, account: "pqspk.\(id)")
        try save(data: Data(withUnsafeBytes(of: id) { Data($0) }), account: "pqspk.current_id")
    }

    public func loadPQSignedPreKey() -> (id: UInt32, data: Data)? {
        guard let idData = try? load(account: "pqspk.current_id"), idData.count == 4 else { return nil }
        let id = idData.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard let keyData = try? load(account: "pqspk.\(id)") else { return nil }
        return (id, keyData)
    }

    public func deletePQSignedPreKey(id: UInt32) {
        try? delete(account: "pqspk.\(id)")
        try? delete(account: "pqspk.current_id")
    }

    // MARK: - Existence Check

    public func hasIdentity() -> Bool {
        return (try? loadSigningKey()) != nil
    }

    // MARK: - App Lock PIN (custom numeric PIN, alternative to biometrics)
    //
    // Stored as PBKDF2-HMAC-SHA256(pin, salt, 100k iterations).
    // 100k iterations ≈ 0.1s on A15+: acceptable UX, ~100k× harder to brute-force than SHA256.
    //
    // Migration: v1 (SHA256) format is detected by the legacy account keys. On first
    // successful v1 verify the hash is automatically upgraded to PBKDF2 and the old
    // keys are deleted. New installs write PBKDF2 only.

    private static let lockPINIterations    = 720_000
    private static let lockPINHashAccountV2 = "settings.lock_pin_v2"
    private static let lockPINSaltAccountV2 = "settings.lock_pin_s_v2"
    private static let lockPINHashAccountV1 = "settings.lock_pin"
    private static let lockPINSaltAccountV1 = "settings.lock_pin_s"

    public func saveRealLockPIN(_ pin: String) throws {
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let hash = try pinHash(pin: pin, salt: salt, iterations: Self.lockPINIterations)
        try save(data: salt, account: Self.lockPINSaltAccountV2)
        try save(data: hash, account: Self.lockPINHashAccountV2)
        try? delete(account: Self.lockPINHashAccountV1)
        try? delete(account: Self.lockPINSaltAccountV1)
    }

    public func verifyRealLockPIN(_ pin: String) -> Bool {
        if let salt     = try? load(account: Self.lockPINSaltAccountV2),
           let stored   = try? load(account: Self.lockPINHashAccountV2),
           let computed = try? pinHash(pin: pin, salt: salt, iterations: Self.lockPINIterations) {
            return timingsafeEqual(computed, stored)
        }
        // Fall back to legacy SHA256 (v1) — upgrade on success
        guard let salt   = try? load(account: Self.lockPINSaltAccountV1),
              let stored = try? load(account: Self.lockPINHashAccountV1) else { return false }
        var input = Data(salt)
        input.append(contentsOf: pin.utf8)
        let computed = Data(SHA256.hash(data: input))
        guard timingsafeEqual(computed, stored) else { return false }
        try? saveRealLockPIN(pin)
        return true
    }

    public func clearRealLockPIN() {
        try? delete(account: Self.lockPINHashAccountV2)
        try? delete(account: Self.lockPINSaltAccountV2)
        try? delete(account: Self.lockPINHashAccountV1)
        try? delete(account: Self.lockPINSaltAccountV1)
    }

    public func hasRealLockPIN() -> Bool {
        (try? load(account: Self.lockPINHashAccountV2)) != nil ||
        (try? load(account: Self.lockPINHashAccountV1)) != nil
    }

    // MARK: - Duress PIN
    //
    // Stored as PBKDF2-HMAC-SHA256(pin, salt, 100k iterations) under obfuscated account keys.
    // PIN is NEVER stored in plaintext, memory, or UserDefaults.

    private static let duressHashAccountV2 = "settings.security_alt_v2"
    private static let duressSaltAccountV2 = "settings.security_alt_s_v2"
    private static let duressHashAccountV1 = "settings.security_alt"
    private static let duressSaltAccountV1 = "settings.security_alt_s"

    public func saveDuressPIN(_ pin: String) throws {
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let hash = try pinHash(pin: pin, salt: salt, iterations: Self.lockPINIterations)
        try save(data: salt, account: Self.duressSaltAccountV2)
        try save(data: hash, account: Self.duressHashAccountV2)
        try? delete(account: Self.duressHashAccountV1)
        try? delete(account: Self.duressSaltAccountV1)
    }

    public func verifyDuressPIN(_ pin: String) -> Bool {
        if let salt     = try? load(account: Self.duressSaltAccountV2),
           let stored   = try? load(account: Self.duressHashAccountV2),
           let computed = try? pinHash(pin: pin, salt: salt, iterations: Self.lockPINIterations) {
            return timingsafeEqual(computed, stored)
        }
        // Fall back to SHA256 v1 — upgrade on success
        guard let salt   = try? load(account: Self.duressSaltAccountV1),
              let stored = try? load(account: Self.duressHashAccountV1) else { return false }
        var input = Data(salt)
        input.append(contentsOf: pin.utf8)
        let computed = Data(SHA256.hash(data: input))
        guard timingsafeEqual(computed, stored) else { return false }
        try? saveDuressPIN(pin)
        return true
    }

    public func clearDuressPIN() {
        try? delete(account: Self.duressHashAccountV2)
        try? delete(account: Self.duressSaltAccountV2)
        try? delete(account: Self.duressHashAccountV1)
        try? delete(account: Self.duressSaltAccountV1)
    }

    public func hasDuressPIN() -> Bool {
        (try? load(account: Self.duressHashAccountV2)) != nil ||
        (try? load(account: Self.duressHashAccountV1)) != nil
    }

    // MARK: - Remote Wipe Dedup
    // Persisted across restarts to block replay attacks on remote wipe requests.
    // Each entry carries a timestamp so records older than 30 days can be pruned —
    // they offer no replay protection value once the device clock has advanced past them.

    private struct WipeRequestRecord: Codable {
        let id:     String
        let seenAt: Date
    }

    /// Persist seen wipe request IDs with their reception timestamps.
    /// IDs older than 30 days are dropped on save; only new IDs (absent from existing records)
    /// are appended with the current time so the stored seenAt is always the first-seen time.
    public func saveSeenWipeRequestIDs(_ ids: [String: Date]) {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        var records = (loadJSON([WipeRequestRecord].self, account: "wipe.seen_ids") ?? [])
            .filter { $0.seenAt > cutoff }
        let existing = Set(records.map { $0.id })
        for (id, seenAt) in ids where !existing.contains(id) {
            records.append(WipeRequestRecord(id: id, seenAt: seenAt))
        }
        try? saveJSON(records, account: "wipe.seen_ids")
    }

    /// Load seen wipe request IDs as a dictionary of id → first-seen timestamp.
    /// IDs older than 30 days are excluded.
    public func loadSeenWipeRequestIDs() -> [String: Date] {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let records = loadJSON([WipeRequestRecord].self, account: "wipe.seen_ids") ?? []
        return Dictionary(
            uniqueKeysWithValues: records
                .filter { $0.seenAt > cutoff }
                .map { ($0.id, $0.seenAt) }
        )
    }

    // MARK: - Linked Devices
    // Stored in Keychain (not UserDefaults) to exclude from iCloud/iTunes backups.

    public func saveLinkedDevices(_ peerIDs: [String]) {
        try? saveJSON(peerIDs, account: "linked.devices")
    }

    public func loadLinkedDevices() -> [String] {
        loadJSON([String].self, account: "linked.devices") ?? []
    }

    // MARK: - Trusted Wipe Peers

    /// Save the list of peerIDs that are authorised to trigger a remote wipe.
    public func saveTrustedWipePeers(_ peers: [String]) {
        try? saveJSON(peers, account: "trustedWipePeers")
    }

    /// Load the list of peerIDs authorised to trigger a remote wipe.
    public func loadTrustedWipePeers() -> [String] {
        loadJSON([String].self, account: "trustedWipePeers") ?? []
    }

    public func wipeAll() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SophaxError.keychainError(status)
        }
    }

    // MARK: - Private helpers

    private func saveJSON<T: Encodable>(_ value: T, account: String) throws {
        try save(data: JSONEncoder().encode(value), account: account)
    }

    private func loadJSON<T: Decodable>(_ type: T.Type, account: String) -> T? {
        (try? load(account: account)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func save(data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let update: [CFString: Any] = [
            kSecValueData: data,
            // kSecAttrAccessibleWhenUnlockedThisDeviceOnly:
            //   - Items NOT backed up to iCloud
            //   - Items NOT transferred to new device
            //   - Accessible only when device is unlocked
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw SophaxError.keychainError(status)
        }
    }

    private func load(account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            throw SophaxError.keychainError(status)
        }
        return data
    }

    private func delete(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SophaxError.keychainError(status)
        }
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            // Forces the data-protection keychain on macOS Catalyst (no-op on iOS where
            // data-protection is always used). Without this flag Mac builds fall back to
            // the file-based keychain which has weaker at-rest encryption.
            kSecUseDataProtectionKeychain: true
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    // MARK: - Private: PIN KDF helpers

    /// PBKDF2-HMAC-SHA256 for PIN storage. Returns 32 derived bytes.
    private func pinHash(pin: String, salt: Data, iterations: Int) throws -> Data {
        var passData = Data(pin.utf8)
        defer { passData.resetBytes(in: 0..<passData.count) }
        var derived = Data(repeating: 0, count: 32)
        let status: CCStatus = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                passData.withUnsafeBytes { passPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress, passData.count,
                        saltPtr.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedPtr.baseAddress, 32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw SophaxError.keyGenerationFailed }
        return derived
    }

    /// Constant-time equality — prevents timing side-channel on PIN comparison.
    private func timingsafeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBytes { ap in
            b.withUnsafeBytes { bp in
                timingsafe_bcmp(ap.baseAddress!, bp.baseAddress!, ap.count) == 0
            }
        }
    }
}
