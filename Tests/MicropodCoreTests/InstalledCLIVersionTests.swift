import Darwin
import Foundation
import XCTest

@testable import MicropodCore

/// The CLI version read from the installer's receipt instead of running
/// `container system version`, and only for the file that install wrote.
final class InstalledCLIVersionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // A real path: the receipt names the prefix without /tmp's symlink.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        directory = base.appendingPathComponent("mp-icv-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var executable: URL { directory.appendingPathComponent("bin/container") }

    private func receipt(installedAt: Date, version: String = "1.5.0", prefix: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent("receipt.plist")
        let plist: [String: Any] = [
            "PackageIdentifier": "com.apple.container-installer", "PackageVersion": version,
            "InstallDate": installedAt, "InstallPrefixPath": prefix ?? String(directory.path.dropFirst()),
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        return url
    }

    private func install(_ script: String = "#!/bin/sh\nexit 0\n") throws {
        try script.write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func testTheReceiptNamesTheVersionOfTheFileItsInstallWrote() throws {
        try install()
        let receipt = try receipt(installedAt: Date().addingTimeInterval(1))
        XCTAssertEqual(InstalledCLIVersion.version(of: executable, receipt: receipt), "1.5.0")
    }

    func testAFileChangedAfterTheInstallIsNotTheOneTheReceiptDescribes() throws {
        try install()
        let receipt = try receipt(installedAt: Date().addingTimeInterval(-3600))
        XCTAssertNil(InstalledCLIVersion.version(of: executable, receipt: receipt), "ctime is after the install")
    }

    func testOnlyTheReceiptsOwnPathAndARegularFileCount() throws {
        try install()
        let elsewhere = directory.appendingPathComponent("container")
        try FileManager.default.copyItem(at: executable, to: elsewhere)
        let receipt = try receipt(installedAt: Date().addingTimeInterval(1))
        XCTAssertNil(InstalledCLIVersion.version(of: elsewhere, receipt: receipt), "not prefix/bin/container")
        XCTAssertNil(
            InstalledCLIVersion.version(of: executable, receipt: directory.appendingPathComponent("none.plist")))
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: elsewhere)
        XCTAssertNil(
            InstalledCLIVersion.version(of: executable, receipt: receipt), "a symlink is not what was installed")
    }

    /// `dependencyReport` hands back the service status the verdict was read
    /// from, which GetRuntimeDependency carries (the MCP's `status` line).
    func testTheDependencyReportCarriesTheStatusItWasJudgedFrom() async throws {
        guard RuntimeDependencyStatus.hostSupported else { throw XCTSkip("needs Apple silicon and macOS 26") }
        try install(
            """
            #!/bin/sh
            case "$*" in
              *"system status"*) echo '{"status":"unregistered"}'; exit 1 ;;
              *"system version"*) echo '[{"appName":"container","version":"1.5.0"}]' ;;
            esac
            """)
        let service = SystemService(
            client: ContainerCLIClient(executableURL: executable), installedVersion: { _ in nil })
        let (dependency, status) = await service.dependencyReport()
        XCTAssertEqual(status?.status, "stopped")
        XCTAssertEqual(status?.cliVersion, "1.5.0")
        XCTAssertEqual(dependency.state, .stopped)
        XCTAssertEqual(dependency.cliVersion, "1.5.0")
        let plain = await service.dependencyStatus()
        XCTAssertEqual(plain, dependency, "dependencyStatus is the same verdict")
    }

    /// With the receipt's word, `cliVersion()` runs nothing.
    func testSystemServiceTakesTheInstalledVersionWithoutRunningTheCLI() async throws {
        let trace = directory.appendingPathComponent("calls")
        try install(
            "#!/bin/sh\necho call >> '\(trace.path)'\necho '[{\"appName\":\"container\",\"version\":\"9.9.9\"}]'\n")
        let receipt = try receipt(installedAt: Date().addingTimeInterval(1), version: "1.5.0")
        let service = SystemService(
            client: ContainerCLIClient(executableURL: executable),
            installedVersion: { InstalledCLIVersion.version(of: $0, receipt: receipt) })
        let version = try await service.cliVersion()
        XCTAssertEqual(version, "1.5.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trace.path), "the CLI was run")

        // No receipt for it: asked, as before.
        let asking = SystemService(
            client: ContainerCLIClient(executableURL: executable), installedVersion: { _ in nil })
        let asked = try await asking.cliVersion()
        XCTAssertEqual(asked, "9.9.9")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trace.path))
    }
}
