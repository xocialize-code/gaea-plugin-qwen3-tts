import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLX
import MLXQwen3TTS
import MLXToolKit

// gaea-plugin-qwen3-tts: Alibaba's Qwen3-TTS 12 Hz (Apache-2.0 weights; the MLX port, mlx-qwen3-tts-swift, is
// Apache-2.0) on MES Audio 0.1 (media-engine-spec v0.7.0, Gaea AB-T-0396). Three 1.7B checkpoints, each a model:
//
// - qwen3-tts (CustomVoice): audio.speak with the nine preset speakers, an emotion label or a delivery description,
//   ten languages. Without a voice it picks the speaker native to the language.
// - qwen3-tts-clone (Base): audio.speak in a voice cloned from voice_ref, keyed by its MES asset (Clone.swift).
// - qwen3-tts-design (VoiceDesign): audio.design_voice. A description of a voice in words, read back as `count`
//   samples of one sentence at seed + i (Audio §3.1). The sample is the voice: a client clones it with voice_ref.
//
// Each has three lanes, the talker's quant: int8 (the default), bf16 and int4, with the package's footprints. The
// talker samples from MLX's random state, so the worker seeds it, and passes the seed to the package, before every
// generation: the same request gives the same WAV, here and in qwen3-inproc. `[pause Ns]` is silence between pieces,
// the one cue the offers list.

public let speakModelID = "qwen3-tts", designModelID = "qwen3-tts-design"
public let maxTextChars = 2000, maxDescriptionChars = 1000, maxSamples = 4

/// The CustomVoice speakers (the checkpoint's `spk_id`), as MES preset voices: id, title, native language, tags, notes.
public let speakers: [(id: String, title: String, language: String, tags: [String], notes: String?)] = [
    ("vivian", "Vivian", "zh", ["female", "chinese", "bright"], nil),
    ("serena", "Serena", "zh", ["female", "chinese", "warm"], nil),
    ("uncle_fu", "Uncle Fu", "zh", ["male", "chinese", "mature"], nil),
    ("dylan", "Dylan", "zh", ["male", "chinese", "beijing"], "Speaks Chinese in the Beijing dialect."),
    ("eric", "Eric", "zh", ["male", "chinese", "sichuan"], "Speaks Chinese in the Sichuan dialect."),
    ("ryan", "Ryan", "en", ["male", "english"], nil),
    ("aiden", "Aiden", "en", ["male", "english", "american"], nil),
    ("ono_anna", "Ono Anna", "ja", ["female", "japanese"], nil),
    ("sohee", "Sohee", "ko", ["female", "korean"], nil),
]

/// The speaker a request without a voice gets: the one native to its language, else Ryan.
public func defaultSpeaker(_ language: String?) -> String {
    ["zh": "vivian", "ja": "ono_anna", "ko": "sohee"][language ?? "en"] ?? "ryan"
}

/// The emotion labels the package's shared vocabulary takes (E12, `neutral` read as calm).
public let emotions = ["neutral", "happy", "sad", "angry", "afraid", "disgusted", "surprised", "calm", "melancholic"]

public func configuration(_ variant: Qwen3TTSVariant, _ quant: Qwen3TTSCheckpointQuant) -> Qwen3TTSConfiguration {
    Qwen3TTSConfiguration(checkpoint: Qwen3TTSCheckpoint(variant: variant, size: .s1_7B, quant: quant))
}

public func lanes(_ variant: Qwen3TTSVariant) -> [LaneDefinition] {
    [("int8", Qwen3TTSCheckpointQuant.q8), ("bf16", .bf16), ("int4", .q4)].map { id, quant in
        LaneDefinition(id: id, default: id == "int8", configuration: configuration(variant, quant))
    }
}

// MARK: - speak

/// What a speak job asks of the package, validated.
public struct SpeakPlan: Sendable {
    public var pieces: [Piece]
    public var speaker: String
    public var language: String?
    public var emotion: TTSEmotion?
    public var seed: UInt64
    public var effective: [String: JSONValue]
}

