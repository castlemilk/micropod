import MicropodCore
import SwiftUI

/// Interactive PTY terminal into a container (`container exec -it`).
///
/// v1 renders plain text (ANSI sequences stripped); control signals are
/// exposed as toolbar buttons.
struct ContainerTerminalView: View {
    @Bindable var store: AppStore
    let containerID: String

    @State private var output = ""
    @State private var input = ""
    @State private var sessionStream: AsyncThrowingStream<Data, Error>?
    @State private var sessionID: UUID?
    @State private var sessionError: String?
    @State private var attached = false
    @State private var autoScroll = true
    @FocusState private var inputFocused: Bool
    private let shell = UserDefaults.standard.string(forKey: UserDefaultsKeys.terminalShell) ?? "/bin/sh"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(attached ? "Attached to \(containerID) · \(shell)" : "Attaching to \(containerID)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                signalButton("Ctrl+C", "^C", 0x03)
                signalButton("Ctrl+D", "^D", 0x04)
                signalButton("Ctrl+Z", "^Z", 0x1A)
                Button {
                    detach()
                } label: {
                    IconLabel(title: "Detach", icon: "detach", fallback: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(output.isEmpty ? "Press Enter to open the shell…" : output)
                        .font(.subheadline.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("output")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .onChange(of: output.count) {
                    if autoScroll {
                        proxy.scrollTo("output", anchor: .bottom)
                    }
                }
            }
            .background(.background)

            Divider()

            HStack(spacing: 8) {
                TextField("Command…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline.monospaced())
                    .focused($inputFocused)
                    .onSubmit { sendInput() }
                    .disabled(!attached)
                Button {
                    sendInput()
                } label: {
                    IconLabel(title: "Send", icon: "send", fallback: "paperplane")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!attached)
            }
            .padding(8)
        }
        .onAppear { attach() }
        .onDisappear { detach() }
    }

    private func signalButton(_ label: String, _ title: String, _ byte: UInt8) -> some View {
        Button(label) {
            sendBytes(Data([byte]))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!attached)
        .help(title)
    }

    private func attach() {
        guard !attached else { return }
        Task {
            do {
                let connection = try await store.dependencies.terminal.open(containerID: containerID, shell: shell)
                sessionID = connection.sessionID
                sessionStream = connection.stream
                await MainActor.run {
                    attached = true
                    inputFocused = true
                }
                consume(connection.stream)
            } catch {
                sessionError = error.localizedDescription
            }
        }
    }

    private func consume(_ stream: AsyncThrowingStream<Data, Error>) {
        Task {
            do {
                for try await chunk in stream {
                    if let text = String(data: chunk, encoding: .utf8) {
                        output += stripANSI(text)
                        if output.count > 200_000 {
                            output.removeFirst(output.count - 200_000)
                        }
                    }
                }
                await MainActor.run { attached = false }
            } catch {
                sessionError = error.localizedDescription
                await MainActor.run { attached = false }
            }
        }
    }

    private func sendInput() {
        sendBytes(Data((input + "\n").utf8))
        input = ""
    }

    private func sendBytes(_ data: Data) {
        guard let sessionID else { return }
        Task {
            do {
                try await store.dependencies.terminal.write(data, to: sessionID)
            } catch {
                sessionError = error.localizedDescription
            }
        }
    }

    private func detach() {
        if let sessionID {
            Task { try? await store.dependencies.terminal.close(sessionID: sessionID) }
        }
        self.sessionID = nil
        sessionStream = nil
        attached = false
    }

    /// Minimal ANSI stripping — v1 shows plain text.
    private func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])"#,
            with: "",
            options: .regularExpression
        )
    }
}
