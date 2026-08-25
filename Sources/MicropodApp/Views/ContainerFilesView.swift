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
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Copy Into Container") {
                HStack {
                    Text("Pick a local file — it will be copied to /tmp inside \(containerID).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showImporter = true
                    } label: {
                        IconLabel(title: "Choose File…", icon: "choosefile", fallback: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(4)
            }

            GroupBox("Copy Out of Container") {
                HStack {
                    Text("Copy /tmp/<file> from \(containerID) to a local location.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showExporter = true
                    } label: {
                        IconLabel(title: "Choose Destination…", icon: "choosedest", fallback: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(4)
            }

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let lastResult {
                Text(lastResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
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
            defaultFilename: lastCopiedOutName ?? "file"
        ) { result in
            switch result {
            case .success(let url):
                copyOut(url)
            case .failure(let error):
                lastError = error.localizedDescription
            }
        }
    }

    @State private var lastCopiedOutName: String?

    private func copyIn(_ url: URL) {
        let hadAccess = url.startAccessingSecurityScopedResource()
        defer { if hadAccess { url.stopAccessingSecurityScopedResource() } }
        Task {
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
        guard let name = lastCopiedOutName else { return }
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
