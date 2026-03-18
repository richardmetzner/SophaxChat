// SophaxChatApp.swift
// SophaxChat
//
// App entry point.

import SwiftUI
import BackgroundTasks
import SophaxChatCore

@main
struct SophaxChatApp: App {

    @StateObject private var appState = AppState()

    // MARK: - Background task identifier

    private static let meshRefreshID = "com.sophax.mesh-refresh"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onOpenURL { url in
                    appState.handleIncomingLink(url)
                }
                // Prevent the app from appearing in the app switcher screenshot
                // (reduces the risk of sensitive content being captured by iOS)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    appState.isBlurred = true
                    appState.lockApp()
                    scheduleBackgroundMeshRefresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    appState.isBlurred = false
                    // AppLockView.onAppear handles unlock attempt automatically
                    // Re-establish TCP connections that dropped while backgrounded
                    appState.reconnectTCPPeers()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                    appState.handleScreenshot()
                }
        }
        // Background processing task — re-wakes the mesh briefly after iOS suspends the app.
        // The bluetooth-central/peripheral background modes in Info.plist allow MPC to stay
        // alive for several minutes after backgrounding; this BGTask extends coverage when
        // iOS has fully suspended the process.
        .backgroundTask(.appRefresh(Self.meshRefreshID)) {
            await appState.handleBackgroundMeshRefresh()
        }
    }

    // MARK: - Background scheduling

    private func scheduleBackgroundMeshRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.meshRefreshID)
        // iOS will call this after ~15 minutes at the earliest; actual timing is system-driven.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            if appState.isSetupComplete {
                ChatListView()
            } else {
                OnboardingView()
            }

            // Security overlay: blurs content when app goes to background
            // Prevents sensitive content appearing in the app switcher
            if appState.isBlurred {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            if appState.isAppLocked {
                AppLockView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            if appState.isScreenBeingRecorded {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse)
                        Text("Screen recording active")
                            .font(.caption.weight(.medium))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.12))
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(.red.opacity(0.25)), alignment: .bottom)
                    Spacer()
                }
                .ignoresSafeArea(edges: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if appState.didTakeScreenshot {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .foregroundStyle(.orange)
                        Text("Screenshot taken — messages may be exposed")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Contact card received toast — must be inside ZStack to overlay content
            if let addr = appState.lastAddedContactAddress {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.plus")
                            .foregroundStyle(.green)
                        Text("Contact added — \(addr.prefix(16))…")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appState.isBlurred)
        .animation(.easeInOut(duration: 0.2), value: appState.isAppLocked)
        .animation(.easeInOut(duration: 0.3), value: appState.isScreenBeingRecorded)
        .animation(.spring(duration: 0.4), value: appState.didTakeScreenshot)
        .animation(.spring(duration: 0.4), value: appState.lastAddedContactAddress)
    }
}
