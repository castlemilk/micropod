import MicropodCore
import SwiftUI
import UniformTypeIdentifiers

/// Streaming log viewer for one container (`container logs -f`).
/// HIG: search with match highlight, follow pause, wrap, copy/save.
struct ContainerLogsView: View {
    @Bindable var store: AppStore
    let containerID: String

    @State private var lines: [LogLine] = []
    @State private var showBoot = false
    @State private var follow = true
    @State private var wrap = false
    @State private var searchText = ""
    @State private var currentMatch: Int = 0
    @State private var streamError: String?
    @State private var streamTask: Task<Void, Never>?
    /// Incremental match index: line id → match ordinal. Rebuilt once per
    /// lines/search change — the previous per-row rescan was O(n²) while
    /// scrolling a capped buffer.
    @State private var matchOrdinalByID: [LogLine.ID: Int] = [:]
    @State private var matchedIDsInOrder: [LogLine.ID] = []
    @State private var seenLineIDs = Set<LogLine.ID>()

    private let maxLines = 1000

    private var matchCount: Int { matchedIDsInOrder.count }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logArea
        }
        .onAppear { restart() }
        .onDisappear {
            streamTask?.cancel()
            streamTask = nil
        }
        .onChange(of: lines) { reconcileMatches() }
        .onChange(of: searchText) {
            // Force a full rescan — match membership depends on the query.
            seenLineIDs = []
            currentMatch = 0
            reconcileMatches()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            searchField
            if matchCount > 0 {
                Button {
                    currentMatch = (currentMatch - 1 + matchCount) % matchCount
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .help("Previous match")
                Button {
                    currentMatch = (currentMatch + 1) % matchCount
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Next match")
                Text("\(currentMatch + 1)/\(matchCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                wrap.toggle()
            } label: {
                Label("Wrap", systemImage: "text.alignleft")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Toggle line wrapping")
            .accessibilityLabel("Toggle line wrapping")

            // One follow control: off == paused, on == live tail.
            Button {
                follow.toggle()
                if follow { scrollToBottom() }
            } label: {
                Label(
                    follow ? "Following" : "Paused",
                    systemImage: follow ? "arrow.down.to.line" : "arrow.down.to.line.slash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(follow ? "Pause the live tail" : "Resume the live tail")
            .accessibilityLabel(follow ? "Pause log follow" : "Resume log follow")

            Menu {
                Toggle("Boot log", isOn: $showBoot)
                    .onChange(of: showBoot) { restart() }
                Divider()
                Button {
                    copyAll()
                } label: {
                    MenuItemIconLabel(title: "Copy All", icon: "copy", fallback: "doc.on.doc")
                }
                Button {
                    saveLogs()
                } label: {
                    MenuItemIconLabel(title: "Save to File…", icon: "save", fallback: "square.and.arrow.down")
                }
                Divider()
                Button {
                    lines.removeAll()
                } label: {
                    MenuItemIconLabel(title: "Clear", icon: "clear", fallback: "eraser")
                }
                Button {
                    restart()
                } label: {
                    MenuItemIconLabel(title: "Restart Stream", icon: "refresh", fallback: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .accessibilityLabel("More log actions")

            if let error = streamError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
            TextField("Find in logs", text: $searchText)
                .textFieldStyle(.plain)
                .frame(maxWidth: 160)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    currentMatch = 0
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var logArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        Text(highlighted(line.text))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(wrap ? nil : 1)
                            .background(matchBackground(index))
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: lines.count) {
                if follow, let last = lines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .background(.background)
    }

    /// Search match highlight via AttributedString.
    private func highlighted(_ text: String) -> AttributedString {
        guard !searchText.isEmpty else { return AttributedString(text) }
        var attributed = AttributedString(text)
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let range = attributed[searchRange].range(of: searchText, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.opacity(0.4)
            attributed[range].foregroundColor = .primary
            searchRange = range.upperBound..<attributed.endIndex
        }
        return attributed
    }

    /// Keeps the match index consistent with the visible buffer: new lines
    /// are scanned once on arrival; evicted lines drop their match ordinals.
    private func reconcileMatches() {
        guard !searchText.isEmpty else {
            matchedIDsInOrder = []
            matchOrdinalByID = [:]
            seenLineIDs = []
            return
        }
        let currentIDs = Set(lines.map(\.id))
        guard currentIDs != seenLineIDs else { return }
        matchedIDsInOrder.removeAll { !currentIDs.contains($0) }
        for line in lines where !seenLineIDs.contains(line.id) {
            if line.text.localizedCaseInsensitiveContains(searchText) {
                matchedIDsInOrder.append(line.id)
            }
        }
        seenLineIDs = currentIDs
        matchOrdinalByID = Dictionary(
            matchedIDsInOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        if !matchedIDsInOrder.isEmpty {
            currentMatch = min(currentMatch, matchedIDsInOrder.count - 1)
        } else {
            currentMatch = 0
        }
    }

    private func matchBackground(_ index: Int) -> Color {
        guard index < lines.count else { return .clear }
        return matchOrdinalByID[lines[index].id] == currentMatch
            ? Color.accentColor.opacity(0.18) : .clear
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
    }

    private func saveLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(containerID).log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? lines.map(\.text).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func scrollToBottom() {
        // The onChange handler scrolls on append; this keeps the intent explicit.
    }

    private func restart() {
        streamTask?.cancel()
        lines.removeAll()
        streamError = nil
        streamTask = Task {
            do {
                for try await line in store.dependencies.logStreamer.stream(
                    id: containerID, tail: 200, boot: showBoot)
                {
                    if Task.isCancelled { break }
                    guard follow else { continue }
                    lines.append(line)
                    if lines.count > maxLines {
                        lines.removeFirst(lines.count - maxLines)
                    }
                }
            } catch is CancellationError {
                // Expected on tab switch.
            } catch {
                streamError = error.localizedDescription
            }
        }
    }
}
