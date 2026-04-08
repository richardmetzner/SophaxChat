// DHTBootstrap.swift
// SophaxChatCore
//
// Hardcoded DHT bootstrap nodes operated by the SophaxChat project.
// These are NOT trusted for content — only for initial routing table population.
// Replace placeholder addresses with real nodes before public release.
//
// Bootstrap node requirements:
//   - Always-on (Raspberry Pi / VPS)
//   - Running SophaxChat in headless mode with a fixed identity
//   - Accessible as a Tor v3 hidden service on port 25519

import Foundation

public enum DHTBootstrap {

    /// Minimum number of responsive bootstrap contacts before we consider
    /// the DHT reachable. Below this, lookups may time out.
    public static let minResponsiveNodes = 1

    /// Well-known bootstrap nodes. Replace before release.
    public static let nodes: [DHTContact] = [
        // Bootstrap node 1 — placeholder
        DHTContact(
            nodeID:       String(repeating: "a", count: 64),
            onionAddress: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion",
            port:         25519
        ),
        // Bootstrap node 2 — placeholder
        DHTContact(
            nodeID:       String(repeating: "b", count: 64),
            onionAddress: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.onion",
            port:         25519
        ),
        // Bootstrap node 3 — placeholder
        DHTContact(
            nodeID:       String(repeating: "c", count: 64),
            onionAddress: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.onion",
            port:         25519
        ),
    ]
}
