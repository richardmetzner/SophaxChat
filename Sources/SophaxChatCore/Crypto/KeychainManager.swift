// KeychainManager.swift
// SophaxChatCore
//
// Secure storage for cryptographic keys using the iOS Keychain.
// All keys are stored with kSecAttrAccessibleWhenUnlockedThisDeviceOnly
// — they are not backed up to iCloud and are wiped on device restore.

import Foundation
import Security
import CryptoKit

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

    // MARK: - Group Keys

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
        let data = try JSONEncoder().encode(states)
        try save(data: data, account: "skd.peers.\(groupID)")
    }

    /// Load peer sender key states; returns empty dict if none stored yet.
    public func loadPeerSenderKeyStates(groupID: String) -> [String: SenderKeyState] {
        guard let data   = try? load(account: "skd.peers.\(groupID)"),
              let states = try? JSONDecoder().decode([String: SenderKeyState].self, from: data)
        else { return [:] }
        return states
    }

    public func saveMySenderKeyState(_ state: SenderKeyState, groupID: String) throws {
        let data = try JSONEncoder().encode(state)
        try save(data: data, account: "skd.mine.\(groupID)")
    }

    /// Returns nil if no sender key has been generated for this group yet.
    public func loadMySenderKeyState(groupID: String) -> SenderKeyState? {
        guard let data  = try? load(account: "skd.mine.\(groupID)"),
              let state = try? JSONDecoder().decode(SenderKeyState.self, from: data)
        else { return nil }
        return state
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
        let data = try JSONEncoder().encode(entries)
        try save(data: data, account: "skd.skipped.all")
    }

    /// Load the skipped-message-key cache, discarding entries older than 7 days.
    public func loadSkippedGroupKeys() -> [String: [String: SkippedKeyEntry]] {
        guard let data    = try? load(account: "skd.skipped.all"),
              let decoded = try? JSONDecoder().decode([String: [String: SkippedKeyEntry]].self, from: data)
        else { return [:] }
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
        let data = try JSONEncoder().encode(peers)
        try save(data: data, account: "verified.peers")
    }

    /// Returns the persisted peerID → safetyNumber map, or [:] if none stored yet.
    public func loadVerifiedPeers() -> [String: String] {
        guard let data  = try? load(account: "verified.peers"),
              let peers = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return peers
    }

    // MARK: - Peer Aliases (user-assigned contact nicknames)
    // Moved from UserDefaults to Keychain to exclude from iCloud/iTunes backups.

    public func savePeerAliases(_ aliases: [String: String]) throws {
        let data = try JSONEncoder().encode(aliases)
        try save(data: data, account: "peer.aliases")
    }

    public func loadPeerAliases() -> [String: String] {
        guard let data    = try? load(account: "peer.aliases"),
              let aliases = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return aliases
    }

    // MARK: - Blocked Peers
    // Moved from UserDefaults to Keychain to exclude from iCloud/iTunes backups.

    public func saveBlockedPeers(_ ids: Set<String>, names: [String: String]) throws {
        let payload = ["ids": Array(ids), "names_keys": Array(names.keys), "names_vals": Array(names.values)]
        let data = try JSONEncoder().encode(payload)
        try save(data: data, account: "blocked.peers")
    }

    public func loadBlockedPeers() -> (ids: Set<String>, names: [String: String]) {
        guard let data    = try? load(account: "blocked.peers"),
              let payload = try? JSONDecoder().decode([String: [String]].self, from: data),
              let ids     = payload["ids"],
              let keys    = payload["names_keys"],
              let vals    = payload["names_vals"],
              keys.count == vals.count
        else { return ([], [:]) }
        let names = Dictionary(uniqueKeysWithValues: zip(keys, vals))
        return (Set(ids), names)
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

    // MARK: - Existence Check

    public func hasIdentity() -> Bool {
        return (try? loadSigningKey()) != nil
    }

    // MARK: - Wipe (for account deletion / security)

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

    private func save(data: Data, account: String) throws {
        // Try to update first, then add
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
            kSecAttrAccount: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }
}
