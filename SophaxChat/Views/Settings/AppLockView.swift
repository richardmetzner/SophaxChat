// AppLockView.swift
// SophaxChat
//
// Full-screen lock overlay shown when app lock is enabled.
// Auto-attempts biometric / passcode authentication on appear.
// If a real lock PIN is set, also offers a PIN entry path (which supports duress PIN).

import SwiftUI

struct AppLockView: View {
    @EnvironmentObject var appState: AppState
    @State private var now          = Date()
    @State private var showPINEntry = false
    @State private var enteredPIN   = ""

    /// Refresh the countdown every second when locked out.
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isLockedOut: Bool {
        if let until = appState.unlockLockedUntil { return now < until }
        return false
    }

    private var hasPIN: Bool { appState.hasRealLockPIN }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)

                VStack(spacing: 6) {
                    Text("SophaxChat")
                        .font(.title.bold())
                    Text("App is locked")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button(action: { appState.tryUnlock() }) {
                    if appState.isUnlocking {
                        ProgressView().frame(width: 24, height: 24)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 14)
                    } else {
                        Label("Unlock with Biometrics", systemImage: "faceid")
                            .font(.headline)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(appState.isUnlocking || isLockedOut)

                if hasPIN {
                    if showPINEntry {
                        pinEntryField
                    } else {
                        Button("Enter PIN instead") {
                            showPINEntry = true
                            appState.unlockError = nil
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }

                if let err = appState.unlockError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .padding(.horizontal, 32)
        }
        .onAppear { appState.tryUnlock() }
        .onReceive(timer) { now = $0 }
    }

    @ViewBuilder
    private var pinEntryField: some View {
        VStack(spacing: 12) {
            SecureField("PIN", text: $enteredPIN)
                .keyboardType(.numberPad)
                .textContentType(.password)
                .multilineTextAlignment(.center)
                .font(.title3.monospacedDigit())
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Button {
                let pin = enteredPIN
                enteredPIN = ""
                appState.tryUnlockWithPIN(pin)
                if !appState.isDuressActive {
                    // Keep PIN field visible if unlock failed; hide on success
                    showPINEntry = appState.isAppLocked
                }
            } label: {
                Text("Unlock")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(enteredPIN.isEmpty || isLockedOut)
        }
    }
}

#Preview {
    AppLockView().environmentObject(AppState())
}
