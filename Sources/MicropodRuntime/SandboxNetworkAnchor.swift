import Foundation
import MicropodCore
import Synchronization
import XPC
import vmnet

/// Materialize the bridge before VZ attaches, then hold it until the VM stops.
/// A network ref alone does not pin its bridge across attachment transitions.
final class SandboxNetworkAnchor: @unchecked Sendable {
    private let interface: interface_ref
    private let queue = DispatchQueue(label: "micropod.sandbox.network-anchor")
    private let confirmation = SandboxNetworkStopConfirmation()
    private let startup = SandboxNetworkStartConfirmation()

    init(network: vmnet_network_ref) throws {
        let startup = self.startup
        let parameters = xpc_dictionary_create(nil, nil, 0)
        // This attachment pins the bridge and never consumes frames. Match the
        // virtio peer so this idle member does not limit bridge segmentation.
        xpc_dictionary_set_bool(parameters, vmnet_enable_tso_key, true)
        xpc_dictionary_set_bool(parameters, vmnet_enable_checksum_offload_key, true)
        let callbackQueue = queue
        guard
            let interface = vmnet_interface_start_with_network(
                network, parameters, queue,
                { status, _ in
                    withExtendedLifetime(callbackQueue) {}
                    startup.complete(status)
                })
        else {
            throw MicropodError.message("sandbox network anchor could not start")
        }
        self.interface = interface
    }

    /// The session must own this anchor before waiting. An uncertain start
    /// can still allocate a bridge and must retain an observable stop handle.
    func waitUntilReady() throws {
        try startup.wait()
    }

    /// Never replay an ambiguous stop. A late callback can settle it; callers
    /// retain the owning session until confirmation rather than claim cleanup.
    func stop() throws {
        try confirmation.stop { complete in
            let queue = self.queue
            return vmnet_stop_interface(interface, queue) { result in
                withExtendedLifetime(queue) {}
                complete(result)
            }
        }
    }

    deinit { try? stop() }
}

final class SandboxNetworkStartConfirmation: @unchecked Sendable {
    private let result = Mutex<vmnet_return_t?>(nil)
    private let finished = DispatchGroup()
    private let timeout: DispatchTimeInterval

    init(timeout: DispatchTimeInterval = .seconds(10)) {
        self.timeout = timeout
        finished.enter()
    }

    func complete(_ status: vmnet_return_t) {
        let first = result.withLock { result in
            guard result == nil else { return false }
            result = status
            return true
        }
        if first { finished.leave() }
    }

    func wait() throws {
        guard finished.wait(timeout: .now() + timeout) == .success,
            result.withLock({ $0 }) == .VMNET_SUCCESS
        else { throw MicropodError.message("sandbox network anchor start was not confirmed") }
    }
}

/// Every concurrent waiter observes the same callback. A late confirmation
/// can settle a timeout without issuing a second vmnet stop.
final class SandboxNetworkStopConfirmation: @unchecked Sendable {
    private let value = Mutex<(issued: Bool, result: vmnet_return_t?)>((false, nil))
    private let finished = DispatchGroup()
    private let timeout: DispatchTimeInterval

    init(timeout: DispatchTimeInterval = .seconds(10)) {
        self.timeout = timeout
        finished.enter()
    }

    func stop(_ issue: (@escaping @Sendable (vmnet_return_t) -> Void) -> vmnet_return_t) throws {
        let claimed = value.withLock { state in
            if state.issued { return false }
            state.issued = true
            return true
        }
        if claimed {
            let status = issue { self.complete($0) }
            if status != .VMNET_SUCCESS { complete(status) }
        }
        guard finished.wait(timeout: .now() + timeout) == .success,
            value.withLock({ $0.result }) == .VMNET_SUCCESS
        else { throw MicropodError.message("sandbox network anchor stop is unconfirmed") }
    }

    private func complete(_ result: vmnet_return_t) {
        let first = value.withLock { state in
            guard state.result == nil else { return false }
            state.result = result
            return true
        }
        if first { finished.leave() }
    }
}
