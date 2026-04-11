// GroupChatViewModel.swift
// SophaxChat
//
// Observable view model for a group conversation.
// Holds message-input and conversation state so GroupChatView stays
// focused on layout only.

import Foundation
import Observation
import PhotosUI
import SophaxChatCore

@MainActor
@Observable
final class GroupChatViewModel {

    // Message input
    var messageText: String = ""

    // Message actions
    var replyingTo: StoredMessage? = nil
    var editingMessage: StoredMessage? = nil
    var editingText: String = ""
    var forwardingMessage: StoredMessage? = nil

    // Search
    var isSearching: Bool = false
    var searchQuery: String = ""

    // Attachments
    var photoPickerItem: PhotosPickerItem? = nil

    // Disappearing messages
    var disappearingInterval: DisappearingInterval = .off

    // AI sheet seed
    var aiSeedPrompt: String? = nil

    // Alert message for MLS migration result
    var migrationAlertMessage: String = ""

    private let disappearingKey: String
    private let draftKey: String

    init(group: GroupInfo) {
        self.disappearingKey = "com.sophax.disappearingInterval.group.\(group.id)"
        self.draftKey = "com.sophax.draft.group.\(group.id)"
        let ud = UserDefaults.standard
        if let raw = ud.string(forKey: disappearingKey) {
            disappearingInterval = DisappearingInterval(rawValue: raw) ?? .off
        }
        messageText = ud.string(forKey: draftKey) ?? ""
    }

    func saveDraft() {
        if messageText.isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else {
            UserDefaults.standard.set(messageText, forKey: draftKey)
        }
    }

    func clearDraft() {
        UserDefaults.standard.removeObject(forKey: draftKey)
    }

    func saveDisappearing() {
        UserDefaults.standard.set(disappearingInterval.rawValue, forKey: disappearingKey)
    }

    func cancelReply() { replyingTo = nil }

    func cancelEdit() {
        editingMessage = nil
        editingText = ""
    }
}
