// AppLockView.swift
// SophaxChat
//
// Full-screen lock overlay shown when app lock is enabled.
// Auto-attempts biometric / passcode authentication on appear.

import SwiftUI

struct AppLockView: View {
    @EnvironmentObject var appState: AppState
    @State private var now = Date()

    /// Refresh the countdown every second when locked out.
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isLockedOut: Bool {
        if let until = appState.unlockLockedUntil { return now < until }
        return false
    }

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
                        Label("Unlock", systemImage: "faceid")
                            .font(.headline)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(appState.isUnlocking || isLockedOut)

                if let err = appState.unlockError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .onAppear { appState.tryUnlock() }
        .onReceive(timer) { now = $0 }
    }
}

#Preview {
    AppLockView().environmentObject(AppState())
}
