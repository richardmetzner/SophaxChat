// DHTEngine.swift
// SophaxChatCore
//
// Kademlia DHT engine — peer discovery over Tor.
// Manages routing table, local store, iterative lookups, and periodic republish.
//
// Usage:
//   1. let engine = DHTEngine(identity: ..., wireBuilder: ..., send: sendBlock)
//   2. await engine.start(bootstrapContacts: [...])
//   3. let (nodeID, bundle) = try await engine.lookup(peerID: "a1b2c3d4e5f6a1b2")
//   4. Pipe incoming DHT wire messages: await engine.handleMessage(message, fromPeer: peerID)

import Foundation

// MARK: - DHTTransport callback

/// Block that sends a DHT WireMessage to a contact.
/// The implementor (ChatManager) is responsible for connecting if not already connected.
public typealias DHTSendBlock = @Sendable (WireMessage, DHTContact) async -> Void

// MARK: - DHTEngine

public actor DHTEngine {

    // Kademlia parameters
    static let k     = 20
    static let alpha = 3
    static let queryTimeout:   TimeInterval = 30
    static let publishInterval: TimeInterval = 24 * 3600
    static let refreshInterval: TimeInterval = 60 * 60

    // Core state
    private let localNodeID:  DHTNodeID
    private let localContact: DHTContact
    public  let table:        KBucketTable
    public  let store:        DHTStore

    // Dependencies (not retained as strong to avoid cycles)
    private let wireBuilder: WireMessageBuilder
    private let send:        DHTSendBlock

    // In-flight lookup tracking
    private var activeLookups:  [String: LookupState] = [:]        // lookupID → state
    private var pendingQueries: [String: PendingQuery] = [:]        // peerNodeID → query

    // Lifecycle
    private var stopped = false
    private var publishTask:  Task<Void, Never>?
    private var refreshTask:  Task<Void, Never>?

    // MARK: - Init

    public init(
        identity:    IdentityManager,
        wireBuilder: WireMessageBuilder,
        send:        @escaping DHTSendBlock
    ) throws {
        let nodeIDData = identity.publicIdentity.dhtNodeID
        self.localNodeID  = try DHTNodeID(bytes: nodeIDData)

        let onion = identity.onionHostname ?? ""
        self.localContact = DHTContact(
            nodeID:       nodeIDData.hexString,
            onionAddress: onion,
            port:         25519
        )
        self.table       = KBucketTable(localNodeID: try DHTNodeID(bytes: nodeIDData))
        self.store       = DHTStore()
        self.wireBuilder = wireBuilder
        self.send        = send
    }

    // MARK: - Lifecycle

    public func start(bootstrapContacts: [DHTContact]) async {
        stopped = false
        schedulePublish()
        scheduleRefresh()
        await bootstrap(contacts: bootstrapContacts)
    }

    public func stop() {
        stopped = true
        publishTask?.cancel()
        refreshTask?.cancel()
        publishTask = nil
        refreshTask = nil
        // Fail all active lookups
        for (id, state) in activeLookups {
            state.continuation?.resume(throwing: DHTError.lookupFailed)
            activeLookups[id] = nil
        }
    }

    // MARK: - Public API

    /// Lookup a peer by their 16-char peerID.
    /// Returns their full dhtNodeID (hex64) and PreKeyBundle when found.
    public func lookup(peerID: String) async throws -> (dhtNodeID: String, bundle: PreKeyBundle) {
        // Fast path: local store hit
        if let bundle = await store.lookupByPrefix(peerID),
           let nodeID = await store.nodeID(forPeerID: peerID) {
            return (nodeID, bundle)
        }

        // Construct a target nodeID: pad peerID to 64 hex chars with zeros.
        // XOR routing converges toward this prefix; prefix-scan at responders finds exact match.
        let padded = peerID + String(repeating: "0", count: 64 - peerID.count)
        let target = try DHTNodeID.from(hex: padded)

        let result = try await iterativeLookup(target: target, wantValue: true,
                                               peerIDPrefix: peerID)
        switch result {
        case .found(let nodeID, let bundle):
            return (nodeID, bundle)
        case .notFound:
            throw DHTError.lookupFailed
        }
    }

    /// Publish our own PreKeyBundle to the k nodes closest to our nodeID.
    public func publishSelf(bundle: PreKeyBundle) async {
        let closest = await table.closestNodes(to: localNodeID, count: DHTEngine.k)
        guard !closest.isEmpty else { return }

        let expiry = Date().addingTimeInterval(DHTStore.defaultTTL)
        let payload = DHTStorePayload(
            nodeID:    localNodeID.hexString,
            bundle:    bundle,
            expiresAt: expiry
        )
        for contact in closest {
            guard let msg = try? wireBuilder.build(.dhtStore, payload: payload) else { continue }
            await send(msg, contact)
        }
    }

    /// Route an incoming DHT wire message to the appropriate handler.
    /// Called by ChatManager.dispatch() for all dht* message types.
    public func handleMessage(_ message: WireMessage, fromPeer senderPeerID: String) async {
        await table.markSeen(nodeID: senderPeerID)

        switch message.type {
        case .dhtPing:
            await handlePing(message, fromPeer: senderPeerID)
        case .dhtPong:
            handlePong(fromPeer: senderPeerID)
        case .dhtFindNode:
            await handleFindNode(message, fromPeer: senderPeerID)
        case .dhtFindNodeResp:
            handleFindNodeResp(message, fromPeer: senderPeerID)
        case .dhtStore:
            await handleStore(message)
        case .dhtFindValue:
            await handleFindValue(message, fromPeer: senderPeerID)
        case .dhtFindValueResp:
            handleFindValueResp(message, fromPeer: senderPeerID)
        default:
            break
        }
    }

    // MARK: - Incoming: Ping / Pong

    private func handlePing(_ message: WireMessage, fromPeer peerID: String) async {
        guard let payload = try? wireBuilder.decodePayload(DHTPingPayload.self, from: message),
              let contact = await contactInfo(for: peerID, nodeID: payload.senderNodeID) else { return }
        let pong = DHTPongPayload(senderNodeID: localNodeID.hexString)
        guard let msg = try? wireBuilder.build(.dhtPong, payload: pong) else { return }
        await send(msg, contact)
    }

    private func handlePong(fromPeer peerID: String) {
        // markSeen already called above; just route to pending query if any
        resolvePendingQuery(peerNodeID: peerID, closestNodes: [], bundle: nil)
    }

    // MARK: - Incoming: FindNode / FindNodeResp

    private func handleFindNode(_ message: WireMessage, fromPeer peerID: String) async {
        guard let payload = try? wireBuilder.decodePayload(DHTFindNodePayload.self, from: message),
              let target  = try? DHTNodeID.from(hex: payload.targetNodeID),
              let contact = await contactInfo(for: peerID, nodeID: nil) else { return }

        let closest = await table.closestNodes(to: target, count: DHTEngine.k)
        let resp = DHTFindNodeRespPayload(closestNodes: closest.map(\.asDHTNodeInfo))
        guard let msg = try? wireBuilder.build(.dhtFindNodeResp, payload: resp) else { return }
        await send(msg, contact)

        // Insert sender into our routing table
        await table.insert(contact)
    }

    private func handleFindNodeResp(_ message: WireMessage, fromPeer peerID: String) {
        guard let payload = try? wireBuilder.decodePayload(DHTFindNodeRespPayload.self, from: message) else { return }
        let contacts = payload.closestNodes.compactMap { $0.asDHTContact }
        resolvePendingQuery(peerNodeID: peerID, closestNodes: contacts, bundle: nil)
    }

    // MARK: - Incoming: Store

    private func handleStore(_ message: WireMessage) async {
        guard let payload = try? wireBuilder.decodePayload(DHTStorePayload.self, from: message) else { return }
        // Only store if we are among the k closest (basic guard against spam)
        await store.store(nodeID: payload.nodeID, bundle: payload.bundle, expiresAt: payload.expiresAt)
        await store.purgeExpired()
    }

    // MARK: - Incoming: FindValue / FindValueResp

    private func handleFindValue(_ message: WireMessage, fromPeer peerID: String) async {
        guard let payload = try? wireBuilder.decodePayload(DHTFindValuePayload.self, from: message),
              let contact = await contactInfo(for: peerID, nodeID: nil) else { return }

        // Check exact match first, then prefix
        var bundle = await store.lookup(nodeID: payload.targetNodeID)
        if bundle == nil, let prefix = payload.peerIDPrefix {
            bundle = await store.lookupByPrefix(prefix)
        }

        let resp: DHTFindValueRespPayload
        if let bundle {
            resp = DHTFindValueRespPayload(bundle: bundle, closestNodes: [])
        } else {
            let target   = (try? DHTNodeID.from(hex: payload.targetNodeID)) ?? localNodeID
            let closest  = await table.closestNodes(to: target, count: DHTEngine.k)
            resp = DHTFindValueRespPayload(bundle: nil, closestNodes: closest.map(\.asDHTNodeInfo))
        }

        guard let msg = try? wireBuilder.build(.dhtFindValueResp, payload: resp) else { return }
        await send(msg, contact)
        await table.insert(contact)
    }

    private func handleFindValueResp(_ message: WireMessage, fromPeer peerID: String) {
        guard let payload = try? wireBuilder.decodePayload(DHTFindValueRespPayload.self, from: message) else { return }
        let contacts = payload.closestNodes.compactMap { $0.asDHTContact }
        resolvePendingQuery(peerNodeID: peerID, closestNodes: contacts, bundle: payload.bundle)
    }

    // MARK: - Iterative Lookup

    private enum LookupResult {
        case found(dhtNodeID: String, bundle: PreKeyBundle)
        case notFound([DHTContact])
    }

    private struct LookupState {
        var target:       DHTNodeID
        var wantValue:    Bool
        var peerIDPrefix: String?
        var queried:      Set<String>         // nodeID hex strings already queried
        var inFlight:     Set<String>         // nodeID hex strings currently in-flight
        var closest:      [DHTContact]        // sorted by XOR distance to target, max k
        var continuation: CheckedContinuation<LookupResult, Error>?
    }

    private struct PendingQuery {
        let lookupID: String
        let wantValue: Bool
        let timeoutTask: Task<Void, Never>
    }

    private func iterativeLookup(
        target: DHTNodeID,
        wantValue: Bool,
        peerIDPrefix: String? = nil
    ) async throws -> LookupResult {
        let lookupID = UUID().uuidString
        let seed = await table.closestNodes(to: target, count: DHTEngine.alpha)

        guard !seed.isEmpty else { throw DHTError.lookupFailed }

        return try await withCheckedThrowingContinuation { cont in
            var state = LookupState(
                target:       target,
                wantValue:    wantValue,
                peerIDPrefix: peerIDPrefix,
                queried:      [],
                inFlight:     [],
                closest:      seed,
                continuation: cont
            )
            activeLookups[lookupID] = state
            // Send to alpha closest
            sendNextQueries(lookupID: lookupID)
        }
    }

    /// Send FIND_NODE / FIND_VALUE to the next alpha not-yet-queried candidates.
    private func sendNextQueries(lookupID: String) {
        guard var state = activeLookups[lookupID] else { return }

        let candidates = state.closest.filter {
            !state.queried.contains($0.nodeID) && !state.inFlight.contains($0.nodeID)
        }.prefix(DHTEngine.alpha)

        if candidates.isEmpty {
            // Frontier converged — no more nodes to query
            if state.inFlight.isEmpty {
                let cont = state.continuation
                state.continuation = nil
                activeLookups[lookupID] = nil
                cont?.resume(returning: .notFound(state.closest))
            }
            return
        }

        for contact in candidates {
            state.inFlight.insert(contact.nodeID)
            activeLookups[lookupID] = state

            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(DHTEngine.queryTimeout * 1_000_000_000))
                guard let self else { return }
                await self.queryTimedOut(peerNodeID: contact.nodeID, lookupID: lookupID)
            }
            pendingQueries[contact.nodeID] = PendingQuery(
                lookupID: lookupID, wantValue: state.wantValue, timeoutTask: timeoutTask
            )

            let msg: WireMessage?
            if state.wantValue {
                let p = DHTFindValuePayload(targetNodeID: state.target.hexString,
                                            peerIDPrefix: state.peerIDPrefix)
                msg = try? wireBuilder.build(.dhtFindValue, payload: p)
            } else {
                let p = DHTFindNodePayload(targetNodeID: state.target.hexString)
                msg = try? wireBuilder.build(.dhtFindNode, payload: p)
            }
            guard let wireMsg = msg else { continue }
            let capturedContact = contact
            Task { await self.send(wireMsg, capturedContact) }
        }
    }

    /// Called when a response arrives — updates lookup state and advances the frontier.
    private func resolvePendingQuery(
        peerNodeID:   String,
        closestNodes: [DHTContact],
        bundle:       PreKeyBundle?
    ) {
        guard let pending = pendingQueries[peerNodeID] else { return }
        pending.timeoutTask.cancel()
        pendingQueries.removeValue(forKey: peerNodeID)

        guard var state = activeLookups[pending.lookupID] else { return }
        state.inFlight.remove(peerNodeID)
        state.queried.insert(peerNodeID)

        // Insert newly discovered contacts into routing table (fire-and-forget)
        for c in closestNodes {
            let contact = c
            Task { await self.table.insert(contact) }
        }

        // If value found — done
        if pending.wantValue, let bundle {
            // Find the nodeID from any stored entry or derive from peerID prefix
            let nodeID = state.peerIDPrefix.flatMap { prefix in
                closestNodes.first { $0.nodeID.hasPrefix(prefix) }?.nodeID
            } ?? peerNodeID
            let cont = state.continuation
            state.continuation = nil
            activeLookups[pending.lookupID] = nil
            cont?.resume(returning: .found(dhtNodeID: nodeID, bundle: bundle))
            return
        }

        // Merge new contacts into closest, keep k best
        let newContacts = closestNodes.filter { !state.queried.contains($0.nodeID) }
        state.closest = (state.closest + newContacts)
            .sorted { a, b in
                guard let aID = try? DHTNodeID.from(hex: a.nodeID),
                      let bID = try? DHTNodeID.from(hex: b.nodeID) else { return false }
                return state.target.xorDistance(to: aID).lexicographicallyPrecedes(
                    state.target.xorDistance(to: bID)
                )
            }
            .prefix(DHTEngine.k)
            .map { $0 }

        activeLookups[pending.lookupID] = state
        sendNextQueries(lookupID: pending.lookupID)
    }

    private func queryTimedOut(peerNodeID: String, lookupID: String) async {
        await table.markFailed(nodeID: peerNodeID)
        resolvePendingQuery(peerNodeID: peerNodeID, closestNodes: [], bundle: nil)
    }

    // MARK: - Bootstrap

    private func bootstrap(contacts: [DHTContact]) async {
        for contact in contacts { await table.insert(contact) }
        // Self-lookup to discover nodes close to us
        _ = try? await iterativeLookup(target: localNodeID, wantValue: false)
    }

    // MARK: - Periodic Tasks

    private func schedulePublish() {
        publishTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(DHTEngine.publishInterval * 1_000_000_000))
                guard let self, await !self.stopped else { return }
                // ChatManager calls publishSelf(bundle:) — engine doesn't hold the bundle
                // so it just purges expired store entries here
                await self.store.purgeExpired()
            }
        }
    }

    private func scheduleRefresh() {
        refreshTask = Task { [weak self] in
            var bucketIdx = 0
            while true {
                try? await Task.sleep(nanoseconds: UInt64(DHTEngine.refreshInterval * 1_000_000_000))
                guard let self, await !self.stopped else { return }
                // 1. Ping the least-recently-seen node in this bucket (liveness check).
                //    Unresponsive nodes accumulate failCount and are evicted at 3.
                if let lrs = await self.table.leastRecentlySeen(in: bucketIdx) {
                    await self.pingForRefresh(lrs)
                }
                // 2. FIND_NODE to a random target in this bucket's ID space —
                //    discovers new nodes and fills sparse buckets.
                let nodeID = await self.localNodeID
                if let target = Self.randomTargetInBucket(bucketIdx, localNodeID: nodeID) {
                    _ = try? await self.iterativeLookup(target: target, wantValue: false)
                }
                bucketIdx = (bucketIdx + 1) % 256
            }
        }
    }

    /// Sends a dhtPing to `contact` and registers a timeout.
    /// On pong, `resolvePendingQuery` cancels the timeout via the normal path.
    /// On timeout, `queryTimedOut` calls `table.markFailed` — eviction after 3 strikes.
    private func pingForRefresh(_ contact: DHTContact) async {
        // Re-use the pendingQueries mechanism with a sentinel lookupID that has no
        // corresponding activeLookup entry — resolvePendingQuery gracefully no-ops for
        // the lookup advancement but still cancels the timeout task.
        let sentinelID = "ping_\(contact.nodeID)"
        guard pendingQueries[contact.nodeID] == nil else { return }  // already in-flight

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DHTEngine.queryTimeout * 1_000_000_000))
            guard let self else { return }
            await self.queryTimedOut(peerNodeID: contact.nodeID, lookupID: sentinelID)
        }
        pendingQueries[contact.nodeID] = PendingQuery(
            lookupID: sentinelID, wantValue: false, timeoutTask: timeoutTask
        )

        let payload = DHTPingPayload(senderNodeID: localNodeID.hexString)
        guard let msg = try? wireBuilder.build(.dhtPing, payload: payload) else {
            pendingQueries.removeValue(forKey: contact.nodeID)
            timeoutTask.cancel()
            return
        }
        await send(msg, contact)
    }

    // MARK: - Helpers

    /// Returns a DHTContact for a peer by consulting the routing table.
    /// Falls back to constructing a minimal contact from the known onion address if unavailable.
    private func contactInfo(for peerID: String, nodeID: String?) async -> DHTContact? {
        let all = await table.allContacts()
        return all.first { $0.nodeID.hasPrefix(peerID) || $0.nodeID == nodeID }
    }

    /// Generate a random target node ID within the keyspace covered by bucket `idx`.
    private static func randomTargetInBucket(_ idx: Int, localNodeID: DHTNodeID) -> DHTNodeID? {
        var bytes = [UInt8](localNodeID.bytes)
        // Flip the bit at position `idx` to land in the right bucket, randomise lower bits
        let bytePos = 31 - (idx / 8)
        let bitPos  = idx % 8
        bytes[bytePos] ^= (1 << bitPos)
        // Randomise bits below idx
        for i in stride(from: bytePos + 1, to: bytes.count, by: 1) {
            bytes[i] = UInt8.random(in: 0...255)
        }
        if bitPos > 0 {
            let mask = UInt8((1 << bitPos) - 1)
            bytes[bytePos] = (bytes[bytePos] & ~mask) | (UInt8.random(in: 0...255) & mask)
        }
        return try? DHTNodeID(bytes: Data(bytes))
    }
}

// MARK: - DHTContact extensions

private extension DHTContact {
    var asDHTNodeInfo: DHTNodeInfo {
        DHTNodeInfo(nodeID: nodeID, onionAddress: onionAddress, port: port)
    }
}

private extension DHTNodeInfo {
    var asDHTContact: DHTContact? {
        guard onionAddress.hasSuffix(".onion"), onionAddress.count == 62 else { return nil }
        return DHTContact(nodeID: nodeID, onionAddress: onionAddress, port: port)
    }
}
