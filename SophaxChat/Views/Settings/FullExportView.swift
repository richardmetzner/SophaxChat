// FullExportView.swift
// SophaxChat
//
// Exports identity keys + all messages into a single encrypted .sxfe file.
// Use "Restore from Full Export" (FullRestoreView) to import.

import SwiftUI
import SophaxChatCore
import UniformTypeIdentifiers

// MARK: - Export view

struct FullExportView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase  = ""
    @State private var confirm     = ""
    @State private var isExporting = false
    @State private var exportItem:  FullExportTransferable?
    @State private var errorText:   String?
    @State private var successText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Exports your identity keys and all messages in one encrypted file. Use to migrate to a new device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Passphrase") {
                    SecureField("Passphrase (min 16 chars)", text: $passphrase)
                        .textContentType(.newPassword)
                    SecureField("Confirm passphrase", text: $confirm)
                        .textContentType(.newPassword)
                }

                Section {
                    Button {
                        runExport()
                    } label: {
                        if isExporting {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Export & Save to Files", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(passphrase.count < 16 || passphrase != confirm || isExporting)
                    .fileExporter(
                        isPresented: Binding(
                            get: { exportItem != nil },
                            set: { if !$0 { exportItem = nil } }
                        ),
                        document: exportItem,
                        contentType: .sxfe,
                        defaultFilename: FullExportManager.suggestedFilename()
                    ) { result in
                        switch result {
                        case .success: successText = "Full export saved."
                        case .failure(let e): errorText = e.localizedDescription
                        }
                        exportItem = nil
                    }
                }

                if let error = errorText {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let success = successText {
                    Section { Text(success).foregroundStyle(.green) }
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Identity keys are included", systemImage: "key.fill")
                        Label("All messages and contacts are included", systemImage: "checkmark.circle")
                        Label("Double Ratchet sessions are NOT included (forward secrecy)", systemImage: "lock.rotation")
                        Label("Keep this file safe — it contains your private keys", systemImage: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Export Everything")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func runExport() {
        guard passphrase == confirm, passphrase.count >= 16 else {
            errorText = "Passphrases do not match or are too short (min 16 characters)."
            return
        }
        isExporting = true
        errorText   = nil
        successText = nil
        Task.detached(priority: .userInitiated) {
            do {
                let data = try await MainActor.run { try appState.exportFullBackup(passphrase: passphrase) }
                await MainActor.run {
                    exportItem  = FullExportTransferable(data: data)
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    errorText   = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }
}

// MARK: - Restore view

struct FullRestoreWrapper: Identifiable {
    let id   = UUID()
    let data: Data
}

struct FullRestoreView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let data: Data

    @State private var passphrase  = ""
    @State private var isRestoring = false
    @State private var errorText:   String?
    @State private var successText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter the passphrase you used when exporting.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Passphrase") {
                    SecureField("Passphrase", text: $passphrase)
                        .textContentType(.password)
                }

                Section {
                    Button {
                        runRestore()
                    } label: {
                        if isRestoring {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Restore", systemImage: "tray.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(passphrase.isEmpty || isRestoring)
                }

                if let error = errorText {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let success = successText {
                    Section { Text(success).foregroundStyle(.green) }
                }

                Section {
                    Text("This replaces your current identity keys and messages. Cannot be undone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Restore Full Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func runRestore() {
        isRestoring = true
        errorText   = nil
        successText = nil
        Task.detached(priority: .userInitiated) {
            do {
                try await MainActor.run { try appState.importFullBackup(data: data, passphrase: passphrase) }
                await MainActor.run {
                    successText = "Restored successfully. Restart the app."
                    isRestoring = false
                    passphrase  = ""
                }
            } catch {
                await MainActor.run {
                    errorText   = error.localizedDescription
                    isRestoring = false
                }
            }
        }
    }
}

// MARK: - FileDocument wrapper

struct FullExportTransferable: FileDocument {
    static var readableContentTypes: [UTType] { [.sxfe, .data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = d
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    static let sxfe = UTType(exportedAs: "com.sophax.sxfe")
}
