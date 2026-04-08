// DHTStore.swift
// SophaxChatCore
//
// Local key-value store for DHT STORE requests.
// Keyed by full 256-bit nodeID (hex). Secondary index allows prefix lookup
// by 16-char peerID so callers need not know the full key.

import Foundation

public actor DHTStore {

    /// Default TTL — slightly longer than the 24h republish interval.
    public static let defaultTTL: TimeInterval = 25 * 60 * 60

    private struct Entry {
        let bundle: PreKeyBundle
        let expiresAt: Date
    }

    /// nodeID(hex64) → Entry
    private var entries: [String: Entry] = [:]
    /// peerID(hex16) → nodeID(hex64) — built from the first 16 chars of each stored nodeID.
    private var prefixIndex: [String: String] = [:]

    public init() {}

    // MARK: - Mutations

    public func store(nodeID: String, bundle: PreKeyBundle,
                      expiresAt: Date = Date().addingTimeInterval(DHTStore.defaultTTL)) {
        entries[nodeID] = Entry(bundle: bundle, expiresAt: expiresAt)
        let prefix = String(nodeID.prefix(16))
        prefixIndex[prefix] = nodeID
    }

    public func remove(nodeID: String) {
        let prefix = String(nodeID.prefix(16))
        if prefixIndex[prefix] == nodeID { prefixIndex.removeValue(forKey: prefix) }
        entries.removeValue(forKey: nodeID)
    }

    public func purgeExpired() {
        let now = Date()
        let expired = entries.filter { $0.value.expiresAt < now }.map(\.key)
        for key in expired { remove(nodeID: key) }
    }

    // MARK: - Queries

    /// Lookup by full 256-bit nodeID (hex64).
    public func lookup(nodeID: String) -> PreKeyBundle? {
        guard let entry = entries[nodeID], entry.expiresAt > Date() else { return nil }
        return entry.bundle
    }

    /// Lookup by 16-char peerID prefix.
    public func lookupByPrefix(_ peerID: String) -> PreKeyBundle? {
        guard let nodeID = prefixIndex[peerID] else { return nil }
        return lookup(nodeID: nodeID)
    }

    /// Full nodeID for a given peerID prefix, if known.
    public func nodeID(forPeerID peerID: String) -> String? {
        prefixIndex[peerID]
    }

    public func allNodeIDs() -> [String] { Array(entries.keys) }
}
