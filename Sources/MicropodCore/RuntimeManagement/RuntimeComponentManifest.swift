import CryptoKit
import Foundation

/// The release key. It signs the Sparkle feeds' disk images and each
/// release's runtime component manifest. It is the app's `SUPublicEDKey`
/// (scripts/package_app.sh) and the CLI's `SelfUpdate.publicKey`.
public enum MicropodReleaseSigning {
    public static let publicKey = "nJEL+JijqhfC7zxPlqxifCqBM06A3DGki/JmBFTW/VM="

    /// Whether `signature` is the release key's EdDSA signature of `data`.
    public static func verify(_ data: Data, signature: Data, publicKey: String = publicKey) -> Bool {
        guard let raw = Data(base64Encoded: publicKey),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

/// What a release's dedicated runtime consists of, signed by the release key
/// (`Contents/Resources/runtime-components.json` and `.sig` inside the
/// desktop app). The root helper accepts a component update only when this
/// manifest verifies against its compiled-in key and the setup app it copied
/// matches every digest here. A Developer ID signature alone, which any local
/// build signed with the team certificate also has, is not enough.
///
/// See docs/runtime-component-update.md.
public struct RuntimeComponentManifest: Codable, Sendable, Equatable {
    public static let schemaV1 = "micropod-runtime-components-v1"
    public static let fileName = "runtime-components.json"
    public static let signatureFileName = "runtime-components.json.sig"
    public static let maximumBytes = 16384
    /// The component update protocol this build implements. A manifest that
    /// needs a newer one is refused before anything is copied.
    public static let protocolVersion = 1

    public struct Code: Codable, Sendable, Equatable {
        public let identifier: String
        public let sha256: String
        public init(identifier: String, sha256: String) {
            self.identifier = identifier
            self.sha256 = sha256
        }
    }

    public struct Setup: Codable, Sendable, Equatable {
        public let bundleIdentifier: String
        /// The sealed setup app's code directory hash (`codesign -dvvv`
        /// CDHash): it covers every executable and resource in the bundle.
        public let cdhash: String
        /// SHA-256 of `Contents/Library/LaunchDaemons/<label>.plist`.
        public let daemonPlistSHA256: String
        public init(bundleIdentifier: String, cdhash: String, daemonPlistSHA256: String) {
            self.bundleIdentifier = bundleIdentifier
            self.cdhash = cdhash
            self.daemonPlistSHA256 = daemonPlistSHA256
        }
    }

    /// One Apple container build the helper's compiled-in release table
    /// names. A patched build is a separate entry with its own package digest.
    public struct AppleRuntime: Codable, Sendable, Equatable, Hashable {
        public let version: String
        public let packageSHA256: String
        public init(version: String, packageSHA256: String) {
            self.version = version
            self.packageSHA256 = packageSHA256
        }
    }

    public let schema: String
    public let componentProtocol: Int
    public let version: String
    public let sourceRevision: String
    /// The oldest installed helper allowed to install this release itself.
    public let minimumHelperVersion: String
    /// Releases below this have a security defect: once a host installs this
    /// release, root refuses to install or roll back to anything older.
    public let securityFloor: String?
    public let setup: Setup
    public let helper: Code
    public let api: Code
    public let guestSHA256: String?
    /// The build this release installs.
    public let appleRuntime: AppleRuntime
    /// Every build this release's helper can verify and manage: the one it
    /// installs and the ones it can roll back to.
    public let appleRuntimes: [AppleRuntime]

    public init(
        version: String, sourceRevision: String, minimumHelperVersion: String, setup: Setup, helper: Code, api: Code,
        guestSHA256: String?, appleRuntime: AppleRuntime, appleRuntimes: [AppleRuntime],
        componentProtocol: Int = Self.protocolVersion, securityFloor: String? = nil
    ) {
        self.securityFloor = securityFloor
        schema = Self.schemaV1
        self.componentProtocol = componentProtocol
        self.version = version
        self.sourceRevision = sourceRevision
        self.minimumHelperVersion = minimumHelperVersion
        self.setup = setup
        self.helper = helper
        self.api = api
        self.guestSHA256 = guestSHA256
        self.appleRuntime = appleRuntime
        self.appleRuntimes = appleRuntimes
    }

    /// Decodes `bytes` only after the release key's signature over exactly
    /// those bytes verifies. `signature` is the base64 text `sign_update`
    /// prints as `sparkle:edSignature`.
    public static func verified(
        _ bytes: Data, signature: Data, publicKey: String = MicropodReleaseSigning.publicKey
    ) throws -> Self {
        guard bytes.count <= maximumBytes, signature.count <= 1024 else {
            throw MicropodError.message("The runtime component manifest exceeds its size limit")
        }
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: text),
            MicropodReleaseSigning.verify(bytes, signature: raw, publicKey: publicKey)
        else {
            throw MicropodError.message(
                "The runtime component manifest is not signed by Micropod's release key; nothing was changed")
        }
        let manifest = try JSONDecoder().decode(Self.self, from: bytes)
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        func hex(_ value: String, _ count: Int) -> Bool {
            value.count == count && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }
        func release(_ value: String) -> Bool {
            value.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
        }
        func apple(_ build: AppleRuntime) -> Bool {
            build.version.range(of: #"^\d+(\.\d+){1,3}$"#, options: .regularExpression) != nil
                && hex(build.packageSHA256, 64)
        }
        guard schema == Self.schemaV1 else {
            throw MicropodError.message("The runtime component manifest schema \(schema) is not supported")
        }
        guard (1...Self.protocolVersion).contains(componentProtocol) else {
            throw MicropodError.message(
                "Micropod \(version) needs runtime component protocol \(componentProtocol); this helper "
                    + "implements \(Self.protocolVersion)")
        }
        guard release(version), release(minimumHelperVersion), securityFloor.map(release) ?? true,
            hex(sourceRevision, 40),
            setup.bundleIdentifier == IsolatedRuntimePolicy.setupIdentifier, hex(setup.cdhash, 40),
            hex(setup.daemonPlistSHA256, 64),
            helper.identifier == IsolatedRuntimePolicy.helperIdentifier, hex(helper.sha256, 64),
            api.identifier == IsolatedRuntimeAPIConfiguration.executableIdentifier, hex(api.sha256, 64),
            guestSHA256.map({ hex($0, 64) }) ?? true,
            apple(appleRuntime), appleRuntimes.allSatisfy(apple), appleRuntimes.contains(appleRuntime),
            appleRuntimes.count <= 8
        else { throw MicropodError.message("The runtime component manifest is malformed") }
    }

    public var releaseVersion: ReleaseVersion? { ReleaseVersion(version) }

    /// Whether this release's helper can manage the Apple build `selection`
    /// names. A release that cannot is never installed over it: its helper
    /// could neither verify the running runtime nor roll back to it.
    public func manages(_ selection: ManagedRuntimeLocation.Selection) -> Bool {
        appleRuntimes.contains(.init(version: selection.version, packageSHA256: selection.packageSHA256))
    }
}

/// What `MicropodRuntimeHost --component-probe` prints: compiled-in facts
/// only. The installed helper runs the staged copy this way before swapping
/// it in, which proves the new binary loads and runs on this Mac.
public struct RuntimeComponentProbe: Codable, Sendable, Equatable {
    public let componentProtocol: Int
    public let version: String
    public let revision: String
    /// Apple builds this helper's release table names.
    public let appleRuntimes: [RuntimeComponentManifest.AppleRuntime]
    /// `IsolatedRuntimePolicy.schema`: the operation journal and identity
    /// formats it reads.
    public let runtimeSchema: String

    public init(
        version: String, revision: String, appleRuntimes: [RuntimeComponentManifest.AppleRuntime],
        componentProtocol: Int = RuntimeComponentManifest.protocolVersion,
        runtimeSchema: String = IsolatedRuntimePolicy.schema
    ) {
        self.componentProtocol = componentProtocol
        self.version = version
        self.revision = revision
        self.appleRuntimes = appleRuntimes
        self.runtimeSchema = runtimeSchema
    }

    /// This build. A table with more than one Apple build lists each here.
    public static func current(version: String, revision: String) -> Self {
        .init(
            version: version, revision: revision,
            appleRuntimes: [
                .init(
                    version: AppleRuntimeRelease.supported.version,
                    packageSHA256: AppleRuntimeRelease.supported.packageSHA256)
            ])
    }
}

/// The component update the root helper reports in status. Never journaled
/// in `operation.json`, which older helpers must always be able to read.
public struct RuntimeComponentUpdateSummary: Codable, Sendable, Equatable {
    public let operation: UUID
    public let phase: String
    public let rollback: Bool
    public let sourceVersion: String
    public let targetVersion: String
    public let runtimeOperation: UUID?
    public let reason: String?
    public var isTerminal: Bool {
        ["completed", "helperUpdated", "rolledBack", "refused", "recoveryRequired"].contains(phase)
    }
    public init(
        operation: UUID, phase: String, rollback: Bool, sourceVersion: String, targetVersion: String,
        runtimeOperation: UUID?, reason: String?
    ) {
        self.operation = operation
        self.phase = phase
        self.rollback = rollback
        self.sourceVersion = sourceVersion
        self.targetVersion = targetVersion
        self.runtimeOperation = runtimeOperation
        self.reason = reason
    }
}
