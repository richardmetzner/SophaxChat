// LinkedDevicesView.swift
// SophaxChat
//
// Manage devices linked to this account (same person, multiple devices).
// Device B scans Device A's QR code; both sides then sync 1-to-1 messages.

import SwiftUI
import CoreImage.CIFilterBuiltins
import SophaxChatCore

struct LinkedDevicesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingQR       = false
    @State private var showingScanner  = false
    @State private var deviceToUnlink: KnownPeer? = nil

    var body: some View {
        List {
            Section {
                Button {
                    showingQR = true
                } label: {
                    Label("Show Link QR Code", systemImage: "qrcode")
                }
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan Another Device's QR", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text("To link two devices, open SophaxChat on both. On Device A tap \"Show Link QR Code\", then on Device B tap \"Scan Another Device's QR\" and point the camera at Device A's screen.")
                    .font(.caption2)
            }

            if !appState.linkedDevices.isEmpty {
                Section("Linked Devices") {
                    ForEach(appState.linkedDevices) { peer in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.username)
                                    .font(.subheadline.weight(.medium))
                                Text(String(peer.id.prefix(8)) + "…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if peer.isOnline {
                                Circle().fill(.green).frame(width: 8, height: 8)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deviceToUnlink = peer
                            } label: {
                                Label("Unlink", systemImage: "link.badge.minus")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Linked Devices")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingQR) {
            DeviceLinkQRSheet()
        }
        .sheet(isPresented: $showingScanner) {
            DeviceLinkScannerSheet()
        }
        .confirmationDialog(
            "Unlink \"\(deviceToUnlink?.username ?? "")\"?",
            isPresented: Binding(get: { deviceToUnlink != nil }, set: { if !$0 { deviceToUnlink = nil } }),
            titleVisibility: .visible
        ) {
            Button("Unlink Device", role: .destructive) {
                if let peer = deviceToUnlink { appState.unlinkDevice(peer) }
                deviceToUnlink = nil
            }
            Button("Cancel", role: .cancel) { deviceToUnlink = nil }
        } message: {
            Text("Messages will no longer be forwarded to this device. This cannot be undone.")
        }
    }
}

// MARK: - QR Sheet (this device shows its link payload)

private struct DeviceLinkQRSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var qrData: Data?       = nil
    @State private var secondsLeft: Int    = 0
    private let totalSeconds               = 600   // 10-minute window

    private func makeQRImage(from data: Data) -> Image? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        let ctx    = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(uiImage: UIImage(cgImage: cgImg))
    }

    private func refresh() {
        qrData      = appState.generateDeviceLinkQR()
        secondsLeft = totalSeconds
    }

    private var countdownLabel: String {
        let m = secondsLeft / 60
        let s = secondsLeft % 60
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Scan this QR with your other device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let data = qrData, let img = makeQRImage(from: data) {
                    img
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 260, height: 260)
                        .padding(16)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 4)
                } else {
                    ProgressView()
                        .frame(width: 260, height: 260)
                }

                // Countdown label — turns red in the last 60 seconds
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text("Expires in \(countdownLabel)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(secondsLeft <= 60 ? .red : .secondary)

                Text("Keep both devices nearby (Bluetooth range) after scanning so they can exchange keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Link This Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { refresh() }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if secondsLeft > 0 {
                    secondsLeft -= 1
                } else {
                    refresh()   // auto-regenerate when expired
                }
            }
        }
    }
}

// MARK: - Scanner Sheet (this device scans the other's QR)

private struct DeviceLinkScannerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var scannedResult: String? = nil
    @State private var didLink = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if didLink {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.green)
                        Text("Device Linked!")
                            .font(.title2.weight(.semibold))
                        Text("Messages will sync between your devices when they're in range.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ContactScannerView(scannedResult: $scannedResult)
                }
            }
            .navigationTitle("Scan Device QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: scannedResult) { _, newValue in
                guard let str = newValue,
                      let data = str.data(using: .utf8) else { return }
                appState.acceptDeviceLink(data)
                didLink = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
            }
        }
    }
}
