// MLSGroupManagerTests.swift
// SophaxChatCoreTests
//
// Unit tests for MLSGroupManager — exercises the full mls-rs Rust layer
// via the UniFFI Swift bindings in-process.
//
// Scenarios:
//  1. Two-party group: Alice creates, Bob joins via Welcome → bidirectional encrypt/decrypt
//  2. Three-party group: Carol is added → all three can communicate
//  3. Removal: Bob is removed → Bob can no longer decrypt new messages

import Testing
import Foundation
import CryptoKit
@testable import SophaxChatCore

// MARK: - Helpers

/// Deterministic 32-byte signing key seed from a label.
private func signingKey(label: String) -> Data {
    let hash = SHA256.hash(data: Data(label.utf8))
    return Data(hash)
}

/// Fresh MLSGroupManager backed by an in-memory KeychainManager substitute.
private func makeManager(peerID: String) throws -> MLSGroupManager {
    let keychain = KeychainManager(service: "com.sophax.test.\(UUID().uuidString)")
    return try MLSGroupManager(
        peerID: peerID,
        signingKeyBytes: signingKey(label: peerID),
        keychain: keychain
    )
}

// MARK: - Tests

@Suite("MLSGroupManager")
struct MLSGroupManagerTests {

    // MARK: Two-party: Alice creates, Bob joins

    @Test("Two-party group: bidirectional encrypt/decrypt")
    func twoPartyBidirectional() async throws {
        let alice = try makeManager(peerID: "alice")
        let bob   = try makeManager(peerID: "bob")

        let groupID = UUID().uuidString

        // Bob generates a KeyPackage so Alice can invite him
        let bobKP = try await bob.generateKeyPackage()

        // Alice creates the group with Bob
        let createOut = try await alice.createGroup(groupID: groupID, memberKeyPackages: [bobKP])
        #expect(createOut.welcomes.count == 1)

        let bobWelcome = createOut.welcomes[0]
        #expect(bobWelcome.peerId == "bob")

        // Bob processes the Welcome (ratchetTreeBytes is always present from mls-rs)
        try await bob.processWelcome(bobWelcome.welcomeBytes, ratchetTree: bobWelcome.ratchetTreeBytes)
        try await bob.commitWelcomeState(groupID: groupID)

        // Alice → Bob
        let msg1 = Data("Hello Bob!".utf8)
        let ct1  = try await alice.encrypt(groupID: groupID, plaintext: msg1)
        let pt1  = try await bob.decrypt(groupID: groupID, ciphertext: ct1)
        #expect(pt1 == msg1)

        // Bob → Alice
        let msg2 = Data("Hello Alice!".utf8)
        let ct2  = try await bob.encrypt(groupID: groupID, plaintext: msg2)
        let pt2  = try await alice.decrypt(groupID: groupID, ciphertext: ct2)
        #expect(pt2 == msg2)

        // Multiple messages in sequence
        for i in 0..<5 {
            let m = Data("msg-\(i)".utf8)
            let c = try await alice.encrypt(groupID: groupID, plaintext: m)
            let d = try await bob.decrypt(groupID: groupID, ciphertext: c)
            #expect(d == m)
        }
    }

    // MARK: Three-party: Carol is added

    @Test("Three-party group: add member and communicate")
    func threePartyAdd() async throws {
        let alice = try makeManager(peerID: "alice")
        let bob   = try makeManager(peerID: "bob")
        let carol = try makeManager(peerID: "carol")

        let groupID = UUID().uuidString

        // Alice creates group with Bob
        let bobKP = try await bob.generateKeyPackage()
        let createOut = try await alice.createGroup(groupID: groupID, memberKeyPackages: [bobKP])
        let bobWelcome = createOut.welcomes[0]
        try await bob.processWelcome(bobWelcome.welcomeBytes, ratchetTree: bobWelcome.ratchetTreeBytes)
        try await bob.commitWelcomeState(groupID: groupID)

        // Alice adds Carol (coordinator role)
        let carolKP = try await carol.generateKeyPackage()
        let addOut = try await alice.addMember(groupID: groupID, keyPackage: carolKP)

        // Bob processes the Commit from Alice
        let commitResult = try await bob.processCommit(groupID: groupID, commitBytes: addOut.commitBytes)
        #expect(commitResult.addedPeerIds.contains("carol"))

        // Carol processes her Welcome (welcomeBytes is non-nil for AddMember commits)
        guard let carolWelcomeBytes = addOut.welcomeBytes else {
            Issue.record("Expected welcomeBytes in AddMember CommitOutput")
            return
        }
        try await carol.processWelcome(carolWelcomeBytes, ratchetTree: nil)
        try await carol.commitWelcomeState(groupID: groupID)

        // All three can now communicate
        let msgA = Data("from alice".utf8)
        let ctA  = try await alice.encrypt(groupID: groupID, plaintext: msgA)
        #expect(try await bob.decrypt(groupID: groupID, ciphertext: ctA) == msgA)
        #expect(try await carol.decrypt(groupID: groupID, ciphertext: ctA) == msgA)

        let msgC = Data("from carol".utf8)
        let ctC  = try await carol.encrypt(groupID: groupID, plaintext: msgC)
        #expect(try await alice.decrypt(groupID: groupID, ciphertext: ctC) == msgC)
        #expect(try await bob.decrypt(groupID: groupID, ciphertext: ctC) == msgC)
    }

