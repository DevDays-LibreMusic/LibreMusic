# On-device audio version comparison

Open a track's options and choose **Compare audio versions**. Search the configured,
enabled extensions that provide both metadata and downloads. Select two exact
provider items (A and B) representing the same performance. The app downloads each
selected item directly, with provider fallback disabled. It rejects a result whose
actual provider/item differs from the selection. Audio processing runs on the phone;
there is no analysis server or audio upload.

The self-contained Android APK includes both pinned ONNX models:

| Model | Bytes | SHA-256 |
| --- | ---: | --- |
| WavLM layer 6 | 216152021 | `594a8aa0be7b036a14ac8b8d15e588b0f388295fbc026bc2acaed6ae983205eb` |
| HTDemucs trunk | 174263852 | `273be7e599749c71ef29b6f34c20721937c336aa85b3e1f2fde5b57a987f07ba` |

On the first comparison, the app streams the bundled assets into its private model
store, validating length and SHA before atomic publication. A valid stored model is
reused without copying the asset again. No separate files, imports or model downloads
are required. Preparation reports progress and can be cancelled; a partial or damaged
model never produces a preferred side. Playback startup does not prepare models or
start inference. Both recordings must be 13 seconds to 10 minutes long.

Alignment and bounded DSP analysis locate candidate changes. WavLM verifies content
changes; HTDemucs separates local stereo contexts and compares vocal energy against
a shared baseline. Only consistent, supported vocal loss produces a preferred side.
Opposing edits, unreliable alignment, missing baseline, unavailable models, or
uncertain direction do not produce a preference. Identical audio does not prove an
uncensored original. Word replacements that retain similar vocal energy may remain
unknown: the experimental Python ASR branch has not been ported to this feature.

The result applies to the compared recordings and confirmed intervals. It is not a
global claim that either track is uncensored. If a direction is supported, choose
**Use the more complete recording for this pair**. Future playback of either exact
provider item uses the retained analyzed recording. Both file hashes and model /
algorithm versions must still match. A changed or missing retained recording
invalidates the preference and normal playback resolution resumes. The user can
also compare two local files from a local track's metadata menu; content-URI inputs
can be analyzed, but a persistent local-file preference requires accessible files.

Leaving an unsaved provider comparison releases its owned downloads. Cancellation
rejects stale analysis results and releases temporary model outputs. Host tests and
model parity checks do not prove phone memory, latency or playback behavior; those
require device validation.
