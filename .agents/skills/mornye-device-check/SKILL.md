---
name: mornye-device-check
description: Safely install a Mornye Android build and validate streaming playback or backup restoration on a connected device. Use for adb installation, on-device verification, signature mismatches, or manual regression testing.
---

# Check Mornye on an Android device

Read root `AGENTS.md` first. Build and verify the APK with the
[Android build skill](../mornye-android-build/SKILL.md). Installation and external
sharing require authorization; this skill does not expand a read-only task.

## Protect app data

- Use `adb install -r <apk>` to update an existing compatible installation.
- Never uninstall Mornye, use `pm clear`, or erase app data to bypass a signature mismatch without explicit user approval and a verified backup.
- An official Mornye installation cannot be updated with the local debug-signed APK. Stop and offer a side-by-side application ID or a properly signed build instead.
- A Mornye `.sflb` backup does not include downloaded audio files. Do not describe it as a complete data backup.

## Connect and install

```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
ADB="$ANDROID_HOME/platform-tools/adb"
"$ADB" devices
```

If no authorized device is listed, report that device verification is blocked. Do not claim playback or restore behavior was tested.

Install without removing existing data:

```bash
"$ADB" install -r "${APK_PATH:?Set APK_PATH to the verified delivery APK}"
```

If installation fails because signatures differ, stop. Do not uninstall automatically.

## Verify progressive playback

Use tracks and albums that are not already downloaded:

1. Start a track and confirm audible playback begins while download progress continues.
2. Let the download finish and confirm playback continues through the partial-file-to-final-file handoff.
3. Start an album from a middle track. Confirm that exact track starts, all tracks
   stay in the playback queue, and automatic downloads schedule only current and
   next. Skip and verify the window moves. Existing/manual downloads may continue;
   an explicit Download album action still requests the whole album.
4. Test pause, resume, seeking within downloaded data, cancellation, and moving to the next track.
5. Check encrypted or unrecognized downloads use the finalized-file fallback rather than playing invalid bytes.
6. Watch Mornye logs for HTTP range, source-resolution, download, and player errors.

Record real-provider startup timing and any player-specific failures. Passing widget or service tests is not a substitute for these checks.

## Verify backup restoration

1. Keep a second copy of the original `.sflb` file.
2. Restore it through Settings > Backup & Restore.
3. Confirm the success message rather than only checking that the file was accepted.
4. Restart Mornye and verify settings, history, liked items, playlists, and extensions included in that backup.
5. If restoration fails, capture the exact log entry. Do not retry by deleting app data.

Report each verified scenario separately and list anything not tested.

## Handoff and diagnostic logs

For music changes, compare the same track from wave, search and album, and include
an unavailable selected-track case: another track must not silently replace it.
For log sharing, check the receiver gets a readable `.txt` attachment. Record the
APK source commit/build marker and each tested scenario; request the attached
log file after a failure so reports are not confused across versions.

Keep useful stage/provider/status/correlation information while redacting keys,
cookies, signed URLs and private paths. Never share `.env`, authorization sessions
or raw request dumps. Report what the user observed separately from automated
checks; do not claim underlying provider availability is fixed from host tests alone.

After process restart, completed downloads can be recovered by their stable track
identity. Tracks that had only an in-memory pending-download reference and no
completed file are omitted from the restored queue; select them again from the
catalog or wave. Verify this separately from resume of a completed local track.
