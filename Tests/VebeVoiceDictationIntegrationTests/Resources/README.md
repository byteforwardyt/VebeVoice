# Dictation audio fixture

`dictation_fixture.wav` is a short, deterministic fixture used by the CI end-to-end dictation integration test. It is synthesized speech (macOS `say`) of the phrase "hello vibe voice".

If you need to regenerate/replace it, keep it:
- WAV, mono, 16kHz, 16-bit PCM
- ~2–4 seconds
- phrase similar to: "hello vibe voice"

Regenerate with:

```sh
say -v Samantha -o fixture.aiff "hello vibe voice"
afconvert -f WAVE -d LEI16@16000 -c 1 fixture.aiff dictation_fixture.wav
```
