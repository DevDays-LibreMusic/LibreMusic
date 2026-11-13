---
name: mornye-android-build
description: Build and verify Mornye Android APKs using the pinned Flutter and native toolchain. Use when asked to build, rebuild, package, or verify an Android artifact for this repository.
---

# Build Mornye for Android

Work from the repository root and read `AGENTS.md` first. Preserve uncommitted changes and never run Flutter tests concurrently with the build.

## 1. Configure the toolchain

The following defaults match the supported local macOS environment. On another
machine, install the pinned tools and set the corresponding paths explicitly.
For updates, pass the installed build's certificate SHA-256 with
`--expected-certificate`; never use another contributor's private signing key.

```bash
export JAVA_HOME="$HOME/.local/share/mise/installs/java/temurin-25.0.5+8.0.LTS/Contents/Home"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/30.0.16248370"
export MORNYE_RUST_ANDROID_ABIS=arm64-v8a
```

Confirm FVM uses the version in `.fvmrc`. Do not replace it with an arbitrary system Flutter installation.

## 2. Check and commit the intended scope

Use `python3 scripts/check_local_changes.py --list AREA` to inspect focused checks
for `lastfm`, `playback`, `logging`, or `build`; run the relevant areas and review
the diff. Native changes additionally require the relevant Cargo tests and
`scripts/check_rust_backend.sh`. Check failures are not automatic exemptions. Preserve unrelated work and never stage secrets or
artifacts. Commit the intended source, tests, and build changes before delivery.
Do not fabricate retrospective commits for previous APKs. Explicit user
instructions take precedence.

### Select meaningful checks

`python3 scripts/check_local_changes.py --list AREA` prints the commands;
`--run AREA` runs them sequentially and stops at the first failure. Default is
listing only. Select areas from the actual diff, not every area for every change.

| Area | Coverage |
| --- | --- |
| `lastfm` | Response/cache/settings, exact identity, selected row, Home integration |
| `playback` | Current/next scheduling, completed-path handoff, runtime and source metadata |
| `logging` | Bounded diagnostics, redaction, UTF-8 file attachments |
| `build` | Python delivery and APK safeguards; does not build Android |

Add checks for other touched code. Large cross-cutting changes warrant the full
Flutter suite; repeated full-suite runs are unnecessary after a small change's
meaningful checks pass. Keep public provider fixtures with provenance rather than
replacing real response-shape evidence with only mocks. A missing exact match does
not prove catalog absence; test retrieval, identity, download and playback separately.
Completed downloads can disappear from queue state immediately, so regression
coverage must include the final local/SAF handoff rather than only queue presence.

### Release acceptance and failure evidence

Stabilize on a feature/fix branch. Before integrating into upstream `main`, run the
full Flutter analysis/test suite, applicable Rust checks, review the final diff,
and audit an APK built from the approved commit. Ordinary small iteration still
uses focused checks. Integrate with a fast-forward or an explicitly reviewed
merge, preserving existing history; do not push without authorization.

When checks fail, record command, source commit, test name and error. Compare an
isolated baseline when needed; fix relevant defects instead of accumulating
permanent skip lists. Report failures and skipped/device-only checks separately.

## 3. Deliver a local debug APK from that commit

For the personal side-by-side installation, use the guarded command below. Select
check areas relevant to the change (multiple `--check-area` flags are supported):

```bash
python3 scripts/deliver_android_debug.py --model-root /path/to/local-model-exports --check-area build --check-area logging
```

The debug delivery is self-contained: both pinned ONNX exports ship as ordinary
Android assets and are prepared automatically on first comparison. The developer
must supply `--model-root` (or `LIBREMUSIC_MODEL_ROOT`) containing
`wavlm/wavlm-layer6-fp32.onnx` and `demucs/htdemucs-trunk-fp32.onnx`.
`scripts/audio_version_model_pins.json` records exact lengths and SHA-256 values.
No downloads run. Missing or altered inputs stop delivery before SDK/check/build
work; CI must supply those same exports explicitly. The helper stages validated
links in ignored `android/app/.bundled-model-assets/`, avoiding another copy of
the 390 MB inputs. Source exports must remain available and unchanged until the
build finishes. Do not commit binaries or staged links.

The APK audit requires exactly both pinned model entries, hashes their actual ZIP
streams, rejects additional ONNX/training/debug tensors, and records input and APK
entry evidence plus `self_contained_models: true` in the delivery JSON. Other
native, signing, package, ABI and source checks still apply.

It rejects dirty source, locks concurrent deliveries, checks pinned FVM, applies
and verifies the repository SDK patch, restores dependencies with an enforced
lockfile, runs and records selected checks, then performs config-only **after**
those tests. The manifest fingerprints the patch and patched SDK source file. It builds
current Rust inputs and ARM64 Lite debug APK, checks package `com.zarz.mornye.debug`,
optional expected signing certificate, source marker, native payload and compact ZIP
packaging. It preserves previous Downloads artifacts and writes a JSON manifest
with source commit/tree, actual command results, APK hash/size, certificate and
payload evidence. Keep APK and manifest together. Report only checks actually run,
including failures/skips and device-only gaps; a prior pass is not evidence for
later edits. The manifest does not prove device behavior or a green full suite.
Do not run other tests/build commands concurrently outside this wrapper's lock.

## 4. Official/local release builds remain separate

The existing release script retains its original supported variants:

```bash
# After all tests, with the environment above:
fvm flutter build apk --config-only
bash scripts/build_android.sh --lite
shasum -a 256 build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
"$ANDROID_HOME/build-tools/37.0.0/apksigner" verify --verbose --print-certs \
  build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Do not use the debug delivery wrapper for an official release. Before delivering
any APK, build the exact committed source by default and report source commit,
build marker, APK path, SHA-256, size, variant and validated checks. The release
script's payload audit must pass; verify APK Signature Scheme v2. Debug signing
updates only a matching local certificate, never bypasses an official signature.

## Avoid incremental debug APK size inflation

Before distributing a debug APK, compare its total size with the sum of ZIP entry compressed sizes. Android incremental packaging can retain large unused gaps after changed native libraries or Dart kernels; this is not application payload growth.

For a fresh debug package, preserve the previous APK outside build outputs, remove only `build/app/intermediates/incremental/packageDebug`, `build/app/outputs/apk/debug`, and the generated `build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk`, then rerun the identical Flutter debug build command (including Dart defines). Do not clean unrelated release outputs or the Rust build cache. Verify the new signature, package/ABI and compare uncompressed ZIP entry hashes with the previous APK when no source changes were intended.
