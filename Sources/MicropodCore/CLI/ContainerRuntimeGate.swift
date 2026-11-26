import Foundation

/// Asked before a `container` command spawns: is the Apple runtime it needs
/// known to be down?
///
/// A ``ContainerCLIClient`` given a gate (``ContainerCLIClient/gated(by:)``)
/// asks it first and, when the runtime is known to be down, throws
/// ``MicropodError/runtimeNotRunning`` without spawning anything. That error
/// is Connect `unavailable`, the class `RuntimeRouter` tolerates for an Apple
/// runtime that is not the default, so a server whose default runtime is
/// another engine stops paying one `container` child (and its `launchctl`
/// grandchild) per request to learn that Apple's runtime is down.
///
/// The client never asks the gate about commands that answer without the
/// apiserver or that start or stop it (``ContainerCommand/needsAPIServer``),
/// about executables other than `container` (launchctl, pkgutil, spctl,
/// codesign), on the isolated transport, or while
/// `MICROPOD_CONTAINER_CLI_PATH` names an explicit CLI: mock CLIs and
/// explicit installs keep spawning exactly as before.
public protocol ContainerRuntimeGate: Sendable {
    /// True when the runtime is known to be down. May wait for a probe whose
    /// answer is due; never waits for an answer that is still fresh.
    func runtimeIsDown() async -> Bool
    /// The same from what is already known, never waiting (a streaming
    /// command starts synchronously). Nothing fresh known means not down.
    func runtimeIsKnownDown() -> Bool
    /// A command that can change whether the runtime runs (`system start`,
    /// `system stop`) finished, whatever its outcome: forget what was known.
    func runtimeMayHaveChanged()
    /// The apiserver just answered another client of this process (the
    /// native backend's own XPC ping): it is up now, whatever an older
    /// observation said.
    func runtimeAnswered()
}

extension ContainerRuntimeGate {
    /// A gate that keeps no state of its own forgets what it knew.
    public func runtimeAnswered() { runtimeMayHaveChanged() }
}
