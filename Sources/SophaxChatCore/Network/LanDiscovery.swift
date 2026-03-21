// LanDiscovery.swift
// SophaxChatCore
//
// mDNS/Bonjour discovery — enables automatic iOS ↔ Android peer discovery
// on the same WiFi network, without any central server.
//
// Both platforms advertise "_sophaxchat._tcp." on port 25519.
// On discovery, the resolved address is passed to the delegate which
// initiates a TCP connection. From there the normal Hello / X3DH handshake
// takes over — this file is transport-only, no crypto.

import Foundation

public protocol LanDiscoveryDelegate: AnyObject {
    /// Called when a peer's TCP address has been resolved. Implementor should
    /// call `ChatManager.connectViaTCP(address:)` with the provided address.
    func lanDiscovery(didFind address: String)
}

public final class LanDiscovery: NSObject {

    // _sophaxchat._tcp. on port 25519 (Curve25519 homage — same as TCPTransport)
    private static let serviceType = "_sophaxchat._tcp."
    private static let port: Int32 = 25519

    private var netService: NetService?
    private var browser: NetServiceBrowser?
    private var myServiceName: String?

    /// Active resolved services — keyed by service name to avoid duplicate TCP connects.
    private var resolved = Set<String>()

    public weak var delegate: LanDiscoveryDelegate?

    public override init() { super.init() }

    // MARK: - Public

    /// Start advertising and browsing. Call from the main thread (or ChatManager's queue).
    public func start(peerID: String) {
        myServiceName = peerID

        // Advertise ourselves so others can find us
        let svc = NetService(
            domain: "local.",
            type:   Self.serviceType,
            name:   peerID,
            port:   Self.port
        )
        svc.delegate = self
        svc.publish()
        netService = svc

        // Browse for others
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        browser = b
    }

    public func stop() {
        netService?.stop()
        browser?.stop()
        netService = nil
        browser = nil
        resolved.removeAll()
    }
}

// MARK: - NetServiceBrowserDelegate

extension LanDiscovery: NetServiceBrowserDelegate {

    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        // Skip ourselves
        guard service.name != myServiceName else { return }
        // Skip peers we've already connected to this session
        guard !resolved.contains(service.name) else { return }

        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        resolved.remove(service.name)
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        // Browse error — non-fatal, discovery will be absent until next restart
    }
}

// MARK: - NetServiceDelegate

extension LanDiscovery: NetServiceDelegate {

    public func netServiceDidPublish(_ sender: NetService) {
        // Advertising confirmed — no action needed
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        // Publication failure (e.g., port already in use) — non-fatal
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        // `hostName` is the resolved mDNS hostname (e.g. "iPhone.local")
        guard let host = sender.hostName else { return }
        resolved.insert(sender.name)
        delegate?.lanDiscovery(didFind: "\(host):\(sender.port)")
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // Resolution failure — non-fatal, peer will be re-discovered on next browse cycle
    }
}
