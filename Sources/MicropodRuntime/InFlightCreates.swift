import MicropodCore

/// Native creates and clone cleanup must use the same process-wide per-ID
/// ownership. The public name remains for existing native callers and tests.
public typealias InFlightCreates = ContainerLifecycleClaims