    // MARK: Removal: Bob removed, can no longer decrypt

    @Test("Remove member: removed peer cannot decrypt new messages")
    func removeMember() async throws {
        let alice = try makeManager(peerID: "alice")
        let bob   = try makeManager(peerID: "bob")

        let groupID = UUID().uuidString

        let bobKP = try await bob.generateKeyPackage()
        let createOut = try await alice.createGroup(groupID: groupID, memberKeyPackages: [bobKP])
        let bobWelcome = createOut.welcomes[0]
        try await bob.processWelcome(bobWelcome.welcomeBytes, ratchetTree: bobWelcome.ratchetTreeBytes)
        try await bob.commitWelcomeState(groupID: groupID)

        // Pre-removal: Bob can decrypt Alice
        let preMsgA = Data("pre-removal".utf8)
        let preCtA  = try await alice.encrypt(groupID: groupID, plaintext: preMsgA)
        #expect(try await bob.decrypt(groupID: groupID, ciphertext: preCtA) == preMsgA)

        // Alice removes Bob (coordinator)
        let removeOut = try await alice.removeMember(groupID: groupID, peerID: "bob")
        #expect(removeOut.newEpoch > 0)

        // Post-removal: Bob's state is stale — decrypting a new message should throw
        let postMsgA = Data("post-removal secret".utf8)
        let postCtA  = try await alice.encrypt(groupID: groupID, plaintext: postMsgA)
        await #expect(throws: (any Error).self) {
            try await bob.decrypt(groupID: groupID, ciphertext: postCtA)
        }
    }

    // MARK: Epoch increments on commit

    @Test("Epoch increments after each commit")
    func epochIncrements() async throws {
        let alice = try makeManager(peerID: "alice")
        let bob   = try makeManager(peerID: "bob")

        let groupID = UUID().uuidString
        let bobKP = try await bob.generateKeyPackage()
        let createOut = try await alice.createGroup(groupID: groupID, memberKeyPackages: [bobKP])
        let bobWelcome = createOut.welcomes[0]
        try await bob.processWelcome(bobWelcome.welcomeBytes, ratchetTree: bobWelcome.ratchetTreeBytes)
        try await bob.commitWelcomeState(groupID: groupID)

        // Remove Bob — epoch should increment
        let removeOut = try await alice.removeMember(groupID: groupID, peerID: "bob")
        #expect(removeOut.newEpoch >= 1)
    }

    // MARK: KeyPackage generation

    @Test("generateKeyPackage returns non-empty data")
    func generateKeyPackage() async throws {
        let alice = try makeManager(peerID: "alice")
        let kp = try await alice.generateKeyPackage()
        #expect(!kp.isEmpty)
    }

    // MARK: hasGroup / deleteGroupState

    @Test("hasGroup and deleteGroupState lifecycle")
    func groupLifecycle() async throws {
        let alice = try makeManager(peerID: "alice")
        let bob   = try makeManager(peerID: "bob")

        let groupID = UUID().uuidString
        #expect(await alice.hasGroup(groupID: groupID) == false)

        let bobKP = try await bob.generateKeyPackage()
        _ = try await alice.createGroup(groupID: groupID, memberKeyPackages: [bobKP])
        #expect(await alice.hasGroup(groupID: groupID) == true)

        try await alice.deleteGroupState(groupID: groupID)
        #expect(await alice.hasGroup(groupID: groupID) == false)
    }
}
