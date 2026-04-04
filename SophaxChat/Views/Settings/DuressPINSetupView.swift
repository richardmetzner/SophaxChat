// DuressPINSetupView.swift
// SophaxChat
//
// UI for setting the real lock PIN and the duress PIN.
// Two separate structs presented from SettingsView.

import SwiftUI

// MARK: - Real lock PIN setup

struct LockPINSetupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var pin        = ""
    @State private var confirm    = ""
    @State private var errorText: String?
    @State private var saved      = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Set a numeric PIN as an alternative unlock method alongside biometrics.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("New PIN") {
                    SecureField("PIN (4–8 digits)", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                    SecureField("Confirm PIN", text: $confirm)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                }

                Section {
                    Button("Save PIN") {
                        savePIN()
                    }
                    .disabled(!isValid)
                }

                if let err = errorText {
                    Section { Text(err).foregroundStyle(.red) }
                }
                if saved {
                    Section { Text("Lock PIN saved.").foregroundStyle(.green) }
                }
            }
            .navigationTitle("Set Lock PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var isValid: Bool {
        let digits = pin.filter(\.isNumber)
        return digits.count >= 4 && digits.count <= 8 && pin == confirm
    }

    private func savePIN() {
        errorText = nil
        saved     = false
        do {
            try appState.setRealLockPIN(pin)
            saved   = true
            pin     = ""
            confirm = ""
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Duress PIN setup

struct DuressPINSetupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var pin        = ""
    @State private var confirm    = ""
    @State private var errorText: String?
    @State private var saved      = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("When you enter this PIN on the lock screen, the app appears empty — no messages, no contacts. The real app remains intact.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Duress PIN") {
                    SecureField("PIN (4–8 digits, different from lock PIN)", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                    SecureField("Confirm PIN", text: $confirm)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                }

                Section {
                    Button("Save Duress PIN") {
                        savePIN()
                    }
                    .disabled(!isValid)
                }

                if let err = errorText {
                    Section { Text(err).foregroundStyle(.red) }
                }
                if saved {
                    Section { Text("Duress PIN saved.").foregroundStyle(.green) }
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Entering this PIN will NOT unlock the real app", systemImage: "eye.slash")
                        Label("The app shows an empty state with no data", systemImage: "tray")
                        Label("Messages are silently dropped until real unlock", systemImage: "bell.slash")
                        Label("Must differ from your real lock PIN", systemImage: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Set Duress PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var isValid: Bool {
        let digits = pin.filter(\.isNumber)
        guard digits.count >= 4 && digits.count <= 8 && pin == confirm else { return false }
        // Must not match the real lock PIN
        return !appState.verifyRealLockPIN(pin)
    }

    private func savePIN() {
        errorText = nil
        saved     = false
        do {
            try appState.setDuressPIN(pin)
            saved   = true
            pin     = ""
            confirm = ""
        } catch {
            errorText = error.localizedDescription
        }
    }
}
