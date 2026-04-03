// NoteToSelfView.swift
// SophaxChat
//
// A local encrypted notepad. Messages are stored in MessageStore under the
// synthetic peerID "__note_to_self__" and never transmitted over the network.

import SwiftUI
import SophaxChatCore

struct NoteToSelfView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var isInputFocused: Bool
    @State private var noteText: String = ""

    private var notes: [StoredMessage] {
        appState.noteToSelfMessages
    }

    var body: some View {
        VStack(spacing: 0) {
            noteList
            Divider()
            inputBar
        }
        .navigationTitle("Note to Self")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Note to Self")
                        .font(.headline)
                    Text("Encrypted — local only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Note list

    private var noteList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(notes) { note in
                        noteBubble(for: note)
                            .id(note.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .onChange(of: notes.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Note bubble

    @ViewBuilder private func noteBubble(for note: StoredMessage) -> some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 3) {
                Text(note.body)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = note.body
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            appState.deleteNoteToSelf(note)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }

                Text(note.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Write a note…", text: $noteText, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .focused($isInputFocused)

            Button {
                let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                appState.sendNoteToSelf(trimmed)
                noteText = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(noteText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
            }
            .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
