import Crypto
import Foundation
import MicropodCore
import NIOSSL
import X509

/// The TLS interception CA behind sandbox secrets — used only when a run
/// injects one. Created once per host (P-256, ten years) under
/// `~/.micropod/sandbox/ca`, private key owner-only: anyone who can read it
/// can mint certificates the secret-bearing sandboxes trust. A run that
/// needs it trusts it through a CA bundle mounted just for that run.
final class SandboxCA: @unchecked Sendable {
    static var directory: URL { SandboxVM.root.appendingPathComponent("ca") }

    let certificate: Certificate
    let pem: String
    private let key: P256.Signing.PrivateKey
    /// One key for every leaf this process mints; leaves differ by name only.
    private let leafKey = P256.Signing.PrivateKey()
    private let lock = NSLock()
    private var contexts: [String: NIOSSLContext] = [:]

    private init(certificate: Certificate, key: P256.Signing.PrivateKey) throws {
        self.certificate = certificate
        self.key = key
        self.pem = try certificate.serializeAsPEM().pemString
    }

    static func loadOrCreate() throws -> SandboxCA {
        let certURL = directory.appendingPathComponent("ca.pem")
        let keyURL = directory.appendingPathComponent("ca-key.pem")
        if let certPEM = try? String(contentsOf: certURL, encoding: .utf8),
            let keyPEM = try? String(contentsOf: keyURL, encoding: .utf8)
        {
            return try SandboxCA(
                certificate: Certificate(pemEncoded: certPEM),
                key: P256.Signing.PrivateKey(pemRepresentation: keyPEM))
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            OrganizationName("micropod")
            CommonName("micropod sandbox CA (\(ProcessInfo.processInfo.hostName))")
        }
        let now = Date()
        let certificate = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(10 * 365 * 86400),
            issuer: name, subject: name,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: .init(key))
        let ca = try SandboxCA(certificate: certificate, key: key)
        try write(key.pemRepresentation, to: keyURL, mode: 0o600)
        try write(ca.pem, to: certURL, mode: 0o644)
        return ca
    }

    /// Atomic, and created with its final mode — never briefly world-readable.
    private static func write(_ text: String, to url: URL, mode: Int) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid())")
        guard
            FileManager.default.createFile(
                atPath: tmp.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
        else { throw MicropodError.message("writing \(tmp.path) failed") }
        guard rename(tmp.path, url.path) == 0 else {
            throw MicropodError.message("saving \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// A TLS server context presenting a leaf for `host` signed by this CA
    /// (minted once per host per process).
    func serverContext(for host: String) throws -> NIOSSLContext {
        if let cached = lock.withLock({ contexts[host] }) { return cached }
        let now = Date()
        let leaf = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(7 * 86400),
            issuer: certificate.subject, subject: try DistinguishedName { CommonName(host) },
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(host)])
            },
            issuerPrivateKey: .init(key))
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [
                .certificate(
                    try NIOSSLCertificate(bytes: Array(try leaf.serializeAsPEM().pemString.utf8), format: .pem))
            ],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(leafKey.pemRepresentation.utf8), format: .pem)))
        config.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: config)
        lock.withLock { contexts[host] = context }
        return context
    }

    /// The host's public roots plus this CA — what a guest's OpenSSL-style
    /// `SSL_CERT_FILE` should point at so ordinary TLS keeps working.
    func bundle() -> String {
        let roots = (try? String(contentsOfFile: "/etc/ssl/cert.pem", encoding: .utf8)) ?? ""
        return roots + "\n" + pem
    }
}
