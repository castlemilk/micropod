import Foundation

/// Packs a stream of whole wire frames into fewer, larger writes.
///
/// The API's streaming writer awaits `contentProcessed` for every element it
/// sends, so a log flood that yields one Connect envelope per line pays one
/// awaited socket write per line. `coalesce` sits between the envelope
/// producer and that writer: it concatenates whole frames until a batch
/// reaches `maxBytes`, or `maxDelay` has passed since the batch's first
/// frame, or the source ends, and then yields the batch as one element.
///
/// Frames are never split or reordered. A frame that alone exceeds
/// `maxBytes` travels as its own element. The wire bytes are the exact
/// concatenation of the source's frames, so a Connect reader still sees one
/// envelope (one message) per source frame.
public enum StreamFrameCoalescer {
    public static let defaultMaxBytes = 64 * 1024
    public static let defaultMaxDelay: Duration = .milliseconds(10)

    public static func coalesce(
        _ source: AsyncStream<Data>,
        maxBytes: Int = defaultMaxBytes,
        maxDelay: Duration = defaultMaxDelay
    ) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let batch = Batch(continuation: continuation, maxBytes: maxBytes)
            let pump = Task {
                for await frame in source {
                    if let generation = batch.append(frame) {
                        // A new batch started: bound how long it can wait for
                        // company. A flush by size or by the source's end
                        // bumps the generation, so a late timer is a no-op.
                        Task {
                            try? await Task.sleep(for: maxDelay)
                            batch.flush(generation: generation)
                        }
                    }
                }
                batch.flush(generation: nil)
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    /// The pending batch. Every yield happens under the lock, so batches
    /// leave in the order their frames arrived even when a timer and the
    /// pump race to flush.
    private final class Batch: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AsyncStream<Data>.Continuation
        private let maxBytes: Int
        private var buffer = Data()
        private var generation = 0

        init(continuation: AsyncStream<Data>.Continuation, maxBytes: Int) {
            self.continuation = continuation
            self.maxBytes = maxBytes
        }

        /// Adds a frame; returns the batch generation when this frame opened
        /// a new batch (the caller then arms that batch's timer).
        func append(_ frame: Data) -> Int? {
            lock.withLock {
                if !buffer.isEmpty, buffer.count + frame.count > maxBytes {
                    emit()
                }
                let opened = buffer.isEmpty
                buffer.append(frame)
                if buffer.count >= maxBytes {
                    emit()
                    return nil
                }
                return opened ? generation : nil
            }
        }

        /// Flushes the pending batch; with a generation, only if that batch
        /// is still the pending one.
        func flush(generation expected: Int?) {
            lock.withLock {
                guard !buffer.isEmpty, expected == nil || expected == generation else { return }
                emit()
            }
        }

        private func emit() {
            continuation.yield(buffer)
            buffer = Data()
            generation += 1
        }
    }
}
