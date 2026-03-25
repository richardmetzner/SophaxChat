// BackupView.swift
// SophaxChat
//
// Export and import encrypted local backups.
// No cloud. No server. You own your data.

import SwiftUI
import SophaxChatCore
import UniformTypeIdentifiers

struct BackupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase  = ""
    @State private var confirm     = ""
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportItem:  BackupTransferable?
    @State private var errorText:   String?
    @State private var successText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your backup is encrypted with your passphrase. Nobody — not us, not Apple — can open it without it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Export Backup") {
                    SecureField("Passphrase", text: $passphrase)
                        .textContentType(.newPassword)
                    SecureField("Confirm passphrase", text: $confirm)
                        .textContentType(.newPassword)

                    Button {
                        export()
                    } label: {
                        if isExporting {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Export Encrypted Backup", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(passphrase.count < 16 || passphrase != confirm || isExporting)
                    .fileExporter(
                        isPresented: Binding(get: { exportItem != nil }, set: { if !$0 { exportItem = nil } }),
                        document: exportItem,
                        contentType: .sophaxBackup,
                        defaultFilename: BackupManager.suggestedFilename()
                    ) { result in
                        switch result {
                        case .success: successText = "Backup saved."
                        case .failure(let e): errorText = e.localizedDescription
                        }
                        exportItem = nil
                    }
                }

                Section("Restore Backup") {
                    SecureField("Passphrase used when exporting", text: $passphrase)
                        .textContentType(.password)

                    Button {
                        isImporting = true
                    } label: {
                        Label("Choose Backup File…", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(passphrase.isEmpty)
                    .fileImporter(
                        isPresented: $isImporting,
                        allowedContentTypes: [.sophaxBackup, .data]
                    ) { result in
                        restore(result: result)
                    }
                }

                if let error = errorText {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
                if let success = successText {
                    Section {
                        Text(success).foregroundStyle(.green)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Messages and contacts are backed up", systemImage: "checkmark.circle")
                        Label("Identity keys are NOT exported (by design)", systemImage: "lock.shield")
                        Label("Contacts will ask to re-verify safety numbers", systemImage: "info.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Backup & Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Actions

    private func export() {
        guard passphrase == confirm, passphrase.count >= 16 else {
            errorText = "Passphrases do not match or are too short (min 16 characters)."
            return
        }
        isExporting = true
        errorText   = nil
        successText = nil
        Task.detached(priority: .userInitiated) {
            do {
                let data = try await MainActor.run { try appState.exportBackup(passphrase: passphrase) }
                await MainActor.run {
                    exportItem  = BackupTransferable(data: data)
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

    private func restore(result: Result<URL, Error>) {
        errorText   = nil
        successText = nil
        switch result {
        case .failure(let e):
            errorText = e.localizedDescription
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                errorText = "Could not access the selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                try appState.importBackup(data: data, passphrase: passphrase)
                successText = "Backup restored. Restart the app to see all messages."
                passphrase  = ""
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - FileDocument wrapper

struct BackupTransferable: FileDocument {
    static var readableContentTypes: [UTType] { [.sophaxBackup, .data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = d
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    static let sophaxBackup = UTType(exportedAs: "com.sophax.sophaxbackup")
}
