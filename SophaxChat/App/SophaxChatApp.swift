// SophaxChatApp.swift
// SophaxChat
//
// App entry point.

import SwiftUI
import BackgroundTasks
import SophaxChatCore
import UIKit

extension Notification.Name {
    static let sophaxShowSettings = Notification.Name("com.sophax.showSettings")
}

@main
struct SophaxChatApp: App {

    @StateObject private var appState = AppState()

    // MARK: - Background task identifier

    private static let meshRefreshID = "com.sophax.mesh-refresh"

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onOpenURL { url in
                    appState.handleIncomingLink(url)
                }
                .onAppear {
                    // Allow free window resizing on macOS (Designed for iPad).
                    // Deferred one run-loop tick so the UIWindowScene is fully
                    // initialised before we touch sizeRestrictions.
                    DispatchQueue.main.async {
                        if let windowScene = UIApplication.shared.connectedScenes
                            .first as? UIWindowScene {
                            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 380, height: 600)
                            windowScene.sizeRestrictions?.maximumSize = CGSize(width: 9999, height: 9999)
                        }
                    }
                }
                // Prevent the app from appearing in the app switcher screenshot
                // (reduces the risk of sensitive content being captured by iOS)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    appState.isBlurred = true
                    appState.lockApp()
                    scheduleBackgroundMeshRefresh()
                    // Clear clipboard on background to prevent sensitive message content leaking
                    UIPasteboard.general.items = []
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
        .commands {
            // ⌘, opens Settings — standard Mac convention
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .sophaxShowSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
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

// MARK: - Screenshot Prevention

/// Wraps content in a UITextField(isSecureTextEntry: true) layer. iOS excludes the secure
/// text field's CALayer subtree from screenshots and screen recordings, making the content
/// appear as a blank frame in any screen capture.
///
/// NOTE: This relies on an undocumented CALayer flag inside UITextField. It works on current
/// iOS versions but could theoretically change in a future OS release. If content ever appears
/// unexpectedly blank, toggle "Block Screenshots" off in Settings > Security.
#if !targetEnvironment(macCatalyst)
private struct SecureContainerView<Content: View>: UIViewRepresentable {
    let content: Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.isSecureTextEntry = true
        field.backgroundColor   = .clear

        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: field.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: field.trailingAnchor),
        ])
        context.coordinator.host = host
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.host?.rootView = content
    }

    class Coordinator {
        var host: UIHostingController<Content>?
    }
}
#endif

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        #if !targetEnvironment(macCatalyst)
        if appState.screenshotPreventionEnabled {
            SecureContainerView(content: rootZStack.environmentObject(appState))
                .ignoresSafeArea()
        } else {
            rootZStack
        }
        #else
        rootZStack
        #endif
    }

    @ViewBuilder private var rootZStack: some View {
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
        .alert(
            "Add contact?",
            isPresented: Binding(
                get: { appState.pendingDeepLink != nil },
                set: { if !$0 { appState.pendingDeepLink = nil } }
            ),
            presenting: appState.pendingDeepLink
        ) { pending in
            Button("Add & Connect") { appState.confirmDeepLink() }
            Button("Cancel", role: .cancel) { appState.pendingDeepLink = nil }
        } message: { pending in
            Text("Connect to \(pending.onionHost)?")
        }
    }
}
