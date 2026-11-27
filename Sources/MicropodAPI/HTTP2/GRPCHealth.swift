import Foundation

/// The standard gRPC health service (`grpc.health.v1.Health`), answered from
/// the API's own `/health` route: SERVING when it answers 200. It passes the
/// request guard like every call and shares `/health`'s exemption from
/// runtime admission. A service name it does not know is NOT_FOUND.
/// `Watch` sends the current status once and holds the stream until the
/// client cancels it. It keeps its stream but frees its handler place, and
/// it does not keep its connection open: a connection with nothing but
/// Watches on it is idle, and gets the idle GOAWAY like one with no stream
/// (a client watches again on its next connection). Otherwise one Watch per
/// connection would hold every HTTP/2 place of a listener for good.
struct GRPCHealth<Writer: HTTP2ResponseWriter, Slot: HTTP2HandlerSlot>: Sendable {
    static var service: String { GRPCWire.healthService }

    let exchange: GRPCExchange<Writer, Slot>
    let state: GRPCResponseState

    enum Status: Int {
        case serving = 1
        case notServing = 2
    }

    func serve(method: String, payload: Data) async {
        let contentType = exchange.contentType
        guard method == "Check" || method == "Watch" else {
            return await state.trailersOnly(
                12, "unknown method \(Self.service)/\(method)", contentType: contentType, writer: exchange.writer)
        }
        guard let name = Self.serviceName(payload, codec: exchange.codec) else {
            return await state.trailersOnly(
                3, "invalid HealthCheckRequest", contentType: contentType, writer: exchange.writer)
        }
        guard name.isEmpty || name == Self.service || RPCCatalog.services[name] != nil else {
            return await state.trailersOnly(
                5, "unknown service \(name)", contentType: contentType, writer: exchange.writer)
        }
        let probe = HTTPRequest(
            method: .get, path: "/health", query: [:], body: Data(), headers: exchange.request.headers)
        let response = await HTTP2Exchange.uncancellable { [handler = exchange.context.handler] in
            await handler(probe)
        }
        let status: Status = HTTP2Exchange.complete(response)?.status == 200 ? .serving : .notServing
        let message = Self.response(status, codec: exchange.codec)
        if method == "Check" {
            return await state.unary(message, contentType: contentType, writer: exchange.writer)
        }
        guard await state.begin(contentType: contentType, writer: exchange.writer),
            await state.send(GRPCWire.message(message), writer: exchange.writer)
        else { return }
        exchange.slot.park()
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    /// `HealthCheckRequest.service` (field 1); nil when undecodable.
    static func serviceName(_ payload: Data, codec: GRPCWire.Codec) -> String? {
        if codec == .json {
            guard !payload.isEmpty else { return "" }
            guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
                return nil
            }
            return object["service"] as? String ?? ""
        }
        var bytes = [UInt8](payload)[...]
        var name = ""
        while let tag = Self.varint(&bytes) {
            switch tag & 0x7 {
            case 0: guard Self.varint(&bytes) != nil else { return nil }
            case 2:
                guard let length = Self.varint(&bytes), length <= UInt64(bytes.count) else { return nil }
                let field = bytes.prefix(Int(length))
                bytes = bytes.dropFirst(Int(length))
                if tag >> 3 == 1 { name = String(decoding: field, as: UTF8.self) }
            case 1:
                guard bytes.count >= 8 else { return nil }
                bytes = bytes.dropFirst(8)
            case 5:
                guard bytes.count >= 4 else { return nil }
                bytes = bytes.dropFirst(4)
            default: return nil
            }
        }
        return bytes.isEmpty ? name : nil
    }

    private static func varint(_ bytes: inout ArraySlice<UInt8>) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while let byte = bytes.first {
            bytes = bytes.dropFirst()
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// `HealthCheckResponse { status }`.
    static func response(_ status: Status, codec: GRPCWire.Codec) -> Data {
        switch codec {
        case .proto: return Data([0x08, UInt8(status.rawValue)])
        case .json: return Data(#"{"status":"\#(status == .serving ? "SERVING" : "NOT_SERVING")"}"#.utf8)
        }
    }
}
