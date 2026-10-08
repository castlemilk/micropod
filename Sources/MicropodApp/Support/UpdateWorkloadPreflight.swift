import Foundation
import MicropodCore

/// A conservative observation, never an admission grant. Callers still need
/// to hold every workload admission path through installation and relaunch.
enum UpdateWorkloadPreflight {
    static func hasNoObservedWork(states: [String]) -> Bool {
        // Created containers may be about to start. Unknown and transitional
        // states must not make a disappearing API/shim look safe to restart.
        states.allSatisfy { ["stopped", "exited"].contains($0) }
    }

    static func hasNoObservedWork(data: Data, response: URLResponse) -> Bool {
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            data.count <= 1024 * 1024,
            let list = try? Micropod_V1_ListContainersResponse(jsonUTF8Data: data)
        else { return false }
        return hasNoObservedWork(states: list.containers.map(\.state))
    }

    static func readLocalAPI(session suppliedSession: URLSession? = nil) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        let session =
            suppliedSession
            ?? URLSession(
                configuration: configuration, delegate: UpdatePreflightRedirectPolicy(), delegateQueue: nil)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:45454/api/micropod.v1.ContainerService/ListContainers")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 5
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.url == request.url else { return false }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1024 * 1024 else { return false }
                try Task.checkCancellation()
                data.append(byte)
            }
            guard !Task.isCancelled else { return false }
            return hasNoObservedWork(data: data, response: response)
        } catch {
            // Connection loss, timeout and cancellation are uncertainty.
            return false
        }
    }
}

private final class UpdatePreflightRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
