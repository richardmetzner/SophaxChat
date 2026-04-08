// DHTStorage.swift
// SophaxChatCore
//
// Persists the KBucketTable snapshot to an AES-256-GCM encrypted blob
// via MessageStore.saveEncryptedBlob — same directory and key as message storage.
// Survives app restarts so we don't cold-bootstrap every time.

import Foundation

public final class DHTStorage: @unchecked Sendable {

    private let messageStore: MessageStore
    private static let fileName = "dht_kbuckets"

    public init(messageStore: MessageStore) {
        self.messageStore = messageStore
    }

    // MARK: - Persist

    /// Saves the k-bucket snapshot (flat array of DHTContact arrays) to encrypted storage.
    public func save(snapshot: [[DHTContact]]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? messageStore.saveEncryptedBlob(data, fileName: Self.fileName)
    }

    /// Loads and decodes the previously saved k-bucket snapshot.
    /// Returns an empty array if no snapshot exists or decoding fails.
    public func load() -> [DHTContact] {
        guard let data = messageStore.loadEncryptedBlob(fileName: Self.fileName),
              let snapshot = try? JSONDecoder().decode([[DHTContact]].self, from: data)
        else { return [] }
        return snapshot.flatMap { $0 }
    }
}
