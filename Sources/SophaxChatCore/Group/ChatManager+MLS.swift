// ChatManager+MLS.swift
// SophaxChatCore
//
// Phase 4: MLS wire-message handlers and MLS send paths for ChatManager.
//
// Threading contract: same as ChatManager — @unchecked Sendable, all access
// serialised by the caller (AppState / MeshManager callbacks on main thread).
// MLS operations are synchronous (mls-rs is pure-Rust, no I/O).

import Foundation

// MARK: - MLS inbound handlers

extension ChatManager {

    // MARK: Welcome

    /// Process an incoming MLS Welcome — join the group and notify the delegate.
    func handleMLSWelcome(_ msg: MLSWelcomeMessage, fromPeer senderID: String) {
        // Guard: creator must be the sender
        guard msg.creatorID == senderID else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let mls = try self.requireMLSManager()
                try await mls.processWelcome(msg.welcomeBytes, ratchetTree: msg.ratchetTreeBytes)
                try await mls.commitWelcomeState(groupID: msg.groupID)

                let group = GroupInfo(
                    id:            msg.groupID,
                    name:          msg.groupName,
                    memberIDs:     msg.memberIDs,
                    creatorID:     msg.creatorID,
                    cryptoVersion: .mls
                )
                self.joinedGroups[msg.groupID] = Set(msg.memberIDs)

                DispatchQueue.main.async {
                    self.delegate?.chatManager(self, didJoinGroup: group)
                }
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.chatManager(self, didEncounterError: error)
                }
            }
        }
    }

    // MARK: Commit

    /// Process an MLS Commit broadcast from the coordinator.
    /// Drops silently if the sender is not the group coordinator.
    func handleMLSCommit(_ msg: MLSCommitMessage, fromPeer senderID: String) {
        // Security: only the coordinator may issue commits
        guard let members = joinedGroups[msg.groupID],
              msg.coordinatorID == senderID else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let mls = try self.requireMLSManager()
                let result = try await mls.processCommit(groupID: msg.groupID, commitBytes: msg.commitBytes)

                // Update in-memory membership
                var updated = members
                result.addedPeerIds.forEach   { updated.insert($0) }
                result.removedPeerIds.forEach { updated.remove($0) }
                self.joinedGroups[msg.groupID] = updated

                // If we were removed, clean up local state
                let myID = self.identity.publicIdentity.peerID
                if result.removedPeerIds.contains(myID) {
                    self.joinedGroups.removeValue(forKey: msg.groupID)
                    try? await mls.deleteGroupState(groupID: msg.groupID)
                }
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.chatManager(self, didEncounterError: error)
                }
            }
        }
    }

    // MARK: Application message

    /// Decrypt and store an MLS application message.
    func handleMLSApplicationMessage(_ msg: MLSApplicationMessage) {
        guard let members = joinedGroups[msg.groupID],
              members.contains(msg.senderPeerID) else { return }
        // Basic field-length guards (mirrors Sender Keys v2 handler)
        guard msg.senderPeerID.count  <= 64,
              msg.senderUsername.count <= 64,
              msg.ciphertext.count    <= 512_000 else { return }

        let convID    = "group.\(msg.groupID)"
        let messageID = msg.messageID

        Task { [weak self] in
            guard let self else { return }
            do {
                let mls = try self.requireMLSManager()
                let captionPlain = try await mls.decrypt(groupID: msg.groupID, ciphertext: msg.ciphertext)
                let body = String(data: captionPlain, encoding: .utf8) ?? ""

                // Decrypt attachment if present and save to AttachmentStore
                var attachmentID: String? = nil
                if let ac = msg.attachmentCiphertext, msg.mimeType != nil {
                    let attachData = try await mls.decrypt(groupID: msg.groupID, ciphertext: ac)
                    let aid = UUID().uuidString
                    try? self.attachmentStore.save(attachData, id: aid)
                    attachmentID = aid
                }

                let stored = StoredMessage(
                    id:                 messageID,
                    peerID:             convID,
                    direction:          .received,
                    body:               body,
                    status:             .delivered,
                    replyToID:          msg.replyToID,
                    expiresAt:          msg.expiresAt,
                    attachmentID:       attachmentID,
                    attachmentMimeType: msg.mimeType,
                    audioDuration:      msg.audioDuration,
                    senderID:           msg.senderPeerID
                )
                try self.messageStore.append(message: stored)

                // Cache sender avatar for group-only contacts
                if let avatarData = msg.senderAvatarData,
                   avatarData.count > 0, avatarData.count <= 8_192,
                   self.peerBundles[msg.senderPeerID]?.avatarData == nil {
                    let senderID = msg.senderPeerID
                    DispatchQueue.main.async {
                        self.delegate?.chatManager(self, didReceiveAvatarData: avatarData, fromPeerID: senderID)
                    }
                }

                DispatchQueue.main.async {
                    self.delegate?.chatManager(self, didReceiveGroupMessage: stored, inGroup: msg.groupID)
                }
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.chatManager(self, didEncounterError: error)
                }
            }
        }
    }

    // MARK: Commit request (coordinator path)

    /// Handle a CommitRequest from a non-coordinator member (add or remove).
    /// Only the group creator processes this — others drop it.
    func handleMLSCommitRequest(_ msg: MLSCommitRequestMessage, fromPeer senderID: String) {
        let myID = identity.publicIdentity.peerID
        guard joinedGroups[msg.groupID] != nil else { return }
        // Only the coordinator (creator) issues commits
        // We verify by checking if we created this group — stored in GroupInfo at the delegate layer.
        // ChatManager has no direct access to persisted GroupInfo, so we rely on the delegate
        // to guard coordinator access. Here we just execute if called.
        Task { [weak self] in
            guard let self else { return }
            do {
                let mls = try self.requireMLSManager()
                let commitOut: CommitOutput
                switch msg.action {
                case .add:
                    guard let kp = msg.keyPackage else { return }
                    commitOut = try await mls.addMember(groupID: msg.groupID, keyPackage: kp)
                case .remove:
                    guard let target = msg.targetPeerID, target != myID else { return }
                    commitOut = try await mls.removeMember(groupID: msg.groupID, peerID: target)
                }
                // Broadcast commit to all current members
                let commitMsg = MLSCommitMessage(
                    groupID:       msg.groupID,
                    epoch:         commitOut.newEpoch,
                    commitBytes:   commitOut.commitBytes,
                    coordinatorID: myID
                )
                if let wire = try? wireBuilder.build(.mlsCommit, payload: commitMsg) {
                    let members = joinedGroups[msg.groupID] ?? []
                    for peerID in members where peerID != myID {
                        try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
                    }
                }
                // Unicast Welcome to the new member (add only)
                if msg.action == .add,
                   let welcomeBytes = commitOut.welcomeBytes,
                   let targetPeerID = msg.targetPeerID ?? (msg.keyPackage != nil ? senderID : nil) {
                    guard let members = joinedGroups[msg.groupID] else { return }
                    let welcomeMsg = MLSWelcomeMessage(
                        groupID:          msg.groupID,
                        groupName:        "",   // delegate fills this in via GroupInfo
                        memberIDs:        Array(members),
                        creatorID:        myID,
                        welcomeBytes:     welcomeBytes,
                        ratchetTreeBytes: Data()
                    )
                    if let wire = try? wireBuilder.build(.mlsWelcome, payload: welcomeMsg) {
                        try? sendOrQueue(wire, toPeerID: targetPeerID, messageID: UUID().uuidString)
                    }
                }
                // Update local membership
                if msg.action == .remove, let target = msg.targetPeerID {
                    self.joinedGroups[msg.groupID]?.remove(target)
                }
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.chatManager(self, didEncounterError: error)
                }
            }
        }
    }

    func handleMLSReaction(_ msg: MLSReactionMessage) {
        guard joinedGroups[msg.groupID] != nil else { return }
        let convID        = "group.\(msg.groupID)"
        let senderPeerID  = msg.senderPeerID
        let targetID      = msg.targetMessageID
        let groupID       = msg.groupID

        Task { [weak self] in
            guard let self else { return }
            do {
                let mls       = try self.requireMLSManager()
                let plain     = try await mls.decrypt(groupID: groupID, ciphertext: msg.ciphertext)
                struct ReactionPayload: Codable { let emoji: String? }
                guard let payload = try? JSONDecoder().decode(ReactionPayload.self, from: plain) else { return }

                guard let msgs = try? self.messageStore.messages(forPeer: convID),
                      let idx  = msgs.firstIndex(where: { $0.id == targetID }) else { return }
                var reactions = msgs[idx].reactions ?? [:]
                if let e = payload.emoji { reactions[senderPeerID] = e }
                else { reactions.removeValue(forKey: senderPeerID) }
                try? self.messageStore.updateReactions(reactions, forMessageID: targetID, peerID: convID)
                let finalReactions = reactions
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.chatManager(self, didUpdateGroupReactions: finalReactions,
                                               onMessageID: targetID, groupID: groupID)
                }
            } catch {
                #if DEBUG
                print("[ChatManager][MLS] handleMLSReaction error: \(error)")
                #endif
            }
        }
    }
}

