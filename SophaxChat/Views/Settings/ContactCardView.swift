// ContactCardView.swift
// SophaxChat
//
// Displays a shareable contact card: QR code + deep link for establishing
// a Tor-based connection with another SophaxChat user anywhere in the world.
// No server involved — the link encodes the peer's identity key and .onion address.

import SwiftUI
import CoreImage.CIFilterBuiltins
import SophaxChatCore

struct ContactCardView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var contactURL: URL? {
        guard let peerID = appState.chatManager?.identity.publicIdentity.peerID,
              let onion  = appState.derivedOnionHostname else { return nil }
        let port = appState.tcpPort.isEmpty ? "25519" : appState.tcpPort
        var comps = URLComponents()
        comps.scheme = "sophaxchat"
        comps.host   = "add"
        comps.queryItems = [
            URLQueryItem(name: "id",    value: peerID),
            URLQueryItem(name: "onion", value: onion),
            URLQueryItem(name: "port",  value: port),
        ]
        return comps.url
    }

    private var qrImage: Image? {
        guard let url = contactURL else { return nil }
        let context = CIContext()
        let filter  = CIFilter.qrCodeGenerator()
        filter.message         = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scale up to ~300×300 pt
        let scale     = 8.0
        let scaled    = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg  = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(uiImage: UIImage(cgImage: cg))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // QR code
                    if let qr = qrImage {
                        qr
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 260, height: 260)
                            .padding(16)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    } else {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color(.systemGray5))
                            .frame(width: 260, height: 260)
                            .overlay {
                                Text("Address not available.\nComplete setup first.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                    }

                    // Address display
                    if let addr = appState.derivedOnionAddress {
                        VStack(spacing: 6) {
                            Text("Your Tor Address")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Text(addr)
                                .font(.system(.caption, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 24)
                    }

                    Text("Share this card with anyone, anywhere in the world.\nThey scan it with SophaxChat to connect securely over Tor.\nNo server. No registration. Fully encrypted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    // Action buttons
                    VStack(spacing: 12) {
                        if let url = contactURL {
                            ShareLink(item: url) {
                                Label("Share Link", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }

                        if let addr = appState.derivedOnionAddress {
                            Button {
                                UIPasteboard.general.string = addr
                            } label: {
                                Label("Copy Address", systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                    .padding(.horizontal, 32)
                }
                .padding(.vertical, 32)
            }
            .navigationTitle("Contact Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ContactCardView().environmentObject(AppState())
}
