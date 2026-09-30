import Foundation

/// Files a client copies into a container before its first start.
///
/// Docker accepts `PUT /containers/{id}/archive` on a created, never-started
/// container, and testcontainers relies on it: every `ContainerRequest.Files`
/// entry is uploaded between create and start (Keycloak realm imports,
/// WireMock mappings, init scripts). Apple's runtime refuses a copy into a
/// container that is not running ("invalidState: container … is not
/// running"), so those suites failed before any test ran.
///
/// The shim therefore stashes such an archive on the host. At the first
/// start it recreates the container under the same id with a wrapper
/// entrypoint that waits for a marker file, starts it, extracts each archive
/// as root (as Docker does, whatever the image's USER), writes the marker,
/// and the wrapper `exec`s the container's real entrypoint and command.
///
/// Requirements on the image: `/bin/sh` for the wrapper and `tar` for the
/// extraction. `tar` was already required by the running-container path.
struct PreStartArchive: Sendable, Equatable {
    /// Directory the archive is extracted into (the request's `path`).
    var destination: String
    /// The uploaded tar, on the host.
    var file: URL
}

enum PreStartArchives {
    /// How long the wrapper waits for the shim before giving up.
    static let wrapperTimeoutSeconds = 120

    /// Name the wrapper runs under (`$0`), visible in `ps` and error text.
    static let wrapperName = "micropod-prestart"

    /// Host directory holding stashed archives, one subdirectory per container.
    static func stagingDirectory(root: URL? = nil) -> URL {
        let base =
            root
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".micropod")
        return base.appendingPathComponent("shim-prestart", isDirectory: true)
    }

    /// Guest path of the marker the shim writes once every archive is in place.
    static func markerPath(token: String) -> String {
        "/.micropod-prestart-\(token)"
    }

    /// POSIX sh that waits for `marker`, then execs its arguments. Exits 125
    /// (Docker's "the container could not run" code) on timeout.
    static func wrapperScript(marker: String, timeoutSeconds: Int = wrapperTimeoutSeconds) -> String {
        let ticks = timeoutSeconds * 10
        return """
            i=0; while [ ! -e '\(marker)' ]; do i=$((i+1)); \
            if [ "$i" -gt \(ticks) ]; then echo "\(wrapperName): files copied before start never arrived" >&2; exit 125; fi; \
            sleep 0.1 2>/dev/null || sleep 1; done; exec "$@"
            """
    }

    /// The command a container runs, by Docker's rules: a create-time
    /// Entrypoint replaces the image's and drops the image's Cmd; `[""]`
    /// clears the entrypoint; a create-time Cmd replaces the image's.
    static func effectiveArgv(
        entrypoint: [String]?, cmd: [String]?, imageEntrypoint: [String]?, imageCmd: [String]?
    ) -> [String] {
        let entry: [String]
        let overridden = entrypoint != nil
        if let entrypoint {
            entry = (entrypoint.count == 1 && entrypoint[0].isEmpty) ? [] : entrypoint
        } else {
            entry = imageEntrypoint ?? []
        }
        let args = cmd ?? (overridden ? [] : (imageCmd ?? []))
        return entry + args
    }

    /// The create body with the wrapper in front of `argv`.
    static func wrapped(_ body: DockerCreateRequest, argv: [String], marker: String) -> DockerCreateRequest {
        var copy = body
        copy.Entrypoint = ["/bin/sh", "-c", wrapperScript(marker: marker), wrapperName]
        copy.Cmd = argv
        return copy
    }

    struct HostFile: Equatable {
        var url: URL
        /// Path below the extraction root, `/`-separated, no leading slash.
        var relativePath: String
        /// Permission bits (e.g. 0o644).
        var mode: Int
    }

    /// Regular files below `root`, sorted by path. Symlinks and directories
    /// are not returned (see `deliverArchiveFromHost`).
    static func regularFiles(under root: URL) -> [HostFile] {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return [] }
        var files: [HostFile] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            files.append(HostFile(url: url, relativePath: String(path.dropFirst(rootPath.count + 1)), mode: mode))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    /// Entrypoint and Cmd from Docker-shaped image inspect JSON.
    static func imageArgv(fromDockerInspect data: Data) -> (entrypoint: [String]?, cmd: [String]?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let config = object["Config"] as? [String: Any]
        else { return (nil, nil) }
        return (config["Entrypoint"] as? [String], config["Cmd"] as? [String])
    }
}
