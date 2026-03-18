// TorOnboardingView.swift
// SophaxChat

import SwiftUI

struct TorOnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 32) {
                    Image(systemName: "globe.badge.chevron.backward")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)

                    VStack(spacing: 12) {
                        Text("One step to go global")
                            .font(.title2.weight(.semibold))
                        Text("SophaxChat uses Tor to reach anyone in the world — anonymously, with no server.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    VStack(alignment: .leading, spacing: 20) {
                        StepRow(number: "1", text: "Install **Orbot** from the App Store")
                        StepRow(number: "2", text: "Open Orbot and enable **Tor VPN**")
                        StepRow(number: "3", text: "Come back and tap **Share** to get your address")
                    }
                    .padding(.horizontal, 32)
                }

                Spacer()

                VStack(spacing: 12) {
                    Link(destination: URL(string: "https://apps.apple.com/app/orbot/id1609461599")!) {
                        Text("Get Orbot")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    Button("Done") { dismiss() }
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

private struct StepRow: View {
    let number: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview { TorOnboardingView() }
