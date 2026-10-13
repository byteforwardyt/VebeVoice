# Audio capture lifetime regression

Run from the project root:

```bash
bash Tests/AudioCaptureLifecycle/run.sh
```

This compiles the production `DirectCoreAudioInput.swift` with a simulated C
capture backend. The handler is deliberately held past the stop timeout. The
test checks that restart is rejected while draining, repeated invalidation is
safe, and the ring is destroyed exactly once only after the worker exits.
The fake backend marks destruction instead of freeing memory so stale accesses
can be counted deterministically. It does not use microphone hardware.
