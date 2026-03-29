// VideoMessageView.swift
// SophaxChat
//
// Thumbnail bubble for video messages. Tap to play fullscreen.

import SwiftUI
import AVKit
import SophaxChatCore

struct VideoMessageView: View {
    let data: Data
    let isSent: Bool

    @State private var thumbnail: UIImage? = nil
    @State private var showingPlayer = false

    var body: some View {
        ZStack {
            if let thumb = thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 220, maxHeight: 200)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.systemGray5))
                    .frame(width: 220, height: 160)
            }

            // Play button overlay
            ZStack {
                Circle()
                    .fill(.black.opacity(0.5))
                    .frame(width: 48, height: 48)
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .offset(x: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSent ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onTapGesture { showingPlayer = true }
        .task { await generateThumbnail() }
        .fullScreenCover(isPresented: $showingPlayer) {
            VideoPlayerSheet(data: data)
        }
    }

    private func generateThumbnail() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try data.write(to: tempURL)
            let asset = AVURLAsset(url: tempURL)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            let cgImage = try await gen.image(at: time).image
            thumbnail = UIImage(cgImage: cgImage)
        } catch {
            // No thumbnail — player overlay still available
        }
    }
}

// MARK: - Fullscreen player

private struct VideoPlayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let data: Data

    @State private var player:   AVPlayer? = nil
    @State private var videoURL: URL?      = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            Button {
                player?.pause()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(16)
            }
        }
        .onAppear {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            try? data.write(to: url)
            videoURL = url
            player = AVPlayer(url: url)
            player?.play()
        }
        .onDisappear {
            if let url = videoURL {
                try? FileManager.default.removeItem(at: url)
                videoURL = nil
            }
        }
    }
}
