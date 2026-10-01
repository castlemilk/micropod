import MicropodCore
import SwiftUI

/// Raw `container inspect` output, pretty-printed.
struct ContainerInspectView: View {
    @Bindable var store: AppStore
    let containerID: String
    /// Inspect JSON source — container inspect by default; machines pass their own.
    private let loadData: (@MainActor () async throws -> Data)?

    init(store: AppStore, containerID: String, loadData: (@MainActor () async throws -> Data)? = nil) {
        self._store = Bindable(store)
        self.containerID = containerID
        self.loadData = loadData
    }

    @State private var document: InspectionDocument?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspect JSON").font(Tokens.Typography.metadata).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document?.text ?? "", forType: .string)
                } label: {
                    IconLabel(title: "Copy", icon: "copy", fallback: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(document == nil)
                .help("Copy complete JSON")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            Group {
                if let document {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(document.lines.indices, id: \.self) { index in
                                Text(String(document.lines[index]))
                                    .font(Tokens.Typography.log)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Inspect Failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: containerID) {
            document = nil
            errorMessage = nil
            do {
                let data: Data
                if let loadData {
                    data = try await loadData()
                } else {
                    data = try await store.dependencies.containers.inspect(containerID)
                }
                guard !Task.isCancelled else { return }
                let formatted = try await InspectionDocument.format(data)
                guard !Task.isCancelled else { return }
                document = formatted
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }
}
