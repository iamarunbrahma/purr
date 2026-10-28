import Foundation
import llama
import os.log

// Thin Swift wrapper around llama.cpp's C API. Owns a single
// `llama_model` + `llama_context` pair and exposes one synchronous
// `generate` entry point.
//
// All llama_* calls in this file are intentionally synchronous and
// CPU/GPU heavy - callers must dispatch via `Task.detached` (or another
// background executor) so the main actor never blocks on a decode.
//
// `generate(prompt:)` is safe to call repeatedly on the same instance.
// `deinit` frees the context and model but deliberately does NOT call
// llama_backend_free - other instances may still be alive in the same
// process, and backend_init is idempotent anyway.
final class LlamaSession {
    enum LlamaError: LocalizedError {
        case modelLoadFailed(path: String)
        case contextInitFailed
        case tokenizeFailed
        case decodeFailed(code: Int32)
        // `budget` is how many prompt tokens fit beside the requested response.
        case promptTooLong(tokens: Int, budget: Int)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let path):
                return "Could not load Gemma GGUF model at \(path)."
            case .contextInitFailed:
                return "Could not create llama.cpp inference context."
            case .tokenizeFailed:
                return "Failed to tokenize prompt."
            case .decodeFailed(let code):
                return "llama_decode failed (code \(code))."
            case .promptTooLong(let tokens, let budget):
                return "Prompt is \(tokens) tokens; at most \(budget) fit in the context window."
            case .cancelled:
                return "Generation was cancelled."
            }
        }
    }

    struct Parameters {
        var maxTokens: Int = 1000
        var temperature: Float = 0.3
        var repetitionPenalty: Float = 1.1
        var repetitionContextSize: Int32 = 64
        var nBatch: UInt32 = 512
    }

    private let log = Logger(subsystem: "com.arunbrahma.hello", category: "llama")
    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let context: OpaquePointer
    private let contextSize: Int

    init(modelPath: String) throws {
        // Must be set before ggml creates the Metal device during the model load
        // below. Residency sets keep GPU memory wired for a ~3-minute window; if
        // the app quits inside it with model buffers still live, ggml-metal's
        // teardown asserts `[rsets->data count] == 0` and SIGABRTs during atexit
        // cleanup. Skipping them only makes GPU memory evictable after ~1 s idle,
        // negligible here. Upstream workaround: ggml-org/llama.cpp#11427.
        setenv("GGML_METAL_NO_RESIDENCY", "1", 1)
        llama_backend_init()

        var modelParams = llama_model_default_params()
        // Offload every block to Metal: Gemma 4 E2B at Q4_0 is ~3.3 GB, which
        // fits the unified-memory GPU partition on every Mac we support (8 GB+).
        modelParams.n_gpu_layers = 999
        modelParams.use_mmap = true

        guard let loaded = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.modelLoadFailed(path: modelPath)
        }
        self.model = loaded

        guard let v = llama_model_get_vocab(loaded) else {
            llama_model_free(loaded)
            throw LlamaError.modelLoadFailed(path: modelPath)
        }
        self.vocab = v

        var ctxParams = llama_context_default_params()
        // Covers a 24K-char transcript head/tail window (~6K prompt tokens of
        // English) plus a 1000-token response. Gemma 4's sliding-window layers
        // keep the KV cache small: 8192 costs ~80 MB more than 4096 did.
        ctxParams.n_ctx = 8192
        ctxParams.n_batch = 512
        // Leave two cores for audio and UI. The cap of 8 mirrors the upstream
        // Swift example - more threads hurt than help on M-series.
        let threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        ctxParams.n_threads = Int32(threads)
        ctxParams.n_threads_batch = Int32(threads)

        guard let c = llama_init_from_model(loaded, ctxParams) else {
            llama_model_free(loaded)
            throw LlamaError.contextInitFailed
        }
        self.context = c
        self.contextSize = Int(llama_n_ctx(c))

        log.info(
            "Llama model loaded: \(modelPath, privacy: .public) (n_ctx=\(ctxParams.n_ctx, privacy: .public), threads=\(threads, privacy: .public))"
        )
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    // Honours Task cancellation between sampling iterations, so the watchdog in
    // MeetingSummarizer can abort a stuck run by cancelling the surrounding Task.
    func generate(prompt: String, parameters: Parameters = .init()) throws -> String {
        // 1. Tokenize. The first llama_tokenize call passes a nil buffer to
        //    learn the token count (returned negative); the second fills it.
        let promptBytes = prompt.utf8.count
        var probe: [llama_token] = []
        let probedNeg = prompt.withCString { cStr in
            llama_tokenize(vocab, cStr, Int32(promptBytes), &probe, 0, true, true)
        }
        let needed = Int(-probedNeg)
        guard needed > 0 else { throw LlamaError.tokenizeFailed }

        var tokens = [llama_token](repeating: 0, count: needed)
        let actual = prompt.withCString { cStr in
            tokens.withUnsafeMutableBufferPointer { buf in
                llama_tokenize(
                    vocab, cStr, Int32(promptBytes), buf.baseAddress, Int32(buf.count), true, true)
            }
        }
        guard actual > 0 else { throw LlamaError.tokenizeFailed }
        tokens = Array(tokens.prefix(Int(actual)))

        // Past the window, llama_decode fails with no free KV slot - in the
        // prompt, or worse, partway through the response. Refuse up front with
        // the measured size so the caller can shorten its input and retry.
        let budget = contextSize - parameters.maxTokens
        guard tokens.count <= budget else {
            throw LlamaError.promptTooLong(tokens: tokens.count, budget: budget)
        }

        // 2. Sampler chain, mirroring llama.cpp's chat examples: penalties
        //    first so they apply before temperature warps the distribution.
        let chainParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(chainParams) else {
            throw LlamaError.contextInitFailed
        }
        defer { llama_sampler_free(sampler) }

        llama_sampler_chain_add(
            sampler,
            llama_sampler_init_penalties(
                Int32(parameters.repetitionContextSize),
                parameters.repetitionPenalty,
                0.0,
                0.0
            )
        )
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(parameters.temperature))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))

        // 3. Decode the prompt. n_seq_max=1 - only ever one sequence at a time.
        var batch = llama_batch_init(Int32(parameters.nBatch), 0, 1)
        defer { llama_batch_free(batch) }

        // Drop KV-cache state left by a previous generate() on this reused
        // session: re-decoding overlapping positions without a clear stacks
        // duplicate cells, making the model attend to stale context.
        llama_memory_clear(llama_get_memory(context), true)

        // A single llama_batch holds at most n_batch tokens, so a longer prompt
        // has to be decoded in chunks. Only the very last token gets the logits
        // bit, so the model yields a next-token distribution.
        let chunkSize = Int(parameters.nBatch)
        var offset = 0
        while offset < tokens.count {
            let end = min(offset + chunkSize, tokens.count)
            llamaBatchClear(&batch)
            for i in offset..<end {
                llamaBatchAdd(&batch, tokens[i], Int32(i), [0], i == tokens.count - 1)
            }
            let promptRC = llama_decode(context, batch)
            if promptRC != 0 { throw LlamaError.decodeFailed(code: promptRC) }
            offset = end
        }

        // 4. Sample a token, keep its bytes, feed it back as a single-token
        //    batch. Stops on EOG (Gemma 4 emits <turn|>), the cap, or
        //    cancellation. Bytes rather than Strings accumulate because a
        //    character outside the vocabulary arrives as several byte tokens,
        //    each one an incomplete UTF-8 sequence on its own.
        var output: [UInt8] = []
        var pos = Int32(tokens.count)
        let maxTokens = parameters.maxTokens

        for _ in 0..<maxTokens {
            if Task.isCancelled { throw LlamaError.cancelled }

            let newToken = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, newToken) { break }

            output.append(contentsOf: Self.tokenBytes(token: newToken, vocab: vocab))

            llamaBatchClear(&batch)
            llamaBatchAdd(&batch, newToken, pos, [0], true)
            pos += 1

            let stepRC = llama_decode(context, batch)
            if stepRC != 0 { throw LlamaError.decodeFailed(code: stepRC) }
        }

        return String(decoding: output, as: UTF8.self)
    }

    // token_to_piece may need more than 16 bytes for a long piece; a negative
    // count is the size to retry with. A piece can be part of a multi-byte
    // character, so it stays raw bytes until the whole response is decoded.
    private static func tokenBytes(token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 16)
        var written = buf.withUnsafeMutableBufferPointer {
            llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false)
        }
        if written < 0 {
            let needed = Int(-written)
            buf = [CChar](repeating: 0, count: needed)
            written = buf.withUnsafeMutableBufferPointer {
                llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false)
            }
        }
        guard written > 0 else { return [] }
        return buf.prefix(Int(written)).map { UInt8(bitPattern: $0) }
    }
}

// Mirrors llama.cpp's official Swift example: the C `llama_batch` exposes
// parallel arrays we populate by hand, as the public API has no append.
private func llamaBatchClear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

private func llamaBatchAdd(
    _ batch: inout llama_batch,
    _ id: llama_token,
    _ pos: llama_pos,
    _ seqIDs: [llama_seq_id],
    _ logits: Bool
) {
    let i = Int(batch.n_tokens)
    batch.token[i] = id
    batch.pos[i] = pos
    batch.n_seq_id[i] = Int32(seqIDs.count)
    for (offset, sid) in seqIDs.enumerated() {
        batch.seq_id[i]![offset] = sid
    }
    batch.logits[i] = logits ? 1 : 0
    batch.n_tokens += 1
}
