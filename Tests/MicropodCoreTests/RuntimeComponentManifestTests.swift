import CryptoKit
import Foundation
import XCTest

@testable import MicropodCore

final class RuntimeComponentManifestTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    private let apple = RuntimeComponentManifest.AppleRuntime(
        version: AppleRuntimeRelease.supported.version, packageSHA256: AppleRuntimeRelease.supported.packageSHA256)

    private func manifest(protocolVersion: Int = RuntimeComponentManifest.protocolVersion, cdhash: String? = nil)
        -> RuntimeComponentManifest
    {
        .init(
            version: "0.13.10", sourceRevision: String(repeating: "a", count: 40), minimumHelperVersion: "0.13.10",
            setup: .init(
                bundleIdentifier: IsolatedRuntimePolicy.setupIdentifier,
                cdhash: cdhash ?? String(repeating: "b", count: 40),
                daemonPlistSHA256: String(repeating: "4", count: 64)),
            helper: .init(
                identifier: IsolatedRuntimePolicy.helperIdentifier, sha256: String(repeating: "c", count: 64)),
            api: .init(
                identifier: IsolatedRuntimeAPIConfiguration.executableIdentifier,
                sha256: String(repeating: "e", count: 64)),
            guestSHA256: String(repeating: "f", count: 64), appleRuntime: apple, appleRuntimes: [apple],
            componentProtocol: protocolVersion)
    }

    private func signed(_ manifest: RuntimeComponentManifest) throws -> (Data, Data) {
        let bytes = try JSONEncoder().encode(manifest)
        return (bytes, Data((try key.signature(for: bytes)).base64EncodedString().utf8 + Data("\n".utf8)))
    }

    func testOnlyTheReleaseKeysSignatureOverTheExactBytesVerifies() throws {
        let (bytes, signature) = try signed(manifest())
        XCTAssertEqual(
            try RuntimeComponentManifest.verified(bytes, signature: signature, publicKey: publicKey), manifest())

        var tampered = bytes
        tampered[tampered.startIndex + 10] ^= 1
        XCTAssertThrowsError(
            try RuntimeComponentManifest.verified(tampered, signature: signature, publicKey: publicKey))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try RuntimeComponentManifest.verified(bytes, signature: signature, publicKey: other))
        // A local build signed with the team certificate has no release signature.
        XCTAssertThrowsError(try RuntimeComponentManifest.verified(bytes, signature: Data(), publicKey: publicKey))
        XCTAssertThrowsError(try RuntimeComponentManifest.verified(bytes, signature: signature)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("release key"), "\($0)")
        }
    }

    func testMalformedAndNewerProtocolManifestsAreRefusedEvenWhenSigned() throws {
        let (newer, newerSignature) = try signed(
            manifest(protocolVersion: RuntimeComponentManifest.protocolVersion + 1))
        XCTAssertThrowsError(
            try RuntimeComponentManifest.verified(newer, signature: newerSignature, publicKey: publicKey)
        ) { XCTAssertTrue("\($0.localizedDescription)".contains("protocol"), "\($0)") }
        let (short, shortSignature) = try signed(manifest(cdhash: "abc"))
        XCTAssertThrowsError(
            try RuntimeComponentManifest.verified(short, signature: shortSignature, publicKey: publicKey))
    }

    /// A patched Apple build is one more table entry: a release may name it
    /// as the build it installs while still managing Apple's for rollback.
    func testAReleaseManagesEveryBuildItsTableNames() throws {
        let patched = RuntimeComponentManifest.AppleRuntime(
            version: "1.5.0", packageSHA256: String(repeating: "7", count: 64))
        let base = manifest()
        let next = RuntimeComponentManifest(
            version: base.version, sourceRevision: base.sourceRevision, minimumHelperVersion: base.minimumHelperVersion,
            setup: base.setup, helper: base.helper, api: base.api, guestSHA256: base.guestSHA256,
            appleRuntime: patched, appleRuntimes: [patched, apple])
        XCTAssertNoThrow(try next.validate())
        XCTAssertTrue(
            next.manages(.init(version: apple.version, packageSHA256: apple.packageSHA256, incarnation: UUID())))
        XCTAssertTrue(next.manages(.init(version: "1.5.0", packageSHA256: patched.packageSHA256)))
        XCTAssertFalse(base.manages(.init(version: "1.5.0", packageSHA256: patched.packageSHA256)))
        let orphan = RuntimeComponentManifest(
            version: base.version, sourceRevision: base.sourceRevision, minimumHelperVersion: base.minimumHelperVersion,
            setup: base.setup, helper: base.helper, api: base.api, guestSHA256: base.guestSHA256,
            appleRuntime: patched, appleRuntimes: [apple])
        XCTAssertThrowsError(try orphan.validate(), "The build it installs must be in its own table")
    }
}

