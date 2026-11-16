import MicropodCore
import XCTest

/// The init image guard as a pure function: which init image a micro-VM
/// boots for a requested override, and the labels that record it.
final class InitImageSelectionTests: XCTestCase {
    private let runtimeDefault = "ghcr.io/apple/containerization/vminit:0.47.0"
    private let steward = "registry.example.com/vminit:0.47.0-steward.3"

    func testUsesAnImageBuiltFromTheRuntimeDefault() {
        XCTAssertEqual(
            InitImageSelection.decide(requested: steward, runtimeDefault: runtimeDefault, baseName: runtimeDefault),
            .use(steward))
        XCTAssertEqual(
            InitImageSelection.decide(
                requested: " \(steward) ", runtimeDefault: " \(runtimeDefault)", baseName: "\(runtimeDefault) "),
            .use(steward), "surrounding spaces do not count")
    }

    func testTheRuntimeDefaultItselfNeedsNoLabel() {
        XCTAssertEqual(
            InitImageSelection.decide(requested: runtimeDefault, runtimeDefault: runtimeDefault, baseName: nil),
            .use(runtimeDefault))
    }

    func testFallsBackWhenTheGuardCannotPass() {
        func reason(_ decision: InitImageSelection.Decision) -> InitImageSelection.Fallback? {
            if case .fallback(let reason, _) = decision { return reason }
            return nil
        }
        XCTAssertEqual(
            reason(InitImageSelection.decide(requested: steward, runtimeDefault: nil, baseName: runtimeDefault)),
            .defaultUnknown)
        XCTAssertEqual(
            reason(InitImageSelection.decide(requested: steward, runtimeDefault: "  ", baseName: runtimeDefault)),
            .defaultUnknown)
        XCTAssertEqual(
            reason(InitImageSelection.decide(requested: steward, runtimeDefault: runtimeDefault, baseName: nil)),
            .noBaseLabel)
        XCTAssertEqual(
            reason(InitImageSelection.decide(requested: steward, runtimeDefault: runtimeDefault, baseName: "")),
            .noBaseLabel)
        // A steward built for the previous vminit release after a runtime
        // upgrade: the most likely mismatch in practice.
        let old = InitImageSelection.decide(
            requested: steward, runtimeDefault: "ghcr.io/apple/containerization/vminit:0.48.0",
            baseName: runtimeDefault)
        XCTAssertEqual(reason(old), .baseMismatch)
        XCTAssertNil(old.reference, "a fallback boots the runtime default")
        if case .fallback(_, let detail) = old {
            XCTAssertTrue(detail.contains(runtimeDefault) && detail.contains("0.48.0"), detail)
        }
    }

    func testApplyingAUseSetsTheImageAndLabel() {
        let request = ContainerRunRequest(
            image: "runner:1", labels: [LabelSpec(key: "keep", value: "1")], initImage: steward)
        let applied = InitImageSelection.applying(.use(steward), to: request, runtimeDefault: runtimeDefault)
        XCTAssertEqual(applied.initImage, steward)
        XCTAssertEqual(
            applied.labels,
            [LabelSpec(key: "keep", value: "1"), LabelSpec(key: InitImageSelection.usedLabel, value: steward)])
    }

    func testApplyingAFallbackBootsTheDefaultAndSaysWhy() {
        let request = ContainerRunRequest(
            image: "runner:1",
            labels: [
                LabelSpec(key: InitImageSelection.usedLabel, value: "caller"),
                LabelSpec(key: InitImageSelection.fallbackLabel, value: "caller"),
                LabelSpec(key: "keep", value: "1"),
            ],
            initImage: steward)
        let applied = InitImageSelection.applying(
            .fallback(.baseMismatch, detail: "x"), to: request, runtimeDefault: runtimeDefault)
        XCTAssertNil(applied.initImage)
        XCTAssertEqual(
            applied.labels,
            [
                LabelSpec(key: "keep", value: "1"),
                LabelSpec(key: InitImageSelection.usedLabel, value: runtimeDefault),
                LabelSpec(key: InitImageSelection.fallbackLabel, value: "base-mismatch"),
            ], "the server owns the init image labels")

        let unknown = InitImageSelection.applying(
            .fallback(.defaultUnknown, detail: "x"), to: request, runtimeDefault: nil)
        XCTAssertEqual(unknown.labels.first { $0.key == InitImageSelection.usedLabel }?.value, "default")
    }

    func testTheCLIBackendDropsTheOverride() {
        let plain = ContainerRunRequest(image: "runner:1")
        XCTAssertEqual(InitImageSelection.unsupported(plain), plain, "no override: unchanged")

        let dropped = InitImageSelection.unsupported(ContainerRunRequest(image: "runner:1", initImage: steward))
        XCTAssertNil(dropped.initImage)
        XCTAssertEqual(
            dropped.labels.first { $0.key == InitImageSelection.fallbackLabel }?.value, "unsupported-backend")
        let argv = " " + ContainerCommandFactory.run(dropped).arguments.joined(separator: " ") + " "
        XCTAssertFalse(argv.contains("init-image "), argv)
        XCTAssertTrue(argv.contains(" --label com.micropod.init-image.fallback=unsupported-backend "), argv)
    }

    func testFallbackReasonsAreLabelValues() {
        XCTAssertEqual(
            InitImageSelection.Fallback.allCases.map(\.rawValue),
            ["unsupported-backend", "default-unknown", "unavailable", "no-base-label", "base-mismatch"])
    }
}
