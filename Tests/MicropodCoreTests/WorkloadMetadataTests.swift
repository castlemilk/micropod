import XCTest

@testable import MicropodCore

final class WorkloadMetadataTests: XCTestCase {
    func testCanonicalWorkloadLabelKeysAreModuleVisible() {
        XCTAssertEqual(WorkloadLabel.agent, "com.micropod.agent")
        XCTAssertEqual(WorkloadLabel.job, "com.micropod.job")
        XCTAssertEqual(WorkloadLabel.owner, "com.micropod.owner")
        XCTAssertEqual(WorkloadLabel.ephemeral, "com.micropod.ephemeral")
        XCTAssertEqual(WorkloadLabel.ttlMinutes, "com.micropod.ttl-minutes")
        XCTAssertEqual(WorkloadLabel.cuttlefishJob, "com.cuttlefish.job")
        XCTAssertEqual(WorkloadLabel.compose, "com.skunkworq.micropod.compose")
    }

    func testMicropodAgentRequiresExactTrueValue() {
        XCTAssertTrue(WorkloadMetadata(labels: ["com.micropod.agent": "true"]).isAgent)

        for value in ["", "false", "TRUE", " true "] {
            XCTAssertFalse(
                WorkloadMetadata(labels: ["com.micropod.agent": value]).isAgent,
                "Unexpectedly classified com.micropod.agent=\(value.debugDescription) as an agent"
            )
        }
    }

    func testNonEmptyCuttlefishJobClassifiesAgent() {
        XCTAssertTrue(WorkloadMetadata(labels: ["com.cuttlefish.job": "job-42"]).isAgent)
        XCTAssertFalse(WorkloadMetadata(labels: ["com.cuttlefish.job": ""]).isAgent)
        XCTAssertFalse(WorkloadMetadata(labels: ["com.cuttlefish.job": "   "]).isAgent)
    }

    func testMetadataLabelsDoNotIndependentlyClassifyAgent() {
        let metadataOnlyLabels = [
            "com.micropod.job": "job-42",
            "com.micropod.owner": "alice",
            "com.micropod.ephemeral": "true",
            "com.micropod.ttl-minutes": "30",
            "com.example.job": "other-job",
        ]

        XCTAssertFalse(WorkloadMetadata(labels: metadataOnlyLabels).isAgent)
    }

    func testLaunchSourceIsIndependentFromAgentClassification() {
        XCTAssertEqual(WorkloadMetadata(labels: [:]).source, .direct)
        XCTAssertEqual(
            WorkloadMetadata(labels: ["com.skunkworq.micropod.compose": "demo"]).source,
            .compose
        )
        XCTAssertEqual(
            WorkloadMetadata(labels: ["com.skunkworq.micropod.compose": "   "]).source,
            .direct
        )

        let composeAgent = WorkloadMetadata(labels: [
            "com.micropod.agent": "true",
            "com.skunkworq.micropod.compose": "demo",
        ])
        XCTAssertTrue(composeAgent.isAgent)
        XCTAssertEqual(composeAgent.source, .compose)
    }

    func testExtractsPreferredJobOwnerEphemeralAndPositiveTTL() {
        let metadata = WorkloadMetadata(labels: [
            "com.micropod.job": "  micropod-job  ",
            "com.cuttlefish.job": "cuttlefish-job",
            "com.micropod.owner": "  alice  ",
            "com.micropod.ephemeral": "true",
            "com.micropod.ttl-minutes": " 45 ",
        ])

        XCTAssertEqual(metadata.jobID, "micropod-job")
        XCTAssertEqual(metadata.owner, "alice")
        XCTAssertTrue(metadata.isEphemeral)
        XCTAssertEqual(metadata.ttlMinutes, 45)
    }

    func testEmptyMicropodJobFallsBackToCuttlefishJob() {
        let metadata = WorkloadMetadata(labels: [
            "com.micropod.job": " ",
            "com.cuttlefish.job": "legacy-job",
        ])

        XCTAssertEqual(metadata.jobID, "legacy-job")
    }

    func testInvalidOptionalMetadataIsIgnored() {
        for ttl in ["", "0", "-1", "1.5", "many"] {
            let metadata = WorkloadMetadata(labels: [
                "com.micropod.owner": " ",
                "com.micropod.ephemeral": "TRUE",
                "com.micropod.ttl-minutes": ttl,
            ])

            XCTAssertNil(metadata.owner)
            XCTAssertFalse(metadata.isEphemeral)
            XCTAssertNil(metadata.ttlMinutes)
        }
    }

