import MicropodCore
import SwiftUI
import UniformTypeIdentifiers

/// Copy files between host and container (`container copy`).
struct ContainerFilesView: View {
    @Bindable var store: AppStore
    let containerID: String

    @State private var lastResult: String?
    @State private var lastError: String?
    @State private var showImporter = false
    @State private var showExporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                PanelCard(title: "Copy Into Container", icon: "container") {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                        Text("Pick a local file — it will be copied to /tmp inside \(containerID).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            showImporter = true
                        } label: {
                            IconLabel(title: "Choose File…", icon: "choosefile", fallback: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Tokens.Palette.action)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                PanelCard(title: "Copy Out of Container", icon: "external-link") {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                        Text("Copy a file from /tmp inside \(containerID) to a local location.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("File name in /tmp", text: $lastCopiedOutName)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline.monospaced())
                            .accessibilityLabel("File name in container /tmp")
                        Button {
                            showExporter = true
                        } label: {
                            IconLabel(title: "Choose Destination…", icon: "choosedest", fallback: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(lastCopiedOutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(Tokens.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let lastResult {
                    Text(lastResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(Tokens.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tokens.Palette.canvas)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                copyIn(url)
            case .failure(let error):
                lastError = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: CopyOutDocument(),
            contentType: .item,
            defaultFilename: lastCopiedOutName.isEmpty
                ? "file" : URL(fileURLWithPath: lastCopiedOutName).lastPathComponent
        ) { result in
            switch result {
            case .success(let url):
                copyOut(url)
            case .failure(let error):
                lastError = error.localizedDescription
            }
        }
    }

    @State private var lastCopiedOutName = ""

    private func copyIn(_ url: URL) {
        Task {
            let hadAccess = url.startAccessingSecurityScopedResource()
            defer { if hadAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                try await store.dependencies.containers.copy(
                    from: url.path, to: "\(containerID):/tmp/\(url.lastPathComponent)")
                lastResult = "Copied \(url.lastPathComponent) to /tmp/ inside \(containerID)"
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func copyOut(_ url: URL) {
        let name = lastCopiedOutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                try await store.dependencies.containers.copy(
                    from: "\(containerID):/tmp/\(name)", to: url.path)
                lastResult = "Copied /tmp/\(name) from \(containerID)"
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}

/// Placeholder document so the exporter can present a save dialog.
/// `copyOut` overwrites the created file with the container's file.
struct CopyOutDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    init() {}

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}