public func speakPlan(text: String?, voice: String?, language tag: String?, emotion: JSONValue?, seed: UInt64) throws -> SpeakPlan {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw GPPError(.invalidRequest, "audio.speak needs text.", detail: ["param": "text"])
    }
    guard text.count <= maxTextChars else {
        throw GPPError(.invalidRequest, "Qwen3-TTS speaks at most \(maxTextChars) characters at a time.", detail: ["param": "text"])
    }
    let lang = try language(tag)
    let speaker = voice ?? defaultSpeaker(lang)
    guard let entry = speakers.first(where: { $0.id == speaker }) else {
        throw GPPError(.invalidRequest, "Qwen3-TTS has no voice \(speaker).", detail: ["param": "voice"])
    }
    // A description says more than a label, so it wins (Audio §2.1).
    var typed: TTSEmotion?
    var effective: [String: JSONValue] = ["voice": .string(speaker), "language": .string(lang ?? entry.language),
                                          "seed": .int(Int64(seed))]
    if let emotion {
        if let description = emotion["description"]?.stringValue {
            typed = .textDescription(description)
        } else if let label = emotion["label"]?.stringValue {
            guard emotions.contains(label) else {
                throw GPPError(.invalidRequest, "Qwen3-TTS can't act \(label).", detail: ["param": "emotion"])
            }
            typed = .categorical(label == "neutral" ? "calm" : label)
        }
        effective["emotion"] = emotion
    }
    return SpeakPlan(pieces: try plan(text), speaker: speaker, language: lang ?? entry.language, emotion: typed, seed: seed,
                     effective: effective)
}

/// The engine request for one piece of a speak plan.
public func request(_ plan: SpeakPlan, words: String) -> TTSRequest {
    var meta: MetaData = ["seed": .int(Int(plan.seed))]
    if let language = plan.language { meta["language"] = .string(language) }
    return TTSRequest(text: words, voice: VoiceSelector(.named(plan.speaker)), emotion: plan.emotion, metaData: meta)
}

/// Seeds MLX's random state, then draws `request` through `run` and returns the WAV.
public func draw(_ request: TTSRequest, seed: UInt64, run: (TTSRequest) async throws -> any CapabilityResponse) async throws -> Data {
    MLXRandom.seed(seed)
    guard let response = try await run(request) as? TTSResponse else {
        throw GPPError(.modelError, "Qwen3-TTS returned no audio.")
    }
    return response.audio.data
}

let speakOperation = EngineOperation("audio.speak") { job, session in
    let plan = try speakPlan(text: try job.text("text"), voice: job.param("voice")?.stringValue,
                             language: job.param("language")?.stringValue, emotion: job.param("emotion"), seed: seed(job))
    var warnings: [Warning] = []
    if job.param("emotion")?["intensity"] != nil {
        warnings.append(Warning(code: "emotion_intensity_ignored", message: "Qwen3-TTS takes no emotion intensity.", param: "emotion"))
    }
    let pcm = try await speak(plan.pieces) { words in
        try await draw(request(plan, words: words), seed: plan.seed) { try await session.run($0 as! any WireRequest) }
    }
    let url = session.outputDir.appending(path: "audio-0.wav")
    try wav16(pcm).write(to: url)
    return RunResult(outputs: [.file("audio", url, mediaType: "audio/wav")], effective: plan.effective, warnings: warnings)
}

// MARK: - design_voice

/// What a design job asks: the description, the sample sentence, the language and how many samples.
public struct DesignPlan: Sendable {
    public var description: String
    public var text: String
    public var language: String
    public var count: Int
    public var seed: UInt64
}

public func designPlan(description: String?, text: String?, language tag: String?, count: Int?, seed: UInt64) throws -> DesignPlan {
    guard let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty else {
        throw GPPError(.invalidRequest, "audio.design_voice needs a description.", detail: ["param": "description"])
    }
    guard description.count <= maxDescriptionChars else {
        throw GPPError(.invalidRequest, "A description is at most \(maxDescriptionChars) characters.", detail: ["param": "description"])
    }
    let lang = try language(tag) ?? "en"
    let count = count ?? 1
    guard (1...maxSamples).contains(count) else {
        throw GPPError(.invalidRequest, "Qwen3-TTS designs 1–\(maxSamples) samples at a time.", detail: ["param": "count"])
    }
    let sentence = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    let sample = sentence?.isEmpty == false ? sentence! : languages.first { $0.tag == lang }!.sample
    guard sample.count <= maxTextChars else {
        throw GPPError(.invalidRequest, "The sample text is at most \(maxTextChars) characters.", detail: ["param": "text"])
    }
    return DesignPlan(description: description, text: sample, language: lang, count: count, seed: seed)
}

/// The engine request for sample `i` of a design: the sample sentence in the described voice, at seed + i.
public func request(_ plan: DesignPlan, sample i: Int) -> TTSRequest {
    TTSRequest(text: plan.text, voice: VoiceSelector(.auto), emotion: .textDescription(plan.description),
               metaData: ["seed": .int(Int(plan.seed) + i), "language": .string(plan.language)])
}

