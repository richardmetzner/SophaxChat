// ChatViewModel.swift
// SophaxChat
//
// Observable view model for an individual conversation (DM).
// Holds message-input and conversation state so ChatView stays
// focused on layout only.

import Foundation
import Observation
import PhotosUI
import SophaxChatCore

@MainActor
@Observable
final class ChatViewModel {

    // Message input
    var messageText: String = ""
    var typingTask: Task<Void, Never>? = nil

    // Message actions
    var replyingTo: StoredMessage? = nil
    var editingMessage: StoredMessage? = nil
    var forwardingMessage: StoredMessage? = nil

    // Search
    var isSearching: Bool = false
    var searchQuery: String = ""

    // Attachments
    var photoPickerItem: PhotosPickerItem? = nil

    // Disappearing messages
    var disappearingInterval: DisappearingInterval = .off

    // Input buffers for dialogs
    var renameText: String = ""
    var deadDropText: String = ""

    // AI sheet seed
    var aiSeedPrompt: String? = nil

    private let disappearingKey: String
    private let draftKey: String

    init(peerID: String) {
        self.disappearingKey = "com.sophax.disappearingInterval.\(peerID)"
        self.draftKey = "com.sophax.draft.\(peerID)"
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
        messageText = ""
    }
}
