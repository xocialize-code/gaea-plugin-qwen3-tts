import Foundation
import GaeaProtocol
import MLXToolKit
@testable import Qwen3Plugin
import Testing

@Suite("Requests")
struct PlanTests {
    @Test func pausesSplitTheTextAndBracketsStayWords() throws {
        #expect(try plan("Hello there. [pause 1.5s] Second line [pause] end \\[aside]")
            == [.words("Hello there."), .pause(1.5), .words("Second line"), .pause(0.5), .words("end [aside]")])
        #expect(throws: GPPError.self) { try plan("a [pause 11s] b") }
        #expect(throws: GPPError.self) { try plan("[pause 1s]") }
    }

    @Test func voicesLanguagesAndEmotions() throws {
        #expect(try speakPlan(text: "Hi", voice: nil, language: nil, emotion: nil, seed: 1).speaker == "ryan")
        #expect(try speakPlan(text: "你好", voice: nil, language: "zh-CN", emotion: nil, seed: 1).speaker == "vivian")
        #expect(try speakPlan(text: "Hi", voice: nil, language: "en-GB", emotion: nil, seed: 1).language == "en")
        #expect(throws: GPPError.self) { try speakPlan(text: "Hi", voice: "nobody", language: nil, emotion: nil, seed: 1) }
        #expect(throws: GPPError.self) { try speakPlan(text: "Hi", voice: nil, language: "nl", emotion: nil, seed: 1) }
        let described = try speakPlan(text: "Hi", voice: "ryan", language: nil,
                                      emotion: ["label": "sad", "description": "tired, after a long day"], seed: 1)
        #expect(described.emotion == .textDescription("tired, after a long day"))
        #expect(try speakPlan(text: "Hi", voice: "ryan", language: nil, emotion: ["label": "neutral"], seed: 1).emotion == .categorical("calm"))
        #expect(throws: GPPError.self) { try speakPlan(text: "Hi", voice: "ryan", language: nil, emotion: ["label": "excited"], seed: 1) }
        let r = request(described, words: "Hi")
        #expect(r.metaData["seed"] == .int(1) && r.metaData["language"] == .string("en"))
        #expect(speakers.count == 9 && Set(speakers.map(\.id)).count == 9)
    }

    @Test func designSamplesUseSeedPlusI() throws {
        let plan = try designPlan(description: "a deep calm voice", text: nil, language: "fr", count: 3, seed: 10)
        #expect(plan.text.hasPrefix("Bonjour") && plan.count == 3)
        #expect(request(plan, sample: 2).metaData["seed"] == .int(12))
        #expect(throws: GPPError.self) { try designPlan(description: " ", text: nil, language: nil, count: 1, seed: 1) }
        #expect(throws: GPPError.self) { try designPlan(description: "x", text: nil, language: nil, count: 5, seed: 1) }
        #expect(languages.count == 10)
    }

    @Test func wavsRoundTrip() throws {
        let pcm = Data((0..<480).map { UInt8($0 % 256) })
        #expect(try pcm16(wav16(pcm)) == pcm)
        #expect(silence(0.5).count == 24000)
    }

    func clip(seconds: Double, channels: Int = 1, rate: Int = 24000) -> Data {
        let frames = Int(seconds * Double(rate))
        let pcm = Data((0..<(frames * channels * 2)).map { UInt8($0 % 200) })
        var out = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(rate))
        u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        out.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); out.append(pcm)
        return out
    }

    @Test func referencesAreMonoAndAtMostThirtySeconds() throws {
        let mono = clip(seconds: 4)
        let kept = try reference(mono)
        #expect(kept.wav == mono && kept.warnings.isEmpty && kept.seconds == 4)
        let stereo = try reference(clip(seconds: 4, channels: 2))
        #expect(stereo.warnings.map(\.code) == ["audio_downmixed"] && stereo.wav.count == mono.count)
        let long = try reference(clip(seconds: 40))
        #expect(long.warnings.map(\.code) == ["voice_ref_trimmed"] && long.seconds == 30)
        #expect(throws: GPPError.self) { try reference(clip(seconds: 0.2)) }
        #expect(throws: GPPError.self) { try reference(Data("RIFF....WAVEjunk".utf8)) }
    }

    @Test func aReferenceIsKeyedByItsAssetElseByItsJob() throws {
        let asset = try clonePlan(text: "Hi", reference: clip(seconds: 3), transcript: "hello", language: nil, asset: "ast_1",
                                  job: "job_1", seed: 5)
        #expect(asset.cacheKey == "ast_1" && !asset.jobScoped && asset.transcript == "hello")
        #expect(request(asset, words: "Hi").metaData["voiceCacheKey"] == .string("ast_1"))
        let plain = try clonePlan(text: "Hi", reference: clip(seconds: 3), transcript: " ", language: "de", asset: nil, job: "job_2", seed: 5)
        #expect(plain.cacheKey == "job:job_2" && plain.jobScoped && plain.transcript == nil && plain.language == "de")
        #expect(plain.effective["x-qwen3.clone"] == "xvector" && asset.effective["x-qwen3.clone"] == "icl")
        #expect(eviction(["ast_1"]).metaData["evictVoiceCacheKeys"] == .array([.string("ast_1")]) && eviction([]).text.isEmpty)
    }
}
