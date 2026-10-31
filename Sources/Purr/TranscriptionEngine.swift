import Foundation

// How long a transcription waits for a downloaded model to load. A first load
// also compiles the model for the Neural Engine, so this is generous. The
// Large Whisper models get longer (WhisperEngine.loadLimit).
let modelLoadTimeout: Duration = .seconds(120)

// Common surface for every speech-to-text backend we ship. Engines that don't
// support streaming (currently Whisper) throw `EngineError.streamingNotSupported`
// from makeStreamingSession(); the coordinator falls back to batch mode for those.
protocol TranscriptionEngine: AnyObject {
    var supportsStreaming: Bool { get }
    // False while transcribe() still has to load the model first.
    @MainActor var isLoaded: Bool { get }
    // True when that load starts with a download.
    @MainActor var needsDownload: Bool { get }
    // False while makeStreamingSession() still has to load its model first.
    @MainActor var isStreamingLoaded: Bool { get }

    func warmup() async
    // Loads the model for a transcription waiting on it. A downloaded model gets
    // modelLoadTimeout (longer for the Large Whisper models), then this throws
    // EngineError.modelLoadTimedOut and the load carries on, so a later call can
    // pick it up. Downloads have no limit.
    func load() async throws
    func transcribe(samples: [Float]) async throws -> String
    // Waits for its model under modelLoadTimeout too.
    func makeStreamingSession() async throws -> any StreamingSession
}

// Events from a live dictation session, in arrival order:
//
// * `.partial(suffix:)` — verbatim new tokens since the last partial,
//   append-only with the model's native spacing.
// * `.endOfUtterance(rawAccumulated:audio:)` - a pause boundary or the final
//   flush: the streaming model's text for the finished utterance (empty when
//   it heard speech but decoded none) plus that utterance's audio, so the
//   consumer can re-transcribe it with the batch model before pasting.
//
// A single AsyncStream guarantees ordering between partial typing and EOU
// corrections.
enum StreamingEvent: Equatable {
    case partial(suffix: String)
    case endOfUtterance(rawAccumulated: String, audio: [Float])
}

protocol StreamingSession: AnyObject {
    var events: AsyncStream<StreamingEvent> { get }
    func feed(samples: [Float]) async throws
    func finish() async throws
    func cancel() async
}
