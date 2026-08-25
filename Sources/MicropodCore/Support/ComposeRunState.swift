/// Live state for the compose step pipeline: maps the ordered plan steps to
/// statuses and streams the up-progress lines into them.
public struct ComposeRunState {
    public enum Status: Equatable {
        case pending, running, success, failed
    }

    public struct StepState: Identifiable {
        public let id: Int
        public let title: String
        public var status: Status = .pending
        public var detail: [String] = []

        public init(step: ComposeStep, index: Int) {
            self.id = index
            self.title = ComposeRunState.title(for: step)
        }
    }

    public var steps: [StepState] = []
    public var rawLog: [String] = []
    public var expandedSteps: Set<Int> = []
    public var cursor = 0

    public var status: Status {
        if steps.contains(where: { $0.status == .failed }) { return .failed }
        if steps.contains(where: { $0.status == .running }) { return .running }
        if steps.allSatisfy({ $0.status == .success }) { return .success }
        return .pending
    }

    public init(steps: [StepState] = []) { self.steps = steps }

    /// Assigns a title to a plan step for the stepper.
    public static func title(for step: ComposeStep) -> String {
        switch step {
        case .network(let n): return "Network \(n.name)"
        case .volume(let v): return "Volume \(v.name)"
        case .pull(let image, _): return "Image \(image)"
        case .build(_, let tag): return "Build \(tag)"
        case .run(let request): return "Run \(request.name ?? "container")"
        case .readiness(let service): return "Wait for \(service.containerName) health"
        }
    }

    /// Feed one stream line; updates the current step and advances.
    public mutating func consume(_ line: String) {
        rawLog.append(line)
        guard cursor < steps.count else { return }
        if steps[cursor].status == .pending { steps[cursor].status = .running }
        steps[cursor].detail.append(line)
        if isSuccessLine(line) {
            steps[cursor].status = .success
            cursor += 1
        }
    }

    /// Success markers are emitted in step order; everything else is detail.
    private func isSuccessLine(_ line: String) -> Bool {
        if line.hasPrefix("Network ") || line.hasPrefix("Volume ") { return line.hasSuffix(" created") }
        if line.hasPrefix("Pulled ") || line.contains("already present") { return true }
        if line.hasPrefix("Built ") { return true }
        if line.hasPrefix("Started ") { return true }
        if line.hasSuffix(" is ready") { return true }
        return false
    }

    public mutating func markCurrentFailed() {
        guard cursor < steps.count else { return }
        steps[cursor].status = .failed
    }

    /// Stream ended cleanly without a marker for the tail step.
    public mutating func markAllPendingSuccess() {
        for index in steps.indices where steps[index].status != .failed {
            steps[index].status = .success
        }
        cursor = steps.count
    }
}
