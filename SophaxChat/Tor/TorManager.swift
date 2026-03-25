// TorManager.swift
// SophaxChat
//
// Manages embedded Tor lifecycle. No Orbot required.
// Provides a local SOCKS5 proxy on 127.0.0.1:9050 once ready.

import Foundation
import Network

@MainActor
final class TorManager: ObservableObject {

    static let shared = TorManager()

    // MARK: - State

    enum TorState: Equatable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    @Published private(set) var state: TorState = .stopped
    @Published private(set) var bootstrapProgress: Int = 0

    /// SOCKS5 proxy string to pass to TCPTransport when ready.
    static let socksProxy = "127.0.0.1:9050"

    // MARK: - Private

    private var thread: TorThread?
    private var controller: TORController?
    private var statusObserver: Any?

    private var torDataDir: URL {
        let app = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return app.appendingPathComponent("tor_data", isDirectory: true)
    }

    private var controlSocketURL: URL {
        torDataDir.appendingPathComponent("control.socket")
    }

    // MARK: - Lifecycle

    private init() {}

    /// Starts embedded Tor. Safe to call multiple times — no-op if already starting/ready.
    func start() {
        guard state == .stopped else { return }
        state = .starting
        bootstrapProgress = 0

        // Create data dir
        try? FileManager.default.createDirectory(at: torDataDir, withIntermediateDirectories: true)

        // Configure Tor
        let config = TorConfiguration()
        config.dataDirectory       = torDataDir
        config.cacheDirectory      = torDataDir
        config.controlSocket       = controlSocketURL
        config.cookieAuthentication = true
        config.clientOnly          = true
        config.avoidDiskWrites     = false
        config.socksPort           = 9050
        config.ignoreMissingTorrc  = true

        // Start Tor thread
        let t = TorThread(configuration: config)
        t.start()
        thread = t

        // Wait for control socket to appear, then connect controller
        connectController(config: config, attempts: 0)
    }

    func stop() {
        statusObserver.map { controller?.removeObserver($0) }
        controller = nil
        thread?.cancel()
        thread = nil
        state = .stopped
        bootstrapProgress = 0
    }

    // MARK: - Controller connection

    private func connectController(config: TorConfiguration, attempts: Int) {
        guard attempts < 30 else {
            state = .failed("Control socket timeout")
            return
        }

        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: self.controlSocketURL.path) else {
                Task { @MainActor in self.connectController(config: config, attempts: attempts + 1) }
                return
            }
            Task { @MainActor in self.authenticate(config: config) }
        }
    }

    private func authenticate(config: TorConfiguration) {
        let ctrl = TORController(socketURL: controlSocketURL)
        controller = ctrl

        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let cookie = config.cookie else {
                Task { @MainActor in self?.state = .failed("No auth cookie") }
                return
            }
            ctrl.authenticate(with: cookie) { [weak self] success, error in
                guard let self else { return }
                Task { @MainActor in
                    if success {
                        self.observeBootstrap(ctrl: ctrl)
                    } else {
                        self.state = .failed(error?.localizedDescription ?? "Auth failed")
                    }
                }
            }
        }
    }

    private func observeBootstrap(ctrl: TORController) {
        // Subscribe to STATUS_CLIENT BOOTSTRAP events
        statusObserver = ctrl.addObserver(forStatusEvents: { [weak self] type, _, action, args in
            guard type == "STATUS_CLIENT", action == "BOOTSTRAP",
                  let progressStr = args?["PROGRESS"],
                  let progress = Int(progressStr) else { return true }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.bootstrapProgress = progress
                if progress >= 100 { self.state = .ready }
            }
            return true
        })

        // Also poll once in case we missed early events
        ctrl.getInfoForKeys(["status/bootstrap-phase"]) { [weak self] values in
            guard let phase = values.first else { return }
            let progress = Self.parseProgress(phase)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.bootstrapProgress = max(self.bootstrapProgress, progress)
                if progress >= 100 { self.state = .ready }
            }
        }
    }

    // MARK: - Helpers

    private static func parseProgress(_ phase: String) -> Int {
        guard let range = phase.range(of: "PROGRESS=") else { return 0 }
        let after = phase[range.upperBound...]
        return Int(after.prefix(3).filter(\.isNumber)) ?? 0
    }
}
