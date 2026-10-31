import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLXQwen3TTS
import MLXToolKit

// qwen3-tts-clone (the Base checkpoint): audio.speak in a voice cloned from `voice_ref` (Audio §3.2). With
// `voice_ref_text`, the reference's transcript, the package clones in context (ICL); without it, from the speaker
// embedding alone (x-vector), which is quicker and less faithful.
//
// The reference's features (the speaker embedding, its codec codes) are what the package can cache, under a key the
// worker gives it (mlx-qwen3-tts-swift 0.7.0, AB-A-0233). MES Base §13 rule 6: a reference that is an asset is keyed by
// its asset id, kept while the asset lives, and evicted when Gaea says it's gone (`onAssetRemoved`); any other
// reference is keyed by the job, so the job's pieces share it, and evicted when the job ends (rules 1–4).

public let cloneModelID = "qwen3-tts-clone"
public let maxVoiceRefSeconds = 30.0

/// A reference clip as the package takes it: mono 16-bit PCM WAV, at most `maxVoiceRefSeconds`, with the warnings for
/// what was changed. Gaea sends every audio input as a canonical 16-bit WAV (a 44-byte header), at its own rate and
/// channels.
public func reference(_ wav: Data) throws -> (wav: Data, seconds: Double, warnings: [Warning]) {
    guard wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8), wav[wav.startIndex + 8..<wav.startIndex + 12] == Data("WAVE".utf8),
          wav[wav.startIndex + 36..<wav.startIndex + 40] == Data("data".utf8) else {
        throw GPPError(.invalidRequest, "voice_ref isn't a 16-bit PCM WAV.", detail: ["param": "voice_ref"])
    }
    func u16(_ at: Int) -> Int { Int(wav[wav.startIndex + at]) | Int(wav[wav.startIndex + at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    let channels = u16(22), rate = u32(24), bits = u16(34)
    guard u16(20) == 1, bits == 16, (1...2).contains(channels), rate > 0 else {
        throw GPPError(.invalidRequest, "voice_ref isn't a mono or stereo 16-bit PCM WAV.", detail: ["param": "voice_ref"])
    }
    var pcm = wav.subdata(in: (wav.startIndex + 44)..<wav.endIndex)
    var warnings: [Warning] = []
    var samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    if channels == 2 {
        samples = stride(from: 0, to: samples.count - 1, by: 2).map { Int16((Int(samples[$0]) + Int(samples[$0 + 1])) / 2) }
        warnings.append(Warning(code: "audio_downmixed", message: "The reference was mixed down to mono.", param: "voice_ref"))
    }
    let most = Int(maxVoiceRefSeconds) * rate
    if samples.count > most {
        samples = Array(samples[..<most])
        warnings.append(Warning(code: "voice_ref_trimmed", message: "The reference was trimmed to its first \(Int(maxVoiceRefSeconds)) s.",
                                param: "voice_ref"))
    }
    guard samples.count >= rate / 2 else {
        throw GPPError(.invalidRequest, "voice_ref is shorter than half a second.", detail: ["param": "voice_ref"])
    }
    if channels == 1, warnings.isEmpty { return (wav, Double(samples.count) / Double(rate), []) }
    pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    var out = Data(capacity: 44 + pcm.count)
    func w32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func w16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    out.append(contentsOf: Array("RIFF".utf8)); w32(UInt32(36 + pcm.count)); out.append(contentsOf: Array("WAVE".utf8))
    out.append(contentsOf: Array("fmt ".utf8)); w32(16); w16(1); w16(1); w32(UInt32(rate)); w32(UInt32(rate * 2)); w16(2); w16(16)
    out.append(contentsOf: Array("data".utf8)); w32(UInt32(pcm.count))
    out.append(pcm)
    return (out, Double(samples.count) / Double(rate), warnings)
}

/// What a clone job asks of the package, validated.
public struct ClonePlan: Sendable {
    public var pieces: [Piece]
    public var reference: Data
    public var transcript: String?
    public var language: String
    public var seed: UInt64
    /// The package's cache key: the asset id, else one for this job alone.
    public var cacheKey: String
    /// Whether the key is the job's own, to evict when it ends.
    public var jobScoped: Bool
    public var warnings: [Warning]
    public var effective: [String: JSONValue]
}

public func clonePlan(text: String?, reference wav: Data, transcript: String?, language tag: String?, asset: String?,
                      job: String, seed: UInt64) throws -> ClonePlan {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw GPPError(.invalidRequest, "audio.speak needs text.", detail: ["param": "text"])
    }
    guard text.count <= maxTextChars else {
        throw GPPError(.invalidRequest, "Qwen3-TTS speaks at most \(maxTextChars) characters at a time.", detail: ["param": "text"])
    }
    let (clip, seconds, warnings) = try reference(wav)
    let lang = try language(tag) ?? "en"
    let said = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
    let script = said?.isEmpty == false ? said : nil
    let effective: [String: JSONValue] = [
        "language": .string(lang), "seed": .int(Int64(seed)),
        "x-qwen3.clone": .string(script == nil ? "xvector" : "icl"), "x-qwen3.voice_ref_s": .double((seconds * 100).rounded() / 100),
    ]
    return ClonePlan(pieces: try plan(text), reference: clip, transcript: script, language: lang, seed: seed,
                     cacheKey: asset ?? "job:\(job)", jobScoped: asset == nil, warnings: warnings, effective: effective)
}

/// The engine request for one piece of a clone plan.
public func request(_ plan: ClonePlan, words: String) -> TTSRequest {
    TTSRequest(text: words, voice: VoiceSelector(.referenceAudio(Audio(format: .wav, data: plan.reference, sampleRate: nil, channels: 1))),
               referenceTranscript: plan.transcript,
               metaData: ["seed": .int(Int(plan.seed)), "language": .string(plan.language), "voiceCacheKey": .string(plan.cacheKey)])
}

/// The package's eviction call for cache keys (mlx-qwen3-tts-swift 0.7.0): empty text, no synthesis.
public func eviction(_ keys: [String]) -> TTSRequest {
    TTSRequest(text: "", metaData: ["evictVoiceCacheKeys": .array(keys.map { .string($0) })])
}

let cloneOperation = EngineOperation("audio.speak") { job, session in
    guard let referenceURL = job.input("voice_ref") else {
        throw GPPError(.invalidRequest, "qwen3-tts-clone speaks only in a cloned voice: send voice_ref.", detail: ["param": "voice_ref"])
    }
    let plan = try clonePlan(text: try job.text("text"), reference: try Data(contentsOf: referenceURL), transcript: try job.text("voice_ref_text"),
                             language: job.param("language")?.stringValue, asset: job.asset("voice_ref"), job: job.job, seed: seed(job))
    let send: (TTSRequest) async throws -> any CapabilityResponse = { try await session.run($0 as! any WireRequest) }
    let pcm: Data
    do {
        pcm = try await speak(plan.pieces) { words in try await draw(request(plan, words: words), seed: plan.seed, run: send) }
    } catch {
        if plan.jobScoped { _ = try? await send(eviction([plan.cacheKey])) }
        throw error
    }
    // A reference that isn't an asset lives no longer than its job (MES Base §13 rules 1–4).
    if plan.jobScoped { _ = try await send(eviction([plan.cacheKey])) }
    let url = session.outputDir.appending(path: "audio-0.wav")
    try wav16(pcm).write(to: url)
    return RunResult(outputs: [.file("audio", url, mediaType: "audio/wav")], effective: plan.effective, warnings: plan.warnings)
}

let cloneModel = ModelDefinition.engine(Qwen3TTSPackage.self, id: cloneModelID, title: "Qwen3-TTS voice cloning",
                                        lanes: lanes(.base), operations: [cloneOperation])

let cloneOffer = PluginManifest.Offer(
    operation: "audio.speak", profile: "audio",
    model: [
        "id": .string(cloneModelID), "title": "Qwen3-TTS voice cloning",
        "license": license, "memory_class": "medium", "speed_class": "standard", "quality_tiers": ["standard", "best"],
        "notes": "Speaks in the voice of a reference clip of 3 to 30 s, in ten languages. Give the clip's transcript (voice_ref_text) for a much closer match. Keep the clip as an asset to reuse it quickly. [pause 1s] adds silence.",
        "supports": [
            "voice_ref": true, "voice_ref_text": "optional", "languages": languageTags, "cues": ["pause"],
            "sample_rate": .int(Int64(sampleRate)), "channels": 1,
        ],
        "limits": ["max_text_chars": .int(Int64(maxTextChars)), "max_voice_ref_s": .double(maxVoiceRefSeconds)],
    ])

/// Gaea says an asset is gone: the clone model forgets the reference it cached under it, if it's loaded.
let forgetAsset: @Sendable (String, ResidentEngine) async -> Void = { asset, resident in
    _ = try? await resident.run(eviction([asset]), model: cloneModelID)
}
