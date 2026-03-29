// KeyTransparencyLog.swift
// SophaxChatCore
//
// Persistent log of observed peer identity keys.
// Lets the user audit when (and how many times) a contact's keys have changed.
//
// Storage: UserDefaults "sophax.keylog" + HMAC tag in "sophax.keylog.mac"
// The HMAC key lives in Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
// so an attacker with filesystem access cannot silently delete entries or add
// fake ones without invalidating the tag — the app clears and re-flags on mismatch.

import Foundation
import CryptoKit

// MARK: - Entry

/// One observed key snapshot for a peer.
public struct KeyLogEntry: Codable, Sendable {
    /// peerID of the contact.
    public let peerID:           String
    /// Ed25519 signing public key observed at this time.
    public let signingKeyPublic: Data
    /// X25519 DH public key observed at this time.
    public let dhKeyPublic:      Data
    /// First time this specific key combination was observed.
    public let firstSeen:        Date
    /// Most recent time this key was seen in a Hello message.
    public var lastSeen:         Date
}

// MARK: - Log

/// Append-only log of all observed peer identity keys.
/// Thread-safety: all mutations must happen on the main thread (owned by ChatManager → AppState).
public final class KeyTransparencyLog: @unchecked Sendable {

    private static let defaultsKey    = "sophax.keylog"
    private static let defaultsMACKey = "sophax.keylog.mac"

    /// In-memory cache: peerID → [KeyLogEntry] (chronological).
    private var log: [String: [KeyLogEntry]] = [:]

    private let macKey: SymmetricKey

    /// Set to true if the stored log failed HMAC verification on last load.
    /// ChatManager exposes this to AppState so the UI can warn the user.
    public private(set) var wasLogTampered: Bool = false

    public init(keychain: KeychainManager) {
        self.macKey = keychain.loadOrCreateLogMACKey()
        load()
    }

    // MARK: - Public API

    /// Record an observed key pair for `peerID`.
    /// - Returns: `true` if the key is NEW or DIFFERENT from the most-recently-seen key,
    ///   `false` if the same key was already the latest entry (no change).
    @discardableResult
    public func record(peerID: String, signingKey: Data, dhKey: Data) -> Bool {
        var entries = log[peerID] ?? []

        // Update `lastSeen` if the last entry has the same keys
        if let last = entries.last,
           last.signingKeyPublic == signingKey,
           last.dhKeyPublic == dhKey {
            entries[entries.count - 1].lastSeen = Date()
            log[peerID] = entries
            save()
            return false
        }

        // New or changed key — append a new entry
        let entry = KeyLogEntry(
            peerID:           peerID,
            signingKeyPublic: signingKey,
            dhKeyPublic:      dhKey,
            firstSeen:        Date(),
            lastSeen:         Date()
        )
        entries.append(entry)
        // Cap history at 20 entries per peer to bound storage size
        if entries.count > 20 { entries.removeFirst(entries.count - 20) }
        log[peerID] = entries
        save()
        return true
    }

    /// Full key history for a peer (oldest first).
    public func history(for peerID: String) -> [KeyLogEntry] {
        log[peerID] ?? []
    }

    /// All logged peerIDs.
    public var allPeerIDs: [String] { Array(log.keys) }

    // MARK: - Persistence

    private func save() {
        guard let jsonData = try? JSONEncoder().encode(log) else { return }
        // Compute HMAC over the JSON and store tag separately
        let mac = HMAC<SHA256>.authenticationCode(for: jsonData, using: macKey)
        UserDefaults.standard.set(jsonData,  forKey: Self.defaultsKey)
        UserDefaults.standard.set(Data(mac), forKey: Self.defaultsMACKey)
    }

    private func load() {
        guard let jsonData = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }

        // Verify HMAC before accepting any data from UserDefaults
        if let storedMAC = UserDefaults.standard.data(forKey: Self.defaultsMACKey),
           HMAC<SHA256>.isValidAuthenticationCode(storedMAC, authenticating: jsonData, using: macKey),
           let decoded = try? JSONDecoder().decode([String: [KeyLogEntry]].self, from: jsonData) {
            log = decoded
        } else {
            // MAC missing or invalid — treat as tampered; wipe and flag for UI alert
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.defaultsMACKey)
            wasLogTampered = true
        }
    }
}
