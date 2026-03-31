// MLSGroupManager.swift
// SophaxChatCore
//
// Swift actor wrapper around the UniFFI-generated mls-rs bindings.
//
// Design — stateless Rust layer, stateful Swift layer:
//   - Every UniFFI function takes a serialised group_state blob and returns a new one.
//   - MLSGroupManager owns persistence: Keychain via KeychainManager ("mls.state.<groupID>").
//   - MlsClientHandle is a thin Arc<> in Rust; safe to hold long-term in the actor.
//
// Threading: all methods are actor-isolated — no external locking needed.

import Foundation

/// Coordinator-aware MLS group manager.
///
/// Only the group creator (coordinator) may call `createGroup`, `addMember`, `removeMember`.
/// All members call `processWelcome`, `processCommit`, `encrypt`, `decrypt`.
public actor MLSGroupManager {

    private let client: MlsClientHandle
    private let keychain: KeychainManager

    // MARK: - Init

    /// - Parameters:
    ///   - peerID: Local peer's identifier (UTF-8, same as used in identity layer).
    ///   - signingKeyBytes: Raw 32-byte Ed25519 private key seed from IdentityManager.
    ///   - keychain: Shared KeychainManager for group-state persistence.
    public init(peerID: String, signingKeyBytes: Data, keychain: KeychainManager) throws {
        self.client = try MlsClientHandle(peerId: peerID, signingKeyBytes: signingKeyBytes)
        self.keychain = keychain
    }

    // MARK: - KeyPackage

    /// Generate a fresh single-use MLS KeyPackage for this identity.
    /// The caller should include this in the next Hello/PreKeyBundle so the
    /// group coordinator can add this peer to an MLS group.
    public func generateKeyPackage() throws -> Data {
        try client.generateKeyPackage()
    }

    // MARK: - Coordinator-only: group lifecycle

    /// Create a new MLS group and produce a Welcome for each initial member.
    ///
    /// - Parameters:
    ///   - groupID: UUID string identifying the group (same as GroupInfo.id).
    ///   - memberKeyPackages: Raw KeyPackage bytes for each invited peer
    ///     (obtained from their PreKeyBundle.mlsKeyPackage).
    /// - Returns: `CreateGroupOutput` containing the coordinator's initial group state
    ///   and one `MemberWelcome` per invitee. Send each Welcome via DR unicast.
    public func createGroup(groupID: String, memberKeyPackages: [Data]) throws -> CreateGroupOutput {
        let groupIdData = groupID.data(using: .utf8) ?? Data(groupID.utf8)
        let output = try mlsCreateGroup(client: client, groupId: groupIdData, memberKeyPackages: memberKeyPackages)
        try saveState(output.groupState, groupID: groupID)
        return output
    }

    /// Add a member to an existing MLS group (coordinator only).
    ///
    /// - Parameters:
    ///   - groupID: Group to update.
    ///   - keyPackage: The new member's MLS KeyPackage bytes.
    /// - Returns: `CommitOutput` with `commitBytes` to broadcast and `welcomeBytes` to
    ///   unicast to the new member.
    public func addMember(groupID: String, keyPackage: Data) throws -> CommitOutput {
        let state = try loadState(groupID: groupID)
        let groupIdData = groupID.data(using: .utf8) ?? Data(groupID.utf8)
        let output = try mlsAddMember(client: client, groupId: groupIdData, groupState: state, keyPackageBytes: keyPackage)
        try saveState(output.newGroupState, groupID: groupID)
        return output
    }

    /// Remove a member from an existing MLS group (coordinator only).
    ///
    /// - Parameters:
    ///   - groupID: Group to update.
    ///   - peerID: PeerID of the member to remove.
    /// - Returns: `CommitOutput` with `commitBytes` to broadcast. `welcomeBytes` is always nil.
    public func removeMember(groupID: String, peerID: String) throws -> CommitOutput {
        let state = try loadState(groupID: groupID)
        let groupIdData = groupID.data(using: .utf8) ?? Data(groupID.utf8)
        let output = try mlsRemoveMember(client: client, groupId: groupIdData, groupState: state, peerId: peerID)
        try saveState(output.newGroupState, groupID: groupID)
        return output
    }

    // MARK: - Any member: join & update

    /// Process a Welcome message received via DR unicast and join the group.
    ///
    /// - Parameters:
    ///   - welcomeBytes: Raw bytes from `MemberWelcome.welcomeBytes`.
    ///   - ratchetTree: Raw bytes from `MemberWelcome.ratchetTreeBytes` (may be nil).
    /// - Returns: The groupID as `Data` (UTF-8 string bytes as used in the group).
    @discardableResult
    public func processWelcome(_ welcomeBytes: Data, ratchetTree: Data?) throws -> Data {
        let newState = try mlsProcessWelcome(client: client, welcomeBytes: welcomeBytes, ratchetTreeBytes: ratchetTree)
        // Extract groupID: we need it to key the stored state.
        // The state blob is opaque; we must ask the caller to provide the groupID
        // from the accompanying MLSWelcomeMessage envelope.
        // Store under a temp key — callers MUST call storeWelcomeState after.
        pendingWelcomeState = newState
        return newState  // caller uses the accompanying groupID from the wire message
    }

    /// Temporary storage for a just-processed Welcome state, before the caller
    /// knows which groupID to associate it with.
    /// Call `commitWelcomeState(groupID:)` immediately after `processWelcome`.
    private var pendingWelcomeState: Data?

    /// Persist the Welcome state under the given groupID.
    /// Must be called once after every `processWelcome` call.
    public func commitWelcomeState(groupID: String) throws {
        guard let state = pendingWelcomeState else {
            throw SophaxError.invalidMessageFormat("No pending MLS welcome state to commit")
        }
        try saveState(state, groupID: groupID)
        pendingWelcomeState = nil
    }

    /// Process a Commit broadcast from the coordinator.
    ///
    /// - Parameters:
    ///   - groupID: Group this commit belongs to.
    ///   - commitBytes: Raw Commit message bytes from `MLSCommitMessage.commitBytes`.
    /// - Returns: `ProcessedCommit` containing added/removed peerIDs and the new epoch.
    public func processCommit(groupID: String, commitBytes: Data) throws -> ProcessedCommit {
        let state = try loadState(groupID: groupID)
        let groupIdData = groupID.data(using: .utf8) ?? Data(groupID.utf8)
        let result = try mlsProcessCommit(client: client, groupId: groupIdData, groupState: state, commitBytes: commitBytes)
        try saveState(result.newGroupState, groupID: groupID)
        return result
    }

    // MARK: - Any member: encrypt / decrypt

    /// Encrypt an application message for the group.
    ///
    /// - Parameters:
    ///   - groupID: Target group.
    ///   - plaintext: Raw message bytes (typically UTF-8 JSON envelope).
    /// - Returns: Opaque MLS ciphertext to broadcast as `MLSApplicationMessage.ciphertext`.
    public func encrypt(groupID: String, plaintext: Data) throws -> Data {
        let state = try loadState(groupID: groupID)
        let groupIdData = groupID.data(using: .utf8) ?? Data(groupID.utf8)
        let output = try mlsEncrypt(client: client, groupId: groupIdData, groupState: state, plaintext: plaintext)
        try saveState(output.newGroupState, groupID: groupID)
        return output.ciphertext
    }

    /// Decrypt an MLS application message.
    ///
    /// - Parameters:
    ///   - groupID: Group this message belongs to.
    ///   - ciphertext: Raw ciphertext from `MLSApplicationMessage.ciphertext`.
    /// - Returns: Decrypted plaintext bytes.
    public func decrypt(groupID: String, ciphertext: Data) throws -> Data {
        let state = try loadState(groupID: groupID)
        let groupIdData = groupID.data(using: .utf8) ?? Data(groupID.utf8)
        let output = try mlsDecrypt(client: client, groupId: groupIdData, groupState: state, ciphertext: ciphertext)
        try saveState(output.newGroupState, groupID: groupID)
        return output.plaintext
    }

    // MARK: - State lifecycle

    /// Delete persisted MLS state for a group (called on leave or account wipe).
    public func deleteGroupState(groupID: String) throws {
        try keychain.deleteMlsGroupState(groupID: groupID)
    }

    /// Returns true if a persisted MLS state exists for the given group.
    public func hasGroup(groupID: String) -> Bool {
        keychain.loadMlsGroupState(groupID: groupID) != nil
    }

    // MARK: - Private helpers

    private func loadState(groupID: String) throws -> Data {
        guard let state = keychain.loadMlsGroupState(groupID: groupID) else {
            throw SophaxError.invalidMessageFormat("No MLS group state for group \(groupID)")
        }
        return state
    }

    private func saveState(_ state: Data, groupID: String) throws {
        try keychain.saveMlsGroupState(state, groupID: groupID)
    }
}
