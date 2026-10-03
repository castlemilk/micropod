import MicropodCore
import SwiftUI
import UniformTypeIdentifiers

/// Build tab: BuildKit image builds with live stage progress.
struct BuildView: View {
    @Bindable var store: AppStore

    @State private var contextDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var dockerfile = ""
    @State private var tagsText = ""
    @State private var buildArgsText = ""
    @State private var platform = ""
    @State private var noCache = false
    @State private var cpus = ""
    @State private var memory = ""
    @State private var showContextPicker = false
    @State private var showDockerfilePicker = false
    /// 3.5 — inline Dockerfile editor + build history.
    @State private var dockerfileContent = ""
    @State private var editorEnabled = false
    @State private var buildHistory: [BuildHistoryEntry] = []

    @State private var buildOpID: UUID?
    @State private var availableWidth: CGFloat = 820
    @State private var availableHeight: CGFloat = 600
    @State private var outputExpanded = true
    @State private var progressCache = BuildProgressCache()

    var body: some View {
        let operation = buildOp
        let progress = progressCache.snapshot(for: operation)
        let building = operation?.status == .running
        return VStack(spacing: 0) {
            WorkspacePageHeader(
                title: "Build", subtitle: "Build container images with BuildKit",
                icon: "terminal", fallback: "terminal"
            )
            .padding(Tokens.Spacing.contentInset)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity, alignment: .top)
            Form {
                fileFieldLayout {
                    fileSelectionField(String(localized: "Context"), path: contextDirectory) {
                        Button(String(localized: "Choose…")) { showContextPicker = true }
                    }
                    fileSelectionField(
                        String(localized: "Dockerfile"),
                        path: dockerfile.isEmpty ? String(localized: "Dockerfile (default)") : dockerfile
                    ) {
                        Button(String(localized: "Choose…")) { showDockerfilePicker = true }
                        if !dockerfile.isEmpty {
                            Button(String(localized: "Clear")) { dockerfile = "" }
                        }
                    }
                }
                LabeledContent(String(localized: "Tags")) {
                    TextField(String(localized: "myapp:latest, myapp:v1"), text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel(String(localized: "Tags"))
                }
                LabeledContent(String(localized: "Build args")) {
                    TextField(String(localized: "KEY=VALUE, one per line"), text: $buildArgsText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.subheadline.monospaced())
                        .lineLimit(1...3)
                        .labelsHidden()
                        .accessibilityLabel(String(localized: "Build args"))
                }
                LabeledContent(String(localized: "Platform")) {
                    TextField(String(localized: "linux/amd64 (optional)"), text: $platform)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel(String(localized: "Platform"))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], spacing: 12) {
                    LabeledContent(String(localized: "CPUs")) {
                        TextField("e.g. 2", text: $cpus)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .accessibilityLabel(String(localized: "CPUs"))
                            .frame(maxWidth: 120)
                    }
                    LabeledContent(String(localized: "Memory")) {
                        TextField("e.g. 2G", text: $memory)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .accessibilityLabel(String(localized: "Memory"))
                            .frame(maxWidth: 120)
                    }
                    LabeledContent(String(localized: "No cache")) {
                        Toggle("", isOn: $noCache).labelsHidden().toggleStyle(.switch)
                    }
                }
                Section {
                    DisclosureGroup(String(localized: "Dockerfile editor")) {
                        VStack(alignment: .leading, spacing: 6) {
                            editorToolbarLayout {
                                Toggle(String(localized: "Use editor content for this build"), isOn: $editorEnabled)
                                    .toggleStyle(.checkbox)
                                    .controlSize(.small)
                                Button(String(localized: "Load from file…")) { showDockerfilePicker = true }
                                    .controlSize(.small)
                            }
                            TextEditor(text: $dockerfileContent)
                                .font(.subheadline.monospaced())
                                .frame(minHeight: 140)
                                .scrollContentBackground(.hidden)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                        }
                        .padding(.vertical, 4)
                    }
                    if !buildHistory.isEmpty {
                        DisclosureGroup(String(localized: "Recent builds")) {
                            VStack(spacing: 2) {
                                ForEach(buildHistory) { entry in
                                    HStack(spacing: 6) {
                                        Image(
                                            systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill"
                                        )
                                        .foregroundStyle(entry.succeeded ? .green : .red)
                                        .font(.system(size: 11))
                                        Text(entry.tag.isEmpty ? String(localized: "untagged") : entry.tag)
                                            .font(.caption.monospaced())
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(Int(entry.duration))s")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Text(entry.date.formatted(.relative(presentation: .named)))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 1)
                                }
                            }
                        }
                    }
                }
                Section {
                    DisclosureGroup(String(localized: "Build output"), isExpanded: $outputExpanded) {
                        buildOutput(progress: progress, operation: operation, building: building)
                            .frame(height: min(320, max(140, availableHeight * 0.35)))
                    }
                    if case .failed(let reason) = buildOp?.status {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity, alignment: .top)

            Divider()

            HStack {
                if building {
                    if let current = progress.events.last, current.stage != nil {
                        ProgressView(
                            value: Double(current.stage ?? 0),
                            total: Double(current.totalStages ?? 1)
                        )
                        .frame(maxWidth: 160)
                        Text(current.stageName ?? String(localized: "Building…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(current.stageName ?? String(localized: "Building…"))
                    } else {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Preparing build…")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if building, let buildOpID {
                    Button(String(localized: "Cancel")) {
                        store.cancelOperation(buildOpID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    startBuild()
                } label: {
                    IconLabel(
                        title: building ? String(localized: "Building…") : String(localized: "Build"),
                        icon: "build", fallback: "hammer")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(building || tagsText.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("build.start")
                .formActionBounds("build.start")
            }
            .padding(10)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            availableWidth = $0.width
            availableHeight = $0.height
        }
        .fileImporter(isPresented: $showContextPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                contextDirectory = url.path
            case .failure: break
            }
        }
        .fileImporter(isPresented: $showDockerfilePicker, allowedContentTypes: [.plainText]) { result in
            switch result {
            case .success(let url):
                dockerfile = url.path
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    dockerfileContent = content
                    editorEnabled = true
                }
            case .failure: break
            }
        }
        .onAppear { loadHistory() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onChange(of: buildOp?.status) { _, status in
            if case .succeeded = status {
                recordHistory(succeeded: true)
            } else if case .failed = status {
                recordHistory(succeeded: false)
            }
        }
    }

    private var fileFieldLayout: AnyLayout {
        availableWidth < 880
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
    }

    private var editorToolbarLayout: AnyLayout {
        availableWidth < 720
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    private func fileSelectionField<Actions: View>(
        _ title: String, path: String, @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(path)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions().fixedSize().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buildOutput(
        progress: BuildProgressSnapshot, operation: ActiveOperation?, building: Bool
    ) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(progress.outputText)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(.background)
        .overlay {
            if progress.events.isEmpty && !building && operation == nil {
                Text(
                    String(
                        localized:
                            "Build output appears here. Cache mounts and multi-stage builds are supported. Keep .dockerignore tight for faster context transfers."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
                .padding(12)
            }
        }
    }

    // MARK: - Dockerfile editor / history / drag-drop (3.5)

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            // loadItem's completion is a @Sendable closure off the main actor
            // — hop before touching @State.
            guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                Task { @MainActor in contextDirectory = url.path }
            } else if let content = try? String(contentsOf: url, encoding: .utf8) {
                Task { @MainActor in
                    dockerfile = url.path
                    dockerfileContent = content
                    editorEnabled = true
                }
            }
        }
        return true
    }

    /// Resolves the Dockerfile path for the build: the editor content wins
    /// when enabled (written to a temp file in the context dir).
    private func resolvedDockerfile() -> String? {
        if editorEnabled && !dockerfileContent.isEmpty {
            let path = (contextDirectory as NSString).appendingPathComponent(".micropod-Dockerfile")
            try? dockerfileContent.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }
        return dockerfile.isEmpty ? nil : dockerfile
    }

    private func recordHistory(succeeded: Bool) {
        guard let op = buildOp else { return }
        let entry = BuildHistoryEntry(
            tag: tagsText.trimmingCharacters(in: .whitespaces),
            duration: max(1, Int(Date().timeIntervalSince(op.startedAt))),
            date: Date(),
            succeeded: succeeded)
        buildHistory.insert(entry, at: 0)
        if buildHistory.count > 20 { buildHistory.removeLast(buildHistory.count - 20) }
        if let data = try? JSONEncoder().encode(buildHistory) {
            UserDefaults.standard.set(data, forKey: "buildHistory")
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "buildHistory"),
            let decoded = try? JSONDecoder().decode([BuildHistoryEntry].self, from: data)
        else { return }
        buildHistory = decoded
    }

    private func startBuild() {
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let request = ContainerBuildRequest(
            contextDirectory: contextDirectory,
            dockerfile: resolvedDockerfile(),
            tags: tags,
            buildArgs: buildArgsText.split(separator: "\n").map(String.init),
            platform: platform.isEmpty ? nil : platform,
            noCache: noCache,
            cpus: Double(cpus),
            memory: memory.isEmpty ? nil : memory
        )
        buildOpID = store.startBuild(request: request)
    }

    /// The store-backed build operation (events + status) driving this view.
    private var buildOp: ActiveOperation? {
        guard let buildOpID else { return nil }
        return store.operations.first { $0.id == buildOpID }
    }

}

/// A recorded build outcome, persisted for the Recent builds list.
struct BuildHistoryEntry: Identifiable, Codable {
    let id: UUID
    let tag: String
    let duration: Int
    let date: Date
    let succeeded: Bool

    init(id: UUID = UUID(), tag: String, duration: Int, date: Date, succeeded: Bool) {
        self.id = id
        self.tag = tag
        self.duration = duration
        self.date = date
        self.succeeded = succeeded
    }
}
