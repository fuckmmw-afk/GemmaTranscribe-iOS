# GemmaTranscribe (iOS)

Minimalist iOS application for on-device real-time speech transcription using **Google Gemma 3n E2B** via **Google AI Edge / LiteRT** runtime, followed by **post-STOP Cloudflare AI structuring and web search**, with strictly local history storage.

```
Микрофон → Audio Pipeline (16kHz) → Gemma 3n E2B (LiteRT) → Realtime Transcript
                                                                  ↓
                                                             [STOP Tapped]
                                                                  ↓
                                                  Clean Transcript (No Audio)
                                                                  ↓
                                                              Cloudflare
                                                                  ↓
                                                             Web Search
                                                                  ↓
                                                             Workers AI
                                                                  ↓
                                                       Final Result & History
```

---

## Key Features

1. **On-Device Realtime Transcription (Google Gemma 3n E2B)**
   - Powered by Google AI Edge / LiteRT runtime with Metal GPU acceleration.
   - Streaming chunking pipeline (1.0–3.0s interval, optimized for iPhone 12).
   - Zero Whisper / WhisperKit dependencies.
   - Pluggable `SpeechModelEngine` protocol allowing model runtime swapping without code rewrites.

2. **On-Demand Hugging Face Model Manager**
   - **Zero weights inside IPA**: the IPA contains strictly the application code and runtime.
   - Built-in Hugging Face Hub search (`https://huggingface.co/api/models`).
   - Default recommended catalog: `google/gemma-3n-E2B-it-litert-lm` (INT4 edge quantized).
   - Multi-model management: download with true byte-level progress bar, switch active models, and delete to reclaim storage.

3. **Real-time Speech Cleaner**
   - Strips oral fillers and hesitations locally in real-time («эээ», «ээ», «ааа», «аа», «ммм», «uh», «um», «типа», «как бы»).
   - Deduplicates consecutive stutter words («я я» → «я», «это это» → «это»).
   - Cleans formatting, spacing, and capitalization.

4. **Post-STOP Cloudflare AI & Web Search Pipeline**
   - **Privacy First**: Audio is NEVER transmitted over the network. Only cleaned plaintext is sent.
   - Automatically executes web search (Wikipedia API) based on transcribed concepts.
   - Cloudflare Workers AI (`@cf/meta/llama-3.1-8b-instruct`) structures the information into:
     - Executive summary
     - Structured definition cards with context notes
     - Web search source citation links
     - Action points

5. **Strictly Local History**
   - Stored in local JSON on device (`Documents/transcription_history.json`).
   - No iCloud, no mandatory accounts, zero cloud synchronization.

6. **iOS 26 Liquid Glass UI**
   - Visual aesthetic based on Dictus and LiquidGlass.
   - Tactile `AnimatedMicButton` with state animations (idle, recording, transcribing, processing).
   - Real-time `BrandWaveform` visualization responding to microphone input power.
   - Streaming captions view with automatic scrolling.

---

## Open-Source Attribution & Notices

This application heavily leverages and gives credit to the following open-source projects:

- **LiveTranscriber**: Audio session coordination, 16kHz audio buffer capture, and real-time caption display architecture.
  - *Attribution*: Based on LiveTranscriber by William Li. Original project: [https://github.com/iamwilliamli/LiveTranscriber](https://github.com/iamwilliamli/LiveTranscriber).
- **Dictus iOS**: SwiftUI interface design, `BrandWaveform`, `AnimatedMicButton`, Model Manager architecture, and local history storage.
  - *Attribution*: Copyright (c) 2026 PIVI Solutions (MIT License). Original project: [https://github.com/getdictus/dictus-ios](https://github.com/getdictus/dictus-ios).
- **LiquidGlass**: iOS 26 Liquid Glass materials, frosted cards, and glass buttons.
  - *Attribution*: Copyright (c) 2026 rguillen-dev (MIT License). Original project: [https://github.com/rguillen-dev/LiquidGlass](https://github.com/rguillen-dev/LiquidGlass).
- **Google AI Edge & LiteRT**: On-device runtime for Gemma 3n multimodal models.
  - *Attribution*: Copyright (c) Google LLC (Apache 2.0). Original project: [https://github.com/google-ai-edge/LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM).

---

## Project Structure

```
GemmaTranscribe-iOS/
├── .github/workflows/
│   └── ios-ci.yml                      # CI workflow producing unsigned IPA
├── GemmaTranscribe/
│   ├── App/                            # Application entry point & configuration
│   ├── Audio/                          # 16kHz audio capture & waveform power
│   ├── Cloudflare/                     # Cloudflare brain service & decodable models
│   ├── Design/                         # LiquidGlass, BrandWaveform, AnimatedMicButton
│   ├── History/                        # Atomic local JSON history storage
│   ├── Models/                         # Hugging Face manager, downloader, LiteRT engine
│   ├── Resources/                      # Info.plist, entitlements, app icon
│   ├── Transcription/                  # Speech cleaner & live transcription coordinator
│   └── Views/                          # SwiftUI screens (Home, Models, History, Settings)
├── cloudflare-worker/                  # Cloudflare Worker code (Wrangler + Workers AI)
├── GemmaTranscribe.xcodeproj/          # Xcode project & scheme
├── NOTICE                              # Third-party attributions
├── LICENSE                             # MIT License
└── README.md
```

---

## Build & Continuous Integration

An automated GitHub Actions workflow (`.github/workflows/ios-ci.yml`) runs on `macos-14`:
1. Compiles the Xcode project for iOS 17+.
2. Verifies that **no model weights** are bundled inside the IPA.
3. Packages an unsigned `.ipa` artifact (`GemmaTranscribe-unsigned-ipa`).
