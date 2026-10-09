import Foundation

/// The tray owns this read-only cadence. Closing it stops future reads without
/// cancelling a coalesced store read that the main window may also be awaiting.
@MainActor
final class MenuBarCacheObservation {
    private let interval: Duration
    private var polling: Task<Void, Never>?
    private var reading: Task<Void, Never>?
    private var refresh: (@MainActor () async -> Void)?

    init(interval: Duration = .seconds(15)) { self.interval = interval }

    func open(refresh: @escaping @MainActor () async -> Void) {
        guard polling == nil else { return }
        self.refresh = refresh
        let previousRead = reading
        polling = Task { [weak self] in
            // Reopening must read after an earlier open's in-flight request.
            if let previousRead { await previousRead.value }
            while !Task.isCancelled {
                guard let self else { return }
                await self.read().value
                do { try await Task.sleep(for: self.interval) } catch { return }
            }
        }
    }

    func refreshNow() {
        guard polling != nil else { return }
        _ = read()
    }

    func close() {
        polling?.cancel()
        polling = nil
        refresh = nil
    }

    private func read() -> Task<Void, Never> {
        if let reading { return reading }
        guard let refresh else { return Task {} }
        let task = Task { [weak self] in
            await refresh()
            self?.reading = nil
        }
        reading = task
        return task
    }
}
