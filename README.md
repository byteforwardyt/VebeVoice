# VebeVoice

**Free, local-first voice dictation for macOS.** Press a hotkey, talk, and VebeVoice types what you said into whatever app you're using. Speech recognition runs on your Mac; no account, no subscription, no telemetry.

<p>
  <a href="https://github.com/byteforwardyt/VebeVoice/releases/latest/download/VebeVoice.zip"><img src="docs/images/download-macos.svg" alt="Download VebeVoice for macOS" height="56"></a>
</p>

Free · macOS 15+ · Signed and notarized · [All releases](https://github.com/byteforwardyt/VebeVoice/releases)

> Based on [FluidVoice](https://github.com/altic-dev/FluidVoice) by altic-dev (GPLv3).

---

## Features

- **Dictate anywhere.** A global hotkey (Right Option by default) starts and stops recording from any app; the text is typed at your cursor.
- **On-device speech engines.** Parakeet TDT v2 (English) and v3 (25 languages), Parakeet Flash, Nemotron, Qwen3 ASR, Cohere Transcribe, Whisper (tiny → large), and Apple Speech. Models download once and run locally.
- **Live preview.** A notch-aware overlay shows the transcript as you speak.
- **Custom dictionary.** Word boosting for names and jargon, plus find-and-replace rules applied to every transcript.
- **Spoken punctuation.** Say "comma", "period", "question mark", and so on.
- **History and stats.** Searchable transcription history and usage stats, stored locally.
- **Meeting transcription.** Transcribe longer audio files.
- **Local API (optional, off by default).** A localhost-only HTTP API for scripting transcription and dictionary edits.

## Requirements

- macOS 15.0 or later
- Apple Silicon recommended (Intel is supported with Whisper / Apple Speech)
- Microphone and Accessibility permissions

## Install

1. [Download VebeVoice.zip](https://github.com/byteforwardyt/VebeVoice/releases/latest/download/VebeVoice.zip) (latest release).
2. Unzip and drag **VebeVoice.app** into `/Applications`.
3. Open it and follow onboarding: grant **Microphone** and **Accessibility** access, then pick a speech model to download.

Release builds are signed with the Altstead LLC Developer ID and notarized by Apple, so they open without Gatekeeper warnings. If you build it yourself with ad-hoc signing and macOS blocks it, right-click the app → **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/VebeVoice.app
```

## Usage

| Action | Default |
| --- | --- |
| Start / stop dictation | Right Option (toggle) |
| Change shortcut or switch to push-to-talk | Settings → Shortcuts |
| Change speech model | Settings → Engine |

Accessibility access is what lets VebeVoice listen for the hotkey and type into other apps. If the hotkey stops working after an update, remove VebeVoice from **System Settings → Privacy & Security → Accessibility** and add it again.

## Privacy

- Audio is captured and transcribed on your Mac. Nothing is uploaded.
- The only network traffic is downloading speech models (from Hugging Face) when you choose one.
- No analytics, crash reporting, or auto-update pings.
- Settings live in `UserDefaults` (`com.thevibefather.vebevoice`); custom vocabulary in `~/Library/Application Support/VebeVoice`; models in `~/Library/Application Support/FluidAudio/Models`; logs in `~/Library/Logs/VebeVoice`.

## Local API

Off by default. Enable it, then relaunch VebeVoice:

```bash
defaults write com.thevibefather.vebevoice LocalAPIEnabled -bool true
defaults write com.thevibefather.vebevoice LocalAPIPort -int 47733   # optional
```

It listens on `http://127.0.0.1:47733` and rejects non-localhost and browser (cross-origin) requests.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/health` | Status check |
| `GET` | `/v1/history` | Transcription history |
| `GET` / `POST` | `/v1/dictionary/replacements` | Read / add replacement rules |
| `GET` / `POST` | `/v1/dictionary/custom-words` | Read / add boosted words |
| `POST` | `/v1/transcribe` | Transcribe a file: `{"path": "/abs/path/audio.wav"}` |

```bash
curl -s http://127.0.0.1:47733/v1/transcribe \
  -H 'Content-Type: application/json' \
  -d '{"path": "/Users/me/Desktop/note.wav"}'
```

## Build from source

Requires Xcode 26 or later.

```bash
git clone https://github.com/byteforwardyt/VebeVoice.git
cd VebeVoice
open VebeVoice.xcodeproj
```

Select the **VebeVoice** scheme, set your signing team, and run (`⌘R`). Swift packages resolve automatically.

Command-line builds:

```bash
./build.sh                                  # unsigned Debug build
./scripts/package-release.sh ~/Desktop      # Release build, repaired + signed
```

`package-release.sh` signs with the first Developer ID Application identity in your keychain, or ad-hoc if there is none. Override with `SIGN_ID="..."`, notarize with `NOTARY_PROFILE=<notarytool profile>`, and add `ZIP=1` to also produce a release zip.

## Tests

```bash
xcodebuild test -project VebeVoice.xcodeproj -scheme VebeVoice \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

bash Tests/AudioCaptureLifecycle/run.sh     # hardware-free audio capture lifetime test
```

The ten-minute long-session test is skipped unless its synthetic fixture exists. Generate it with `bash Tests/VebeVoiceDictationIntegrationTests/Resources/make-long-session-fixture.sh` (needs macOS speech services and a cached Parakeet v2 model).

## Project layout

```
VebeVoice/
├── VebeVoice.xcodeproj
├── Package.swift                 # SwiftPM manifest (FluidAudio, transcribe-cpp-swift)
├── Info.plist
├── VebeVoice.entitlements
├── Sources/
│   ├── VebeVoice/
│   │   ├── Services/             # ASR providers, audio capture, hotkeys, typing, local API
│   │   ├── Persistence/          # settings, history, dictionary stores
│   │   ├── UI/, Views/, Theme/   # SwiftUI screens, overlays, design tokens
│   │   └── Networking/           # model downloads
│   └── CoreAudioCaptureSupport/  # C helpers for Core Audio capture
├── Tests/
└── scripts/
```

## Contributing

Issues and pull requests are welcome. Please keep changes focused, run the tests above, and format with `scripts/format-and-lint.sh` before opening a PR. By contributing you agree your work is licensed under GPLv3.

## License

VebeVoice is free software under the [GNU General Public License v3.0](LICENSE). It is a modified version of FluidVoice by altic-dev; see [NOTICE](NOTICE) for attribution and third-party details.
