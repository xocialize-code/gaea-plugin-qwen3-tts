# gaea-plugin-qwen3-tts

Alibaba's **Qwen3-TTS** 12 Hz, 1.7B (Apache-2.0) as a [Gaea](https://github.com/xocialize-code/gaea) plugin:
expressive speech in ten languages, and voices designed from a description, on MES Audio 0.1. It is built on
[GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit) over
[mlx-qwen3-tts-swift](https://github.com/xocialize/mlx-qwen3-tts-swift), runs in its own process, and speaks the Gaea
Plugin Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-qwen3-tts
```

## What it offers

| Model | Checkpoint | MES operation |
|---|---|---|
| `qwen3-tts` | CustomVoice | `audio.speak` with nine preset speakers |
| `qwen3-tts-clone` | Base | `audio.speak` in a voice cloned from `voice_ref` (0.2.0) |
| `qwen3-tts-design` | VoiceDesign | `audio.design_voice` |

- **Voices.** Vivian, Serena, Uncle Fu, Dylan (Beijing dialect) and Eric (Sichuan dialect) speak Chinese natively,
  Ryan and Aiden English, Ono Anna Japanese, and Sohee Korean. Every speaker speaks all ten languages, and sounds
  best in their own. Without a voice, the speaker native to the request's language reads it (Ryan for the rest).
- **Languages.** Chinese, English, Japanese, Korean, German, French, Russian, Portuguese, Spanish and Italian (`zh`,
  `en`, `ja`, `ko`, `de`, `fr`, `ru`, `pt`, `es`, `it`).
- **Emotion.** A label from `neutral`, `happy`, `sad`, `angry`, `afraid`, `disgusted`, `surprised`, `calm` and
  `melancholic`, or the delivery described in words (`emotion.description`, which wins over a label). An intensity is
  ignored, with `emotion_intensity_ignored`.
- **Text.** Up to 2,000 characters, read in one pass. `[pause 1.5s]` (or `[pause]`, half a second) is silence, up to
  10 s, and the only cue the model performs.
- **Design.** A description of a voice (up to 1,000 characters) is read back as 1 to 4 samples of one sentence. Sample
  `i` uses `seed + i`, and the sentence is reported as `effective.text`. Give your own with the `text` input, or get a
  short sentence in the request's language. The sample is the voice: keep it as an asset and clone it.
- **Seeds.** The talker samples from MLX's random state. The worker seeds it with the job's seed (0 to 2³² − 1) before
  every generation and passes the seed to the package. The same request gives the same WAV.
- **Output.** 24 kHz mono 16-bit WAV, converted by Gaea to the request's `output`.
- **Cloning.** `qwen3-tts-clone` speaks in the voice of a 3 to 30 s reference clip (`voice_ref`). A longer clip is
  trimmed with `voice_ref_trimmed`, and a stereo one mixed down with `audio_downmixed`.
  - **With the clip's transcript** (`voice_ref_text`), it clones in context (ICL): much closer to the voice.
  - **Without it**, it clones from the speaker embedding alone (x-vector).
  - **Caching:** the reference's features are cached in the package (mlx-qwen3-tts-swift 0.7.0). A clip sent as an
    MES asset is keyed by its asset id, and evicted when Gaea reports the asset gone (MES Base §13 rule 6). Any other
    clip is keyed by its job, and evicted when the job ends.
  - A second job on the same asset skips the reference's encoding (about 1.4 s against 3.8 s for a short line).
- **Not yet.** Streaming waits on the package (`StreamEmitting`).

On an M5 Max at int8, warm, a 6.7 s sentence takes about 2.2 s, and two designed samples about 3 s.

## Lanes and memory

Three lanes, the talker's quant: `int8` (the default), `bf16` and `int4`, with the package's footprints. A worker
with one model loaded measures about 3 GB.

## Weights

Gaea sends its models root in `configure` (MLXEngine's store by default). Each lane reads
`mlx-community/Qwen3-TTS-12Hz-1.7B-{CustomVoice,Base,VoiceDesign}-{8bit,bf16,4bit}` and the shared codec,
`Qwen/Qwen3-TTS-Tokenizer-12Hz`, there, and downloads them on `prepare` or `materialize` when they're missing (about
3.1 GB per 8-bit checkpoint, and 0.7 GB for the codec).

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`check-plugin.sh` speaks one sentence over GPP on the signed bundle, with every `.build` folder hidden, then shows
that the bare worker outside the bundle finds no metallib. `scripts/release.sh` builds, checks, notarizes with the
fleet's `mlx-notary` profile, and publishes the GitHub release. The release workflow does the same in CI when a
`v<version>` tag is pushed.

`qwen3-inproc` (its header lists the options) is not part of the plugin: it runs the same lanes in-process through
MLXServeEngine, with the worker's requests and seeding, as the reference Gaea's runs are compared against.

```bash
scripts/golden.sh <out-dir>
```

`golden.sh` runs seeded jobs over GPP on the signed bundle and through `qwen3-inproc`, and needs each pair to be the
same WAV byte for byte:
- speak cases: Ryan neutral, Ryan angry, Aiden with a described delivery, and Vivian in Chinese with a pause;
- two designed samples of one description;
- the first sample cloned with its text (ICL) and without it (x-vector).

## CI secrets

The release workflow signs with Developer ID and notarizes. It reads four organization secrets on xocialize-code:
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID` and `NOTARY_APP_PASSWORD` (Gaea's
`Docs/Signing secrets.md`).

## Licence

The plugin is Apache-2.0 (Gaea G-21). Qwen3-TTS's weights are Apache-2.0 (Alibaba Qwen), and mlx-qwen3-tts-swift and
its qwen3-tts-mlx-swift core are Apache-2.0.
