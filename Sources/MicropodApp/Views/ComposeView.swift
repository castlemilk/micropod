import MicropodCore
import SwiftProtobuf
import SwiftUI
import UniformTypeIdentifiers

/// Compose tab: import docker-compose.yml → review plan → up/down.
/// The plan renders as a live vertical stepper (pending → running → ✓/✕),
/// with a per-step raw log and per-service live log streams.
struct ComposeView: View {
    @Bindable var store: AppStore

    @State private var spec: Micropod_V1_ComposeSpec?
    @State private var plan: ComposePlan?
    @State private var showImporter = false
    @State private var parseError: String?
    @State private var running = false
    @State private var runError: String?
    @State private var saved = false
    @State private var enabledProfiles: Set<String> = []
    @State private var run: ComposeRunState = .init()
    @State private var serviceLogs: Set<String> = []
    @State private var rawYAML: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if spec != nil {
                    Button {
                        saveEnvironment()
                    } label: {
                        saved
                            ? IconLabel(title: String(localized: "Saved"), icon: "save", fallback: "checkmark")
                            : IconLabel(
                                title: String(localized: "Save"), icon: "save", fallback: "square.and.arrow.down")
                    }
                    .controlSize(.small)
                    .disabled(saved)
                }
                Button {
                    showImporter = true
                } label: {
                    IconLabel(
                        title: String(localized: "Import compose file…"), icon: "import", fallback: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)

            if let spec, !availableProfiles.isEmpty {
                profileBar(spec)
            }

            Divider()

            if let spec {
                specSummary(spec)
            } else if let parseError {
                ContentUnavailableView(
                    String(localized: "Compose Import Failed"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(parseError))
            } else {
                EmptyStateView(
                    title: String(localized: "No Compose File"),
                    description: String(
                        localized:
                            "Import a docker-compose.yml to orchestrate multi-container environments on the container runtime. Apple's `container` has no native compose — Micropod translates it: networks, volumes, builds, ordered starts, and real healthcheck-based readiness probes."
                    ),
                    imageName: EmptyStateArtwork.compose,
                    symbol: "square.stack.3d.up",
                    actionTitle: String(localized: "Import compose file…"),
                    action: { showImporter = true })
            }

            Divider()

            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Running…")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if spec != nil {
                    Button {
                        down()
                    } label: {
                        IconLabel(title: String(localized: "Down"), icon: "composedown", fallback: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(running)
                    Button {
                        up()
                    } label: {
                        IconLabel(title: String(localized: "Up"), icon: "composeup", fallback: "arrow.up.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(running)
                }
            }
            .padding(10)

            if !run.steps.isEmpty || runError != nil || run.rawLog.isEmpty == false {
                Divider()
                stepPipeline
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText]) { result in
            switch result {
            case .success(let url):
                importCompose(url)
            case .failure(let error):
                parseError = error.localizedDescription
            }
        }
    }

    // MARK: - Step pipeline (plan → live stepper → service logs)

    private var stepPipeline: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                stepper
                if let runError {
                    Text(runError).font(.footnote.monospaced()).foregroundStyle(.red)
                }
                serviceLogSection
                rawLogDisclosure
            }
            .padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.25))
    }

    /// The ordered plan as a stepper: icons + status, expandable per-step
    /// command lines, live-updating during `up`.
    private var stepper: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(run.steps) { step in
                stepRow(step)
                if step.id < run.steps.count - 1 {
                    stepConnector(step.status)
                }
            }
        }
    }

    private func stepRow(_ step: ComposeRunState.StepState) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { run.expandedSteps.contains(step.id) },
                set: { on in
                    if on { run.expandedSteps.insert(step.id) } else { run.expandedSteps.remove(step.id) }
                }
            )
        ) {
            if !step.detail.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(step.detail.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                }
                .padding(.leading, 22)
                .padding(.vertical, 4)
            }
        } label: {
            HStack(spacing: 8) {
                statusIcon(step.status)
                Text(step.title).font(.callout.weight(.medium))
                if step.status == .running {
                    Text("…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ComposeRunState.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func stepConnector(_ status: ComposeRunState.Status) -> some View {
        Rectangle()
            .fill(status == .success ? Color.green.opacity(0.35) : Color.secondary.opacity(0.2))
            .frame(width: 2, height: 10)
            .padding(.leading, 8)
    }

    private var serviceLogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Service logs")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if activeServices.isEmpty {
                Text(String(localized: "No services in this plan."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(Array(activeServices.enumerated()), id: \.offset) { _, service in
                let container = runningContainer(service)
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { serviceLogs.contains(service.name) },
                        set: { on in
                            if on { serviceLogs.insert(service.name) } else { serviceLogs.remove(service.name) }
                        }
                    )
                ) {
                    if let container {
                        ContainerLogsView(store: store, containerID: container.id)
                            .frame(height: 160)
                            .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text(
                            run.status == .failed
                                ? String(localized: "Container did not start.") : String(localized: "Starting…")
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 6)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        Text(service.name).font(.callout)
                        if let container {
                            Text(container.state).font(.caption).foregroundStyle(.green)
                        } else {
                            Text(String(localized: "not running")).font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(.top, 4)
    }

    private var rawLogDisclosure: some View {
        DisclosureGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(run.rawLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 120)
        } label: {
            Text(String(localized: "Raw log (\(run.rawLog.count) lines)"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func importCompose(_ url: URL) {
        let hadAccess = url.startAccessingSecurityScopedResource()
        defer { if hadAccess { url.stopAccessingSecurityScopedResource() } }
        Task {
            do {
                let parsed = try await store.dependencies.compose.parse(url: url)
                rawYAML = (try? String(contentsOf: url, encoding: .utf8))
                spec = parsed
                enabledProfiles = []
                plan = try store.dependencies.compose.plan(spec: parsed, enabledProfiles: [])
                parseError = nil
                saved = false
                runError = nil
                run = ComposeRunState()
            } catch {
                parseError = error.localizedDescription
            }
        }
    }

    private func up() {
        guard let spec else { return }
        do {
            plan = try store.dependencies.compose.plan(spec: spec, enabledProfiles: enabledProfiles)
        } catch {
            runError = error.localizedDescription
            return
        }
        guard let plan else { return }
        running = true
        runError = nil
        run = ComposeRunState(
            steps: plan.steps.enumerated().map { index, step in
                ComposeRunState.StepState(step: step, index: index)
            })
        Task {
            do {
                for try await line in store.composeUpStream(plan: plan) {
                    run.consume(line)
                }
                run.markAllPendingSuccess()
            } catch {
                runError = error.localizedDescription
                run.markCurrentFailed()
            }
            running = false
            await store.refreshContainers()
            await store.refreshNetworks()
            await store.refreshVolumes()
        }
    }

    private func down() {
        guard let spec else { return }
        running = true
        runError = nil
        Task {
            do {
                try await store.composeDown(composeName: spec.name)
                run.rawLog.append("Tore down \(spec.name)")
                run.markAllPendingSuccess()
                await store.refreshContainers()
                await store.refreshNetworks()
                await store.refreshVolumes()
            } catch {
                runError = error.localizedDescription
            }
            running = false
        }
    }

    private func specSummary(_ spec: Micropod_V1_ComposeSpec) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(spec.name).font(.headline)
                    Text(spec.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(Array(spec.services.enumerated()), id: \.offset) { _, service in
                    let isActive =
                        service.profiles.isEmpty
                        || service.profiles.contains(where: enabledProfiles.contains)
                    VStack(alignment: .leading, spacing: 2) {
                        if !isActive {
                            Text(String(localized: "off — profile \(service.profiles.joined(separator: ", "))"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 6) {
                            Text(service.name).font(.callout.weight(.medium))
                            if !service.image.isEmpty {
                                Text(service.image).font(.caption).foregroundStyle(.secondary)
                            } else if !service.buildContext.isEmpty {
                                Text(String(localized: "build: \(service.buildContext)")).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !service.healthcheckCommand.isEmpty {
                                Text(String(localized: "healthcheck")).font(.caption2).foregroundStyle(.orange)
                            }
                            if !service.dependsOn.isEmpty {
                                Text(String(localized: "depends on: \(service.dependsOn.joined(separator: ", "))"))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if !service.ports.isEmpty {
                            Text(
                                service.ports.map { "\($0.hostPort):\($0.containerPort)/\($0.protocol)" }.joined(
                                    separator: ", ")
                            )
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        }
                        let extras = composeExtras(service)
                        if !extras.isEmpty {
                            Text(extras).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    .opacity(isActive ? 1 : 0.45)
                }
                if let plan {
                    Text(String(localized: "Plan: \(plan.steps.count) steps"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity)
    }

    private var availableProfiles: [String] {
        guard let spec else { return [] }
        return Array(Set(spec.services.flatMap(\.profiles))).sorted()
    }

    /// HIG: chips toggle profiles; profiled services are dimmed until enabled.
    private func profileBar(_ spec: Micropod_V1_ComposeSpec) -> some View {
        HStack(spacing: 6) {
            Text(String(localized: "Profiles")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(ProfileChip.all(availableProfiles)) { chip in
                Button {
                    if profileIsOn(chip.name) {
                        enabledProfiles.remove(chip.name)
                    } else {
                        enabledProfiles.insert(chip.name)
                    }
                    plan = try? store.dependencies.compose.plan(spec: spec, enabledProfiles: enabledProfiles)
                } label: {
                    Text(chip.name)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            profileIsOn(chip.name) ? Color.accentColor : Color(nsColor: .quaternaryLabelColor),
                            in: Capsule()
                        )
                        .foregroundStyle(profileIsOn(chip.name) ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func profileIsOn(_ name: String) -> Bool {
        enabledProfiles.contains(name)
    }

    private struct ProfileChip: Identifiable {
        let name: String
        var id: String { name }
        static func all(_ names: [String]) -> [ProfileChip] { names.map { ProfileChip(name: $0) } }
    }

    // MARK: - Helpers

    /// Services in the current spec that would run with the enabled profiles.
    private var activeServices: [Micropod_V1_ComposeService] {
        guard let spec else { return [] }
        return spec.services.filter {
            $0.profiles.isEmpty || $0.profiles.contains(where: enabledProfiles.contains)
        }
    }

    private func runningContainer(_ service: Micropod_V1_ComposeService) -> Micropod_V1_Container? {
        guard let spec else { return nil }
        let composeName = "\(spec.name)-\(service.containerName)"
        return store.containers.first { $0.id == composeName }
    }

    private func composeExtras(_ service: Micropod_V1_ComposeService) -> String {
        var parts: [String] = []
        if !service.user.isEmpty { parts.append("user \(service.user)") }
        if !service.entrypoint.isEmpty { parts.append("entrypoint \(service.entrypoint)") }
        if !service.networks.isEmpty { parts.append("nets \(service.networks.joined(separator: ","))") }
        if !service.tmpfs.isEmpty { parts.append("tmpfs \(service.tmpfs.joined(separator: ","))") }
        if !service.dns.isEmpty { parts.append("dns \(service.dns.count)") }
        if !service.capAdd.isEmpty { parts.append("cap+ \(service.capAdd.count)") }
        if !service.capDrop.isEmpty { parts.append("cap- \(service.capDrop.count)") }
        if service.readOnly { parts.append("read-only") }
        if service.init_p { parts.append("init") }
        if service.tty { parts.append("tty") }
        if service.stdinOpen { parts.append("stdin") }
        if !service.restart.isEmpty && service.restart != "no" { parts.append("restart \(service.restart)") }
        if service.stopGracePeriodSeconds > 0 { parts.append("grace \(service.stopGracePeriodSeconds)s") }
        return parts.joined(separator: " · ")
    }

    private func saveEnvironment() {
        guard let spec else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Micropod/environments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(spec.name).spec.bin")
        do {
            let data: Data = try spec.serializedBytes()
            try data.write(to: url)
            // Sidecar with the original YAML powers the Environments editor.
            let yaml = rawYAML ?? composeYAML(from: spec)
            try yaml.write(to: dir.appendingPathComponent("\(spec.name).yml"), atomically: true, encoding: .utf8)
            saved = true
        } catch {
            runError = error.localizedDescription
        }
    }
}
