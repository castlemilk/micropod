import MicropodCore
import SwiftUI

/// Image detail sheet: metadata table (digest/created/size/variants) plus
/// inspect-derived labels/env/entrypoint/cmd, with Run…/Copy digest/Tag.
struct ImageDetailSheet: View {
    @Bindable var store: AppStore
    let image: Micropod_V1_Image

    @Environment(\.dismiss) private var dismiss
    @State private var inspect: [String: Any]?
    @State private var inspectError: String?
    @State private var showRun = false
    @State private var showTag = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "photo.stack").foregroundStyle(.secondary)
                Text(primaryName).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(image.digest, forType: .string)
                } label: {
                    IconLabel(title: String(localized: "Copy digest"), icon: "copy", fallback: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(image.digest.isEmpty)
                Button(String(localized: "Run…")) { showRun = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(String(localized: "Tag…")) { showTag = true }
                    .controlSize(.small)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    metadataSection
                    if let inspect { inspectSection(inspect) }
                    if let inspectError {
                        Text(inspectError).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .sheet(isPresented: $showRun) {
            RunContainerSheet(store: store, initialImage: primaryName)
        }
        .sheet(isPresented: $showTag) {
            TagImageSheet(store: store, image: image)
        }
        .task { await loadInspect() }
    }

    // MARK: - Sections

    private var metadataSection: some View {
        section(String(localized: "Metadata")) {
            metaRow(String(localized: "Digest"), image.digest.isEmpty ? "—" : image.digest)
            metaRow(String(localized: "Created"), image.createdAt.isEmpty ? "—" : image.createdAt)
            metaRow(String(localized: "Size"), ByteFormat.string(image.sizeBytes))
            if image.names.count > 1 {
                metaRow(String(localized: "Tags"), image.names.joined(separator: ", "))
            }
        }
    }

    private func inspectSection(_ json: [String: Any]) -> some View {
        section(String(localized: "Inspect")) {
            if let mediaType = json["mediaType"] as? String {
                metaRow(String(localized: "Media type"), mediaType)
            }
            if let config = json["configuration"] as? [String: Any] {
                if let labels = config["labels"] as? [String: String], !labels.isEmpty {
                    ForEach(Array(labels.keys.sorted()), id: \.self) { key in
                        metaRow(String(localized: "Label \(key)"), labels[key] ?? "")
                    }
                }
                if let env = config["env"] as? [String], !env.isEmpty {
                    ForEach(Array(env.enumerated()), id: \.offset) { _, line in
                        metaRow(String(localized: "Env"), line)
                    }
                }
                if let entrypoint = config["entrypoint"] as? [String], !entrypoint.isEmpty {
                    metaRow(String(localized: "Entrypoint"), entrypoint.joined(separator: " "))
                }
                if let cmd = config["cmd"] as? [String], !cmd.isEmpty {
                    metaRow(String(localized: "Cmd"), cmd.joined(separator: " "))
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .padding(8)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.subheadline.monospaced()).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Copy"))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Data

    private var primaryName: String {
        image.names.first ?? image.id
    }

    private func loadInspect() async {
        do {
            let data = try await store.dependencies.images.inspect(primaryName)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            inspect = (root["image"] as? [String: Any]) ?? root
        } catch {
            inspectError = error.localizedDescription
        }
    }
}
