import Foundation
import GaeaPluginKit
import GaeaProtocol

// What the Qwen3-TTS models share: languages, the text plan (`[pause Ns]`), and the package's 16-bit WAVs.

public let sampleRate = 24000
public let defaultPauseSeconds = 0.5
public let maxPauseSeconds = 10.0

/// The ten languages Qwen3-TTS speaks, as MES base subtags (BCP 47), with the sentence `design_voice` reads when a
/// request gives none (Audio §3.1).
public let languages: [(tag: String, sample: String)] = [
    ("zh", "你好！这是我朗读一句话时的声音。"),
    ("en", "Hello! This is how I sound when I read a sentence aloud."),
    ("ja", "こんにちは。これが、文を読み上げるときの私の声です。"),
    ("ko", "안녕하세요! 제가 문장을 소리 내어 읽을 때 이런 목소리예요."),
    ("de", "Hallo! So klinge ich, wenn ich einen Satz vorlese."),
    ("fr", "Bonjour ! Voici ma voix quand je lis une phrase à voix haute."),
    ("ru", "Привет! Так звучит мой голос, когда я читаю фразу вслух."),
    ("pt", "Olá! É assim que soa a minha voz quando leio uma frase em voz alta."),
    ("es", "¡Hola! Así suena mi voz cuando leo una frase en voz alta."),
    ("it", "Ciao! Questa è la mia voce quando leggo una frase ad alta voce."),
]

/// A request's language as the base subtag the package takes (`en-GB` → `en`), refusing one it doesn't speak. MES
/// gates `language` by the offer's `supports.languages` first, so this is a second check.
public func language(_ tag: String?) throws -> String? {
    guard let tag else { return nil }
    let base = String(tag.split(separator: "-").first ?? "").lowercased()
    guard languages.contains(where: { $0.tag == base }) else {
        throw GPPError(.invalidRequest, "Qwen3-TTS doesn't speak \(tag).", detail: ["param": "language"])
    }
    return base
}

// MARK: - The text plan

/// One piece of the plan: words for one generation, or silence.
public enum Piece: Sendable, Equatable {
    case words(String)
    case pause(Double)
}

/// The text as pieces (Audio §2.2's cue syntax: `[pause Ns]`, `[pause]`, and `\[` for a literal bracket). The talker
/// is autoregressive and reads long text in one pass, so words are cut only at pauses.
public func plan(_ text: String) throws -> [Piece] {
    var pieces: [Piece] = []
    var buffer = ""
    func flush() {
        let words = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { pieces.append(.words(words)) }
        buffer = ""
    }
    var i = text.startIndex
    while i < text.endIndex {
        let c = text[i]
        if c == "\\", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "[" {
            buffer.append("[")
            i = text.index(i, offsetBy: 2)
            continue
        }
        if c == "[", let close = text[i...].firstIndex(of: "]"),
           let m = text[text.index(after: i)..<close].wholeMatch(of: /pause(?: ([0-9]+(?:\.[0-9]+)?)s)?/) {
            let seconds = m.1.flatMap { Double($0) } ?? defaultPauseSeconds
            guard seconds <= maxPauseSeconds else {
                throw GPPError(.invalidRequest, "A pause is at most \(Int(maxPauseSeconds)) s.", detail: ["param": "text"])
            }
            flush()
            if seconds > 0 { pieces.append(.pause(seconds)) }
            i = text.index(after: close)
            continue
        }
        buffer.append(c)
        i = text.index(after: i)
    }
    flush()
    guard pieces.contains(where: { if case .words = $0 { true } else { false } }) else {
        throw GPPError(.invalidRequest, "There are no words to speak, only pauses.", detail: ["param": "text"])
    }
    return pieces
}

/// Draws the plan piece by piece with `draw`, and returns the 16-bit samples, pauses included.
public func speak(_ pieces: [Piece], draw: (String) async throws -> Data) async throws -> Data {
    var all = Data()
    for piece in pieces {
        try Task.checkCancellation()
        switch piece {
        case .words(let words): all.append(try pcm16(try await draw(words)))
        case .pause(let seconds): all.append(silence(seconds))
        }
    }
    return all
}

// MARK: - WAV

/// The 16-bit PCM inside one of the package's WAVs (its `encodeWAV16`: a 44-byte header, mono, 24 kHz).
public func pcm16(_ wav: Data) throws -> Data {
    guard wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8), wav[wav.startIndex + 8..<wav.startIndex + 12] == Data("WAVE".utf8),
          wav[wav.startIndex + 36..<wav.startIndex + 40] == Data("data".utf8) else {
        throw GPPError(.modelError, "Qwen3-TTS returned audio that isn't its usual 16-bit WAV.")
    }
    return wav.subdata(in: (wav.startIndex + 44)..<wav.endIndex)
}

/// Silence: `seconds` of 16-bit zeros.
public func silence(_ seconds: Double) -> Data { Data(count: Int((seconds * Double(sampleRate)).rounded()) * 2) }

/// A mono 16-bit WAV of `pcm` at 24 kHz.
public func wav16(_ pcm: Data) -> Data {
    var out = Data(capacity: 44 + pcm.count)
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); out.append(contentsOf: Array("WAVE".utf8))
    out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    out.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
    out.append(pcm)
    return out
}

/// MES seeds are 0 to 2³² − 1 (Audio §1.6); a job without one gets one.
public func seed(_ job: Job) -> UInt64 { job.seed.map { $0 & 0xFFFF_FFFF } ?? UInt64.random(in: 0..<(1 << 32)) }
