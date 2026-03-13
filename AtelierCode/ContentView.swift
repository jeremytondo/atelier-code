//
//  ContentView.swift
//  AtelierCode
//
//  Created by Jeremy Margaritondo on 3/12/26.
//

import SwiftUI

struct ContentView: View {
    @Bindable var store: CodexStore

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.messages.isEmpty {
                            placeholder
                        }

                        ForEach(store.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(20)
                }
                .background(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor),
                            Color(nsColor: .underPageBackgroundColor)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

                Divider()

                composer
            }
            .frame(minWidth: 640, minHeight: 520)
            .background(Color(nsColor: .controlBackgroundColor))
            .task {
                guard !isRunningInPreview else { return }
                await store.connectIfNeeded()
            }
            .onChange(of: store.scrollTargetMessageID) { _, newValue in
                guard let newValue else { return }

                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex App Server PoC")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("Local WebSocket session at 127.0.0.1:4500")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(store.statusText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(store.isErrorVisible ? Color.red : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(store.isErrorVisible ? Color.red.opacity(0.12) : Color.black.opacity(0.05))
                )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.thinMaterial)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Waiting for your first prompt")
                .font(.title3.weight(.semibold))

            Text("The app connects on launch, creates a single thread, and streams assistant text into one live response bubble.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Ask the local Codex server anything…", text: $store.draftPrompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1 ... 5)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .foregroundStyle(Color(nsColor: .textColor))
                .disabled(store.isSending)
                .onSubmit {
                    Task {
                        await store.sendPrompt()
                    }
                }

            Button {
                Task {
                    await store.sendPrompt()
                }
            } label: {
                Text(store.isSending ? "Streaming" : "Send")
                    .frame(minWidth: 88)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!store.canSendPrompt)
        }
        .padding(20)
        .background(.ultraThinMaterial)
    }

    private var isRunningInPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

#Preview {
    ContentView(store: CodexStore())
}

private struct MessageRow: View {
    let message: ConversationMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 60)
            }

            messageContent
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 460, alignment: .leading)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )

            if message.role != .user {
                Spacer(minLength: 60)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.text.isEmpty, message.role == .assistant {
            Text("Waiting for assistant response...")
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
        } else {
            Text(message.text)
                .textSelection(.enabled)
                .font(.body)
                .foregroundStyle(foregroundColor)
        }
    }

    private var foregroundColor: Color {
        switch message.role {
        case .assistant:
            return Color(nsColor: .textColor)
        case .system:
            return Color.secondary
        case .user:
            return .white
        }
    }

    private var bubbleBackground: AnyShapeStyle {
        switch message.role {
        case .assistant:
            return AnyShapeStyle(
                Color(nsColor: .textBackgroundColor)
            )
        case .system:
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        case .user:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color(red: 0.15, green: 0.35, blue: 0.74), Color(red: 0.09, green: 0.55, blue: 0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var borderColor: Color {
        switch message.role {
        case .assistant:
            return Color(nsColor: .separatorColor).opacity(0.35)
        case .system:
            return Color(nsColor: .separatorColor).opacity(0.25)
        case .user:
            return Color.white.opacity(0.18)
        }
    }
}
