import Darwin
import Foundation
import MachO
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
        guard geteuid() == 0, CommandLine.arguments.count == 1 else {
            fputs("Micropod's runtime helper must be started by macOS Service Management.\n", stderr)
            exit(1)
        }
        do {
            try RootRuntimeStorage.prepareRoot()
            let fd = open(
                IsolatedRuntimePolicy.root.appendingPathComponent("host.lock").path,
                O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw MicropodError.message("Another runtime helper owns the state")
            }
            var count: UInt32 = 4096
            var path = [CChar](repeating: 0, count: Int(count))
            guard _NSGetExecutablePath(&path, &count) == 0 else {
                throw MicropodError.message("The runtime helper executable path is unavailable")
            }
            let executable = URL(
                fileURLWithPath: String(
                    decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            ).resolvingSymlinksInPath()
            try RuntimeCodeIdentity.verifyExecutable(executable, identifier: IsolatedRuntimePolicy.helperIdentifier)
            let controller = IsolatedRuntimeHostController(
                driver: NativeIsolatedRuntimeHostDriver(executable: executable))
            let server = RuntimeHostServer(controller: controller)
            try server.start()
            let rig = IsolatedRuntimeRigServer(controller: controller)
            try rig.start()
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            withExtendedLifetime(rig) {}
        } catch {
            fputs("Runtime helper could not start: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
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

private final class RuntimeHostServer: @unchecked Sendable {
    private let controller: IsolatedRuntimeHostController
    private nonisolated(unsafe) var listener: xpc_connection_t?
    init(controller: IsolatedRuntimeHostController) { self.controller = controller }
    func start() throws {
        let listener = xpc_connection_create_mach_service(
            IsolatedRuntimePolicy.serviceName, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
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
                    let status: IsolatedRuntimeStatus
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
