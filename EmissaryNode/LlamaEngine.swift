// LlamaEngine - the iPhone's own local language model, through llama.cpp (MIT, pinned commit in
// LLAMA_CPP_COMMIT). Adapted from llama.cpp's official examples/llama.swiftui/LibLlama.swift.
// Inference runs ON THIS DEVICE; nothing here touches the network.
import Foundation
import llama

enum LlamaEngineError: Error, LocalizedError {
    case modelLoadFailed(String), contextFailed, decodeFailed(Int32), notLoaded, templateFailed
    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let p): return "Could not load the model file at \(p)"
        case .contextFailed: return "Could not create the model context (not enough memory?)"
        case .decodeFailed(let c): return "The model failed while reading the prompt (code \(c))"
        case .notLoaded: return "No model is loaded"
        case .templateFailed: return "Could not format the prompt with the model's chat template"
        }
    }
}

struct GenerationResult {
    let text: String
    let promptTokens: Int
    let outputTokens: Int
    let promptSeconds: Double
    let generationSeconds: Double
    let truncatedPrompt: Bool
}

actor LlamaEngine {
    static let contextTokens: Int32 = 4096
    static let batchSize: Int32 = 512

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private(set) var modelDescription = ""
    private(set) var parameterCount: UInt64 = 0
    private var cancelled = false

    init() { llama_backend_init() }

    func load(path: String) throws {
        unload()
        var mparams = llama_model_default_params()
        #if targetEnvironment(simulator)
        mparams.n_gpu_layers = 0
        #endif
        guard let m = llama_model_load_from_file(path, mparams) else { throw LlamaEngineError.modelLoadFailed(path) }
        let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(Self.contextTokens)
        cparams.n_batch = UInt32(Self.batchSize)
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            throw LlamaEngineError.contextFailed
        }
        model = m; context = c; vocab = llama_model_get_vocab(m)
        parameterCount = llama_model_n_params(m)
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_model_desc(m, &buf, 256)
        modelDescription = n > 0 ? String(cString: buf) : "unknown"
    }

    func unload() {
        if let c = context { llama_free(c) }
        if let m = model { llama_model_free(m) }
        context = nil; model = nil; vocab = nil
    }

    var isLoaded: Bool { context != nil }

    func cancel() { cancelled = true }

    /// Formats `userText` with the model's own chat template (falls back to plain text).
    private func applyTemplate(_ userText: String) -> String {
        guard let m = model, let tmpl = llama_model_chat_template(m, nil) else { return userText }
        let role = strdup("user"), content = strdup(userText)
        defer { free(role); free(content) }
        var msg = llama_chat_message(role: role, content: content)
        var size = Int32(userText.utf8.count * 2 + 512)
        for _ in 0..<2 {
            var out = [CChar](repeating: 0, count: Int(size))
            let n = llama_chat_apply_template(tmpl, &msg, 1, true, &out, size)
            if n < 0 { return userText }
            if n <= size { return String(cString: out) }
            size = n + 1
        }
        return userText
    }

    private func tokenize(_ text: String) -> [llama_token] {
        guard let v = vocab else { return [] }
        let cap = Int32(text.utf8.count + 16)
        var tokens = [llama_token](repeating: 0, count: Int(cap))
        var n = llama_tokenize(v, text, Int32(text.utf8.count), &tokens, cap, false, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(v, text, Int32(text.utf8.count), &tokens, -n, false, true)
        }
        return Array(tokens.prefix(Int(max(0, n))))
    }

    private func piece(_ token: llama_token) -> [CChar] {
        guard let v = vocab else { return [] }
        var buf = [CChar](repeating: 0, count: 32)
        var n = llama_token_to_piece(v, token, &buf, 32, 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(v, token, &buf, -n, 0, false)
        }
        return Array(buf.prefix(Int(max(0, n))))
    }

    /// Runs the model on this device. The prompt is trimmed (head + tail kept) if it does not fit.
    func generate(prompt rawPrompt: String, maxOutputTokens: Int, deadline: Date) throws -> GenerationResult {
        guard let ctx = context, let v = vocab else { throw LlamaEngineError.notLoaded }
        cancelled = false
        llama_memory_clear(llama_get_memory(ctx), true)

        let budget = Int(Self.contextTokens) - maxOutputTokens - 8
        var tokens = tokenize(applyTemplate(rawPrompt))
        var truncated = false
        if tokens.count > budget {
            // Keep the instructions at the start and the question at the end.
            truncated = true
            let marker = "\n\n[... part of the material was left out to fit this device ...]\n\n"
            let chars = Array(rawPrompt)
            var keep = max(400, Int(Double(chars.count) * Double(budget) / Double(tokens.count)) - marker.count)
            while true {
                let head = String(chars.prefix(keep * 6 / 10)), tail = String(chars.suffix(keep * 4 / 10))
                tokens = tokenize(applyTemplate(head + marker + tail))
                if tokens.count <= budget || keep <= 400 { break }
                keep = keep * 85 / 100
            }
            if tokens.count > budget { tokens = Array(tokens.suffix(budget)) }
        }

        let t0 = Date()
        var batch = llama_batch_init(Self.batchSize, 0, 1)
        defer { llama_batch_free(batch) }
        var pos: Int32 = 0
        var i = 0
        while i < tokens.count {
            batch.n_tokens = 0
            let end = min(i + Int(Self.batchSize), tokens.count)
            for j in i..<end {
                let k = Int(batch.n_tokens)
                batch.token[k] = tokens[j]
                batch.pos[k] = pos
                batch.n_seq_id[k] = 1
                batch.seq_id[k]![0] = 0
                batch.logits[k] = (j == tokens.count - 1) ? 1 : 0
                batch.n_tokens += 1
                pos += 1
            }
            let rc = llama_decode(ctx, batch)
            if rc != 0 { throw LlamaEngineError.decodeFailed(rc) }
            i = end
            if cancelled || Date() > deadline { break }
        }
        let promptSeconds = Date().timeIntervalSince(t0)

        let sparams = llama_sampler_chain_default_params()
        let sampler = llama_sampler_chain_init(sparams)
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.3))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))

        let t1 = Date()
        var out: [CChar] = []
        var produced = 0
        while produced < maxOutputTokens && !cancelled && Date() < deadline {
            let tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(v, tok) { break }
            out.append(contentsOf: piece(tok))
            produced += 1
            batch.n_tokens = 1
            batch.token[0] = tok
            batch.pos[0] = pos
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            pos += 1
            if llama_decode(ctx, batch) != 0 { break }
        }
        let text = String(decoding: out.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return GenerationResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                promptTokens: tokens.count, outputTokens: produced,
                                promptSeconds: promptSeconds, generationSeconds: Date().timeIntervalSince(t1),
                                truncatedPrompt: truncated)
    }
}
