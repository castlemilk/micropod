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
            HStack(alignment: .top, spacing: Tokens.Spacing.md) {
                WorkspaceIconTile(name: "images", fallback: "square.stack")
                Text(primaryName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.middle)
                    .help(primaryName)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    metadataSection
                    if let inspect { inspectSection(inspect) }
                    if let inspectError {
                        Text(inspectError).font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(4)
            }

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(image.digest, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy digest")
                .accessibilityLabel("Copy digest")
                .disabled(image.digest.isEmpty)
                Button(String(localized: "Tag…")) { showTag = true }
                Spacer(minLength: 8)
                Button(String(localized: "Run…")) { showRun = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.Palette.action)
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .background(Tokens.Palette.canvas)
        .frame(minWidth: 320, idealWidth: 520, maxWidth: 780, minHeight: 260, idealHeight: 460, maxHeight: 760)
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

    private func section<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        PanelCard(title: title) {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        InspectorFieldRow(label: label, value: value)
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
