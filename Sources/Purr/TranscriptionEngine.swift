import Foundation

// Common surface for every speech-to-text backend we ship: batch
// `transcribe(samples:)` and streaming `makeStreamingSession()`.
//
// Engines that don't support streaming (currently Whisper) throw
// `EngineError.streamingNotSupported`; the coordinator transparently falls
// back to batch mode for those.
protocol TranscriptionEngine: AnyObject {
    var supportsStreaming: Bool { get }

    func warmup() async
    func transcribe(samples: [Float]) async throws -> String
    func makeStreamingSession() async throws -> any StreamingSession
}

// Events from a live dictation session, in arrival order:
//
// * `.partial(text:)` — full text of the current utterance, with native
//   spacing. Consumers can distinguish new words from recognizer revisions.
// * `.endOfUtterance(rawAccumulated:)` — silence boundary or final
//   flush. The consumer subtracts the previous boundary's raw text to
//   isolate the just-completed utterance, runs PostProcessor, and
//   reconciles the typed text in place.
//
// Single AsyncStream guarantees ordering between partial typing and
// EOU corrections.
enum StreamingEvent: Equatable {
    case partial(text: String)
    case endOfUtterance(rawAccumulated: String)
}

protocol StreamingSession: AnyObject {
    var events: AsyncStream<StreamingEvent> { get }
    func feed(samples: [Float]) async throws
    func finish() async throws
    func cancel() async
}
