# kokoro-swift

Native Swift inference for [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) text-to-speech on Apple Silicon.

- **MLX backend** — GPU inference via Metal
- **CoreML backend** — Segmented model for optimal Neural Engine (ANE) utilization
- **On-demand voice downloads** — 54 voices fetched from HuggingFace as needed
- **Built-in English G2P** — Text → phonemes via the bundled Misaki engine (no Python or espeak needed)

## Quick Start

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/mweinbach/kokoro-swift.git", from: "0.1.0"),
]
```

### Download Voices

Voices are downloaded on demand from [mweinbach/Kokoro-82M-Swift](https://huggingface.co/mweinbach/Kokoro-82M-Swift).

```swift
import Kokoro

// Download a specific voice
let downloader = VoiceDownloader()
let voiceURL = try await downloader.downloadVoice("af_heart")

// Or download all 54 voices
let allVoices = try await downloader.downloadAllVoices()
```

### Synthesize Speech (MLX)

```swift
import Kokoro

// Load model (requires MLX weights from HuggingFace)
let model = try KModel(
    configURL: URL(fileURLWithPath: "MLX_GPU/config.json"),
    weightsURL: URL(fileURLWithPath: "MLX_GPU/kokoro-v1_0.safetensors")
)
let voices = VoiceLoader(
    baseDirectory: URL(fileURLWithPath: "MLX_GPU/voices"),
    enableDownload: true  // auto-download missing voices
)
let pipeline = KPipeline(model: model, voices: voices)

// Text to speech
let result = try pipeline.synthesize(text: "Hello world!", voice: "af_heart")
try AudioWriter.writeWAV(samples: result.audio, to: outputURL, sampleRate: 24000)
```

### Synthesize Speech (CoreML ANE)

```swift
import Kokoro

let model = try SegmentedCoreMLModel(
    segmentedDir: URL(fileURLWithPath: "CoreML_ANE/segmented"),
    configURL: URL(fileURLWithPath: "MLX_GPU/config.json")
)
let voices = VoiceLoader(
    baseDirectory: URL(fileURLWithPath: "MLX_GPU/voices"),
    enableDownload: true
)
let pipeline = KPipeline(coreMLSegmentedModel: model, voices: voices)
let result = try pipeline.synthesize(text: "Hello from the Neural Engine!", voice: "af_heart")
```

## CLI

Build and run the included CLI:

```bash
# Build
cd kokoro-swift
xcodebuild build -scheme KokoroCLI -destination 'platform=macOS' -derivedDataPath .build/xcode

# List available voices
./KokoroCLI list-voices

# Download voices
./KokoroCLI download-voice af_heart af_bella
./KokoroCLI download-voice --all

# Synthesize (MLX GPU)
./KokoroCLI --text "Hello world" --voice af_heart --output hello.wav --weights-dir MLX_GPU

# Synthesize (CoreML ANE segmented)
./KokoroCLI --text "Hello world" --voice af_heart --output hello.wav \
  --backend coreml-ane-segmented --coreml-segmented-dir CoreML_ANE/segmented --weights-dir MLX_GPU

# Auto-download missing voices during synthesis
./KokoroCLI --text "Hello world" --voice af_heart --output hello.wav --auto-download --weights-dir MLX_GPU
```

## Model Weights

Download converted weights from HuggingFace: [mweinbach/Kokoro-82M-Swift](https://huggingface.co/mweinbach/Kokoro-82M-Swift)

| Directory | Format | Backend |
|-----------|--------|---------|
| `MLX_GPU/` | safetensors + npy | MLX-Swift (Metal GPU) |
| `CoreML_ANE/segmented/` | 4 × mlpackage | CoreML (ANE + CPU) |

The CoreML model is split into 4 segments for maximum ANE utilization:
- `albert.mlpackage` — ALBERT encoder → **ANE**
- `decoder.mlpackage` — Vocoder → **ANE**
- `prosody.mlpackage` — Prosody predictor → CPU (LSTM-based)
- `text_encoder.mlpackage` — Text encoder → CPU (LSTM-based)

### Convert Weights Yourself

```bash
# MLX format
python3 Scripts/convert_weights.py \
  --checkpoint Kokoro-82M/kokoro-v1_0.pth \
  --voices Kokoro-82M/voices \
  --config Kokoro-82M/config.json \
  --output-dir MLX_GPU

# CoreML ANE segmented format
python3 Scripts/convert_to_coreml_segmented.py
```

## Architecture

```
Text → Misaki G2P → Phonemes → Kokoro Model → 24kHz Audio
         (Swift)                  (MLX or CoreML)
```

- **Misaki** (`Packages/Misaki/`) — English grapheme-to-phoneme engine using Apple NaturalLanguage framework
- **Kokoro** (`Sources/Kokoro/`) — Neural network inference + pipeline orchestration
- **KokoroCLI** (`Sources/KokoroCLI/`) — Command-line interface

## Voices

54 voices across 8 languages. Voice naming: `{lang}{gender}_{name}`

| Prefix | Language | Voices |
|--------|----------|--------|
| `af_` / `am_` | American English | 11F + 9M |
| `bf_` / `bm_` | British English | 4F + 4M |
| `ef_` / `em_` | Spanish | 1F + 2M |
| `ff_` | French | 1F |
| `hf_` / `hm_` | Hindi | 2F + 2M |
| `if_` / `im_` | Italian | 1F + 1M |
| `jf_` / `jm_` | Japanese | 4F + 1M |
| `pf_` / `pm_` | Portuguese | 1F + 2M |
| `zf_` / `zm_` | Chinese | 4F + 4M |

## Requirements

- macOS 14+ / iOS 17+
- Apple Silicon (M1+)
- Xcode 15+

## Credits

- [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) by hexgrad — Apache 2.0 licensed model
- [StyleTTS 2](https://arxiv.org/abs/2306.07691) architecture by Li et al.
- [Misaki](https://github.com/hexgrad/misaki) G2P engine by hexgrad
- [MLX-Swift](https://github.com/ml-explore/mlx-swift) by Apple

## License

Apache 2.0
