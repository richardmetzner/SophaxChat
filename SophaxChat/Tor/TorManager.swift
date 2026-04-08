// TorManager.swift
// SophaxChat
//
// Manages embedded Tor lifecycle. No Orbot required.
// Provides a local SOCKS5 proxy on 127.0.0.1:9050 once ready.

import Foundation
import Network

#if !targetEnvironment(macCatalyst)
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
    /// Hostname of our v3 hidden service (without port), set once Tor reaches 100% bootstrap.
    /// Equals `OnionAddress.from(ed25519PublicKey:)` when started with an identity seed.
    @Published private(set) var hiddenServiceHostname: String? = nil

    /// SOCKS5 proxy string to pass to TCPTransport when ready.
    static let socksProxy = "127.0.0.1:9050"

    // MARK: - Private

    private var thread: TorThread?
    private var controller: TorController?
    private var statusObserver: Any?
    /// 32-byte Ed25519 private key seed — stored only long enough to write the HS key file.
    private var pendingIdentitySeed: Data? = nil

    private var torDataDir: URL {
        let app = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return app.appendingPathComponent("tor_data", isDirectory: true)
    }

    private var hiddenServiceDir: URL {
        torDataDir.appendingPathComponent("hidden_service", isDirectory: true)
    }

    private var controlSocketURL: URL {
        torDataDir.appendingPathComponent("control.socket")
    }

    // MARK: - Lifecycle

    private init() {}

    /// Call before `start()` to bind the hidden service address to the user's identity key.
    /// If not called, Tor generates a random hidden service key on first run.
    func configureHiddenService(ed25519PrivateKeySeed seed: Data) {
        pendingIdentitySeed = seed
    }

    /// Starts embedded Tor. Safe to call multiple times — no-op if already starting/ready.
    func start() {
        guard state == .stopped else { return }
        state = .starting
        bootstrapProgress = 0
        hiddenServiceHostname = nil

        // Create data dir
        try? FileManager.default.createDirectory(at: torDataDir, withIntermediateDirectories: true)

        // Write deterministic hidden service key file so .onion == identity key.
        if let seed = pendingIdentitySeed {
            try? HiddenServiceKeyWriter.write(to: hiddenServiceDir, seed: seed)
            pendingIdentitySeed = nil
        }

        // Configure Tor
        let config = TorConfiguration()
        config.dataDirectory        = torDataDir
        config.cacheDirectory       = torDataDir
        config.controlSocket        = controlSocketURL
        config.cookieAuthentication = true
        config.avoidDiskWrites      = false
        config.socksPort            = 9050
        config.ignoreMissingTorrc   = true
        // Hidden service: serve on port 25519, forward to local TCP listener.
        config.hiddenServiceDirectory = hiddenServiceDir
        config.options["HiddenServicePort"]    = "25519 127.0.0.1:25519"
        config.options["HiddenServiceVersion"] = "3"

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
        let ctrl = TorController(socketURL: controlSocketURL)
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

    private func observeBootstrap(ctrl: TorController) {
        // Subscribe to STATUS_CLIENT BOOTSTRAP events
        statusObserver = ctrl.addObserver(forStatusEvents: { [weak self] type, _, action, args in
            guard type == "STATUS_CLIENT", action == "BOOTSTRAP",
                  let progressStr = args?["PROGRESS"],
                  let progress = Int(progressStr) else { return true }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.bootstrapProgress = progress
                if progress >= 100 {
                    self.readHiddenServiceHostname()
                    self.state = .ready
                }
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
                if progress >= 100 {
                    self.readHiddenServiceHostname()
                    self.state = .ready
                }
            }
        }
    }

    /// Reads the `.onion` hostname from the hidden service directory once Tor has written it.
    private func readHiddenServiceHostname() {
        let hostnameURL = hiddenServiceDir.appendingPathComponent("hostname")
        guard let raw = try? String(contentsOf: hostnameURL, encoding: .utf8) else { return }
        let hostname = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hostname.hasSuffix(".onion"), hostname.count == 62 else { return }
        hiddenServiceHostname = hostname
    }

    // MARK: - Helpers

    private static func parseProgress(_ phase: String) -> Int {
        guard let range = phase.range(of: "PROGRESS=") else { return 0 }
        let after = phase[range.upperBound...]
        return Int(after.prefix(3).filter(\.isNumber)) ?? 0
    }
}
#endif // !targetEnvironment(macCatalyst)
