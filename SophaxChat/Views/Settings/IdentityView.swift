// IdentityView.swift
// SophaxChat
//
// Shows the local user's identity info and safety number.
// Also links to settings and security options.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import SophaxChatCore

struct IdentityView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showingRenameAlert   = false
    @State private var renameText           = ""
    @State private var avatarPickerItem:    PhotosPickerItem? = nil

    // Identity backup
    @State private var exportPassphrase     = ""
    @State private var exportedBlob:        IdentityTransferable? = nil
    @State private var exportError:         String? = nil
    @State private var showingImportPicker  = false
    @State private var showingImportConfirm = false
    @State private var pendingImportData:   Data?   = nil
    @State private var importPassphrase     = ""
    @State private var importError:         String? = nil
    @State private var importSuccess        = false

    private var identity: IdentityManager? { appState.chatManager?.identity }

    var body: some View {
        NavigationStack {
            List {
                // Identity summary
                Section {
                    if let id = identity?.publicIdentity {
                        VStack(spacing: 16) {
                            // Avatar — tap to change
                            PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                                if let data = appState.myAvatarData, let uiImage = UIImage(data: data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(Color.accentColor.opacity(0.3), lineWidth: 2))
                                } else {
                                    ZStack {
                                        Circle()
                                            .fill(Color.accentColor.opacity(0.12))
                                            .frame(width: 80, height: 80)
                                        Text(String(id.username.prefix(1)).uppercased())
                                            .font(.system(size: 36, weight: .bold))
                                            .foregroundStyle(Color.accentColor)
                                        Image(systemName: "camera.fill")
                                            .font(.caption)
                                            .foregroundStyle(.white)
                                            .padding(5)
                                            .background(Color.accentColor)
                                            .clipShape(Circle())
                                            .offset(x: 26, y: 26)
                                    }
                                }
                            }
                            .onChange(of: avatarPickerItem) { _, item in
                                guard let item else { return }
                                Task {
                                    if let data = try? await item.loadTransferable(type: Data.self),
                                       let img  = UIImage(data: data) {
                                        appState.setMyAvatar(img)
                                    }
                                    avatarPickerItem = nil
                                }
                            }

                            VStack(spacing: 4) {
                                Button {
                                    renameText = id.username
                                    showingRenameAlert = true
                                } label: {
                                    Text(id.username)
                                        .font(.title3.bold())
                                        .foregroundStyle(.primary)
                                }
                                .buttonStyle(.plain)
                                Text("Peer ID: \(id.peerID.prefix(16))…")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if appState.myAvatarData != nil {
                                    Button("Remove Photo", role: .destructive) {
                                        appState.removeMyAvatar()
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                    }
                }

                // Share contact link
                Section {
                    if let link = appState.generateInviteLink() {
                        ShareLink(item: link, subject: Text("Add me on SophaxChat"),
                                  message: Text("Tap to add me as a contact in SophaxChat — encrypted, serverless, no account needed.")) {
                            Label("Share Contact Link", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("Invite")
                } footer: {
                    Text("Share this link so others can add you as a contact — no Bluetooth or WiFi needed.")
                }

                // Safety number
                Section {
                    if let safetyNumber = identity?.publicIdentity.safetyNumber {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Your Safety Number", systemImage: "checkmark.shield.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)

                            let groups = safetyNumber.split(separator: " ")
                            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 8) {
                                ForEach(groups, id: \.self) { group in
                                    Text(group)
                                        .font(.system(.footnote, design: .monospaced).bold())
                                        .padding(8)
                                        .background(Color(.tertiarySystemGroupedBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }

                            Text("Share this with contacts to verify your identity out-of-band.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Identity Verification")
                }

                // Identity backup
                Section {
                    // Export
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Export Identity", systemImage: "square.and.arrow.up.on.square")
                            .font(.subheadline.weight(.semibold))
                        Text("Save your encryption keys so you can restore your identity on a new device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("Passphrase (min 16 chars)", text: $exportPassphrase)
                            .textContentType(.newPassword)
                            .autocorrectionDisabled()
                        if let err = exportError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        if exportedBlob != nil {
                            Button {
                                // fileExporter is shown via the binding below
                            } label: {
                                Label("Share Identity File", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .fileExporter(
                                isPresented: Binding(
                                    get: { exportedBlob != nil },
                                    set: { if !$0 { exportedBlob = nil } }
                                ),
                                document: exportedBlob!,
                                contentType: .sophaxIdentity,
                                defaultFilename: IdentityExportManager.suggestedFilename()
                            ) { _ in }
                        } else {
                            Button {
                                exportError = nil
                                let trimmed = exportPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard trimmed.count >= 16 else {
                                    exportError = "Passphrase must be at least 16 characters."
                                    return
                                }
                                do {
                                    let data = try appState.exportIdentity(passphrase: trimmed)
                                    exportedBlob = IdentityTransferable(data: data)
                                } catch {
                                    exportError = error.localizedDescription
                                }
                            } label: {
                                Label("Create Identity Backup", systemImage: "key.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(exportPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).count < 16)
                        }
                    }
                    .padding(.vertical, 4)

                    // Import
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Restore Identity", systemImage: "square.and.arrow.down.on.square")
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Replaces current keys. All sessions will be reset.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if importSuccess {
                            Label("Identity restored successfully.", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if let err = importError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        Button {
                            showingImportPicker = true
                        } label: {
                            Label("Load Identity File…", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Identity Backup")
                } footer: {
                    Text("The identity file contains your private keys encrypted with your passphrase. Keep it safe — anyone with the file and passphrase can impersonate you.")
                }

                // Security info
                Section {
                    Label("End-to-end encrypted", systemImage: "lock.fill")
                        .foregroundStyle(.green)
                    Label("No servers — P2P only", systemImage: "wifi.slash")
                        .foregroundStyle(.blue)
                    Label("Anonymous — no account needed", systemImage: "person.slash")
                        .foregroundStyle(.purple)
                    Label("Keys stored in iOS Keychain", systemImage: "key.shield")
                        .foregroundStyle(.orange)

                    if appState.opkCount < 5 {
                        HStack {
                            Label("One-time prekeys low (\(appState.opkCount) left)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Regenerate") {
                                appState.chatManager?.replenishPreKeys()
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .font(.caption)
                        }
                    }
                } header: {
                    Text("Security")
                }

            }
            .navigationTitle("My Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Change Username", isPresented: $showingRenameAlert) {
                TextField("New username", text: $renameText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save") {
                    appState.changeUsername(renameText)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your new username will be shared with nearby peers.")
            }
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [UTType(filenameExtension: "sophaxid") ?? .data]
            ) { result in
                guard case .success(let url) = result,
                      url.startAccessingSecurityScopedResource(),
                      let data = try? Data(contentsOf: url) else { return }
                url.stopAccessingSecurityScopedResource()
                pendingImportData = data
                showingImportConfirm = true
            }
            .alert("Enter Passphrase", isPresented: $showingImportConfirm) {
                SecureField("Passphrase", text: $importPassphrase)
                    .textContentType(.password)
                Button("Restore", role: .destructive) {
                    importError   = nil
                    importSuccess = false
                    guard let data = pendingImportData else { return }
                    do {
                        try appState.importIdentity(data: data, passphrase: importPassphrase)
                        importSuccess    = true
                        importPassphrase = ""
                        pendingImportData = nil
                    } catch {
                        importError      = error.localizedDescription
                        importPassphrase = ""
                    }
                }
                Button("Cancel", role: .cancel) {
                    importPassphrase = ""
                    pendingImportData = nil
                }
            } message: {
                Text("Enter the passphrase used when you exported this identity file. Your current keys will be replaced.")
            }
        }
    }
}

// MARK: - FileDocument wrapper for identity export

struct IdentityTransferable: FileDocument {
    static var readableContentTypes: [UTType] { [.sophaxIdentity, .data] }
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
    static let sophaxIdentity = UTType(exportedAs: "com.sophax.sophaxidentity")
}

#Preview {
    IdentityView().environmentObject(AppState())
}
