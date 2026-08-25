import MicropodCore
import SwiftUI

/// Persistent bottom drawer listing long-running operations (pulls, builds,
/// compose ups) with live progress, cancel, and a compact event preview.
/// Completed ops collapse to a one-line history strip before rolling out.
struct OperationsDrawerView: View {
    @Bindable var store: AppStore

    @State private var expanded = true
    @State private var pinned: Set<UUID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let active = store.operations.filter { $0.status == .running }
        let recent = store.operations.filter { $0.status != .running }
        VStack(spacing: 0) {
            header(activeCount: active.count)
            if expanded {
                if store.operations.isEmpty {
                    emptyState
                } else {
                    opList
                }
            }
        }
        .background(.regularMaterial)
    }

    private var emptyState: some View {
        HStack {
            Text(String(localized: "No operations"))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, Tokens.Spacing.sm)
    }

    private func header(activeCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(
                activeCount > 0
                    ? String(localized: "Operations · \(activeCount) running") : String(localized: "Operations")
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            if activeCount > 0 {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if !store.operations.isEmpty {
                Button {
                    pinned = []
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    expanded ? String(localized: "Collapse operations") : String(localized: "Expand operations"))
            }
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, Tokens.Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            if !store.operations.isEmpty {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { expanded.toggle() }
            }
        }
    }

    private var opList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(store.operations) { op in
                    OperationRowView(
                        operation: op,
                        isPinned: pinned.contains(op.id),
                        onPin: {
                            if pinned.contains(op.id) { pinned.remove(op.id) } else { pinned.insert(op.id) }
                        },
                        onCancel: { store.cancelOperation(op.id) })
                }
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .padding(.bottom, Tokens.Spacing.xs)
        }
        .frame(maxHeight: 150)
    }
}

struct OperationRowView: View {
    let operation: ActiveOperation
    let isPinned: Bool
    let onPin: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(operation.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let preview = operation.events.last, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text(elapsedText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            if case .running = operation.status {
                Text(elapsedText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Cancel"))
                .accessibilityLabel(String(localized: "Cancel \(operation.title)"))
            } else {
                Button {
                    onPin()
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(isPinned ? String(localized: "Unpin") : String(localized: "Pin"))
            }
        }
        .padding(.horizontal, Tokens.Spacing.sm)
        .padding(.vertical, Tokens.Spacing.xs)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch operation.status {
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.system(size: 12))
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.gray).font(.system(size: 12))
        }
    }

    private var elapsedText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(operation.startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
