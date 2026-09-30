import Foundation
import MicropodCore
import NIOCore
import NIOPosix
import NIOSSL
import Security

/// A secret the guest only ever sees as a placeholder: the egress proxy
/// swaps the real value in on HTTPS requests to `hosts`, so it never enters
/// the VM. The value comes from a ``SecretSource`` — fixed, or a host
/// command that mints and refreshes it.
public struct SandboxSecret: Sendable, Equatable {
    /// The env var the guest gets (holding the placeholder).
    public var name: String
    public var hosts: [String]
    public let placeholder: String
    public let source: SecretSource

    public init(name: String, value: String, hosts: [String]) throws {
        self.init(name: name, source: try SecretSource(value: value), hosts: hosts)
    }

    public init(name: String, source: SecretSource, hosts: [String]) {
        self.name = name
        self.hosts = hosts.map { $0.lowercased() }
        self.source = source
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        placeholder = "micropod_secret_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func == (a: SandboxSecret, b: SandboxSecret) -> Bool {
        a.name == b.name && a.hosts == b.hosts && a.placeholder == b.placeholder
    }

    /// `NAME=ENV_VAR@host1,host2` — the value is read from the host's
    /// `ENV_VAR`.
    public static func parse(
        _ spec: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SandboxSecret {
        guard let eq = spec.firstIndex(of: "="), let at = spec.lastIndex(of: "@"), eq < at else {
            throw MicropodError.message("invalidArgument: secret '\(spec)' — want NAME=ENV_VAR@host[,host]")
        }
        let name = String(spec[..<eq])
        let source = String(spec[spec.index(after: eq)..<at])
        let hosts = spec[spec.index(after: at)...].split(separator: ",").map(String.init)
        guard !name.isEmpty, !source.isEmpty, !hosts.isEmpty else {
            throw MicropodError.message("invalidArgument: secret '\(spec)' — want NAME=ENV_VAR@host[,host]")
        }
        guard let value = environment[source], !value.isEmpty else {
            throw MicropodError.message("invalidArgument: secret \(name): host env var \(source) is unset")
        }
        do {
            return try SandboxSecret(name: name, value: value, hosts: hosts)
        } catch {
            throw MicropodError.message("invalidArgument: secret \(name): \(error)")
        }
    }

    /// From the API / `micropod.json` shape: a supplied value (with an
    /// optional expiry) or — `micropod.json` only — a command. A relative
    /// command or directory resolves against `directory`.
    public static func from(
        _ spec: SandboxSecretSpec, directory: URL? = nil,
        log: @escaping @Sendable (String) -> Void = SecretSource.stderrLog
    ) throws -> SandboxSecret {
        guard spec.name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            throw MicropodError.message("invalidArgument: secret name '\(spec.name)' is not an env var name")
        }
        guard !spec.hosts.isEmpty else {
            throw MicropodError.message("invalidArgument: secret \(spec.name) needs at least one host")
        }
        switch (spec.value, spec.command.isEmpty) {
        case (let value?, true):
            do {
                return SandboxSecret(
                    name: spec.name, source: try SecretSource(value: value, expiresAt: spec.expiresAt),
                    hosts: spec.hosts)
            } catch {
                throw MicropodError.message("invalidArgument: secret \(spec.name): \(error)")
            }
        case (nil, false):
            let dir = spec.commandDirectory.map { SecretSource.resolve($0, in: directory) } ?? directory
            let source = SecretSource(
                command: spec.command, directory: dir?.standardizedFileURL, ttl: spec.ttl ?? SecretSource.defaultTTL,
                log: log)
            return SandboxSecret(name: spec.name, source: source, hosts: spec.hosts)
        default:
            throw MicropodError.message("invalidArgument: secret \(spec.name): set exactly one of value or command")
        }
    }

    /// Placeholder → current value for each secret, minting as needed.
    static func substitutions(for secrets: [SandboxSecret]) async throws -> [String: String] {
        var values: [String: String] = [:]
        for secret in secrets {
            do {
                values[secret.placeholder] = try await secret.source.value()
            } catch {
                throw MicropodError.message("secret \(secret.name) is unavailable (\(error))")
            }
        }
        return values
    }
}

/// What a proxied sandbox may reach. The VM has no route out besides the
/// egress proxy, so this is enforced, not advisory.
public struct EgressPolicy: Sendable, Equatable {
    /// `api.example.com` or `*.example.com` (any subdomain); empty = all.
    public var allowHosts: [String] = []
    public var secrets: [SandboxSecret] = []

