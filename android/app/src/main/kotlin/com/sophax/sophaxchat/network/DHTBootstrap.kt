package com.sophax.sophaxchat.network

// DHTBootstrap.kt
// SophaxChat — Android
//
// Hardcoded DHT bootstrap nodes operated by the SophaxChat project.
// These are NOT trusted for content — only for initial routing table population.
// Replace placeholder addresses with real nodes before public release.
//
// Bootstrap node requirements:
//   - Always-on (Raspberry Pi / VPS)
//   - Running SophaxChat in headless mode with a fixed identity
//   - Accessible as a Tor v3 hidden service on port 25519

object DHTBootstrap {

    /** Minimum number of responsive bootstrap contacts before we consider
     *  the DHT reachable. Below this, lookups may time out. */
    const val MIN_RESPONSIVE_NODES = 1

    /** Well-known bootstrap nodes. Replace before release. */
    val nodes: List<DHTContact> = listOf(
        // Bootstrap node 1 — placeholder
        DHTContact(
            nodeID       = "a".repeat(64),
            onionAddress = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion",
            port         = 25519
        ),
        // Bootstrap node 2 — placeholder
        DHTContact(
            nodeID       = "b".repeat(64),
            onionAddress = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.onion",
            port         = 25519
        ),
        // Bootstrap node 3 — placeholder
        DHTContact(
            nodeID       = "c".repeat(64),
            onionAddress = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.onion",
            port         = 25519
        )
    )
}
