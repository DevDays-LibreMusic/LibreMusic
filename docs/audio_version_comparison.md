# Local audio version comparison

From a local track's menu, select **Compare audio versions**, choose a second
local file and start explicitly. FFmpeg decodes the complete recordings into
mono 16 kHz float32 PCM. Each recording must be 13–600 seconds. Network inputs
are rejected; no audio or embeddings are uploaded.

Rust performs alignment and generates acoustic candidates. Without the optional
model, these remain candidates requiring review. On Android, import the pinned
WavLM layer-6 ONNX file explicitly using the comparison screen. It is not bundled
or downloaded by the app. The accepted file is exactly 216152021 bytes with SHA-256
`594a8aa0be7b036a14ac8b8d15e588b0f388295fbc026bc2acaed6ae983205eb`.

The learned boundary receives app-owned raw, zero-padded 12-second PCM contexts
(192000 little-endian float32 samples). Rust reports `normalization: runtime`;
Kotlin performs the single normalization with epsilon 1e-7 before CPU ONNX
inference. A and B execute sequentially with two intra-op threads. Output shape
is `[1,599,768]`. Rust validates the pinned digest and applies the local-baseline
content verifier. Its result can confirm a **content change**, never which side
is censored. `preferred_side` remains null and the absolute uncensored status
remains unknown. Demucs and lexical verification are not implemented here.

Contexts run sequentially, one candidate at a time, with a maximum of 64 candidates.
Events longer than ten seconds and larger candidate sets remain inconclusive.
Cancellation rejects stale results and releases owned PCM/embedding files after
workers finish. Imported model files are streamed, hash checked and atomically
replaced; a failed replacement preserves the previously valid model.

Tests use synthetic audio and numeric exporter goldens; no copyrighted recordings,
model weights or real-track debug arrays belong in source or APK assets. Host
unit tests and numeric parity do not establish latency, memory use or correctness
of file picking/inference on a physical Android phone. Device verification remains
required before claiming those properties.
