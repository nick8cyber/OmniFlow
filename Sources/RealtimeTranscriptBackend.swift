import Foundation

protocol RealtimeTranscriptBackend: AnyObject {
    /// Partial transcript updates, delivered on the main queue.
    var onPartialUpdate: ((String) -> Void)? { get set }

    func start() throws
    /// Append a chunk of 16-bit LE mono PCM at 24 kHz. Must silently ignore
    /// calls after cancel() and empty data.
    func appendPCM16(_ data: Data)
    func commitAndAwaitFinal() async throws -> String
    /// Close the socket and break any pending wait. Safe to call multiple times.
    func cancel()
}
