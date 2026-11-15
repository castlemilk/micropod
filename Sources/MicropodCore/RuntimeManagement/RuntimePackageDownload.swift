import Foundation

/// Disk-backed, bounded HTTPS download. Cookies, credentials and caches are
/// disabled; only Apple's GitHub release redirect chain is accepted.
final class RuntimePackageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var outcome: Result<URL, Error>?
    private var cancelled = false
    private var redirects = 0
    private let release: AppleRuntimeRelease
    private let destination: URL

    init(release: AppleRuntimeRelease, destination: URL) {
        self.release = release
        self.destination = destination
    }

    func download() async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.httpShouldSetCookies = false
                config.urlCredentialStorage = nil
                config.urlCache = nil
                config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                config.timeoutIntervalForRequest = 45
                config.timeoutIntervalForResource = 300
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                let task = session.downloadTask(with: release.packageURL)
                lock.lock()
                self.continuation = continuation
                self.session = session
                self.task = task
                let cancelled = self.cancelled
                lock.unlock()
                if cancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirects += 1
        let host = request.url?.host?.lowercased()
        let valid =
            request.url?.scheme == "https" && request.url?.user == nil && request.url?.password == nil
            && (request.url?.port == nil || request.url?.port == 443) && redirects <= 5
            && ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(
                host ?? "")
        if !valid { outcome = .failure(MicropodError.message("Runtime download redirect was refused")) }
        completionHandler(valid ? request : nil)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > release.packageBytes || totalBytesExpectedToWrite > release.packageBytes {
            outcome = .failure(MicropodError.message("Runtime download exceeded its verified size"))
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard outcome == nil else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                (try location.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(release.packageBytes)
            else { throw MicropodError.message("Runtime download was incomplete or refused") }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            outcome = .success(destination)
        } catch { outcome = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        self.task = nil
        self.session = nil
        let cancelled = cancelled
        lock.unlock()
        defer { session.invalidateAndCancel() }
        if cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let outcome {
            continuation?.resume(with: outcome)
        } else {
            continuation?.resume(throwing: error ?? MicropodError.message("Runtime download did not complete"))
        }
    }
}
