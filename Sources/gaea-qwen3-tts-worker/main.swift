import GaeaPluginKit
import Qwen3Plugin

// The plugin's worker: Qwen3Plugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(qwen3Plugin)
