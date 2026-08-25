import Foundation
import MicropodCore
import SwiftUI

/// "Run a container" sheet — maps user input to a `container run` invocation.
struct RunContainerSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var image: String
    @State private var name = ""
    @State private var isAgent = false
    @State private var jobID = ""
    @State private var owner = ""
    @State private var isEphemeral = false
    @State private var ttlMinutes = ""
    @State private var advancedExpanded = false
    @State private var cpus = ""
    @State private var memory = ""
    @State private var detach = true
    @State private var useInit = true
    @State private var rosetta = false
    @State private var readOnly = false
    @State private var platform = ""
    @State private var workdir = ""
    @State private var entrypoint = ""
    @State private var envText = ""
    @State private var portsText = ""
    @State private var volumesText = ""
    @State private var argsText = ""
    @State private var isRefreshingImages = false

    init(store: AppStore, initialImage: String = "alpine:latest") {
        self.store = store
        _image = State(initialValue: initialImage)
    }

    var body: some View {
        let evaluation = evaluateForm()
        let localImages = localImageReferences

        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    containerSection(evaluation, localImages: localImages)
                    Divider()
                    agentSection(evaluation)
                    Divider()
                    advancedSection(evaluation)
                }
                .padding(20)
            }

            Divider()
            footer(evaluation)
        }
        .background(.background)
        .frame(width: 600)
        .frame(maxHeight: 680)
        .task { await refreshLocalImages() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run Container")
                    .font(.title3.weight(.semibold))
                Text("Launch an image with optional workload metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private func containerSection(
        _ evaluation: LaunchFormEvaluation,
        localImages: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Container")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Image")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("alpine:latest", text: $image)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Image")
                        .accessibilityIdentifier("runContainer.image")

                    Menu {
                        ForEach(localImages, id: \.self) { reference in
                            Button(reference) {
                                image = reference
                            }
                        }
                    } label: {
                        Label("Local Images", systemImage: "internaldrive")
                    }
                    .disabled(
                        localImages.isEmpty || isRefreshingImages || !store.isRuntimeRunning
                            || !store.hasLoadedImages
                    )
                    .accessibilityLabel("Choose a local image")
                    .accessibilityIdentifier("runContainer.localImageMenu")
                }

                if let imageError = evaluation.imageError {
                    validationMessage(imageError)
                }
            }

            imagePreflight(evaluation, localImages: localImages)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Optional", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name")
                    .accessibilityIdentifier("runContainer.name")
            }
        }
    }

    private func imagePreflight(
        _ evaluation: LaunchFormEvaluation,
        localImages: [String]
    ) -> some View {
        let presentation = preflightPresentation(evaluation, localImages: localImages)

        return HStack(spacing: 10) {
            Image(systemName: presentation.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(presentation.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.callout.weight(.medium))
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.28))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("runContainer.localImagePreflight")
    }

    private func agentSection(_ evaluation: LaunchFormEvaluation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $isAgent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent workload")
                        .font(.headline)
                    Text("Attach canonical job metadata to this container.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("runContainer.agentToggle")

            if isAgent {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        compactField(
                            "Job ID",
                            text: $jobID,
                            placeholder: "Optional",
                            accessibilityIdentifier: "runContainer.agentJobID"
                        )
                        compactField(
                            "Owner",
                            text: $owner,
                            placeholder: "Optional",
                            accessibilityIdentifier: "runContainer.agentOwner"
                        )
                    }

                    HStack(alignment: .top, spacing: 16) {
                        Toggle("Ephemeral", isOn: $isEphemeral)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("runContainer.agentEphemeral")

                        VStack(alignment: .leading, spacing: 6) {
                            Text("TTL")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                TextField("Optional", text: $ttlMinutes)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("TTL minutes")
                                    .accessibilityIdentifier("runContainer.agentTTL")
                                Text("minutes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let ttlError = evaluation.ttlError {
                                validationMessage(ttlError)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("TTL is metadata only; cleanup remains explicit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 24)
            }
        }
    }

    private func advancedSection(_ evaluation: LaunchFormEvaluation) -> some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    compactField(
                        "CPUs",
                        text: $cpus,
                        placeholder: "e.g. 2",
                        error: evaluation.cpuError,
                        accessibilityIdentifier: "runContainer.advancedCPUs"
                    )
                    compactField(
                        "Memory",
                        text: $memory,
                        placeholder: "e.g. 512M or 2G",
                        accessibilityIdentifier: "runContainer.advancedMemory"
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    compactField(
                        "Platform",
                        text: $platform,
                        placeholder: "linux/amd64",
                        accessibilityIdentifier: "runContainer.advancedPlatform"
                    )
                    compactField(
                        "Workdir",
                        text: $workdir,
                        placeholder: "/app",
                        accessibilityIdentifier: "runContainer.advancedWorkdir"
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    compactField(
                        "Entrypoint",
                        text: $entrypoint,
                        placeholder: "/bin/sh",
                        accessibilityIdentifier: "runContainer.advancedEntrypoint"
                    )
                    compactField(
                        "Arguments",
                        text: $argsText,
                        placeholder: "--verbose",
                        accessibilityIdentifier: "runContainer.advancedArguments"
                    )
                }

                Divider()

                multilineField(
                    "Environment",
                    text: $envText,
                    placeholder: "KEY=VALUE, one per line",
                    lineLimit: 2...4,
                    accessibilityIdentifier: "runContainer.advancedEnvironment"
                )
                multilineField(
                    "Ports (host:container)",
                    text: $portsText,
                    placeholder: "8080:80, 5432:5432",
                    lineLimit: 1...2,
                    error: evaluation.portsError,
                    accessibilityIdentifier: "runContainer.advancedPorts"
                )
                multilineField(
                    "Volumes (name:/path)",
                    text: $volumesText,
                    placeholder: "mydata:/var/lib/postgresql/data",
                    lineLimit: 1...2,
                    accessibilityIdentifier: "runContainer.advancedVolumes"
                )

                Divider()

                HStack(spacing: 16) {
                    Toggle("Detach", isOn: $detach)
                    Toggle("Init", isOn: $useInit)
                    Toggle("Rosetta", isOn: $rosetta)
                    Toggle("Read-only", isOn: $readOnly)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Text("Advanced")
                    .font(.headline)
                if !advancedExpanded, let summary = evaluation.advancedErrorSummary {
                    Label(summary, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .accessibilityIdentifier("runContainer.advanced")
        .accessibilityValue(evaluation.advancedErrorSummary ?? "No validation issues")
    }

    private func footer(_ evaluation: LaunchFormEvaluation) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                run(evaluation)
            } label: {
                IconLabel(title: "Run", icon: "start", fallback: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!evaluation.canRun)
            .accessibilityIdentifier("runContainer.run")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var localImageReferences: [String] {
        localImageReferenceInventory(from: store.images)
    }

    private struct LaunchFormEvaluation {
        let imageReference: String
        let cpu: Double?
        let ports: [PortSpec]
        let ttlMinutes: Int?
        let imageError: String?
        let cpuError: String?
        let portsError: String?
        let ttlError: String?

        var canRun: Bool {
            imageError == nil && cpuError == nil && portsError == nil && ttlError == nil
        }

        var advancedErrorSummary: String? {
            let errors = [cpuError, portsError].compactMap { $0 }
            if errors.count == 1 { return errors[0] }
            return errors.isEmpty ? nil : "\(errors.count) validation issues"
        }
    }

    private struct ImagePreflightPresentation {
        let icon: String
        let color: Color
        let title: String
        let detail: String
    }

    private func evaluateForm() -> LaunchFormEvaluation {
        let imageReference = trimmed(image)
        let imageError: String?
        if imageReference.isEmpty {
            imageError = "Image is required."
        } else if !containerImageReferenceIsValid(imageReference) {
            imageError = "Use a valid image reference without spaces or empty tags."
        } else {
            imageError = nil
        }

        var parsedCPU: Double?
        var cpuError: String?
        do {
            parsedCPU = try ContainerLaunchInput.parseOptionalCPU(cpus)
        } catch {
            cpuError = error.localizedDescription
        }

        var parsedPorts: [PortSpec] = []
        var portsError: String?
        do {
            parsedPorts = try ContainerLaunchInput.parsePorts(portsText)
        } catch {
            portsError = error.localizedDescription
        }

        var parsedTTL: Int?
        var ttlError: String?
        if isAgent {
            do {
                parsedTTL = try ContainerLaunchInput.parseOptionalTTL(ttlMinutes)
            } catch {
                ttlError = error.localizedDescription
            }
        }

        return LaunchFormEvaluation(
            imageReference: imageReference,
            cpu: parsedCPU,
            ports: parsedPorts,
            ttlMinutes: parsedTTL,
            imageError: imageError,
            cpuError: cpuError,
            portsError: portsError,
            ttlError: ttlError)
    }

    private func preflightPresentation(
        _ evaluation: LaunchFormEvaluation,
        localImages: [String]
    ) -> ImagePreflightPresentation {
        if let imageError = evaluation.imageError {
            return ImagePreflightPresentation(
                icon: "questionmark.circle",
                color: .secondary,
                title: evaluation.imageReference.isEmpty ? "Image required" : "Invalid image",
                detail: imageError)
        }

        if isRefreshingImages {
            return ImagePreflightPresentation(
                icon: "arrow.triangle.2.circlepath",
                color: .secondary,
                title: "Checking local images",
                detail: "Reading the Apple container image inventory.")
        }

        guard store.isRuntimeRunning, store.hasLoadedImages else {
            return ImagePreflightPresentation(
                icon: "exclamationmark.circle",
                color: .secondary,
                title: "Local inventory unavailable",
                detail: "Start the container runtime to check local availability.")
        }

        if localImageIsPresent(evaluation.imageReference, in: localImages) {
            return ImagePreflightPresentation(
                icon: "checkmark.circle.fill",
                color: .green,
                title: "Present locally",
                detail: "This image reference is available on this Mac.")
        }

        return ImagePreflightPresentation(
            icon: "arrow.down.circle.fill",
            color: .orange,
            title: "Pull required",
            detail: "This image reference is not present locally; launch will pull it.")
    }

    private func compactField(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        error: String? = nil,
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
                .accessibilityIdentifier(accessibilityIdentifier)
            if let error {
                validationMessage(error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func multilineField(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        lineLimit: ClosedRange<Int>,
        error: String? = nil,
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(lineLimit)
                .padding(8)
                .background(.quaternary.opacity(0.24))
                .accessibilityLabel(label)
                .accessibilityIdentifier(accessibilityIdentifier)
            if let error {
                validationMessage(error)
            }
        }
    }

    private func validationMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
    }

    private func run(_ evaluation: LaunchFormEvaluation) {
        guard evaluation.canRun else { return }

        let request = ContainerRunRequest(
            image: evaluation.imageReference,
            name: optionalTrimmed(name),
            detach: detach,
            cpus: evaluation.cpu,
            memory: optionalTrimmed(memory),
            env: environmentLines(envText),
            publishedPorts: evaluation.ports,
            volumes: splitLines(volumesText),
            labels: ContainerLaunchInput.agentLabels(
                isAgent: isAgent,
                jobID: jobID,
                owner: owner,
                isEphemeral: isEphemeral,
                ttlMinutes: evaluation.ttlMinutes
            ),
            useInit: useInit,
            readOnly: readOnly,
            rosetta: rosetta,
            platform: optionalTrimmed(platform),
            workdir: optionalTrimmed(workdir),
            entrypoint: optionalTrimmed(entrypoint),
            arguments: argsText.split(whereSeparator: \.isWhitespace).map(String.init)
        )
        store.startRunContainer(request)
        dismiss()
    }

    private func refreshLocalImages() async {
        isRefreshingImages = true
        defer { isRefreshingImages = false }
        await store.refreshImages()
    }

    private func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { trimmed($0) }
            .filter { !$0.isEmpty }
    }

    private func environmentLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .filter { !trimmed($0).isEmpty }
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let value = trimmed(value)
        return value.isEmpty ? nil : value
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
