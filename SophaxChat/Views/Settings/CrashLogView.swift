// CrashLogView.swift
// SophaxChat
//
// Displays the on-device diagnostic log. Users can share the file when filing a bug report.
// No message content or peer identifiers are ever stored in the log.

import SwiftUI
import SophaxChatCore

struct CrashLogView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var logText      = ""
    @State private var showClearAlert = false
    @State private var exportURL: URL? = nil

    var body: some View {
        NavigationStack {
            Group {
                if logText.isEmpty || logText == "(no log entries)" {
                    ContentUnavailableView(
                        "No Log Entries",
                        systemImage: "checkmark.seal",
                        description: Text("The diagnostic log is empty.")
                    )
                } else {
                    ScrollView {
                        Text(logText)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Diagnostic Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let url = exportURL {
                        ShareLink(item: url, subject: Text("SophaxChat Diagnostic Log")) {
                            Label("Share Log", systemImage: "square.and.arrow.up")
                        }
                        .disabled(logText.isEmpty || logText == "(no log entries)")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        showClearAlert = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .disabled(logText.isEmpty || logText == "(no log entries)")
                }
            }
            .alert("Clear Diagnostic Log?", isPresented: $showClearAlert) {
                Button("Clear", role: .destructive) {
                    CrashLogManager.shared.clear()
                    logText = "(no log entries)"
                    exportURL = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        logText = CrashLogManager.shared.exportableText()
        // Write to a temp file for ShareLink
        guard logText != "(no log entries)", !logText.isEmpty else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sophaxchat-crash-log.txt")
        try? logText.write(to: tmp, atomically: true, encoding: .utf8)
        exportURL = tmp
    }
}
