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
}
