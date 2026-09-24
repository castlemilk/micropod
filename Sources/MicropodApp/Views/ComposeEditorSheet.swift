import MicropodCore
import SwiftProtobuf
import SwiftUI

/// Compose YAML editor: live parse validation + Save / Save & Up.
struct ComposeEditorSheet: View {
    @Bindable var store: AppStore
    let environment: EnvironmentsView.SavedEnvironment
    let initialYAML: String

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var validation: ValidationState = .idle
    @State private var isSaving = false
    @State private var errorMessage: String?

    enum ValidationState: Equatable {
        case idle, checking, valid
        case invalid(String)
    }

    init(store: AppStore, environment: EnvironmentsView.SavedEnvironment, initialYAML: String) {
        self.store = store
        self.environment = environment
        self.initialYAML = initialYAML
        _text = State(initialValue: initialYAML)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Edit \(environment.spec.name)").font(.title3.weight(.semibold))
                Spacer()
                validationIndicator
            }

            TextEditor(text: $text)
                .font(.subheadline.monospaced())
                .frame(minHeight: 300)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(validationBorderColor, lineWidth: 1)
                )

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Text("Changes to a working environment are applied on Save; Save & Up also starts it.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    save(up: false)
                } label: {
                    IconLabel(title: "Save", icon: "save", fallback: "square.and.arrow.down")
                }
                .disabled(isSaving)
                Button {
                    save(up: true)
                } label: {
                    IconLabel(title: "Save & Up", icon: "saveup", fallback: "arrow.up.square")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(width: 620, height: 480)
        .onChange(of: text) { _, _ in
            validateDebounced()
        }
        .task { await validate() }
    }

    // MARK: - Validation

    @ViewBuilder
    private var validationIndicator: some View {
        switch validation {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Validating…").font(.caption).foregroundStyle(.secondary)
            }
        case .valid:
            Label("Valid", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium)).foregroundStyle(.green)
        case .invalid(let reason):
            Label("Invalid", systemImage: "xmark.octagon.fill")
                .font(.caption.weight(.medium)).foregroundStyle(.red)
                .help(reason)
        }
    }

    private var validationBorderColor: Color {
        switch validation {
        case .invalid: .red
        case .valid: .green.opacity(0.6)
        default: .clear
        }
    }

    private func validateDebounced() {
        validation = .checking
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            await validate()
        }
    }

    private func validate() async {
        guard !text.isEmpty else {
            validation = .invalid("YAML is empty")
            return
        }
        do {
            _ = try await parseCurrent()
            validation = .valid
        } catch {
            validation = .invalid(error.localizedDescription)
        }
    }

    /// Parses the editor text as a compose file (temp file in the env dir).
    private func parseCurrent() async throws -> Micropod_V1_ComposeSpec {
        let dir = environmentsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(".tmp-\(environment.spec.name).yml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await store.dependencies.compose.parse(url: url)
    }

    // MARK: - Save

    private func save(up: Bool) {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let spec = try await parseCurrent()
                try writeEnvironment(spec)
                if up {
                    let plan = try store.dependencies.compose.plan(spec: spec)
                    for try await _ in store.dependencies.compose.up(plan: plan) {}
                    await store.refreshContainers()
                }
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func writeEnvironment(_ spec: Micropod_V1_ComposeSpec) throws {
        let dir = environmentsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data: Data = try spec.serializedBytes()
        try data.write(to: dir.appendingPathComponent("\(spec.name).spec.bin"))
        try text.write(to: dir.appendingPathComponent("\(spec.name).yml"), atomically: true, encoding: .utf8)
        if spec.name != environment.spec.name {
            // Renamed: drop the old spec + sidecar.
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(environment.spec.name).spec.bin"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(environment.spec.name).yml"))
        }
    }

    private var environmentsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Micropod/environments", isDirectory: true)
    }
}