    func testQueryMatchesIDImageLabelKeysAndLabelValues() {
        let labels = [
            "com.micropod.agent": "true",
            "com.micropod.owner": "Alice-Team",
        ]
        func matches(_ query: String) -> Bool {
            workloadMatchesQuery(
                query: query,
                id: "api-worker",
                image: "ghcr.io/acme/worker:1",
                labels: labels
            )
        }

        XCTAssertTrue(matches("API"))
        XCTAssertTrue(matches("ACME/WORKER"))
        XCTAssertTrue(matches("micropod.agent"))
        XCTAssertTrue(matches("alice-team"))
        XCTAssertTrue(matches("  "))
        XCTAssertFalse(matches("database"))
    }

    func testOfficialDockerImageReferencesNormalizeToTheSameLocalImage() {
        let localReferences = ["docker.io/library/alpine:latest"]

        XCTAssertTrue(localImageIsPresent("alpine", in: localReferences))
        XCTAssertTrue(localImageIsPresent("alpine:latest", in: localReferences))
        XCTAssertTrue(localImageIsPresent("library/alpine", in: localReferences))
        XCTAssertTrue(localImageIsPresent("docker.io/alpine", in: localReferences))
        XCTAssertTrue(localImageIsPresent("docker.io/library/alpine:latest", in: localReferences))
    }

    func testImagePresencePreservesExplicitRegistryNamespaceAndTag() {
        XCTAssertTrue(
            localImageIsPresent(
                "ghcr.io/acme/worker",
                in: ["ghcr.io/acme/worker:latest"]
            )
        )
        XCTAssertTrue(
            localImageIsPresent(
                "acme/worker",
                in: ["docker.io/acme/worker:latest"]
            )
        )
        XCTAssertFalse(
            localImageIsPresent(
                "ghcr.io/acme/worker:2",
                in: ["ghcr.io/acme/worker:latest"]
            )
        )
        XCTAssertFalse(
            localImageIsPresent(
                "ghcr.io/other/worker:latest",
                in: ["ghcr.io/acme/worker:latest"]
            )
        )
    }

    func testImagePresenceDoesNotInferSharedLayerCache() {
        XCTAssertFalse(
            localImageIsPresent(
                "alpine:3.20",
                in: ["docker.io/library/alpine:latest", "ghcr.io/acme/alpine-based:latest"]
            )
        )
        XCTAssertFalse(localImageIsPresent("", in: ["docker.io/library/alpine:latest"]))
    }

    func testImagePresenceMatchesEquivalentReferencesWithTheSameDigest() {
        XCTAssertTrue(
            localImageIsPresent(
                "alpine@sha256:abc123",
                in: ["docker.io/library/alpine@sha256:abc123"]
            )
        )
    }

    func testImagePresenceRejectsTheSameRepositoryWithADifferentDigest() {
        XCTAssertFalse(
            localImageIsPresent(
                "alpine@sha256:abc123",
                in: ["docker.io/library/alpine@sha256:def456"]
            )
        )
    }

    func testImageInventoryProjectsDescriptorDigestFromRealImageShape() {
        var image = Micropod_V1_Image()
        image.names = ["docker.io/library/alpine:latest"]
        image.digest = "sha256:abc123"

        let references = localImageReferenceInventory(from: [image])

        XCTAssertTrue(localImageIsPresent("alpine:latest", in: references))
        XCTAssertTrue(localImageIsPresent("alpine@sha256:abc123", in: references))
        XCTAssertFalse(localImageIsPresent("alpine@sha256:def456", in: references))
    }

    func testContainerImageReferenceValidationRejectsMalformedInput() {
        for reference in [
            "", "   ", "alpine latest", "alpine:", "alpine::latest", "/alpine", "alpine@",
            "alpine@sha256:",
        ] {
            XCTAssertFalse(
                containerImageReferenceIsValid(reference),
                "Unexpectedly accepted \(reference.debugDescription)"
            )
        }
    }

    func testContainerImageReferenceValidationAcceptsTagsRegistriesAndDigests() {
        for reference in [
            "alpine",
            "alpine:latest",
            "ghcr.io/acme/worker:2",
            "localhost:5000/acme/worker",
            "alpine@sha256:abc123",
        ] {
            XCTAssertTrue(
                containerImageReferenceIsValid(reference),
                "Unexpectedly rejected \(reference.debugDescription)"
            )
        }
    }
}