final class RuntimeComponentUpdateClientTests: XCTestCase {
    private actor Helper {
        var requests: [IsolatedRuntimeRequest] = []
        var loseReplies = 0
        var protocolVersion: Int? = RuntimeComponentManifest.protocolVersion
        var recorded: UUID?
        var phases: [String] = []
        func setLoseReplies(_ count: Int) { loseReplies = count }
        func setLegacy() { protocolVersion = nil }
        func setPhases(_ value: [String]) { phases = value }
        func handle(_ request: IsolatedRuntimeRequest) throws -> IsolatedRuntimeStatus {
            requests.append(request)
            var status = IsolatedRuntimeStatus(phase: "completed", message: "")
            status.componentProtocol = protocolVersion
            if request.action == .update {
                // Recorded, even when the reply is then lost.
                recorded = recorded ?? request.operation
                if loseReplies > 0 {
                    loseReplies -= 1
                    throw MicropodError.message("Runtime helper request timed out")
                }
            }
            if let recorded {
                let phase = request.action == .status && !phases.isEmpty ? phases.removeFirst() : "staging"
                status.componentUpdate = .init(
                    operation: recorded, phase: phase, rollback: false, sourceVersion: "0.13.9",
                    targetVersion: "0.13.10", runtimeOperation: nil, reason: nil)
            }
            return status
        }
    }

    private func client(_ helper: Helper, ledger: URL) -> RuntimeComponentUpdateClient {
        .init(call: { try await helper.handle($0) }, ledger: ledger, sleep: { _ in })
    }

    private func ledger() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rcu-ledger-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.appendingPathComponent("runtime-component-update.json")
    }

    func testALostReplyResendsTheSameOperation() async throws {
        let helper = Helper()
        await helper.setLoseReplies(2)
        let ledger = ledger()
        let operation = try await client(helper, ledger: ledger).request(rollback: false)
        let updates = await helper.requests.filter { $0.action == .update }
        XCTAssertEqual(updates.count, 3)
        XCTAssertEqual(Set(updates.map(\.operation)), [operation], "Never a second operation")
    }

    func testARerunResumesThePendingOperationAndFollowsItToTheEnd() async throws {
        let helper = Helper()
        let ledger = ledger()
        let first = try await client(helper, ledger: ledger).request(rollback: false)
        // The terminal closed; a new run asks again.
        let second = try await client(helper, ledger: ledger).request(rollback: false)
        XCTAssertEqual(first, second)
        await helper.setPhases(["relaunching", "restarting", "completed"])
        let summary = try await client(helper, ledger: ledger).follow(first)
        XCTAssertEqual(summary.phase, "completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.path), "A finished update is forgotten")
    }

    func testAHelperThatCannotUpdateItselfIsNamed() async throws {
        let helper = Helper()
        await helper.setLegacy()
        do {
            _ = try await client(helper, ledger: ledger()).request(rollback: false)
            XCTFail("A legacy helper was asked to update")
        } catch is RuntimeComponentUpdateClient.LegacyHelper {}
        let updates = await helper.requests.filter { $0.action == .update }
        XCTAssertTrue(updates.isEmpty)
    }

    func testFollowToleratesTheHelperRelaunch() async throws {
        actor Flaky {
            var calls = 0
            func handle() throws -> IsolatedRuntimeStatus {
                calls += 1
                if (2...4).contains(calls) { throw MicropodError.message("connection invalid") }
                var status = IsolatedRuntimeStatus(phase: "completed", message: "")
                status.componentUpdate = .init(
                    operation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    phase: calls > 5 ? "completed" : "relaunching", rollback: false, sourceVersion: "a",
                    targetVersion: "b", runtimeOperation: nil, reason: nil)
                return status
            }
        }
        let flaky = Flaky()
        let client = RuntimeComponentUpdateClient(
            call: { _ in try await flaky.handle() }, ledger: ledger(), sleep: { _ in })
        let summary = try await client.follow(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        XCTAssertEqual(summary.phase, "completed")
    }
}
