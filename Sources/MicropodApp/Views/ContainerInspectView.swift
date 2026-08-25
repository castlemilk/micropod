import MicropodCore
import SwiftUI

/// Raw `container inspect` output, pretty-printed.
struct ContainerInspectView: View {
    @Bindable var store: AppStore
    let containerID: String

    @State private var json: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let json {
                ScrollView {
                    Text(json)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Inspect Failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            do {
                let data = try await store.dependencies.containers.inspect(containerID)
                let object = try JSONSerialization.jsonObject(with: data)
                let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                json = String(data: pretty, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if json != nil {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json ?? "", forType: .string)
                } label: {
                    IconLabel(title: "Copy", icon: "copy", fallback: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(12)
            }
        }
    }
}