    public init(allowHosts: [String] = [], secrets: [SandboxSecret] = []) {
        self.allowHosts = allowHosts.map { $0.lowercased() }
        self.secrets = secrets
    }

    public var isEmpty: Bool { allowHosts.isEmpty && secrets.isEmpty }

    public func allows(_ host: String) -> Bool {
        allowHosts.isEmpty || allowHosts.contains { Self.matches(host, $0) }
    }

    func secrets(for host: String) -> [SandboxSecret] {
        secrets.filter { $0.hosts.contains { Self.matches(host, $0) } }
    }

    static func matches(_ host: String, _ pattern: String) -> Bool {
        let host = host.lowercased()
        if pattern.hasPrefix("*.") { return host.hasSuffix(pattern.dropFirst()) }
        return host == pattern
    }
}

/// The host end of a proxied sandbox network: an HTTP proxy on the gateway.
/// CONNECT to an allowed host is tunnelled blind; to a host with secrets it
/// is intercepted — TLS terminated with a SandboxCA leaf, placeholders
/// swapped in the request head, re-encrypted upstream. Absolute-form
/// `https://` requests (clients such as busybox wget never CONNECT) go
/// upstream over TLS from here, secrets swapped in. Plain-HTTP requests are
/// forwarded but never get secrets. Anything not allowed gets 403.
final class EgressProxy: @unchecked Sendable {
    static let port: UInt16 = 3128

    let policy: EgressPolicy
    let ca: SandboxCA?

    init(policy: EgressPolicy, ca: SandboxCA?) {
        self.policy = policy
        self.ca = ca
    }

    func start(on host: String) throws -> Channel {
        try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ProxyRequestHandler(proxy: self))
            }
            .bind(host: host, port: Int(Self.port))
            .wait()
    }

    static let upstreamTLS: NIOSSLContext? = {
        var config = TLSConfiguration.makeClientConfiguration()
        config.applicationProtocols = ["http/1.1"]
        return try? NIOSSLContext(configuration: config)
    }()

    /// Current values for `secrets` (placeholder → value), minted off the
    /// event loop; an empty list resolves at once.
    static func substitutions(for secrets: [SandboxSecret], on eventLoop: any EventLoop)
        -> EventLoopFuture<[String: String]>
    {
        guard !secrets.isEmpty else { return eventLoop.makeSucceededFuture([:]) }
        let promise = eventLoop.makePromise(of: [String: String].self)
        promise.completeWithTask { try await SandboxSecret.substitutions(for: secrets) }
        return promise.futureResult
    }

    /// A connection to the real host; with `tls`, verified against the
    /// system roots for `host` (an IP literal can't be, so it fails).
    static func connect(host: String, port: Int, tls: Bool, on eventLoop: any EventLoop) -> EventLoopFuture<Channel> {
        ClientBootstrap(group: eventLoop)
            .channelOption(.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in
                guard tls else { return channel.eventLoop.makeSucceededVoidFuture() }
                do {
                    guard let context = upstreamTLS else { throw MicropodError.message("no TLS client context") }
                    return channel.pipeline.addHandler(try NIOSSLClientHandler(context: context, serverHostname: host))
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: host, port: port)
    }
}

