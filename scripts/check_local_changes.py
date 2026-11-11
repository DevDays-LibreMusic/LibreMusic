#!/usr/bin/env python3
"""List or run focused checks. Never builds, commits, or skips failing checks."""
import argparse
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]

# Explicit test lists keep selection reviewable; this is not automatic coverage.
TESTS = {
    "lastfm": [
        "lastfm_wave_service", "lastfm_wave_resolver",
        "lastfm_account_service", "lastfm_account_controller",
        "lastfm_account_provider", "wave_session_controller", "wave_session_startup",
        "wave_listening_observer", "wave_audio_cache", "playable_wave_metadata",
        "lastfm_wave_card", "lastfm_wave_selection", "home_search_tabs",
    ],
    "playback": [
        "download_playback", "music_player_runtime", "playlist_playback",
        "album_track_metadata", "track_model", "collection_header_actions",
        "playback_path_resolution", "music_player_playback_failures",
    ],
    "logging": ["playback_diagnostics", "log_share_service"],
}
SOURCES = {
    "lastfm": ["lib/services/lastfm_wave_service.dart",
               "lib/services/lastfm_wave_resolver.dart",
               "lib/providers/lastfm_account_provider.dart",
               "lib/providers/wave_session_provider.dart",
               "lib/models/wave_session.dart",
               "lib/services/lastfm_account_service.dart",
               "lib/services/lastfm_account_controller.dart",
               "lib/services/wave_audio_cache.dart",
               "lib/services/wave_listening_observer.dart",
               "lib/widgets/lastfm_account_sheet.dart",
               "lib/widgets/wave_controls.dart",
               "lib/widgets/lastfm_wave_card.dart"],
    "playback": ["lib/services/download_playback.dart",
                 "lib/providers/download_playback_provider.dart",
                 "lib/providers/playback_provider.dart",
                 "lib/services/music_player_service.dart",
                 "lib/models/track.dart"],
    "logging": ["lib/services/playback_diagnostics.dart",
                "lib/services/log_share_service.dart", "lib/utils/logger.dart",
                "lib/screens/settings/log_screen.dart"],
}
AREAS = (*TESTS, "build")


def commands(area):
    if area == "build":
        return [["python3", f"scripts/test_{module}.py"]
                for module in ("check_local_changes", "deliver_android_debug",
                               "build_android", "check_backend_apk")]
    paths = [f"test/{name}_test.dart" for name in TESTS[area]]
    return [
        ["fvm", "dart", "format", "--output=none", "--set-exit-if-changed",
         *SOURCES[area], *paths],
        ["fvm", "flutter", "analyze", "--no-pub", *SOURCES[area], *paths],
        ["fvm", "flutter", "test", "--no-pub", *paths],
    ]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--list", action="store_true", help="print commands (default)")
    mode.add_argument("--run", action="store_true", help="run sequentially; stop on failure")
    parser.add_argument("area", choices=AREAS)
    args = parser.parse_args(argv)
    for command in commands(args.area):
        print(shlex.join(command), flush=True)
        if args.run:
            result = subprocess.run(command, cwd=ROOT, check=False)
            if result.returncode:
                return result.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
