import Foundation

// Common surface for every speech-to-text backend we ship. Engines that don't
// support streaming (currently Whisper) throw `EngineError.streamingNotSupported`
// from makeStreamingSession(); the coordinator falls back to batch mode for those.
protocol TranscriptionEngine: AnyObject {
    var supportsStreaming: Bool { get }

    func warmup() async
    func transcribe(samples: [Float]) async throws -> String
    func makeStreamingSession() async throws -> any StreamingSession
}

// Events from a live dictation session, in arrival order:
//
// * `.partial(suffix:)` — verbatim new tokens since the last partial,
//   append-only with the model's native spacing.
// * `.endOfUtterance(rawAccumulated:)` — silence boundary or final flush. The
//   consumer subtracts the previous boundary's raw text to isolate the completed
//   utterance, runs PostProcessor, and reconciles the typed text in place.
//
// A single AsyncStream guarantees ordering between partial typing and EOU
// corrections.
enum StreamingEvent: Equatable {
    case partial(suffix: String)
    case endOfUtterance(rawAccumulated: String)
}

protocol StreamingSession: AnyObject {
    var events: AsyncStream<StreamingEvent> { get }
    func feed(samples: [Float]) async throws
    func finish() async throws
    func cancel() async
}