/// Reads the first request head, applies the policy, then gets out of the
/// way: bytes that arrive while the upstream is connecting are held and
/// replayed, so nothing sent right after the head (a TLS ClientHello) is lost.
private final class ProxyRequestHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Mode { case head, holding, passthrough }

    private let proxy: EgressProxy
    private var mode = Mode.head
    private var buffer = ByteBuffer()

    init(proxy: EgressProxy) { self.proxy = proxy }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var chunk = unwrapInboundIn(data)
        switch mode {
        case .passthrough: context.fireChannelRead(data)
        case .holding: buffer.writeBuffer(&chunk)
        case .head:
            buffer.writeBuffer(&chunk)
            guard let head = HTTPHead.take(from: &buffer) else {
                if buffer.readableBytes > 64 * 1024 {
                    reply(context, 431, "request head too large")
                }
                return
            }
            mode = .holding
            route(context, head)
        }
    }

    private func route(_ context: ChannelHandlerContext, _ head: HTTPHead) {
        if head.method == "CONNECT" {
            guard let (host, port) = HTTPHead.authority(head.target) else {
                return reply(context, 400, "bad CONNECT target")
            }
            guard proxy.policy.allows(host) else { return deny(context, host) }
            let secrets = proxy.policy.secrets(for: host)
            if secrets.isEmpty || proxy.ca == nil {
                return tunnel(context, host: host, port: port, established: true, first: nil)
            }
            return intercept(context, host: host, port: port, secrets: secrets)
        }
        guard let origin = HTTPHead.origin(head.target) else {
            return reply(context, 400, "only CONNECT and absolute-form http(s) requests are proxied")
        }
        guard proxy.policy.allows(origin.host) else { return deny(context, origin.host) }
        let secrets = origin.tls ? proxy.policy.secrets(for: origin.host) : []
        EgressProxy.substitutions(for: secrets, on: context.eventLoop).whenComplete { result in
            switch result {
            case .failure(let error):
                self.reply(context, 502, "micropod sandbox: \(error)")
            case .success(let values):
                self.tunnel(
                    context, host: origin.host, port: origin.port, established: false,
                    first: head.rewritten(target: origin.path, substitutions: values), tls: origin.tls)
            }
        }
    }

    private func deny(_ context: ChannelHandlerContext, _ host: String) {
        reply(context, 403, "micropod sandbox: egress to \(host) is not allowed (--allow-host)")
    }

    /// The upstream (plain TCP, or TLS from here), glued to the client.
    private func tunnel(
        _ context: ChannelHandlerContext, host: String, port: Int, established: Bool, first: ByteBuffer?,
        tls: Bool = false
    ) {
        let inbound = context.channel
        EgressProxy.connect(host: host, port: port, tls: tls, on: context.eventLoop)
            .whenComplete { result in
                switch result {
                case .failure(let error):
                    self.reply(context, 502, "upstream \(host):\(port): \(error)")
                case .success(let upstream):
                    if established {
                        context.writeAndFlush(self.wrapOutboundOut(HTTPHead.connectEstablished), promise: nil)
                    }
                    if let first { upstream.write(first, promise: nil) }
                    let (a, b) = GlueHandler.matchedPair()
                    inbound.pipeline.addHandler(a).and(upstream.pipeline.addHandler(b)).whenComplete { _ in
                        // Everything held while connecting, then live bytes.
                        upstream.writeAndFlush(self.buffer, promise: nil)
                        self.buffer.clear()
                        self.mode = .passthrough
                        inbound.pipeline.removeHandler(self, promise: nil)
                    }
                }
            }
    }

    /// Terminate the client's TLS ourselves, then hand the decrypted stream
    /// to a HeadRewriter that connects upstream.
    private func intercept(_ context: ChannelHandlerContext, host: String, port: Int, secrets: [SandboxSecret]) {
        guard let ca = proxy.ca, let tls = try? ca.serverContext(for: host) else {
            return reply(context, 502, "cannot mint a certificate for \(host)")
        }
        context.writeAndFlush(wrapOutboundOut(HTTPHead.connectEstablished), promise: nil)
        let rewriter = HeadRewriter(host: host, port: port, secrets: secrets)
        context.pipeline.addHandlers([NIOSSLServerHandler(context: tls), rewriter], position: .after(self))
            .whenSuccess {
                self.mode = .passthrough
                if self.buffer.readableBytes > 0 {
                    let held = self.buffer
                    self.buffer.clear()
                    context.fireChannelRead(NIOAny(held))
                }
                context.pipeline.removeHandler(self, promise: nil)
            }
    }

    private func reply(_ context: ChannelHandlerContext, _ status: Int, _ message: String) {
        context.writeAndFlush(wrapOutboundOut(HTTPHead.response(status, message)))
            .whenComplete { _ in context.close(promise: nil) }
    }
}

