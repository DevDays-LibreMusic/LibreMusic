# Exact mobile export protocol

These exporters preserve the original recovery protocol: Python 3.12, pinned CPU
PyTorch/Transformers/Demucs/ONNX versions from `requirements.txt`, legacy TorchScript
ONNX export (`dynamo=False`), opset 17, FP32 and no external tensor data. WavLM
retains six encoder layers and is checked against full-model `hidden_states[6]`.
Demucs retains the exact real neural trunk with its native FFT boundary split.
The deterministic synthetic PCM fixture and numerical reconstruction checks are
part of the recovery, not user audio. Demucs uses the HF-only loader so failure
cannot silently download a different legacy checkpoint.

`sources.json` records official repository revisions, input hashes and upstream
license references. `../audio_version_model_pins.json` independently records the
required output lengths and hashes. Source downloads are temporary; the cache
contains exports, and every restore is hashed before ignored Android asset links
are staged. A different platform graph serialization or computed weight is a hard
failure; changing expected hashes to make CI pass is not a recovery procedure.
CI audits the actual APK ZIP streams after both debug and release builds.

`python3 scripts/bootstrap_audio_version_models.py --model-root PATH` verifies
existing exports, or recovers absent exports with the pinned environment. It also
accepts `LIBREMUSIC_MODEL_ROOT` and defaults to `~/.cache/libremusic/mobile-models`.
`--require-existing` verifies a cache restore without downloading. This script
never substitutes other model artifacts or publishes model binaries.
