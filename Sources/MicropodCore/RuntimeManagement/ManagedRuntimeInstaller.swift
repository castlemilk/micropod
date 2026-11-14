import CryptoKit
import Darwin
import Foundation

public struct ManagedRuntimeReceipt: Codable, Sendable, Equatable {
    public let selection: ManagedRuntimeLocation.Selection
    public let files: [String: String]
    public init(selection: ManagedRuntimeLocation.Selection, files: [String: String]) {
        self.selection = selection
        self.files = files
    }
}

/// Stages an official signed package without executing its installer scripts or
/// changing the selected runtime. Activation belongs to the maintenance owner.
public actor ManagedRuntimeInstaller {
    public let root: URL
    public let release: AppleRuntimeRelease
    private let download: @Sendable (URL) async throws -> URL

    public init(root: URL = ManagedRuntimeLocation.root) {
        self.root = root
        self.release = .supported
        self.download = { try await RuntimePackageDownload(release: .supported, destination: $0).download() }
    }

    init(root: URL, download: @escaping @Sendable (URL) async throws -> URL) {
        self.root = root
        self.release = .supported
        self.download = download
    }

    public func prepare() async throws -> ManagedRuntimeReceipt {
        let work = root.appendingPathComponent("staging/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let cached = root.appendingPathComponent("packages/" + release.packageSHA256 + ".pkg")
        let package: URL
        if FileManager.default.fileExists(atPath: cached.path),
            (try? Self.sha256(cached)) == release.packageSHA256
        {
            package = cached
        } else {
            package = try await download(work.appendingPathComponent("runtime.pkg"))
        }
        let receipt = try await stage(package: package, work: work)
        try retainVerifiedPackage(package)
        return receipt
    }

    private func retainVerifiedPackage(_ package: URL) throws {
        let cached = root.appendingPathComponent("packages/" + release.packageSHA256 + ".pkg")
        if package != cached {
            try FileManager.default.createDirectory(
                at: cached.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // The source is already verified. Atomic replacement cannot expose
            // a partial package to a concurrent reader or the next repair.
            guard rename(package.path, cached.path) == 0 else {
                throw MicropodError.message("Could not retain the verified runtime package")
            }
            try RuntimeDurableFile.syncDirectory(cached.deletingLastPathComponent())
        }
    }

    /// Also used by the offline verification harness. The same digest, size,
    /// notarization and code-signing checks apply to an already downloaded file.
    public func prepare(package: URL) async throws -> ManagedRuntimeReceipt {
        let work = root.appendingPathComponent("staging/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let privateCopy = work.appendingPathComponent("runtime.pkg")
        try FileManager.default.copyItem(at: package, to: privateCopy)
        let receipt = try await stage(package: privateCopy, work: work)
        try retainVerifiedPackage(privateCopy)
        return receipt
    }

    private func stage(package: URL, work: URL) async throws -> ManagedRuntimeReceipt {
        try Task.checkCancellation()
        guard (try package.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(release.packageBytes),
            try Self.sha256(package) == release.packageSHA256
        else { throw MicropodError.message("Apple runtime package integrity check failed") }
        let signature = try await tool("/usr/sbin/pkgutil", ["--check-signature", package.path])
        guard signature.contains("Developer ID Installer: Apple Inc. - Containerization (\(release.teamIdentifier))")
        else { throw MicropodError.message("Apple runtime installer signer did not match") }
        _ = try await tool("/usr/sbin/spctl", ["--assess", "--type", "install", package.path], timeout: .seconds(60))
        let expanded = work.appendingPathComponent("expanded")
        _ = try await tool("/usr/sbin/pkgutil", ["--expand-full", package.path, expanded.path], timeout: .seconds(90))
        let parser = PackageInfoVerifier(version: release.version)
        guard let xml = XMLParser(contentsOf: expanded.appendingPathComponent("PackageInfo")) else {
            throw MicropodError.message("Apple runtime package metadata is missing")
        }
        xml.delegate = parser
        xml.shouldResolveExternalEntities = false
        guard xml.parse(), parser.valid,
            !FileManager.default.fileExists(atPath: expanded.appendingPathComponent("Scripts").path)
        else { throw MicropodError.message("Apple runtime package layout is unsupported") }
        let payload = expanded.appendingPathComponent("Payload")
        let files = try await inspectPayload(payload)
        guard files == AppleRuntimeRelease.payloadSHA256 else {
            throw MicropodError.message("Apple runtime package is incomplete")
        }
        let selection = ManagedRuntimeLocation.Selection(
            version: release.version, packageSHA256: release.packageSHA256, incarnation: UUID())
        let receipt = ManagedRuntimeReceipt(selection: selection, files: files)
        let versions = root.appendingPathComponent("versions")
        try FileManager.default.createDirectory(
            at: versions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = versions.appendingPathComponent(selection.directoryName)
        if FileManager.default.fileExists(atPath: target.path) {
            try verify(receipt, at: target)
        } else {
            try FileManager.default.moveItem(at: payload, to: target)
            try RuntimeDurableFile.syncDirectory(versions)
        }
        try RuntimeDurableFile.write(receipt, to: target.appendingPathComponent("micropod-receipt.json"))
        return receipt
    }

    public func verify(_ receipt: ManagedRuntimeReceipt) throws {
        guard receipt.selection.isSupported, receipt.files == AppleRuntimeRelease.payloadSHA256 else {
            throw MicropodError.message("Unqualified runtime receipt")
        }
        try verify(receipt, at: root.appendingPathComponent("versions/" + receipt.selection.directoryName))
    }

    private func verify(_ receipt: ManagedRuntimeReceipt, at directory: URL) throws {
        guard receipt.files == AppleRuntimeRelease.payloadSHA256 else {
            throw MicropodError.message("Unqualified runtime file inventory")
        }
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
            directory.resolvingSymlinksInPath().deletingLastPathComponent()
                == root.resolvingSymlinksInPath().appendingPathComponent("versions"),
            let inventory = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else {
            throw MicropodError.message("Managed runtime directory changed")
        }
        let prefix = directory.resolvingSymlinksInPath().path + "/"
        var count = 0
        for case let file as URL in inventory {
            count += 1
            guard count <= 128 else { throw MicropodError.message("Managed runtime inventory exceeds its limit") }
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let name = String(file.resolvingSymlinksInPath().path.dropFirst(prefix.count))
            guard attributes.isSymbolicLink != true,
                attributes.isRegularFile != true || receipt.files[name] != nil || name == "micropod-receipt.json"
            else {
                throw MicropodError.message("Managed runtime contains an unexpected file or link")
            }
        }
        for (relative, digest) in receipt.files {
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
                try Self.sha256(directory.appendingPathComponent(relative)) == digest
            else { throw MicropodError.message("Managed runtime files changed; repair is required") }
        }
    }

    private func inspectPayload(_ root: URL) async throws -> [String: String] {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: []
            )
        else {
            throw MicropodError.message("Apple runtime payload cannot be inspected")
        }
        var files: [String: String] = [:]
        var total = 0
        let prefix = root.resolvingSymlinksInPath().path + "/"
        let entries = enumerator.allObjects.compactMap { $0 as? URL }
        for file in entries {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                throw MicropodError.message("Apple runtime payload contains an escaping link")
            }
            guard values.isSymbolicLink != true else {
                throw MicropodError.message("Apple runtime payload contains an unexpected link")
            }
            guard values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
            guard files.count < 512, total <= 1 << 30 else {
                throw MicropodError.message("Apple runtime payload exceeds its budget")
            }
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(prefix.count))
            files[relative] = try Self.sha256(file)
            let handle = try FileHandle(forReadingFrom: file)
            let magic = try handle.read(upToCount: 4)
            try handle.close()
            if magic == Data([0xcf, 0xfa, 0xed, 0xfe]) || magic == Data([0xca, 0xfe, 0xba, 0xbe]) {
                _ = try await tool(
                    "/usr/bin/codesign",
                    [
                        "--verify", "--strict", "--all-architectures", "-R",
                        "=anchor apple generic and certificate leaf[subject.OU] = \"\(release.teamIdentifier)\"",
                        file.path,
                    ])
            }
        }
        return files
    }

    public nonisolated static func sha256(_ file: URL) throws -> String {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MicropodError.message("Runtime artifact is unavailable or is a symbolic link") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size >= 0, info.st_size <= 1 << 30
        else { throw MicropodError.message("Runtime artifact exceeds its size limit") }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty { hasher.update(data: bytes) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func tool(_ path: String, _ arguments: [String], timeout: Duration = .seconds(30)) async throws -> String {
        try await ContainerCLIClient(executableURL: URL(fileURLWithPath: path)).run(
            .init(arguments: arguments), timeout: timeout)
    }
}

private final class PackageInfoVerifier: NSObject, XMLParserDelegate {
    let version: String
    var valid = false
    init(version: String) { self.version = version }
    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        if elementName == "pkg-info" {
            valid =
                attributes["identifier"] == "com.apple.container-installer"
                && attributes["version"] == version && attributes["install-location"] == "/usr/local"
        }
        if elementName == "scripts" {
            valid = false
            parser.abortParsing()
        }
    }
}
