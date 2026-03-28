// KeyTransparencyLog.swift
// SophaxChatCore
//
// Persistent log of observed peer identity keys.
// Lets the user audit when (and how many times) a contact's keys have changed.
//
// Storage: UserDefaults "sophax.keylog" — contains only public keys (no secrets).

import Foundation

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

    private static let defaultsKey = "sophax.keylog"

    /// In-memory cache: peerID → [KeyLogEntry] (chronological).
    private var log: [String: [KeyLogEntry]] = [:]

    public init() {
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
        guard let data = try? JSONEncoder().encode(log) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [KeyLogEntry]].self, from: data)
        else { return }
        log = decoded
    }
}
