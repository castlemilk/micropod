import SwiftUI

/// Create a `container machine` (VM) from an image reference.
struct CreateMachineSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var image = "alpine:3.22"
    @State private var name = ""
    @State private var cpus = ""
    @State private var memory = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("Create MicroVM")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    inputField("Image", hint: "Image reference", text: $image)
                    inputField("Name", hint: "Optional; default machine", text: $name)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading,
                        spacing: 12
                    ) {
                        inputField("CPUs", hint: "Optional", text: $cpus)
                        inputField("Memory", hint: "Optional, e.g. 4G", text: $memory)
                    }
                    Text(
                        "Creates a dedicated VM for the container runtime. This boots a full Linux VM — allow a minute."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        await store.createMachine(image: image, name: name, cpus: cpus, memory: memory)
                    }
                    dismiss()
                } label: {
                    IconLabel(title: "Create", icon: "create", fallback: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 320, idealWidth: 460, maxWidth: 640, minHeight: 300, idealHeight: 380, maxHeight: 600)
    }

    private func inputField(_ label: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Tokens.Typography.metadata).foregroundStyle(.secondary)
            TextField(hint, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        }
    }
}
