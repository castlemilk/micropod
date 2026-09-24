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

    /// Live build progress, streamed from the store's operations drawer.
    private var building: Bool {
        buildOp?.status == .running
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                HStack {
                    LabeledContent(String(localized: "Context")) {
                        HStack {
                            Text(contextDirectory).font(.subheadline.monospaced()).lineLimit(1)
                            Button(String(localized: "Choose…")) { showContextPicker = true }
                                .controlSize(.small)
                        }
                    }
                    LabeledContent(String(localized: "Dockerfile")) {
                        HStack {
                            Text(dockerfile.isEmpty ? String(localized: "Dockerfile (default)") : dockerfile)
                                .font(.subheadline.monospaced())
                                .lineLimit(1)
                            Button(String(localized: "Choose…")) { showDockerfilePicker = true }
                                .controlSize(.small)
                            if !dockerfile.isEmpty {
                                Button(String(localized: "Clear")) { dockerfile = "" }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                LabeledContent(String(localized: "Tags")) {
                    TextField(String(localized: "myapp:latest, myapp:v1"), text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent(String(localized: "Build args")) {
                    TextField(String(localized: "KEY=VALUE, one per line"), text: $buildArgsText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.subheadline.monospaced())
                        .lineLimit(1...3)
                }
                LabeledContent(String(localized: "Platform")) {
                    TextField(String(localized: "linux/amd64 (optional)"), text: $platform)
                        .textFieldStyle(.roundedBorder)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        LabeledContent(String(localized: "CPUs")) {
                            TextField("e.g. 2", text: $cpus).textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                        }
                        LabeledContent(String(localized: "Memory")) {
                            TextField("e.g. 2G", text: $memory).textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                        }
                        LabeledContent(String(localized: "No cache")) {
                            Toggle("", isOn: $noCache).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }
                Section {
                    DisclosureGroup(String(localized: "Dockerfile editor")) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle(String(localized: "Use editor content for this build"), isOn: $editorEnabled)
                                    .toggleStyle(.checkbox)
                                    .controlSize(.small)
                                Spacer()
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
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                if building {
                    if let current = buildEvents.last, current.stage != nil {
                        ProgressView(
                            value: Double(current.stage ?? 0),
                            total: Double(current.totalStages ?? 1))
                        Text(current.stageName ?? String(localized: "Building…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            }
            .padding(10)

            Divider()

            ScrollView {
                Text(buildEvents.map(\.line).joined(separator: "\n"))
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.background)
            .overlay {
                if buildEvents.isEmpty && !building && buildOp == nil {
                    Text(
                        String(
                            localized:
                                "Output appears here. The builder is BuildKit — cache mounts and multi-stage builds are supported. Note: build context transfer is slow for large directories; keep .dockerignore tight."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 320)
                }
            }
            .frame(minHeight: 160)
            if case .failed(let reason) = buildOp?.status {
                Text(reason).font(.caption).foregroundStyle(.red).padding(8)
            }
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

    /// Latest build output lines, capped to keep the pane fast.
    private var buildEvents: [ProgressEvent] {
        guard let op = buildOp else { return [] }
        return Array(op.events.suffix(500)).compactMap { ProgressEvent.parse(line: $0) }
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
