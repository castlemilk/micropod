import XCTest

@testable import MicropodCore

/// Command construction for persistent-machine keep-alive
/// (`micropod machines run/stop`).
final class MachineCommandTests: XCTestCase {
    func testRunMachinePassesArgvThrough() {
        let command = ContainerCommandFactory.runMachine(
            "ci-keepalive",
            extraArgs: ["--env", "FOO=bar", "--workdir", "/tmp"],
            command: ["go", "test", "./..."])
        XCTAssertEqual(
            command.arguments,
            [
                "machine", "run", "-n", "ci-keepalive", "--env", "FOO=bar",
                "--workdir", "/tmp", "go", "test", "./...",
            ])
    }

    func testStopMachine() {
        let command = ContainerCommandFactory.stopMachine("ci-keepalive")
        XCTAssertEqual(command.arguments, ["machine", "stop", "ci-keepalive"])
    }
}
