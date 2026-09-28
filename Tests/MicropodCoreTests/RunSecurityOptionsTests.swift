import MicropodCore
import XCTest

/// `RunContainerRequest.cap_add` / `cap_drop` / `rosetta` / `privileged`:
/// name validation + normalisation, the proto → request mapping, and the
/// `container run|create` argv the CLI backend renders from them.
final class RunSecurityOptionsTests: XCTestCase {
    // MARK: - LinuxCapabilities.normalize

    func testNormalizeAcceptsDockerSpellings() throws {
        XCTAssertEqual(
            try LinuxCapabilities.normalize(["net_admin", "CAP_SYS_PTRACE", "Cap_Net_Raw", "mknod"]),
            ["CAP_NET_ADMIN", "CAP_SYS_PTRACE", "CAP_NET_RAW", "CAP_MKNOD"])
    }

    /// Same rule as the Go server (whose buf.validate pattern forbids any
    /// whitespace): a padded name is invalid, never silently trimmed.
    func testNormalizeRejectsSurroundingWhitespace() {
        for bad in [" mknod ", "NET_ADMIN\n", "\tNET_RAW", "ALL ", "\r\nSYS_ADMIN"] {
            XCTAssertThrowsError(try LinuxCapabilities.normalize([bad]), bad.debugDescription)
        }
    }

    func testOrderedMatchesKnownInKernelOrder() {
        XCTAssertEqual(LinuxCapabilities.ordered.count, 41)
        XCTAssertEqual(Set(LinuxCapabilities.ordered), LinuxCapabilities.known)
        XCTAssertEqual(LinuxCapabilities.ordered.first, "CHOWN")
        XCTAssertEqual(LinuxCapabilities.ordered.last, "CHECKPOINT_RESTORE")
    }

    func testNormalizeKeepsAllWildcardAndDeduplicates() throws {
        XCTAssertEqual(try LinuxCapabilities.normalize(["all"]), ["ALL"])
        XCTAssertEqual(
            try LinuxCapabilities.normalize(["NET_ADMIN", "cap_net_admin", "ALL", "all"]),
            ["CAP_NET_ADMIN", "ALL"])
        XCTAssertEqual(try LinuxCapabilities.normalize([]), [])
    }

    func testNormalizeRejectsUnknownNames() {
        for bad in ["NET_ADMINN", "CAP_", "", "CAP_ALL", "SYS-ADMIN"] {
            XCTAssertThrowsError(try LinuxCapabilities.normalize(["NET_RAW", bad]), bad) { error in
                XCTAssertEqual((error as? LinuxCapabilities.InvalidName)?.name, bad)
            }
        }
    }

    func testKnownSetCoversEveryKernelCapability() {
        // CAP_CHOWN (0) … CAP_CHECKPOINT_RESTORE (40).
        XCTAssertEqual(LinuxCapabilities.known.count, 41)
        XCTAssertTrue(LinuxCapabilities.known.isSuperset(of: ["SYS_ADMIN", "NET_ADMIN", "BPF", "PERFMON"]))
    }

    // MARK: - proto → ContainerRunRequest

    private func mapped(_ configure: (inout Micropod_V1_RunContainerRequest) -> Void) throws
        -> ContainerRunRequest
    {
        var proto = Micropod_V1_RunContainerRequest()
        proto.image = "docker:dind"
        configure(&proto)
        var request = ContainerRunRequest(image: proto.image)
        try request.applySecurityOptions(from: proto)
        return request
    }

    func testUnsetFieldsLeaveDefaults() throws {
        let request = try mapped { _ in }
        XCTAssertEqual(request.capAdd, [])
        XCTAssertEqual(request.capDrop, [])
        XCTAssertFalse(request.rosetta)
        XCTAssertFalse(request.privileged)
        XCTAssertEqual(request.effectiveCapAdd, [])
    }

    func testCapListsAreNormalised() throws {
        let request = try mapped {
            $0.capAdd = ["net_admin", "all"]
            $0.capDrop = ["NET_RAW"]
        }
        XCTAssertEqual(request.capAdd, ["CAP_NET_ADMIN", "ALL"])
        XCTAssertEqual(request.capDrop, ["CAP_NET_RAW"])
    }

    func testUnknownCapabilityFailsTheMapping() {
        XCTAssertThrowsError(try mapped { $0.capDrop = ["NOT_A_CAP"] })
    }

    func testRosettaFalseIsTheSameAsUnset() throws {
        XCTAssertTrue(try mapped { $0.rosetta = true }.rosetta)
        XCTAssertFalse(try mapped { $0.rosetta = false }.rosetta)
    }

    func testPrivilegedSubsumesCapAdd() throws {
        let request = try mapped {
            $0.privileged = true
            $0.capAdd = ["NET_ADMIN"]
        }
        XCTAssertTrue(request.privileged)
        XCTAssertEqual(request.effectiveCapAdd, ["ALL"])
        XCTAssertFalse(try mapped { $0.privileged = false }.privileged)
    }

