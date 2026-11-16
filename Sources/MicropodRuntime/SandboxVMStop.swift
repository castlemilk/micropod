/// One stop intent per VM. Concurrent reaping/deletion joins the same result;
/// a refused or ambiguous stop never becomes an automatic mutation replay.
actor SandboxVMStop {
    private var operation: Task<Void, Error>?

    func run(_ stop: @escaping @Sendable () async throws -> Void) async throws {
        if operation == nil { operation = Task { try await stop() } }
        try await operation!.value
    }
}
