# Third-party software and models

Sona's own code is MIT licensed. It uses the following, with thanks.

## Code

**FluidAudio**: Swift SDK for on-device speech on Apple Silicon (ASR, VAD, diarization on CoreML).
- https://github.com/FluidInference/FluidAudio, by FluidInference
- Apache License 2.0
- Linked as a Swift package, pinned to commit `1b0ed50d686873128a4129b3510ce3914c849bab`. Not modified.
- Its licence text and its own third-party notices (VBx, Apache-2.0, © BUT Speech@FIT; fastcluster, BSD-2-Clause, © Daniel Müllner and Google Inc.) ship inside the app bundle in `Contents/Resources/Licenses/`.

**Model Context Protocol**: Sona implements the open MCP spec (https://modelcontextprotocol.io) with a small hand-written stdio JSON-RPC server. No code from the official Swift SDK (https://github.com/modelcontextprotocol/swift-sdk, MIT) is included. It was left out to avoid its swift-nio dependency tree for a handful of tools.

**Anarlog** (https://github.com/fastrepl/anarlog, MIT, by Fastrepl): used as a reference only. No code copied. Two ideas borrowed for the MCP tools: tool descriptions that say what an empty result means ("don't invent meetings"), and paging long transcripts instead of returning them whole.

**OpenWhispr** (https://github.com/OpenWhispr/openwhispr, MIT) and **VoiceInk** (https://github.com/Beingpax/VoiceInk, GPL-3.0): read as references for fn dictation; no code copied from either. Ideas borrowed: turning the fn/🌐 key's own action off while the app runs (and restoring it on quit), cancelling when another key is pressed during the hold, marking the pasted clipboard item as transient, and a non-activating floating panel rebuilt for each dictation.

**handy-keys** (https://github.com/handy-computer/handy-keys, MIT, Copyright (c) 2026 handy-computer), the hotkey library of **Handy** (https://github.com/cjpais/Handy, MIT): the dictation key monitor (`Sources/SonaApp/KeyMonitor.swift`) ports its macOS listener's approach to Swift: a session-level CGEventTap inserted at the head, on its own thread's run loop with no polling; turning the tap back on from its own callback when macOS disables it (polling `CGEventTapIsEnabled` leaked kernel IPC until macOS panicked, Handy #1827); tracking each modifier by toggling its key code on flagsChanged, reconciled with the event's own modifier flags to clear missed key-ups; shortcuts where one side of a modifier means that side and both sides mean either; a modifiers-alone hold that ends when any of its keys is let go; swallowing only a shortcut's non-modifier key; and noting that under secure input only flagsChanged still arrives. Used under the MIT License (text below, under hearsay).

**hyperkey** (https://github.com/feedthejim/hyperkey, MIT): read as a reference for remapping Caps Lock to F18 with `UserKeyMapping` (HID usage 0x700000039 to 0x70000006D, Apple TN2450) and applying it again when a keyboard appears. Sona sets it through IOKit's `IOHIDServiceClientSetProperty` per keyboard, keeping other mappings, instead of running `hidutil`. No code copied.

**hearsay** (https://github.com/vrennat/hearsay, MIT, Copyright (c) 2026 Tanner Vass): the loudness gate in the echo filter (`EchoGate` in `Sources/NotesKit/EchoFilter.swift`) is adapted from hearsay's `EchoFilter`: 10 ms dB loudness curves of the mic and the system track compared in 1.5 s windows by Pearson correlation (silence floored at -70 dB, a match at r ≥ 0.75 with 0.3 s of sound in each, confirmed only when a neighbouring window agrees on the lag within 50 ms), and the idea of dropping mic words that have a text twin on the system track. Used under the MIT License:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

**AudioCap** (https://github.com/insidegui/AudioCap, BSD-2-Clause, by Guilherme Rambo) and **Meetily** (https://github.com/Zackriya-Solutions/meeting-minutes, MIT): read as references for Core Audio process taps; no code copied. The tap (`Sources/LiveCore/MacAudio.swift`) follows Apple's "Capturing system audio with Core Audio taps". Borrowed ideas: tearing down in the reverse order of making (AudioCap), and an aggregate device that holds only the tap, so a headset's mic is never opened (Meetily).

## Models

Downloaded once on first run from Hugging Face (FluidInference's CoreML conversions). Not included in this repository.

**Parakeet TDT 0.6B v2** (English) and **Parakeet TDT 0.6B v3** (25 European languages)
- By NVIDIA. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2, https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- CoreML: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml, https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- Creative Commons Attribution 4.0 (CC-BY-4.0): https://creativecommons.org/licenses/by/4.0/

**pyannote speaker-diarization-community-1** (segmentation and speaker embedding; clustering with VBx)
- By pyannote / pyannoteAI, with a WeSpeaker speaker embedding and PLDA parameters from BUT Speech@FIT. https://huggingface.co/pyannote/speaker-diarization-community-1
- CoreML: https://huggingface.co/FluidInference/speaker-diarization-coreml (modified Core ML conversions by FluidInference; its NOTICE.md lists what the licence covers)
- Creative Commons Attribution 4.0 (CC-BY-4.0): https://creativecommons.org/licenses/by/4.0/

**Parakeet Unified 0.6B** (English, streaming; the live transcript and hold-to-dictate)
- By NVIDIA. https://huggingface.co/nvidia/parakeet-unified-en-0.6b
- CoreML: https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml (converted and int8-quantized by FluidInference)
- NVIDIA Open Model License: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/ . Licensed by NVIDIA Corporation under the NVIDIA Open Model License. (The CoreML conversion's card says CC-BY-4.0; the upstream model's licence is the one that applies, so it's treated as the NVIDIA Open Model License here.)

**Parakeet Realtime EOU 120M** (English, streaming; only in the developer latency bench `sona-live-bench`, for comparison. Not in the app, and the app never downloads it)
- By NVIDIA. https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1
- CoreML: https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml
- NVIDIA Open Model License: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/ . Licensed by NVIDIA Corporation under the NVIDIA Open Model License.

**Nemotron 3 Diarization** (streaming speaker separation in the live transcript)
- By NVIDIA. https://huggingface.co/nvidia/Nemotron-3-Diarization
- CoreML: https://huggingface.co/FluidInference/nemotron-3-diarization-coreml
- OpenMDW License 1.1: https://openmdw.ai/license/ . Copyright NVIDIA Corporation.

**Silero VAD**
- By the Silero Team. https://github.com/snakers4/silero-vad
- CoreML: https://huggingface.co/FluidInference/silero-vad-coreml
- MIT License

Sona doesn't change any of these models. FluidInference's CoreML versions are conversions of the originals (fixed input shapes, lower precision or quantization), downloaded as published.

## iPhone and Apple Watch app

The iPhone app (`ios/`) links the same **FluidAudio** package (Apache License 2.0, above). After the first screen
(which says so, with the size), it downloads by itself, once, the same **Parakeet TDT 0.6B v2** speech model and the
**pyannote speaker-diarization-community-1** models (both CC-BY-4.0, above) and **Silero VAD** (MIT, above) from
FluidInference's Hugging Face pages. It doesn't download the Mac's live-transcript models. The watch app and the
widgets contain no third-party code or models.

- **Apple's frameworks**, part of iOS and watchOS, not bundled: Foundation Models for titles on the device
  (`SystemLanguageModel` only), Core Location and MapKit's reverse geocoder for a note's street name (it sends a
  recording's coordinates to Apple, see `PRIVACY.md`), ActivityKit and WidgetKit for the Live Activity and widgets, and
  WatchConnectivity for the watch.

Distributing the app through the App Store means these notices must travel with it. The app's Settings > Licences
lists FluidAudio (Apache-2.0) with its NOTICE's third-party notices (VBx, Apache-2.0, © BUT Speech@FIT; fastcluster,
BSD-2-Clause, © Daniel Müllner and Google Inc.), NVIDIA's Parakeet TDT 0.6B v2 and pyannote's
speaker-diarization-community-1 under CC-BY-4.0, and Silero VAD under MIT, each linking to its licence's text. Unlike
the Mac app, the iPhone app doesn't bundle the licence files themselves.

## Test audio

The test clips are made on your Mac with the macOS `say` voices (Samantha, Daniel, Eddy, Fred, Karen) by `scripts/make-test-clip.sh` and `scripts/make-mac-audio-clip.sh`. They're synthetic voices reading a made-up script, not recordings of people, and the audio isn't included in the repository. `test-audio/*.ref.json` and `*.turns.tsv` are timings and text for those clips.