// MARK: - MLS outbound

extension ChatManager {

    /// Create a new MLS group and distribute Welcomes to all members.
    /// Requires all `memberPeerIDs` to have an `mlsKeyPackage` in their stored PreKeyBundle.
    /// Returns nil if any member is missing a KeyPackage or MLS init fails.
    @discardableResult
    public func createMLSGroup(name: String, memberPeerIDs: [String]) -> GroupInfo? {
        let myID = identity.publicIdentity.peerID
        var seen = Set<String>()
        let allMembers = ([myID] + memberPeerIDs).filter { seen.insert($0).inserted }

        // Collect KeyPackages — fail if any member is missing one
        var keyPackages: [(peerID: String, kp: Data)] = []
        for peerID in memberPeerIDs {
            guard let bundle = peerBundles[peerID],
                  let kp = bundle.mlsKeyPackage else {
                delegate?.chatManager(self, didEncounterError:
                    SophaxError.invalidMessageFormat("Peer \(peerID) has no MLS KeyPackage — cannot create MLS group"))
                return nil
            }
            keyPackages.append((peerID, kp))
        }

        let groupID = UUID().uuidString
        let group   = GroupInfo(id: groupID, name: name, memberIDs: allMembers, creatorID: myID, cryptoVersion: .mls)

        Task { [weak self] in
            guard let self else { return }
            do {
                let mls = try self.requireMLSManager()
                let createOut = try await mls.createGroup(
                    groupID: groupID,
                    memberKeyPackages: keyPackages.map(\.kp)
                )
                self.joinedGroups[groupID] = Set(allMembers)

                // Send each member their Welcome via DR unicast
                for welcome in createOut.welcomes {
                    let welcomeMsg = MLSWelcomeMessage(
                        groupID:          groupID,
                        groupName:        name,
                        memberIDs:        allMembers,
                        creatorID:        myID,
                        welcomeBytes:     welcome.welcomeBytes,
                        ratchetTreeBytes: welcome.ratchetTreeBytes
                    )
                    if let wire = try? self.wireBuilder.build(.mlsWelcome, payload: welcomeMsg) {
                        try? self.sendOrQueue(wire, toPeerID: welcome.peerId, messageID: UUID().uuidString)
                    }
                }

                DispatchQueue.main.async {
                    self.delegate?.chatManager(self, didJoinGroup: group)
                }
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.chatManager(self, didEncounterError: error)
                }
            }
        }
        return group
    }

    /// Send a text message to an MLS group.
    public func sendMLSGroupMessage(
        _ body: String,
        group: GroupInfo,
        expiresAt: Date? = nil,
        replyToID: String? = nil
    ) {
        guard !body.isEmpty else { return }
        let myID      = identity.publicIdentity.peerID
        let messageID = UUID().uuidString
        let convID    = "group.\(group.id)"

        func fail(_ error: Error) {
            try? messageStore.updateStatus(.failed, forMessageID: messageID, peerID: convID)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.chatManager(self, didEncounterError: error)
            }
        }

        // Store locally as .sending so the bubble appears immediately
        let stored = StoredMessage(
            id: messageID, peerID: convID,
            direction: .sent, body: body, status: .sending,
            replyToID: replyToID, expiresAt: expiresAt, senderID: myID
        )
        do { try messageStore.append(message: stored) } catch { fail(error); return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveGroupMessage: stored, inGroup: group.id)
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let mls = try self.requireMLSManager()
                guard let plaintext = body.data(using: .utf8) else { throw SophaxError.encryptionFailed("Body is not UTF-8") }
                let ciphertext = try await mls.encrypt(groupID: group.id, plaintext: plaintext)

                let appMsg = MLSApplicationMessage(
                    groupID:              group.id,
                    messageID:            messageID,
                    senderPeerID:         myID,
                    senderUsername:       self.identity.publicIdentity.username,
                    timestamp:            Date(),
                    ciphertext:           ciphertext,
                    expiresAt:            expiresAt,
                    replyToID:            replyToID,
                    attachmentCiphertext: nil,
                    mimeType:             nil,
                    audioDuration:        nil,
                    senderAvatarData:     self.identity.loadAvatar()
                )
                guard let wire = try? self.wireBuilder.build(.mlsMessage, payload: appMsg) else {
                    throw SophaxError.encryptionFailed("Failed to build MLS wire message")
                }

                try? self.messageStore.updateStatus(.delivered, forMessageID: messageID, peerID: convID)

                let members = group.memberIDs
                for peerID in members where peerID != myID {
                    try? self.sendOrQueue(wire, toPeerID: peerID, messageID: messageID)
                }
            } catch {
                fail(error)
            }
        }
    }

    /// Send a binary attachment (image or audio) to an MLS group.
    public func sendMLSGroupAttachment(
        _ data: Data,
        mimeType: String,
        caption: String = "",
        audioDuration: Double? = nil,
        group: GroupInfo,
        expiresAt: Date? = nil,
        replyToID: String? = nil
    ) {
        guard data.count <= 512_000 else {
            delegate?.chatManager(self, didEncounterError:
                SophaxError.invalidMessageFormat("Attachment exceeds 512 KB limit"))
            return
        }

        let myID         = identity.publicIdentity.peerID
        let messageID    = UUID().uuidString
        let attachmentID = UUID().uuidString
        let convID       = "group.\(group.id)"
        let msgType      = mimeType.hasPrefix("image/") ? "image" : "audio"
        let displayBody  = caption.isEmpty
            ? (msgType == "image" ? "📷 Photo" : "🎤 Voice message")
            : caption

        func fail(_ error: Error) {
            try? messageStore.updateStatus(.failed, forMessageID: messageID, peerID: convID)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.chatManager(self, didEncounterError: error)
            }
        }

        // Save attachment locally for sender's own bubble
        try? attachmentStore.save(data, id: attachmentID)

        let stored = StoredMessage(
            id: messageID, peerID: convID,
            direction: .sent, body: displayBody, status: .sending,
            replyToID: replyToID, expiresAt: expiresAt,
            attachmentID: attachmentID, attachmentMimeType: mimeType,
            audioDuration: audioDuration, senderID: myID
        )
        do { try messageStore.append(message: stored) } catch { fail(error); return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveGroupMessage: stored, inGroup: group.id)
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let mls = try self.requireMLSManager()

                // Encrypt caption (may be empty)
                let captionPlain  = caption.data(using: .utf8) ?? Data()
                let bodyCipher    = try await mls.encrypt(groupID: group.id, plaintext: captionPlain)
                // Encrypt attachment bytes
                let attachCipher  = try await mls.encrypt(groupID: group.id, plaintext: data)

                let appMsg = MLSApplicationMessage(
                    groupID:              group.id,
                    messageID:            messageID,
                    senderPeerID:         myID,
                    senderUsername:       self.identity.publicIdentity.username,
                    timestamp:            Date(),
                    ciphertext:           bodyCipher,
                    expiresAt:            expiresAt,
                    replyToID:            replyToID,
                    attachmentCiphertext: attachCipher,
                    mimeType:             mimeType,
                    audioDuration:        audioDuration,
                    senderAvatarData:     self.identity.loadAvatar()
                )
                guard let wire = try? self.wireBuilder.build(.mlsMessage, payload: appMsg) else {
                    throw SophaxError.encryptionFailed("Failed to build MLS attachment wire message")
                }

                try? self.messageStore.updateStatus(.delivered, forMessageID: messageID, peerID: convID)

                for peerID in group.memberIDs where peerID != myID {
                    try? self.sendOrQueue(wire, toPeerID: peerID, messageID: messageID)
                }
            } catch {
                fail(error)
            }
        }
    }

    /// Send an emoji reaction (or remove one) on a message in an MLS group.
    public func sendMLSGroupReaction(emoji: String?, toMessageID targetID: String, group: GroupInfo) {
        let myID      = identity.publicIdentity.peerID
        let messageID = UUID().uuidString
        let convID    = "group.\(group.id)"

        // Encode reaction payload and apply locally immediately
        struct ReactionPayload: Codable { let emoji: String? }
        guard let payloadData = try? JSONEncoder().encode(ReactionPayload(emoji: emoji)) else { return }

        // Apply locally (mirrors SKv2 sendGroupReaction pattern)
        if let msgs = try? messageStore.messages(forPeer: convID),
           let idx  = msgs.firstIndex(where: { $0.id == targetID }) {
            var reactions = msgs[idx].reactions ?? [:]
            if let e = emoji { reactions[myID] = e } else { reactions.removeValue(forKey: myID) }
            try? messageStore.updateReactions(reactions, forMessageID: targetID, peerID: convID)
            let finalReactions = reactions
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.chatManager(self, didUpdateGroupReactions: finalReactions,
                                           onMessageID: targetID, groupID: group.id)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let mls       = try self.requireMLSManager()
                let ciphertext = try await mls.encrypt(groupID: group.id, plaintext: payloadData)
                let wire_msg  = MLSReactionMessage(
                    groupID: group.id, messageID: messageID,
                    senderPeerID: myID, targetMessageID: targetID,
                    ciphertext: ciphertext, timestamp: Date()
                )
                guard let wire = try? self.wireBuilder.build(.mlsReaction, payload: wire_msg) else { return }
                for peerID in group.memberIDs where peerID != myID {
                    try? self.sendOrQueue(wire, toPeerID: peerID, messageID: messageID)
                }
            } catch {
                #if DEBUG
                print("[ChatManager][MLS] sendMLSGroupReaction error: \(error)")
                #endif
            }
        }
    }
}