    /// The runtime drops before it adds, so an ALL grant would re-add every
    /// dropped capability: with drops, ALL expands to everything else.
    func testCapDropReallyAppliesOnTopOfPrivileged() throws {
        let request = try mapped {
            $0.privileged = true
            $0.capAdd = ["NET_ADMIN"]
            $0.capDrop = ["SYS_MODULE", "net_raw"]
        }
        XCTAssertEqual(request.capDrop, ["CAP_SYS_MODULE", "CAP_NET_RAW"])
        XCTAssertEqual(request.effectiveCapAdd.count, 39)
        XCTAssertFalse(request.effectiveCapAdd.contains("ALL"))
        XCTAssertFalse(request.effectiveCapAdd.contains("CAP_SYS_MODULE"))
        XCTAssertFalse(request.effectiveCapAdd.contains("CAP_NET_RAW"))
        XCTAssertTrue(request.effectiveCapAdd.contains("CAP_SYS_ADMIN"))
        XCTAssertEqual(request.effectiveCapAdd.first, "CAP_CHOWN", "kernel order")
    }

    func testCapDropAppliesOnTopOfCapAddAll() {
        let request = ContainerRunRequest(image: "alpine:3.20", capAdd: ["ALL"], capDrop: ["CAP_NET_RAW"])
        XCTAssertEqual(
            request.effectiveCapAdd, LinuxCapabilities.ordered.filter { $0 != "NET_RAW" }.map { "CAP_\($0)" })
        // No ALL grant: explicit lists pass through (drop ALL + add minimal).
        let minimal = ContainerRunRequest(image: "alpine:3.20", capAdd: ["CAP_NET_ADMIN"], capDrop: ["ALL"])
        XCTAssertEqual(minimal.effectiveCapAdd, ["CAP_NET_ADMIN"])
    }

    func testDropAllWithAnAllGrantIsAConflict() {
        XCTAssertThrowsError(
            try mapped {
                $0.privileged = true
                $0.capDrop = ["all"]
            }
        ) { error in
            XCTAssertTrue(error is LinuxCapabilities.Conflict, "\(error)")
        }
        XCTAssertThrowsError(
            try mapped {
                $0.capAdd = ["ALL"]
                $0.capDrop = ["ALL"]
            }
        ) { error in
            XCTAssertTrue(error is LinuxCapabilities.Conflict, "\(error)")
        }
        XCTAssertNoThrow(
            try mapped {
                $0.capAdd = ["NET_ADMIN"]
                $0.capDrop = ["ALL"]
            })
        XCTAssertNoThrow(
            try mapped {
                $0.privileged = true
                $0.capDrop = ["NET_RAW"]
            })
    }

    func testFeaturesListTheOptionalRunFields() {
        XCTAssertEqual(APIFeatures.supported, ["cap_add", "cap_drop", "rosetta", "privileged"])
    }

    // MARK: - CLI backend argv

    private func joined(_ command: ContainerCommand) -> String {
        " " + command.arguments.joined(separator: " ") + " "
    }

    func testRunArgvCarriesCapsAndRosetta() {
        let request = ContainerRunRequest(
            image: "alpine:3.20", rosetta: true, capAdd: ["CAP_NET_ADMIN"], capDrop: ["CAP_NET_RAW"],
            platform: "linux/amd64")
        let argv = joined(ContainerCommandFactory.run(request))
        for want in [
            " --rosetta ", " --cap-add CAP_NET_ADMIN ", " --cap-drop CAP_NET_RAW ", " --platform linux/amd64 ",
        ] {
            XCTAssertTrue(argv.contains(want), "missing \(want) in \(argv)")
        }
        XCTAssertFalse(argv.contains("--read-only-path"), argv)
        XCTAssertFalse(argv.contains("--masked-path"), argv)
    }

    func testPrivilegedArgvClearsDefaultPathsOnRunAndCreate() {
        let request = ContainerRunRequest(image: "docker:dind", capAdd: ["CAP_NET_ADMIN"], privileged: true)
        for command in [ContainerCommandFactory.run(request), ContainerCommandFactory.create(request)] {
            let argv = joined(command)
            XCTAssertTrue(argv.contains(" --cap-add ALL "), argv)
            XCTAssertFalse(argv.contains("CAP_NET_ADMIN"), "privileged subsumes explicit cap_add: \(argv)")
            XCTAssertTrue(argv.contains(" --read-only-path NONE --masked-path NONE "), argv)
            // Flags precede the image.
            let image = argv.range(of: " docker:dind ")!.lowerBound
            XCTAssertLessThan(argv.range(of: " --masked-path ")!.lowerBound, image)
        }
        XCTAssertEqual(ContainerCommandFactory.create(request).arguments.first, "create")
    }

    func testPrivilegedArgvWithDropsNeverAddsAll() {
        let request = ContainerRunRequest(image: "docker:dind", capDrop: ["CAP_SYS_MODULE"], privileged: true)
        let argv = joined(ContainerCommandFactory.create(request))
        XCTAssertFalse(argv.contains(" --cap-add ALL "), argv)
        XCTAssertFalse(argv.contains(" --cap-add CAP_SYS_MODULE "), argv)
        XCTAssertTrue(argv.contains(" --cap-add CAP_SYS_ADMIN "), argv)
        XCTAssertTrue(argv.contains(" --cap-drop CAP_SYS_MODULE "), argv)
    }
}
