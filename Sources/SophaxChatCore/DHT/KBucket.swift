// KBucket.swift
// SophaxChatCore
//
// Kademlia routing table: 256 k-buckets indexed by XOR distance, k=20.
// All mutations are actor-isolated — no external locking required.

import Foundation
import CryptoKit

// MARK: - DHTNodeID

/// A 256-bit Kademlia node identifier derived from SHA256(signingKey || dhKey).
public struct DHTNodeID: Equatable, Hashable, Sendable {
    public let bytes: Data  // always 32 bytes

    public init(bytes: Data) throws {
        guard bytes.count == 32 else {
            throw DHTError.invalidNodeID(bytes.count)
        }
        self.bytes = bytes
    }

    public static func from(hex: String) throws -> DHTNodeID {
        guard hex.count == 64 else { throw DHTError.invalidNodeID(hex.count / 2) }
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else {
                throw DHTError.invalidNodeID(0)
            }
            data.append(byte)
            idx = next
        }
        return try DHTNodeID(bytes: data)
    }

    public var hexString: String { bytes.hexString }

    /// XOR distance to another node — big-endian 32-byte result.
    public func xorDistance(to other: DHTNodeID) -> Data {
        Data(zip(bytes, other.bytes).map { $0 ^ $1 })
    }

    /// Kademlia bucket index: position of the highest set bit in the XOR distance (0–255).
    /// Returns -1 if distance == 0 (same node — never inserted).
    public func bucketIndex(to other: DHTNodeID) -> Int {
        let d = xorDistance(to: other)
        for byteIdx in 0..<d.count {
            let byte = d[d.startIndex + byteIdx]
            if byte == 0 { continue }
            for bitIdx in stride(from: 7, through: 0, by: -1) {
                if byte & (1 << bitIdx) != 0 {
                    // (31 - byteIdx) * 8 + bitIdx  →  0 = LSB of rightmost byte
                    return (d.count - 1 - byteIdx) * 8 + bitIdx
                }
            }
        }
        return -1  // distance == 0
    }
}

public enum DHTError: Error, Sendable {
    case invalidNodeID(Int)
    case lookupTimeout
    case lookupFailed
}

// MARK: - DHTContact

public struct DHTContact: Codable, Sendable {
    public let nodeID: String        // hex 64 chars (DHTNodeID.hexString)
    public let onionAddress: String  // 62-char .onion hostname, no port
    public let port: UInt16
    public var lastSeen: Date
    public var failCount: Int

    public init(nodeID: String, onionAddress: String, port: UInt16 = 25519,
                lastSeen: Date = Date(), failCount: Int = 0) {
        self.nodeID       = nodeID
        self.onionAddress = onionAddress
        self.port         = port
        self.lastSeen     = lastSeen
        self.failCount    = failCount
    }

    /// "host.onion:port" string for TCPTransport.connect().
    public var tcpAddress: String { "\(onionAddress):\(port)" }
}

// MARK: - KBucketTable

/// Kademlia routing table. Actor-isolated — all access is serial.
public actor KBucketTable {

    public static let k = 20              // bucket size
    private static let bucketCount = 256  // one per bit position of the 256-bit ID space

    private var buckets: [[DHTContact]]   // [256][≤20]
    private let localNodeID: DHTNodeID

    public init(localNodeID: DHTNodeID) {
        self.localNodeID = localNodeID
        self.buckets = Array(repeating: [], count: KBucketTable.bucketCount)
    }

    // MARK: - Core operations

    /// Insert or refresh a contact. Ignored if nodeID == localNodeID.
    /// When the bucket is full, the oldest contact with failCount ≥ 1 is evicted;
    /// otherwise the new contact is discarded (Kademlia stability preference).
    public func insert(_ contact: DHTContact) {
        guard let localID = try? DHTNodeID(bytes: localNodeID.bytes),
              let contactID = try? DHTNodeID.from(hex: contact.nodeID) else { return }
        let idx = localID.bucketIndex(to: contactID)
        guard idx >= 0 else { return }  // same node

        // If already present, refresh lastSeen.
        if let pos = buckets[idx].firstIndex(where: { $0.nodeID == contact.nodeID }) {
            var updated = buckets[idx][pos]
            updated.lastSeen  = contact.lastSeen
            updated.failCount = 0
            buckets[idx][pos] = updated
            return
        }

        if buckets[idx].count < KBucketTable.k {
            buckets[idx].append(contact)
        } else {
            evictOrDiscard(contact, bucketIdx: idx)
        }
    }

    /// Returns up to `count` contacts closest to `target` by XOR distance.
    public func closestNodes(to target: DHTNodeID, count: Int) -> [DHTContact] {
        let all = buckets.flatMap { $0 }
        return all
            .filter { $0.nodeID != localNodeID.hexString }
            .sorted { a, b in
                guard let aID = try? DHTNodeID.from(hex: a.nodeID),
                      let bID = try? DHTNodeID.from(hex: b.nodeID) else { return false }
                return target.xorDistance(to: aID).lexicographicallyPrecedes(
                    target.xorDistance(to: bID)
                )
            }
            .prefix(count)
            .map { $0 }
    }

    /// Mark a contact as successfully seen — resets failCount.
    public func markSeen(nodeID: String) {
        for i in 0..<buckets.count {
            if let pos = buckets[i].firstIndex(where: { $0.nodeID == nodeID }) {
                buckets[i][pos].lastSeen  = Date()
                buckets[i][pos].failCount = 0
                return
            }
        }
    }

    /// Increment failCount. Evicts the contact after 3 consecutive failures.
    public func markFailed(nodeID: String) {
        for i in 0..<buckets.count {
            if let pos = buckets[i].firstIndex(where: { $0.nodeID == nodeID }) {
                buckets[i][pos].failCount += 1
                if buckets[i][pos].failCount >= 3 {
                    buckets[i].remove(at: pos)
                }
                return
            }
        }
    }

    public func remove(nodeID: String) {
        for i in 0..<buckets.count {
            buckets[i].removeAll { $0.nodeID == nodeID }
        }
    }

    public func allContacts() -> [DHTContact] {
        buckets.flatMap { $0 }
    }

    // MARK: - Persistence

    public func snapshot() -> [[DHTContact]] { buckets }

    public func restore(from snapshot: [[DHTContact]]) {
        guard snapshot.count == KBucketTable.bucketCount else { return }
        buckets = snapshot.map { Array($0.prefix(KBucketTable.k)) }
    }

    // MARK: - Private

    /// When a bucket is full, evict the oldest contact whose failCount ≥ 1
    /// and replace it with the new contact. Otherwise discard the new contact.
    private func evictOrDiscard(_ contact: DHTContact, bucketIdx idx: Int) {
        let staleThreshold = Date().addingTimeInterval(-15 * 60)  // 15 min ago
        if let evictPos = buckets[idx]
            .enumerated()
            .first(where: { $0.element.failCount >= 1 && $0.element.lastSeen < staleThreshold })?
            .offset
        {
            buckets[idx][evictPos] = contact
        }
        // else: bucket is full of fresh contacts — discard new one (Kademlia spec)
    }
}
