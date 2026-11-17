/// Shared state semantics for execution observers and restart safety.
public enum ContainerActivity {
    public static func isPending(_ state: String) -> Bool {
        ["starting", "creating", "created"].contains(state.lowercased())
    }

    public static func mayExecute(_ state: String) -> Bool {
        ["running", "stopping"].contains(state.lowercased()) || isPending(state)
    }

    /// Unknown state cannot establish that restarting the runtime is safe.
    public static func isTerminal(_ state: String) -> Bool {
        ["stopped", "exited", "dead"].contains(state.lowercased())
    }
}
