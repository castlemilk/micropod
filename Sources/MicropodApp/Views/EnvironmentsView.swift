import MicropodCore
import SwiftProtobuf
import SwiftUI
import UniformTypeIdentifiers

/// Environments tab: saved compose environments as cards with up/down,
/// edit, duplicate, export/import, per-environment run counts, and delete.
struct EnvironmentsView: View {
    @Bindable var store: AppStore
    private let usesPreviewData: Bool

    @State private var environments: [SavedEnvironment] = []
    @State private var editing: ComposeEditSelection?
    @State private var showImporter = false
    @State private var exporting: ExportSelection?
    @State private var confirmDelete: String?
    @State private var errorMessage: String?

    struct SavedEnvironment: Identifiable {
        let id: String
        let spec: Micropod_V1_ComposeSpec
        let yamlURL: URL?
        let binURL: URL
    }

    init(store: AppStore, initialEnvironments: [SavedEnvironment]? = nil) {
        self._store = Bindable(store)
        self._environments = State(initialValue: initialEnvironments ?? [])
        self.usesPreviewData = initialEnvironments != nil
    }

    struct ExportSelection: Identifiable {
        let id = UUID()
        let environment: SavedEnvironment
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspacePageHeader(
                title: "Environments",
                subtitle: "\(environments.count) saved \(environments.count == 1 ? "environment" : "environments")",
                icon: "workloads", fallback: "folder"
            ) {
                HStack(spacing: Tokens.Spacing.sm) {
                    Button {
                        showImporter = true
                    } label: {
                        IconLabel(title: String(localized: "Import…"), icon: "import", fallback: "arrow.down.doc")
                    }
                    .controlSize(.small)
                    Button {
                        loadEnvironments()
                    } label: {
                        IconLabel(title: String(localized: "Reload"), icon: "refresh", fallback: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            }
            .padding(Tokens.Spacing.contentInset)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(errorMessage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.Spacing.contentInset)
                    .padding(.bottom, 8)
            }

            Divider()

            if environments.isEmpty {
                EmptyStateView(
                    title: String(localized: "No Saved Environments"),
                    description: String(
                        localized:
                            "Save a compose file from the Compose tab, or import a compose spec here, to manage it as an environment."
                    ),
                    imageName: EmptyStateArtwork.environments,
                    symbol: "folder",
                    actionTitle: String(localized: "Import…"),
                    action: { showImporter = true })
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 460), alignment: .top)], spacing: 12) {
                        ForEach(environments) { environment in
                            EnvironmentCardView(
                                store: store,
                                environment: environment,
                                runCount: runCount(for: environment.spec.name),
                                onEdit: { beginEdit(environment) },
                                onDuplicate: { duplicate(environment) },
                                onExport: { exporting = ExportSelection(environment: environment) },
                                onDelete: { confirmDelete = environment.spec.name },
                                onChanged: { loadEnvironments() })
                        }
                    }
                    .padding(Tokens.Spacing.contentInset)
                    .frame(maxWidth: 1200)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .onAppear { if !usesPreviewData { loadEnvironments() } }
        .sheet(item: $editing) { selection in
            ComposeEditorSheet(store: store, environment: selection.environment, initialYAML: selection.yaml)
                .onDisappear { loadEnvironments() }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.plainText, .data]
        ) { result in
            switch result {
            case .success(let url):
                importEnvironment(url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
            document: TextFile(environmentText(exporting?.environment)),
            contentType: .plainText,
            defaultFilename: "\(exporting?.environment.spec.name ?? "environment").yml"
        ) { result in
            switch result {
            case .success: break
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            String(localized: "Delete environment?"),
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { name in
            Button(String(localized: "Delete"), role: .destructive) { deleteEnvironment(named: name) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { name in
            Text(String(localized: "Removes the saved compose spec for \(name). Running containers are not affected."))
        }
    }

    // MARK: - Load / persist

    private func loadEnvironments() {
        let dir = environmentsDirectory
        let files =
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "bin" } ?? []
        environments = files.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                let spec = try? Micropod_V1_ComposeSpec(serializedBytes: data)
            else { return nil }
            let yamlURL = url.deletingPathExtension().appendingPathExtension("yml")
            return SavedEnvironment(
                id: spec.name,
                spec: spec,
                yamlURL: FileManager.default.fileExists(atPath: yamlURL.path) ? yamlURL : nil,
                binURL: url)
        }
        .sorted { $0.id < $1.id }
    }

    private var environmentsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Micropod/environments", isDirectory: true)
    }

    private func saveEnvironment(spec: Micropod_V1_ComposeSpec, yaml: String) throws {
        let dir = environmentsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data: Data = try spec.serializedBytes()
        try data.write(to: dir.appendingPathComponent("\(spec.name).spec.bin"))
        try yaml.write(to: dir.appendingPathComponent("\(spec.name).yml"), atomically: true, encoding: .utf8)
    }

    private func beginEdit(_ environment: SavedEnvironment) {
        let yaml: String
        if let url = environment.yamlURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            yaml = text
        } else {
            yaml = composeYAML(from: environment.spec)
        }
        editing = ComposeEditSelection(environment: environment, yaml: yaml)
    }

    private func importEnvironment(_ url: URL) {
        let hadAccess = url.startAccessingSecurityScopedResource()
        defer { if hadAccess { url.stopAccessingSecurityScopedResource() } }
        Task {
            do {
                if url.pathExtension == "bin" {
                    let data = try Data(contentsOf: url)
                    let spec = try Micropod_V1_ComposeSpec(serializedBytes: data)
                    try saveEnvironment(spec: spec, yaml: composeYAML(from: spec))
                } else {
                    let yaml = try String(contentsOf: url, encoding: .utf8)
                    let parsed = try await store.dependencies.compose.parse(url: url)
                    try saveEnvironment(spec: parsed, yaml: yaml)
                }
                loadEnvironments()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func duplicate(_ environment: SavedEnvironment) {
        let base = environment.spec.name
        var candidate = "\(base)-copy"
        var n = 2
        while environments.contains(where: { $0.spec.name == candidate }) {
            candidate = "\(base)-copy-\(n)"
            n += 1
        }
        var spec = environment.spec
        spec.name = candidate
        spec.path = ""
        let yaml: String
        if let text = try? String(contentsOf: environment.yamlURL ?? URL(fileURLWithPath: ""), encoding: .utf8) {
            yaml = text
        } else {
            yaml = composeYAML(from: environment.spec)
        }
        do {
            try saveEnvironment(spec: spec, yaml: yaml)
            loadEnvironments()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteEnvironment(named name: String) {
        let dir = environmentsDirectory
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(name).spec.bin"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(name).yml"))
        loadEnvironments()
    }

    private func environmentText(_ environment: SavedEnvironment?) -> String {
        guard let environment else { return "" }
        if let url = environment.yamlURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return composeYAML(from: environment.spec)
    }

    private func runCount(for name: String) -> Int {
        UserDefaults.standard.integer(forKey: "envRunCount.\(name)")
    }
}

/// A compose environment as a card with up/down + manage menu.
struct EnvironmentCardView: View {
    @Bindable var store: AppStore
    let environment: EnvironmentsView.SavedEnvironment
    let runCount: Int
    var onEdit: () -> Void
    var onDuplicate: () -> Void
    var onExport: () -> Void
    var onDelete: () -> Void
    var onChanged: () -> Void

    @State private var isRunning = false
    @State private var statusText: String?
    @State private var availableWidth: CGFloat = 800

    private var isEnvironmentRunning: Bool {
        store.containers.contains {
            $0.labels["com.skunkworq.micropod.compose"] == environment.spec.name && $0.state == "running"
        }
    }

    private var hasContainers: Bool {
        store.containers.contains { $0.labels["com.skunkworq.micropod.compose"] == environment.spec.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardLayout {
                summary
                actions
            }
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            availableWidth = $0
        }
    }

    private var cardLayout: AnyLayout {
        availableWidth < 780
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.stack.3d.up").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(environment.spec.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(environment.spec.name)
                    if runCount > 0 {
                        Text("ran \(runCount)×").font(.caption2).foregroundStyle(Tokens.Palette.tertiary).fixedSize()
                    }
                }
                Text(
                    "\(environment.spec.services.count) services · \(environment.spec.services.map(\.name).joined(separator: ", "))"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(environment.spec.services.map(\.name).joined(separator: ", "))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if isRunning {
                ProgressView().controlSize(.small)
            } else if isEnvironmentRunning {
                Text(String(localized: "running")).font(.caption2.weight(.medium)).foregroundStyle(
                    Tokens.Palette.success)
            } else if hasContainers {
                Text(String(localized: "stopped")).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(String(localized: "not started")).font(.caption2).foregroundStyle(Tokens.Palette.tertiary)
            }
            if availableWidth < 780 {
                Spacer(minLength: 0)
            }
            Menu {
                Button {
                    onEdit()
                } label: {
                    MenuItemIconLabel(title: String(localized: "Edit…"), icon: "edit", fallback: "pencil")
                }
                Button {
                    onDuplicate()
                } label: {
                    MenuItemIconLabel(
                        title: String(localized: "Duplicate"), icon: "duplicate", fallback: "plus.square.on.square")
                }
                Button {
                    onExport()
                } label: {
                    MenuItemIconLabel(
                        title: String(localized: "Export…"), icon: "export", fallback: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    MenuItemIconLabel(title: String(localized: "Delete"), icon: "delete", fallback: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(String(localized: "Environment actions"))
            Button {
                down()
            } label: {
                IconLabel(title: String(localized: "Down"), icon: "composedown", fallback: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRunning)
            Button {
                up()
            } label: {
                IconLabel(title: String(localized: "Up"), icon: "composeup", fallback: "arrow.up.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isRunning)
        }
        .fixedSize(horizontal: availableWidth >= 780, vertical: true)
    }

    private func up() {
        isRunning = true
        statusText = nil
        Task {
            do {
                let plan = try store.dependencies.compose.plan(spec: environment.spec)
                for try await _ in await store.dependencies.compose.up(plan: plan) {}
                statusText = "Running"
                let count = UserDefaults.standard.integer(forKey: "envRunCount.\(environment.spec.name)") + 1
                UserDefaults.standard.set(count, forKey: "envRunCount.\(environment.spec.name)")
                await store.refreshContainers()
                onChanged()
            } catch {
                statusText = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func down() {
        isRunning = true
        statusText = nil
        Task {
            do {
                try await store.dependencies.compose.down(composeName: environment.spec.name)
                statusText = "Stopped"
                await store.refreshContainers()
            } catch {
                statusText = error.localizedDescription
            }
            isRunning = false
        }
    }
}

/// Minimal FileDocument for exporting YAML.
struct TextFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .yaml] }
    var text: String

    init(_ text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Identifiable wrapper for the compose editor sheet.
struct ComposeEditSelection: Identifiable {
    let id: String
    let environment: EnvironmentsView.SavedEnvironment
    let yaml: String

    init(environment: EnvironmentsView.SavedEnvironment, yaml: String) {
        self.id = environment.id
        self.environment = environment
        self.yaml = yaml
    }
}
