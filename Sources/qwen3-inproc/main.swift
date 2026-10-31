import Foundation
import GaeaProtocol
import MLXQwen3TTS
import MLXServeCore
import MLXToolKit
import Qwen3Plugin

// The in-process reference for the plugin: one Qwen3-TTS checkpoint loaded by MLXServeEngine in this process, with the
// lane configuration, the requests and the seeding the worker uses (Qwen3Plugin). The WAVs are written to --out (speak)
// or --out-dir as samples-<i>.wav (design), and one JSON line of timings is printed. Not part of the plugin bundle.
//
//   qwen3-inproc speak [--text <text> | --text-file <path>] [--voice ryan] [--language en] [--emotion <label>]
//                      [--emotion-description <text>] [--seed 42] [--lane int8 | bf16 | int4] [--models-root <dir>]
//                      [--out <wav>]
//   qwen3-inproc design --description <text> [--text <sample>] [--language en] [--count 1] [--seed 42] [--lane int8]
//                       [--models-root <dir>] [--out-dir <dir>]

var args = Array(CommandLine.arguments.dropFirst())
let mode = args.isEmpty ? "speak" : args.removeFirst()
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let laneID = option("--lane") ?? "int8"
let seed = UInt64(option("--seed") ?? "") ?? 42
let languageTag = option("--language")
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)
let variant: Qwen3TTSVariant = mode == "design" ? .voiceDesign : .customVoice
guard let lane = lanes(variant).first(where: { $0.id == laneID }) else { fatalError("no lane \(laneID)") }

// The budget Gaea sends a worker on a large Mac (wiresWeights off).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(mode == "design" ? designModelID : speakModelID)
_ = try await engine.register(Qwen3TTSPackage.registration, configuration: lane.configuration, id: id)
var clock = ContinuousClock.now
_ = try await engine.prepare(.tts, package: id)
var result: [String: Any] = ["model": id.rawValue, "lane": laneID, "seed": seed, "prepare_s": seconds(since: clock)]
let run: (TTSRequest) async throws -> any CapabilityResponse = { try await engine.run($0, package: id) }

clock = ContinuousClock.now
if mode == "design" {
    let plan = try designPlan(description: option("--description"), text: option("--text"), language: languageTag,
                              count: Int(option("--count") ?? ""), seed: seed)
    let dir = URL(fileURLWithPath: option("--out-dir") ?? ".", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for i in 0..<plan.count {
        let wav = try await draw(request(plan, sample: i), seed: plan.seed + UInt64(i), run: run)
        try wav16(try pcm16(wav)).write(to: dir.appending(path: "samples-\(i).wav"))
    }
    result["text"] = plan.text
    result["count"] = plan.count
} else {
    let text = try option("--text-file").map { try String(contentsOfFile: $0, encoding: .utf8) }
        ?? option("--text") ?? "Gaea speaks. This sentence came from a signed plugin, over its own protocol."
    var emotion: JSONValue?
    if let label = option("--emotion") { emotion = ["label": .string(label)] }
    if let description = option("--emotion-description") { emotion = ["description": .string(description)] }
    let plan = try speakPlan(text: text, voice: option("--voice"), language: languageTag, emotion: emotion, seed: seed)
    let pcm = try await speak(plan.pieces) { words in try await draw(request(plan, words: words), seed: plan.seed, run: run) }
    if let out = option("--out") { try wav16(pcm).write(to: URL(fileURLWithPath: out)) }
    result["voice"] = plan.speaker
    result["audio_s"] = Double(pcm.count / 2) / Double(sampleRate)
}
result["run_s"] = seconds(since: clock)
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
result["max_rss_gb"] = Double(usage.ru_maxrss) / 1e9
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
