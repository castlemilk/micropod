import MicropodCore
import SwiftUI
import UniformTypeIdentifiers

/// Images tab: local images with pull/push/save/load/tag/delete/prune.
struct ImagesView: View {
    @Bindable var store: AppStore

    @State private var searchText = ""
    @State private var displayed: [Micropod_V1_Image] = []
    @State private var selection: String?
    @State private var showPullSheet = false
    @State private var showTagSheet = false
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var activePull: ActivePull?
    @State private var imageError: String?
    @State private var confirmDeleteName: String?
    @State private var confirmPruneAll = false
    /// 2.5 — expandable variant chips per row + detail sheet.
    @State private var expandedVariants: Set<String> = []
    @State private var detail: ImageDetailSelection?
    @State private var runImage: String?
    @State private var showRunSheet = false

    struct ActivePull: Identifiable {
        let id = UUID()
        let reference: String
        let opID: UUID
    }

    /// Multi-select (batch delete/copy) — embedded floating bar, like containers.
    @State private var isSelecting = false
    @State private var batchSelection = Set<String>()
    @State private var confirmBatchDelete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Incremented per refresh tap — drives the rotate symbol effect.
    @State private var refreshTicks = 0

    @ViewBuilder
    private func imageContextMenu(_ image: Micropod_V1_Image) -> some View {
        Button {
            detail = ImageDetailSelection(image: image)
        } label: {
            IconLabel(title: "Details…", icon: "details", fallback: "info.circle")
        }
        Button {
            runImage = image.names.first ?? image.id
            showRunSheet = true
        } label: {
            IconLabel(title: "Run…", icon: "start", fallback: "play.circle")
        }
        Button {
            showPullSheet = true
        } label: {
            IconLabel(title: "Pull…", icon: "pull", fallback: "arrow.down.circle")
        }
        Button {
            showTagSheet = true
        } label: {
            IconLabel(title: "Tag…", icon: "tag", fallback: "tag")
        }
        Button {
            showExporter = true
        } label: {
            IconLabel(title: "Save to Tar…", icon: "export", fallback: "square.and.arrow.down")
        }
        Divider()
        Button(role: .destructive) {
            confirmDeleteName = image.names.first ?? image.id
        } label: {
            IconLabel(title: "Delete", icon: "delete", fallback: "trash")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            imagesToolbar
                .padding(8)

            Divider()

            if displayed.isEmpty {
                EmptyStateView(
                    title: store.images.isEmpty
                        ? String(localized: "No Images") : String(localized: "No Matching Images"),
                    description: store.images.isEmpty
                        ? String(localized: "Pull an image to run your first container.")
                        : String(localized: "No images match your search."),
                    imageName: store.images.isEmpty ? EmptyStateArtwork.images : nil,
                    symbol: "photo.stack",
                    actionTitle: store.images.isEmpty ? "Pull an Image…" : nil,
                    action: { showPullSheet = true })
            } else if isSelecting {
                List(selection: $batchSelection) {
                    ForEach(displayed) { image in
                        imageRow(image)
                            .tag(image.id)
                    }
                }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isSelecting {
                        imageSelectionBar
                            .transition(
                                reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
            } else {
                List(selection: $selection) {
                    ForEach(displayed) { image in
                        imageRow(image)
                            .tag(image.id)
                            .contextMenu { imageContextMenu(image) }
                            .onTapGesture(count: 2) {
                                detail = ImageDetailSelection(image: image)
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { applyFilter() }
        .onChange(of: store.images) { applyFilter() }
        .onChange(of: searchText) { applyFilter() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isSelecting)
        .task {
            if store.images.isEmpty {
                await store.refreshImages()
            }
        }
        .sheet(isPresented: $showPullSheet) {
            PullImageSheet(
                store: store,
                onPull: { reference in
                    let opID = store.startPull(reference: reference, platform: nil)
                    activePull = ActivePull(reference: reference, opID: opID)
                })
        }
        .onChange(of: store.pendingPullSheet) { _, pending in
            if pending {
                showPullSheet = true
                store.pendingPullSheet = false
            }
        }
        .sheet(isPresented: $showTagSheet) {
            TagImageSheet(store: store, image: selectedImage)
        }
        .sheet(item: $activePull) { pull in
            PullProgressSheet(store: store, reference: pull.reference, opID: pull.opID)
        }
        .sheet(item: $detail) { selection in
            ImageDetailSheet(store: store, image: selection.image)
        }
        .sheet(isPresented: $showRunSheet) {
            RunContainerSheet(store: store, initialImage: runImage ?? "alpine:latest")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.archive]) { result in
            switch result {
            case .success(let url):
                importImage(url)
            case .failure(let error):
                imageError = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: CopyOutDocument(),
            contentType: .archive,
            defaultFilename: "\(selection ?? "image").tar"
        ) { result in
            switch result {
            case .success(let url):
                saveImage(to: url)
            case .failure(let error):
                imageError = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Delete Image?",
            isPresented: Binding(
                get: { confirmDeleteName != nil },
                set: { if !$0 { confirmDeleteName = nil } })
        ) {
            Button("Delete Image", role: .destructive) {
                if let name = confirmDeleteName {
                    confirmDeleteName = nil
                    Task { await store.deleteImage(name, force: true) }
                }
            }
            Button("Cancel", role: .cancel) { confirmDeleteName = nil }
        } message: {
            Text("This removes the image and its layers locally. Containers using it keep running until deleted.")
        }
        .confirmationDialog(
            "Prune All Unused Images?",
            isPresented: $confirmPruneAll
        ) {
            Button("Prune All Unused Images", role: .destructive) {
                Task { await store.pruneImages(all: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every image not referenced by a container. Reclaimable: \(reclaimableImages).")
        }
        .confirmationDialog(
            "Delete \(batchSelection.count) images?",
            isPresented: $confirmBatchDelete
        ) {
            Button("Delete \(batchSelection.count) Images", role: .destructive) {
                Task { await batchDeleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the selected images and their layers locally. Containers using them keep running until deleted."
            )
        }
    }

    private var reclaimableImages: String {
        guard let bytes = store.diskUsage?.images.reclaimableBytes else { return "unknown" }
        return ByteFormat.string(bytes)
    }

    @ViewBuilder
    private var imagesToolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search images")
                    .accessibilityIdentifier("images.search")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 260)

            Spacer()

            if let error = imageError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Button {
                if !reduceMotion { refreshTicks += 1 }
                Task { await store.refreshImages() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .symbolEffect(.rotate.byLayer, value: refreshTicks)
            }
            .help("Refresh images")
            .accessibilityLabel("Refresh images")

            Button {
                isSelecting.toggle()
                batchSelection.removeAll()
            } label: {
                Image(systemName: isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .help(isSelecting ? "Done selecting" : "Select multiple images")
            .accessibilityLabel(isSelecting ? "Done selecting" : "Select multiple images")

            Menu {
                Button {
                    Task { await store.pruneImages(all: false) }
                } label: {
                    MenuItemIconLabel(title: "Prune Dangling Images", icon: "prune")
                }
                Button(role: .destructive) {
                    confirmPruneAll = true
                } label: {
                    MenuItemIconLabel(title: "Prune All Unused Images", icon: "prune")
                }
                Divider()
                Button {
                    showImporter = true
                } label: {
                    MenuItemIconLabel(title: "Import from Tar…", icon: "import")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More image actions")

            Button {
                showPullSheet = true
            } label: {
                IconLabel(title: "Pull", icon: "pull")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var selectedImage: Micropod_V1_Image? {
        store.images.first { $0.id == selection }
    }

    private func imageRow(_ image: Micropod_V1_Image) -> some View {
        ImageRowView(
            image: image,
            isExpanded: Binding(
                get: { expandedVariants.contains(image.id) },
                set: { on in
                    if on {
                        expandedVariants.insert(image.id)
                    } else {
                        expandedVariants.remove(image.id)
                    }
                }
            )
        )
    }

    /// Embedded multi-select action bar (floating bottom capsule).
    private var imageSelectionBar: some View {
        SelectionActionBar(count: batchSelection.count) {
            Button(role: .destructive) {
                confirmBatchDelete = true
            } label: {
                IconLabel(title: "Delete…", icon: "delete", fallback: "trash")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    batchSelection.sorted().joined(separator: "\n"), forType: .string)
            } label: {
                IconLabel(title: "Copy IDs", icon: "copy", fallback: "doc.on.doc")
            }
        } onDone: {
            isSelecting = false
            batchSelection.removeAll()
        }
    }

    private func batchDeleteSelected() async {
        let ids = batchSelection
        batchSelection.removeAll()
        isSelecting = false
        for id in ids.sorted() {
            if let name = store.images.first(where: { $0.id == id })?.names.first ?? id as String? {
                await store.deleteImage(name, force: true)
            }
        }
    }

    private func applyFilter() {
        let query = searchText.lowercased()
        displayed = store.images.filter { image in
            guard !query.isEmpty else { return true }
            return image.id.lowercased().contains(query)
                || image.names.contains { $0.lowercased().contains(query) }
        }
    }

    private func importImage(_ url: URL) {
        let hadAccess = url.startAccessingSecurityScopedResource()
        defer { if hadAccess { url.stopAccessingSecurityScopedResource() } }
        Task {
            do {
                try await store.dependencies.images.load(from: url.path)
                await store.refreshImages()
            } catch {
                imageError = error.localizedDescription
            }
        }
    }

    private func saveImage(to url: URL) {
        guard let image = selectedImage, let name = image.names.first else { return }
        Task {
            do {
                try await store.dependencies.images.save(name, to: url.path)
            } catch {
                imageError = error.localizedDescription
            }
        }
    }
}

struct ImageRowView: View, @MainActor Equatable {
    let image: Micropod_V1_Image
    @Binding var isExpanded: Bool

    static func == (lhs: ImageRowView, rhs: ImageRowView) -> Bool {
        lhs.image == rhs.image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "photo.stack")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(platformSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !image.digest.isEmpty {
                            Text(String(image.digest.prefix(19)))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteFormat.string(image.sizeBytes))
                        .font(.caption.monospacedDigit())
                    Text(image.createdAt)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if image.variants.count > 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if image.variants.count > 1 {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                variantChips
            }
        }
        .padding(.vertical, 2)
    }

    private var variantChips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(Array(image.variants.enumerated()), id: \.offset) { _, variant in
                Text(variantLabel(variant))
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.35), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 24)
    }

    private func variantLabel(_ variant: Micropod_V1_ImageVariant) -> String {
        var label = "\(variant.os)/\(variant.architecture)"
        if !variant.variant.isEmpty && variant.variant != "v1" {
            label += "/\(variant.variant)"
        }
        return label
    }

    private var primaryName: String {
        image.names.first ?? image.id
    }

    private var platformSummary: String {
        image.variants.isEmpty ? "—" : image.variants.map { "\($0.os)/\($0.architecture)" }.joined(separator: ", ")
    }
}

/// Identifiable wrapper for presenting an image in a sheet.
struct ImageDetailSelection: Identifiable {
    let id: String
    let image: Micropod_V1_Image
    init(image: Micropod_V1_Image) {
        self.id = image.id
        self.image = image
    }
}

struct PullImageSheet: View {
    @Bindable var store: AppStore
    var onPull: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pull Image").font(.title3.weight(.semibold))
            TextField("e.g. postgres:16 or ghcr.io/org/image:tag", text: $reference)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    onPull(reference)
                    dismiss()
                } label: {
                    IconLabel(title: "Pull", icon: "pull", fallback: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(reference.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct TagImageSheet: View {
    @Bindable var store: AppStore
    let image: Micropod_V1_Image?

    @Environment(\.dismiss) private var dismiss
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tag Image").font(.title3.weight(.semibold))
            HStack {
                Text("Source").font(.caption).frame(width: 60, alignment: .leading)
                Text(image?.names.first ?? image?.id ?? "")
                    .font(.caption.monospaced())
            }
            HStack {
                Text("Target").font(.caption).frame(width: 60, alignment: .leading)
                TextField("myregistry.local/app:latest", text: $target)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    if let image {
                        Task {
                            await store.tagImage(source: image.names.first ?? image.id, target: target)
                        }
                    }
                    dismiss()
                } label: {
                    IconLabel(title: "Tag", icon: "tag", fallback: "tag")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(target.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Streaming pull progress rendered from the store's operation drawer entry,
/// so the sheet and the drawer stay in sync.
struct PullProgressSheet: View {
    @Bindable var store: AppStore
    let reference: String
    let opID: UUID

    @Environment(\.dismiss) private var dismiss

    private var op: ActiveOperation? {
        store.operations.first { $0.id == opID }
    }

    private var events: [String] {
        op?.events ?? []
    }

    private var failed: Bool {
        if case .failed = op?.status { return true }
        return false
    }

    private var finished: Bool {
        op?.status != .running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pulling \(reference)").font(.title3.weight(.semibold))
                Spacer()
                if let op, case .running = op.status {
                    Button {
                        store.cancelOperation(op.id)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                }
            }
            if let last = events.last {
                let parsed = ProgressEvent.parse(line: last)
                if parsed.stage != nil {
                    ProgressView(
                        value: Double(parsed.stage ?? 0),
                        total: Double(parsed.totalStages ?? 1)
                    )
                    Text(parsed.stageName ?? parsed.line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if !failed {
                ProgressView().controlSize(.small)
            }
            ScrollView {
                Text(events.joined(separator: "\n"))
                    .font(.footnote.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            if failed {
                Label("Pull failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                if case .failed(let reason) = op?.status {
                    Text(reason)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack {
                Spacer()
                Button(finished ? "Done" : "Dismiss") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
