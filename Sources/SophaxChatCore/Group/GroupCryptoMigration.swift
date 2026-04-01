// GroupCryptoMigration.swift
// SophaxChatCore
//
// Phase 5: Opt-in migration from Sender Keys v2 to MLS for existing groups.
//
// Design:
//   - Only the group creator can initiate migration (they are the MLS coordinator).
//   - All current members must have an MLS KeyPackage available (from their Hello bundle).
//   - A new MLS group is created with the same name and members; the old SKv2 group is
//     left in place so existing message history remains accessible.
//   - SKv2 Keychain state for the old group expires naturally (7-day rotation window).
//   - The UI flow for presenting migration to users is a future sprint concern.

import Foundation

// MARK: - Result type

public enum GroupMigrationResult: Sendable {
    /// The group is already running MLS — nothing to do.
    case notNeeded
    /// One or more members lack an MLS KeyPackage; wait until they reconnect.
    case requiresAllOnline([String])   // peerIDs that are missing a KeyPackage
    /// Migration initiated — new MLS group was created and Welcomes are being distributed.
    case initiated(newGroup: GroupInfo)
}

// MARK: - Migration entry point

/// Attempt to migrate `group` from Sender Keys v2 to MLS.
///
/// - Parameters:
///   - group:       The existing SKv2 GroupInfo to migrate.
///   - chatManager: The active ChatManager instance (must be the group creator's).
/// - Returns: A `GroupMigrationResult` describing the outcome.
/// - Throws: If the local identity's signing key is unavailable.
@discardableResult
public func migrateGroupToMLS(
    _ group: GroupInfo,
    in chatManager: ChatManager
) throws -> GroupMigrationResult {

    // Already MLS — nothing to do.
    guard group.cryptoVersion == .senderKeysV2 else { return .notNeeded }

    // Only the coordinator (creator) may initiate MLS migration.
    let myID = chatManager.identity.publicIdentity.peerID
    guard group.creatorID == myID else {
        throw SophaxError.invalidMessageFormat("Only the group creator can initiate MLS migration")
    }

    // Verify every non-self member has a KeyPackage in their stored PreKeyBundle.
    let otherMembers = group.memberIDs.filter { $0 != myID }
    let missing = otherMembers.filter { peerID in
        chatManager.peerBundles[peerID]?.mlsKeyPackage == nil
    }
    guard missing.isEmpty else { return .requiresAllOnline(missing) }

    // Create the new MLS group (same name, same members, new groupID).
    guard let newGroup = chatManager.createMLSGroup(
        name: group.name,
        memberPeerIDs: otherMembers
    ) else {
        throw SophaxError.encryptionFailed("MLS group creation failed during migration")
    }

    return .initiated(newGroup: newGroup)
}
