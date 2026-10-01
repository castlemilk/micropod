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
    @State private var sessionID: UUID?
    @State private var sessionError: String?
    @State private var attached = false
    @State private var isConnecting = false
    @State private var autoScroll = true
    @State private var wrap = true
    @State private var attachTask: Task<Void, Never>?
    @State private var consumeTask: Task<Void, Never>?
    @State private var attachGeneration = UUID()
    @State private var discardedBytes = 0
    @State private var outputRevision: UInt64 = 0
    @FocusState private var inputFocused: Bool
    private let shell = UserDefaults.standard.string(forKey: UserDefaultsKeys.terminalShell) ?? "/bin/sh"

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 600
            VStack(spacing: 0) {
                if compact {
                    VStack(alignment: .leading, spacing: 8) {
                        connectionStatus
                        terminalControls(compact: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else {
                    HStack(spacing: 12) {
                        connectionStatus
                        Spacer(minLength: 8)
                        terminalControls(compact: false)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                if let sessionError {
                    Text(sessionError)
                        .font(Tokens.Typography.metadata)
                        .foregroundStyle(Tokens.Palette.danger)
                        .lineLimit(3)
                        .help(sessionError)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
                if discardedBytes > 0 {
                    Text("Older output discarded · 256 KiB scrollback")
                        .font(Tokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
                Divider()

                ScrollViewReader { proxy in
                    ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                        Text(output.isEmpty ? "Press Enter to open the shell…" : output)
                            .font(Tokens.Typography.log)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: !wrap, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("output")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .onChange(of: outputRevision) {
                        if autoScroll {
                            proxy.scrollTo("output", anchor: .bottom)
                        }
                    }
                    .onChange(of: autoScroll) { _, enabled in
                        if enabled { proxy.scrollTo("output", anchor: .bottom) }
                    }
                }
                .background(Tokens.Palette.surface)

                Divider()

                HStack(spacing: 8) {
                    TextField("Command…", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .font(Tokens.Typography.log)
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
        }
        .onAppear { attach() }
        .onDisappear { detach() }
        .onChange(of: containerID) { _, _ in
            detach()
            output = ""
            discardedBytes = 0
            input = ""
            attach()
        }
    }

    private var connectionStatus: some View {
        Text(
            attached
                ? "Attached to \(containerID) · \(shell)"
                : isConnecting ? "Attaching to \(containerID)…" : "Detached from \(containerID)"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help("\(containerID) · \(shell)")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func terminalControls(compact: Bool) -> some View {
        HStack(spacing: 8) {
            signalButton("Ctrl+C", "Interrupt", 0x03)
            if !compact {
                signalButton("Ctrl+D", "End of input", 0x04)
                signalButton("Ctrl+Z", "Suspend", 0x1A)
            }
            Menu {
                if compact {
                    Button("Ctrl+D — End of input") { sendBytes(Data([0x04])) }.disabled(!attached)
                    Button("Ctrl+Z — Suspend") { sendBytes(Data([0x1A])) }.disabled(!attached)
                    Divider()
                }
                Toggle("Wrap lines", isOn: $wrap)
                Toggle("Follow output", isOn: $autoScroll)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .accessibilityLabel("Terminal controls")
            if compact { Spacer(minLength: 4) }
            Button {
                detach()
            } label: {
                IconLabel(title: "Detach", icon: "detach", fallback: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
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
        attachTask?.cancel()
        sessionError = nil
        isConnecting = true
        let requestedID = containerID
        let generation = UUID()
        attachGeneration = generation
        attachTask = Task {
            do {
                let connection = try await store.dependencies.terminal.open(containerID: requestedID, shell: shell)
                guard !Task.isCancelled, requestedID == containerID, attachGeneration == generation else {
                    try? await store.dependencies.terminal.close(sessionID: connection.sessionID)
                    return
                }
                sessionID = connection.sessionID
                await MainActor.run {
                    attached = true
                    isConnecting = false
                    inputFocused = true
                }
                consume(connection.stream, session: connection.sessionID)
            } catch {
                if !Task.isCancelled, attachGeneration == generation {
                    sessionError = error.localizedDescription
                    isConnecting = false
                }
            }
        }
    }

    private func consume(_ stream: AsyncThrowingStream<Data, Error>, session: UUID) {
        consumeTask?.cancel()
        let snapshots = CoalescedUIStream.snapshots(
            from: stream, initial: BoundedTerminalRenderBuffer(),
            append: { $0.append($1) }, finish: { $0.finish() }, snapshot: { $0.snapshot })
        consumeTask = Task {
            do {
                for try await snapshot in snapshots {
                    guard !Task.isCancelled, sessionID == session else { break }
                    output = snapshot.text
                    discardedBytes = snapshot.discardedBytes
                    outputRevision &+= 1
                }
                if sessionID == session { attached = false }
            } catch {
                if !Task.isCancelled, sessionID == session {
                    sessionError = error.localizedDescription
                    attached = false
                }
            }
            try? await store.dependencies.terminal.close(sessionID: session)
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
                if self.sessionID == sessionID { sessionError = error.localizedDescription }
            }
        }
    }

    private func detach() {
        attachGeneration = UUID()
        attachTask?.cancel()
        attachTask = nil
        consumeTask?.cancel()
        consumeTask = nil
        if let sessionID {
            Task { try? await store.dependencies.terminal.close(sessionID: sessionID) }
        }
        self.sessionID = nil
        attached = false
        isConnecting = false
    }

}
