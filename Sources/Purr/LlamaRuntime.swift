import Foundation
import os.log

// Owns the single app-wide Gemma `LlamaSession` and serialises every call into
// it. llama.cpp's context is not reentrant: a meeting summary and a voice edit
// decoding at the same time would corrupt the shared KV cache. Being an actor,
// each `generate` runs to completion before the next begins, off the main
// thread. The shared instance also keeps the ~2.5 GB model loaded at most once
// however many features touch it.
actor LlamaRuntime {
    static let shared = LlamaRuntime()

    private var session: LlamaSession?
    private let log = Logger(subsystem: "com.arunbrahma.hello", category: "llama-runtime")

    private init() {}

    // Honours Task cancellation between sampling steps - callers race this
    // against a timeout by cancelling the surrounding Task.
    func generate(prompt: String, parameters: LlamaSession.Parameters) throws -> String {
        try loadedSession().generate(prompt: prompt, parameters: parameters)
    }

    // Best-effort background load, a no-op once the session is resident. Used
    // to overlap a cold model load with other work (e.g. the voice-edit
    // recording window).
    func warmUp() {
        guard session == nil else { return }
        do {
            session = try makeSession()
            log.info("Llama runtime warmed up.")
        } catch {
            log.error("Llama warmup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MUST run before the on-disk weights are deleted, or the next generate()
    // reuses a session pointing at a removed file and leaks ~2.5 GB.
    func unload() {
        session = nil
        log.info("Llama runtime unloaded.")
    }

    private func loadedSession() throws -> LlamaSession {
        if let session { return session }
        let created = try makeSession()
        session = created
        return created
    }

    private func makeSession() throws -> LlamaSession {
        try LlamaSession(modelPath: LLMModelManager.localURL.path)
    }
}
