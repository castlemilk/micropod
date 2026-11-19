import Darwin
import Foundation
import MachO
import MicropodBuildInfo
import MicropodCore
import MicropodRuntimeHostKit

@main
struct MicropodRuntimeHost {
    static func main() async {
        if CommandLine.arguments.dropFirst().elementsEqual(["--enter-worker"]) {
            do {
                guard getuid() == 0, geteuid() == 0 else {
                    throw MicropodError.message("Only the runtime authority can enter the private account")
                }
                let identity = try IsolatedRuntimeIdentity.readRootOwned()
                var group = gid_t(identity.serviceGID)
                guard setgroups(1, &group) == 0,
                    IsolatedRuntimePolicy.accountName.withCString({ initgroups($0, Int32(group)) }) == 0,
                    setgid(group) == 0, setuid(identity.serviceUID) == 0,
                    getuid() == identity.serviceUID, geteuid() == identity.serviceUID,
                    getgid() == identity.serviceGID, getegid() == identity.serviceGID
                else {
                    throw MicropodError.message("Could not irreversibly enter the private runtime account")
                }
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            await worker()
            return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--worker"]) {
            await worker()
            return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--component-probe"]) {
            // Compiled-in facts only, no privilege used: the installed helper
            // runs a staged copy this way before swapping it in.
            probe()
            return
        }
        guard geteuid() == 0, CommandLine.arguments.count == 1 else {
            fputs("Micropod's runtime helper must be started by macOS Service Management.\n", stderr)
            exit(1)
        }
        // Armed before anything else: a helper that hangs anywhere before it
        // serves (a Security.framework call, a lock, a probe) exits, so its
        // launch is counted and a swapped-in helper that never serves is
        // rolled back (docs/runtime-component-update.md).
        let confirmed = LaunchConfirmation()
        DispatchQueue.global().asyncAfter(deadline: .now() + RuntimeComponentUpdater.confirmationDeadline) {
            if !confirmed.value {
                fputs("Runtime helper did not start serving in time\n", stderr)
                exit(75)
            }
        }
        do {
            var count: UInt32 = 4096
            var path = [CChar](repeating: 0, count: Int(count))
            guard _NSGetExecutablePath(&path, &count) == 0 else {
                throw MicropodError.message("The runtime helper executable path is unavailable")
            }
            let executable = URL(
                fileURLWithPath: String(
                    decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            ).resolvingSymlinksInPath()
            // Started by the legacy SMAppService job from /Applications: yield
            // to an installed root-owned authority, so at most one helper
            // serves. Exit 0 keeps launchd from respawning it.
            // install-authority boots out and disables that job as well.
            let authority = executable.path == IsolatedRuntimePolicy.authorityProgram.path
            if !authority, RuntimeAuthority.legacyJobShouldYield() {
                fputs("The root-owned runtime authority is installed; the legacy helper job yields\n", stderr)
                exit(0)
            }
            try RootRuntimeStorage.prepareRoot()
            let fd = open(
                IsolatedRuntimePolicy.root.appendingPathComponent("host.lock").path,
                O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw MicropodError.message("Another runtime helper owns the state")
            }
            // Under the lock: settle a component update the previous helper
            // left, and count this launch of a swapped-in helper.
            let components = RuntimeComponentUpdater(
                environment: NativeRuntimeComponentEnvironment(
                    executable: executable, runningVersion: MicropodBuildInfo.version))
            if components.launch() == .relaunch {
                fputs("Runtime helper restarts into the installed authority\n", stderr)
                exit(75)
            }
            // The VM release gate's crash and hang faults (root-only file).
            RuntimeGateHooks.applyFault(version: MicropodBuildInfo.version)
            if let reason = components.launchBelowFloor() {
                // Below the signed security floor: refuse to run at all. Exit
                // 0 so launchd does not respawn it; install-authority repairs.
                fputs(reason + "; it refuses to run\n", stderr)
                exit(0)
            }
            try RuntimeCodeIdentity.verifyExecutable(executable, identifier: IsolatedRuntimePolicy.helperIdentifier)
            let controller = IsolatedRuntimeHostController(
                driver: NativeIsolatedRuntimeHostDriver(executable: executable), components: components)
            let server = RuntimeHostServer(
                controller: controller,
                serviceName: authority ? IsolatedRuntimePolicy.authorityServiceName : IsolatedRuntimePolicy.serviceName)
            try server.start()
            let rig = IsolatedRuntimeRigServer(controller: controller)
            try rig.start()
            // install-authority's proof that the authority serves.
            try RuntimeAuthority.recordServing(
                serviceName: authority ? IsolatedRuntimePolicy.authorityServiceName : IsolatedRuntimePolicy.serviceName,
                version: MicropodBuildInfo.version, executable: executable)
            confirmed.value = await controller.continueComponentUpdate()
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            withExtendedLifetime(rig) {}
        } catch {
            fputs("Runtime helper could not start: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func probe() {
        // The compiled-in release, not a plist in a writable bundle.
        let report = RuntimeComponentProbe.current(
            version: MicropodBuildInfo.version, revision: MicropodBuildInfo.sourceRevision,
            authorityDefinitionSHA256: RuntimeAuthority.definitionSHA256)
        guard let data = try? JSONEncoder().encode(report) else { exit(1) }
        FileHandle.standardOutput.write(data + Data([10]))
    }

    private static func worker() async {
        do {
            let identity = try IsolatedRuntimeIdentity.readRootOwned()
            guard getuid() == identity.serviceUID, geteuid() == identity.serviceUID,
                let birth = try RuntimeProcessBirth.read(getpid())
            else { throw MicropodError.message("The private worker uid is invalid") }
            try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(birth) + Data([10]))
            guard let input = try FileHandle.standardInput.read(upToCount: 16385), input.count <= 16384 else {
                throw MicropodError.message("Private worker request exceeded its limit")
            }
            let request = try JSONDecoder().decode(IsolatedRuntimeWorkerRequest.self, from: input)
            let result = try await IsolatedRuntimeWorker.execute(request)
            try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(result) + Data([10]))
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

/// Set once the helper serves and a swapped-in helper confirmed itself.
private final class LaunchConfirmation: @unchecked Sendable {
    private let lock = NSLock()
    private var confirmed = false
    var value: Bool {
        get { lock.withLock { confirmed } }
        set { lock.withLock { confirmed = newValue } }
    }
}

private final class RuntimeHostServer: @unchecked Sendable {
    private let controller: IsolatedRuntimeHostController
    private let serviceName: String
    private nonisolated(unsafe) var listener: xpc_connection_t?
    init(controller: IsolatedRuntimeHostController, serviceName: String) {
        self.controller = controller
        self.serviceName = serviceName
    }
    func start() throws {
        let listener = xpc_connection_create_mach_service(
            serviceName, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        self.listener = listener
        xpc_connection_set_event_handler(listener) { [self] peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            nonisolated(unsafe) let peer = peer
            // Every request on the accepted connection is checked as well.
            do {
                try RuntimeCodeIdentity.require(
                    peer, identifiers: IsolatedRuntimePolicy.clientIdentifiers)
            } catch {
                xpc_connection_cancel(peer)
                return
            }
            xpc_connection_set_event_handler(peer) { [self] message in
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY, xpc_connection_get_euid(peer) >= 500 else { return }
                nonisolated(unsafe) let message = message
                var size = 0
                guard let bytes = xpc_dictionary_get_data(message, "request", &size), size > 0, size <= 8192 else {
                    return
                }
                let data = Data(bytes: bytes, count: size)
                let uid = xpc_connection_get_euid(peer)
                Task {
                    var status: IsolatedRuntimeStatus
                    do {
                        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                            Set(body.keys) == ["operation", "action"]
                        else { throw MicropodError.message("Unknown runtime request fields") }
                        let request = try JSONDecoder().decode(IsolatedRuntimeRequest.self, from: data)
                        if request.action == .session {
                            let identity = try IsolatedRuntimeIdentity.readRootOwned()
                            guard identity.ownerUID == uid,
                                let birth = try RuntimeProcessBirth.read(xpc_connection_get_pid(peer)), birth.uid == uid
                            else { throw MicropodError.message("The API client process identity changed") }
                            if IsolatedRuntimePolicy.publicProviderIdentifiers.contains(where: {
                                RuntimeCodeIdentity.verifyProcess(birth.pid, identifier: $0)
                            }),
                                try IsolatedRuntimeRigRegistration.read(identity: identity) == nil,
                                try IsolatedRuntimeSessionStore.hasExistingRig(ownerUID: uid)
                            {
                                throw MicropodError.message(
                                    "Update and enroll Cuttlefish before connecting the managed API; the current rig runtime was left unchanged"
                                )
                            }
                            var current = try await controller.submit(.init(action: .status), ownerUID: uid)
                            current.session = try IsolatedRuntimeSessionStore.issue(identity: identity, subject: birth)
                            status = current
                        } else {
                            status = try await controller.submit(request, ownerUID: uid)
                        }
                    } catch {
                        var refused = IsolatedRuntimeStatus(phase: "blocked", message: "Runtime request was refused")
                        refused.error = error.localizedDescription
                        status = refused
                    }
                    status.helperService = serviceName
                    guard let reply = xpc_dictionary_create_reply(message),
                        let output = try? JSONEncoder().encode(status)
                    else { return }
                    output.withUnsafeBytes { buffer in
                        xpc_dictionary_set_data(reply, "response", buffer.baseAddress!, buffer.count)
                    }
                    xpc_connection_send_message(peer, reply)
                }
            }
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(listener)
    }
}
