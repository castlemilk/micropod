import XCTest

@testable import MicropodCore

final class ContainerLaunchInputTests: XCTestCase {
    func testOptionalCPUTrimsBlankAndParsesPositiveFiniteValue() throws {
        XCTAssertNil(try ContainerLaunchInput.parseOptionalCPU("  \n "))
        XCTAssertEqual(try ContainerLaunchInput.parseOptionalCPU(" 1.5 "), 1.5)
    }

    func testOptionalCPURejectsNonPositiveNonNumericAndNonFiniteValues() {
        for value in ["0", "-1", "many", "nan", "inf"] {
            XCTAssertThrowsError(try ContainerLaunchInput.parseOptionalCPU(value)) { error in
                XCTAssertEqual(error as? ContainerLaunchInputError, .invalidCPU)
                XCTAssertEqual(
                    error.localizedDescription,
                    "CPU must be a finite number greater than 0."
                )
            }
        }
    }

    func testPortsTrimBlankAndParseStrictCommaSeparatedMappings() throws {
        XCTAssertEqual(try ContainerLaunchInput.parsePorts(" \n "), [])
        XCTAssertEqual(
            try ContainerLaunchInput.parsePorts(" 8080 : 80, 8443:443 "),
            [
                PortSpec(hostPort: 8080, containerPort: 80),
                PortSpec(hostPort: 8443, containerPort: 443),
            ]
        )
    }

    func testPortsRejectMalformedEmptyOrOutOfRangeSegments() {
        let invalidValues = [
            "8080",
            "8080:80:tcp",
            ":80",
            "8080:",
            "8080:80,",
            "8080:80,,8443:443",
            "0:80",
            "8080:0",
            "65536:80",
            "8080:65536",
            "-1:80",
            "+8080:80",
            "eight:80",
        ]

        for value in invalidValues {
            XCTAssertThrowsError(try ContainerLaunchInput.parsePorts(value)) { error in
                XCTAssertEqual(error as? ContainerLaunchInputError, .invalidPorts)
                XCTAssertEqual(
                    error.localizedDescription,
                    "Ports must use host:container with each port from 1 to 65535."
                )
            }
        }
    }

    func testOptionalTTLTrimsBlankAndParsesPositiveInteger() throws {
        XCTAssertNil(try ContainerLaunchInput.parseOptionalTTL(" \n "))
        XCTAssertEqual(try ContainerLaunchInput.parseOptionalTTL(" 45 "), 45)
    }

    func testOptionalTTLRejectsNonPositiveAndNonIntegerValues() {
        for value in ["0", "-1", "+1", "1.5", "many"] {
            XCTAssertThrowsError(try ContainerLaunchInput.parseOptionalTTL(value)) { error in
                XCTAssertEqual(error as? ContainerLaunchInputError, .invalidTTL)
                XCTAssertEqual(
                    error.localizedDescription,
                    "TTL must be a whole number of minutes greater than 0."
                )
            }
        }
    }

    func testAgentLabelsAreEmptyWhenAgentModeIsOff() {
        XCTAssertEqual(
            ContainerLaunchInput.agentLabels(
                isAgent: false,
                jobID: "job-42",
                owner: "alice",
                isEphemeral: true,
                ttlMinutes: 30
            ),
            []
        )
    }

    func testAgentLabelsUseCanonicalKeysAndTrimOptionalMetadata() {
        XCTAssertEqual(
            ContainerLaunchInput.agentLabels(
                isAgent: true,
                jobID: "  job-42  ",
                owner: "  alice  ",
                isEphemeral: true,
                ttlMinutes: 30
            ),
            [
                LabelSpec(key: WorkloadLabel.agent, value: "true"),
                LabelSpec(key: WorkloadLabel.job, value: "job-42"),
                LabelSpec(key: WorkloadLabel.owner, value: "alice"),
                LabelSpec(key: WorkloadLabel.ephemeral, value: "true"),
                LabelSpec(key: WorkloadLabel.ttlMinutes, value: "30"),
            ]
        )
    }

    func testAgentLabelsOmitEmptyOptionalMetadataAndDisabledFlags() {
        XCTAssertEqual(
            ContainerLaunchInput.agentLabels(
                isAgent: true,
                jobID: "  ",
                owner: "\n",
                isEphemeral: false,
                ttlMinutes: nil
            ),
            [LabelSpec(key: WorkloadLabel.agent, value: "true")]
        )
    }

    func testAgentLabelsOmitNonPositiveTTLMetadata() {
        for ttlMinutes in [0, -1] {
            XCTAssertEqual(
                ContainerLaunchInput.agentLabels(
                    isAgent: true,
                    jobID: "",
                    owner: "",
                    isEphemeral: false,
                    ttlMinutes: ttlMinutes
                ),
                [LabelSpec(key: WorkloadLabel.agent, value: "true")]
            )
        }
    }
}
