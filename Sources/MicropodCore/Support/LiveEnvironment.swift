import Darwin

/// One variable of the live process environment, read with `getenv`.
///
/// `ProcessInfo.processInfo.environment` builds a dictionary of the whole
/// environment on every access (~20 µs with ~80 variables): read on a
/// request path several times per request, it cost a sizeable share of a
/// sub-millisecond call. This reads the same live value without it.
public enum LiveEnvironment {
    public static func value(_ name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }

    /// `MICROPOD_ISOLATED_RUNTIME=1`: this process is the dedicated runtime's API.
    public static var isIsolatedRuntime: Bool { value("MICROPOD_ISOLATED_RUNTIME") == "1" }
}