let designOperation = EngineOperation("audio.design_voice") { job, session in
    let plan = try designPlan(description: try job.text("description"), text: try job.text("text"),
                              language: job.param("language")?.stringValue, count: job.param("count")?.intValue, seed: seed(job))
    var warnings: [Warning] = []
    if job.param("prompt_enhance")?.stringValue == "on" {
        warnings.append(Warning(code: "prompt_enhance_ignored", message: "Qwen3-TTS reads the description as written.",
                                param: "prompt_enhance"))
    }
    var outputs: [Output] = []
    for i in 0..<plan.count {
        let wav = try await draw(request(plan, sample: i), seed: plan.seed + UInt64(i)) { try await session.run($0 as! any WireRequest) }
        let url = session.outputDir.appending(path: "samples-\(i).wav")
        try wav16(try pcm16(wav)).write(to: url)
        outputs.append(.file("samples", url, mediaType: "audio/wav"))
    }
    let effective: [String: JSONValue] = ["seed": .int(Int64(plan.seed)), "text": .string(plan.text),
                                          "language": .string(plan.language), "count": .int(Int64(plan.count))]
    return RunResult(outputs: outputs, effective: effective, warnings: warnings)
}

// MARK: - The plugin

let license: JSONValue = ["spdx": "Apache-2.0", "commercial_use": true, "terms_url": "https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base"]
let languageTags: JSONValue = .array(languages.map { .string($0.tag) })

let speakModel = ModelDefinition.engine(Qwen3TTSPackage.self, id: speakModelID, title: "Qwen3-TTS",
                                        lanes: lanes(.customVoice), operations: [speakOperation])
let designModel = ModelDefinition.engine(Qwen3TTSPackage.self, id: designModelID, title: "Qwen3-TTS VoiceDesign",
                                         lanes: lanes(.voiceDesign), operations: [designOperation])

let speakOffer = PluginManifest.Offer(
    operation: "audio.speak", profile: "audio",
    model: [
        "id": .string(speakModelID), "title": "Qwen3-TTS",
        "license": license, "memory_class": "medium", "speed_class": "standard", "quality_tiers": ["standard", "best"],
        "notes": "Expressive multilingual speech with nine preset speakers in ten languages. Give an emotion label, or describe the delivery in words (\"tired, as if after a long day\"); [pause 1s] adds silence. Each speaker sounds best in their own language.",
        "supports": [
            "voices": .int(Int64(speakers.count)), "default_voice": true, "languages": languageTags,
            "emotions": .array(emotions.map { .string($0) }), "emotion_description": true,
            "cues": ["pause"], "sample_rate": .int(Int64(sampleRate)), "channels": 1,
        ],
        "limits": ["max_text_chars": .int(Int64(maxTextChars))],
    ],
    voices: speakers.map { s -> JSONValue in
        var fields: [String: JSONValue] = ["id": .string(s.id), "title": .string(s.title), "languages": [.string(s.language)],
                                           "tags": .array(s.tags.map { .string($0) })]
        if let notes = s.notes { fields["notes"] = .string(notes) }
        return .object(fields)
    })

let designOffer = PluginManifest.Offer(
    operation: "audio.design_voice", profile: "audio",
    model: [
        "id": .string(designModelID), "title": "Qwen3-TTS VoiceDesign",
        "license": license, "memory_class": "medium", "speed_class": "standard", "quality_tiers": ["standard", "best"],
        "notes": "Describe a voice in a sentence or two (age, pitch, pace, accent, character), and hear it read a sample. Keep the sample you like as an asset and clone it with voice_ref.",
        "supports": ["languages": languageTags, "sample_rate": .int(Int64(sampleRate)), "channels": 1],
        "limits": ["max_text_chars": .int(Int64(maxDescriptionChars)), "max_count": .int(Int64(maxSamples))],
    ])

public let qwen3Plugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.qwen3-tts", version: "0.2.1", minGaea: "0.9.0", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-qwen3-tts", title: "Qwen3-TTS",
    summary: "Qwen3-TTS 1.7B: expressive speech in ten languages with nine preset speakers, speech in a voice cloned from a clip (MES audio.speak), and voices designed from a description (audio.design_voice).",
    license: "Apache-2.0", executable: "gaea-qwen3-tts-worker",
    models: [speakModel, cloneModel, designModel], offers: [speakOffer, cloneOffer, designOffer],
    onAssetRemoved: forgetAsset)
