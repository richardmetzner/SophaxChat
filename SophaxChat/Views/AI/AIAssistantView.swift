// AIAssistantView.swift
// SophaxChat
//
// Local AI assistant powered by Apple Foundation Models.
// Runs entirely on-device — no server, no API key, no data leaves the phone.
// Requires Xcode 26 SDK + iOS 26 with Apple Intelligence enabled.

import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Entry point

struct AIAssistantView: View {
    var body: some View {
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            AIAssistantViewImpl()
        } else {
            UnavailableView()
        }
#else
        UnavailableView()
#endif
    }
}

// MARK: - Unavailable placeholder

private struct UnavailableView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Requires iOS 26")
                .font(.title3.weight(.semibold))
            Text("Update to iOS 26 with Apple Intelligence enabled to use the on-device assistant.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Implementation (only compiled when FoundationModels SDK is present)

#if canImport(FoundationModels)

@available(iOS 26.0, *)
private struct AIAssistantViewImpl: View {
    @StateObject private var ai = AISession()
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messagesView
            Divider()
            inputBar
        }
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !ai.messages.isEmpty {
                    Button("Clear") { ai.reset() }
                        .font(.subheadline)
                }
            }
        }
    }

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if ai.messages.isEmpty { emptyState }
                    ForEach(ai.messages) { msg in AIBubble(message: msg) }
                    if ai.isThinking {
                        HStack {
                            ThinkingBubble()
                            Spacer(minLength: 60)
                        }
                        .padding(.horizontal, 16)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.top, 8)
            }
            .onChange(of: ai.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") }
            }
            .onChange(of: ai.isThinking) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("On-device AI")
                .font(.title3.weight(.semibold))
            Text("Runs on your device.\nNothing leaves your phone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if ai.isUnavailable {
                Text("Apple Intelligence is not enabled on this device.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 72)
        .padding(.horizontal, 40)
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Message", text: $text, axis: .vertical)
                .focused($focused)
                .lineLimit(1...5)
                .autocorrectionDisabled()
                .textContentType(.none)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? Color.accentColor : .secondary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty && !ai.isThinking && !ai.isUnavailable
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        text = ""
        Task { await ai.send(trimmed) }
    }
}

@available(iOS 26.0, *)
@MainActor
private final class AISession: ObservableObject {
    @Published var messages: [AIMessage] = []
    @Published var isThinking = false
    @Published var isUnavailable = false

    private var session: LanguageModelSession?

    private static let instructions = """
        You are a private local AI assistant inside SophaxChat — a secure, serverless chat app. \
        Be concise and direct. You can help with: drafting messages, summarizing conversations, \
        translating text, and answering questions. \
        You run entirely on this device. No data ever leaves the phone.
        """

    init() {
        switch SystemLanguageModel.default.availability {
        case .available:
            session = LanguageModelSession(instructions: Self.instructions)
        default:
            isUnavailable = true
        }
    }

    func send(_ text: String) async {
        messages.append(AIMessage(body: text, isUser: true))
        isThinking = true
        defer { isThinking = false }
        guard let session else { return }
        do {
            let response = try await session.respond(to: text)
            messages.append(AIMessage(body: response.content, isUser: false))
        } catch {
            messages.append(AIMessage(body: "Couldn't process that. Try again.", isUser: false))
        }
    }

    func reset() {
        messages.removeAll()
        session = LanguageModelSession(instructions: Self.instructions)
    }
}

private struct AIMessage: Identifiable {
    let id = UUID()
    let body: String
    let isUser: Bool
}

private struct AIBubble: View {
    let message: AIMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.isUser { Spacer(minLength: 60) }
            Text(message.body)
                .font(.body)
                .foregroundStyle(message.isUser ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.isUser ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            if !message.isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 16)
    }
}

private struct ThinkingBubble: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 7, height: 7)
                    .offset(y: animating ? -4 : 0)
                    .animation(
                        .easeInOut(duration: 0.45).repeatForever().delay(Double(i) * 0.15),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onAppear { animating = true }
    }
}

#endif

#Preview {
    NavigationStack { AIAssistantView() }
}