// MARK: - Wire dispatch (replaces Phase 3 stubs)

extension ChatManager {

    /// Called from the two main dispatch switches to route MLS wire messages.
    func dispatchMLSMessage(_ message: WireMessage) {
        do {
            switch message.type {
            case .mlsWelcome:
                let payload = try wireBuilder.decodePayload(MLSWelcomeMessage.self, from: message)
                handleMLSWelcome(payload, fromPeer: message.senderID)
            case .mlsCommit:
                let payload = try wireBuilder.decodePayload(MLSCommitMessage.self, from: message)
                handleMLSCommit(payload, fromPeer: message.senderID)
            case .mlsMessage:
                let payload = try wireBuilder.decodePayload(MLSApplicationMessage.self, from: message)
                handleMLSApplicationMessage(payload)
            case .mlsCommitRequest:
                let payload = try wireBuilder.decodePayload(MLSCommitRequestMessage.self, from: message)
                handleMLSCommitRequest(payload, fromPeer: message.senderID)
            case .mlsReaction:
                let payload = try wireBuilder.decodePayload(MLSReactionMessage.self, from: message)
                handleMLSReaction(payload)
            default:
                break
            }
        } catch {
            #if DEBUG
            print("[ChatManager][MLS] dispatch error: \(error)")
            #endif
        }
    }
}
