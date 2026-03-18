// ContactCardView.swift
// SophaxChat

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
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(uiImage: UIImage(cgImage: cg))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                // QR Code
                Group {
                    if let qr = qrImage {
                        qr
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.systemGray5))
                            .overlay {
                                Text("Complete setup first")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 240, height: 240)
                .padding(20)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.1), radius: 20, y: 8)

                Spacer().frame(height: 32)

                Text("Scan to add me")
                    .font(.title2.weight(.semibold))

                Spacer().frame(height: 8)

                Text("Open SophaxChat → tap \(Image(systemName: "plus")) → scan")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                // Share button
                if let url = contactURL {
                    ShareLink(item: url) {
                        Text("Share")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    ContactCardView().environmentObject(AppState())
}
