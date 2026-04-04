// DuressEmptyView.swift
// SophaxChat
//
// Shown when the duress PIN was entered. Looks like the real app but has no data.
// The user can "use" it normally — nothing is stored, no messages appear.
// Exiting back to the lock screen and entering the real PIN restores normal operation.

import SwiftUI

struct DuressEmptyView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                // Intentionally empty — presents the same shell as ChatListView
            }
            .navigationTitle("Messages")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                // Subtle empty-state label — matches what new users see
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 48))
                        .foregroundStyle(.quaternary)
                    Text("No messages yet")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Go nearby someone running SophaxChat\nto start a conversation.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}
