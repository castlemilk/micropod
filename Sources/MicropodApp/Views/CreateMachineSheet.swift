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
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Machine").font(.title3.weight(.semibold))
            TextField("Image", text: $image).textFieldStyle(.roundedBorder)
            TextField("Name (optional, default)", text: $name).textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                TextField("CPUs (optional)", text: $cpus).textFieldStyle(.roundedBorder)
                TextField("Memory (optional, e.g. 4G)", text: $memory).textFieldStyle(.roundedBorder)
            }
            Text("Creates a dedicated VM for the container runtime. This boots a full Linux VM — allow a minute.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                .disabled(image.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
