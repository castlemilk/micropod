import Foundation

/// Per-VM init image (`RunContainerRequest.init_image`) and the guard that
/// keeps a micro-VM on an init image built for the runtime that boots it.
///
/// The host runtime drives the guest agent (vminitd) in the init image over
/// gRPC. An init image built from another vminit release may not speak that
/// protocol, so an override is used only when the image says it was built
/// from the runtime's own default init image: its config label
/// `org.opencontainers.image.base.name` equals the `vminit.image` property.
/// Any other request boots the default init image. The container's labels
/// record the outcome, so a caller can count fallbacks without reading logs.
public enum InitImageSelection {
    /// `PingResponse.features` name. Only the native backend lists it.
    public static let feature = "init_image"
    /// Config label that names the image an init image was built from (the
    /// OCI `org.opencontainers.image.base.name` key).
    public static let baseNameLabel = "org.opencontainers.image.base.name"
    /// Container label: the init image the VM booted. After a fallback it is
    /// the runtime default's reference, or "default" when that is unknown.
    public static let usedLabel = "com.micropod.init-image"
    /// Container label: why the requested init image was not used.
    public static let fallbackLabel = "com.micropod.init-image.fallback"

    /// Why a requested init image was not used. The raw value is the
    /// `fallbackLabel` value.
    public enum Fallback: String, Sendable, Equatable, CaseIterable {
        /// The backend cannot read the image's labels (the CLI backend).
        case unsupportedBackend = "unsupported-backend"
        /// The runtime's `vminit.image` property could not be read.
        case defaultUnknown = "default-unknown"
        /// The image is absent under `no_pull`, or its pull or read failed.
        case unavailable = "unavailable"
        /// The image has no base-name label.
        case noBaseLabel = "no-base-label"
        /// The image was built from a different init image.
        case baseMismatch = "base-mismatch"
    }

    public enum Decision: Sendable, Equatable {
        /// Boot this init image.
        case use(String)
        /// Boot the runtime's default init image. `detail` is for the log.
        case fallback(Fallback, detail: String)

        /// The init image to hand the runtime. Nil boots its default.
        public var reference: String? {
            if case .use(let reference) = self { return reference }
            return nil
        }
    }

    /// The guard. `runtimeDefault` is the `vminit.image` property and
    /// `baseName` the requested image's base-name label. The references are
    /// compared as written: the image builder copies the property's value.
    public static func decide(requested: String, runtimeDefault: String?, baseName: String?) -> Decision {
        let requested = requested.trimmingCharacters(in: .whitespaces)
        guard let runtimeDefault = trimmed(runtimeDefault) else {
            return .fallback(.defaultUnknown, detail: "the runtime's vminit.image property is unknown")
        }
        if requested == runtimeDefault { return .use(requested) }
        guard let baseName = trimmed(baseName) else {
            return .fallback(.noBaseLabel, detail: "\(requested) has no \(baseNameLabel) label")
        }
        guard baseName == runtimeDefault else {
            return .fallback(
                .baseMismatch, detail: "\(requested) was built from \(baseName), the runtime boots \(runtimeDefault)")
        }
        return .use(requested)
    }

    /// `request` with `decision` applied: `initImage` is what the runtime
    /// gets (nil boots its default), and the labels record the outcome.
    /// The server owns these label keys, so a caller's values are replaced.
    public static func applying(_ decision: Decision, to request: ContainerRunRequest, runtimeDefault: String?)
        -> ContainerRunRequest
    {
        var request = request
        request.initImage = decision.reference
        request.labels.removeAll { $0.key == usedLabel || $0.key == fallbackLabel }
        switch decision {
        case .use(let reference):
            request.labels.append(LabelSpec(key: usedLabel, value: reference))
        case .fallback(let reason, _):
            request.labels.append(LabelSpec(key: usedLabel, value: trimmed(runtimeDefault) ?? "default"))
            request.labels.append(LabelSpec(key: fallbackLabel, value: reason.rawValue))
        }
        return request
    }

    /// A backend that cannot read image labels boots the default init image
    /// and records why. A request without an override passes unchanged.
    public static func unsupported(_ request: ContainerRunRequest) -> ContainerRunRequest {
        guard let requested = request.initImage else { return request }
        return applying(
            .fallback(.unsupportedBackend, detail: "\(requested): this backend cannot check an init image"),
            to: request, runtimeDefault: nil)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}