/// On an intercepted (decrypted) connection: substitute secrets in the first
/// request head, force `Connection: close` so every request gets a fresh
/// head, and relay the rest untouched over TLS to the real host. Bodies are
/// never rewritten — a placeholder there reaches the upstream as-is.
private final class HeadRewriter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Mode { case head, holding, passthrough }

    private let host: String
    private let port: Int
    private let secrets: [SandboxSecret]
    private var buffer = ByteBuffer()
    private var mode = Mode.head

    init(host: String, port: Int, secrets: [SandboxSecret]) {
        self.host = host
        self.port = port
        self.secrets = secrets
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var chunk = unwrapInboundIn(data)
        switch mode {
        case .passthrough: return context.fireChannelRead(data)
        case .holding:
            buffer.writeBuffer(&chunk)
            return
        case .head: buffer.writeBuffer(&chunk)
        }
        guard let head = HTTPHead.take(from: &buffer) else {
            if buffer.readableBytes > 64 * 1024 { context.close(promise: nil) }
            return
        }
        mode = .holding
        let inbound = context.channel
        let host = self.host
        let port = self.port
        let values = EgressProxy.substitutions(for: secrets, on: context.eventLoop)
        values.flatMap { values in
            EgressProxy.connect(host: host, port: port, tls: true, on: context.eventLoop)
                .map { (head.rewritten(target: head.target, substitutions: values), $0) }
        }
        .whenComplete { result in
            switch result {
            case .failure(let error):
                // A secret that can't be minted fails the request closed:
                // never forward the placeholder.
                context.writeAndFlush(
                    self.wrapOutboundOut(HTTPHead.response(502, "micropod sandbox: \(host): \(error)"))
                ).whenComplete { _ in context.close(promise: nil) }
            case .success(let (first, upstream)):
                upstream.write(first, promise: nil)
                let (a, b) = GlueHandler.matchedPair()
                inbound.pipeline.addHandler(a).and(upstream.pipeline.addHandler(b)).whenComplete { _ in
                    upstream.writeAndFlush(self.buffer, promise: nil)
                    self.buffer.clear()
                    self.mode = .passthrough
                    inbound.pipeline.removeHandler(self, promise: nil)
                }
            }
        }
    }
}

/// Just enough HTTP/1.1 to route a proxy request and rewrite its head.
struct HTTPHead {
    var method: String
    var target: String
    var version: String
    var headers: [(name: String, value: String)]

    static let connectEstablished = ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n")

    static func response(_ status: Int, _ message: String) -> ByteBuffer {
        let reason = [400: "Bad Request", 403: "Forbidden", 431: "Request Header Fields Too Large", 502: "Bad Gateway"]
        let body = message + "\n"
        return ByteBuffer(
            string: "HTTP/1.1 \(status) \(reason[status] ?? "Error")\r\nContent-Type: text/plain\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    }

    /// Pops one complete head (through the blank line) off `buffer`.
    static func take(from buffer: inout ByteBuffer) -> HTTPHead? {
        let view = buffer.readableBytesView
        guard let end = view.firstRange(of: Array("\r\n\r\n".utf8)) else { return nil }
        let length = view.distance(from: view.startIndex, to: end.upperBound)
        guard let text = buffer.readString(length: length) else { return nil }
        var lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count == 3 else { return HTTPHead(method: "", target: "", version: "", headers: []) }
        let headers = lines.compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return HTTPHead(method: requestLine[0], target: requestLine[1], version: requestLine[2], headers: headers)
    }

    /// An absolute-form target (`http://host/path`, `https://…`) split into
    /// where to connect and the origin-form path to send, escapes intact.
    static func origin(_ target: String) -> (host: String, port: Int, tls: Bool, path: String)? {
        guard let url = URLComponents(string: target), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else { return nil }
        let tls = scheme == "https"
        var path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        if let query = url.percentEncodedQuery { path += "?" + query }
        return (host, url.port ?? (tls ? 443 : 80), tls, path)
    }

    /// `host:port` of a CONNECT target.
    static func authority(_ target: String) -> (String, Int)? {
        guard let colon = target.lastIndex(of: ":"), let port = Int(target[target.index(after: colon)...]),
            port > 0, port < 65536
        else { return nil }
        let host = String(target[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host.isEmpty ? nil : (host, port)
    }

    /// The head re-serialised with `target`, placeholders in the request
    /// line and header values replaced, hop-by-hop proxy headers dropped and
    /// `Connection: close` set.
    func rewritten(target: String, substitutions: [String: String]) -> ByteBuffer {
        func substitute(_ text: String) -> String {
            substitutions.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }
        var out = "\(method) \(substitute(target)) \(version)\r\n"
        for (name, value) in headers
        where !["connection", "proxy-connection", "proxy-authorization"].contains(name.lowercased()) {
            out += "\(name): \(substitute(value))\r\n"
        }
        out += "Connection: close\r\n\r\n"
        return ByteBuffer(string: out)
    }
}
