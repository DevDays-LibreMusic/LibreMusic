# LibreMusic streaming server

C++20/userver 3.2 API, SQLite catalog and durable jobs, disk media storage,
a Rust/QuickJS extension worker, and an Nginx media gateway. One API process
serves multiple users.
The Flutter client streams completed audio; it does not save server tracks or
prefetch full copies. Desktop playback uses an 8 MiB forward and 2 MiB backward
memory buffer. Native mobile playback uses the platform streaming buffer.

## Build and run

The Docker recipe currently targets Linux amd64. From the repository root:

```bash
mkdir -p server/private server/imports/alice
cp server/config/service.example.json server/private/service.json
docker compose -f server/compose.yaml build
docker compose -f server/compose.yaml run --rm -T --entrypoint music-admin music \
  /etc/music/private/service.json create-user alice < /path/to/password-file
docker compose -f server/compose.yaml up -d
```

The password file contains one password of at least 12 characters. Keep it
outside the repository and remove it after provisioning. Repeat `create-user`
for each account and add that username's sources to `private/service.json`.
The application has no public registration endpoint. The service never trusts
a client-supplied user ID. Each device receives its own session, with hashed
access/refresh tokens and rotating refresh tokens. Logging out revokes that
session's audio tickets as well.

Only the gateway publishes loopback port 8080. userver is internal to the
Compose network. It validates each ticket and returns an internal
`X-Accel-Redirect`; Nginx serves the authorized file with Content-Length, HEAD
and Range support. The `/_protected_media/` location cannot be requested
directly. Put an HTTPS reverse proxy in front of the gateway
for device access, preserving Range and HEAD. Disable proxy request/response
body logging, Authorization logging and access logging of `/v1/media/` ticket
paths. The client accepts HTTP only on loopback for development. The data volume
holds `catalog.sqlite3` (WAL), `media`, per-user extension state and staging.
Use a local filesystem for SQLite, even if imported music resides on a NAS.
Back up the entire data volume with the service stopped, or use SQLite's online
backup API and coordinate the media snapshot. Preserve each account's
`users/<id>/master.key` to retain encrypted extension credentials.

For native builds install userver 3.2 core development dependencies, SQLite3,
OpenSSL, libcurl, nlohmann-json, FFmpeg, Nginx, CMake and a C++20 compiler:

```bash
cmake -S server -B server/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build server/build -j2
ctest --test-dir server/build --output-on-failure
python3 server/tests/http_test.py --build server/build
```

`-DLIBREMUSIC_BUILD_HTTP=OFF` builds the core tests and administration CLI
without userver. HTTP handlers use the filesystem task processor; blocking
SQLite and password hashing do not block the main HTTP processor.
The downloader runs in a separate native thread and checks cancellation.

## Sources

Sources are configured by the operator per username, then advertised through
`GET /v1/sources`. Changing the config requires a service restart.

- `url`: HTTPS audio URLs on explicitly allowed hostnames. Connections are pinned
  to a validated public IPv4 address; redirects, proxies and private addresses
  are rejected. Configure the final audio host rather than a redirector.
- `storage`: a path relative to an operator-configured read-only root. Mount an
  existing NAS share on the server host and bind it under `server/imports`.
  The server copies requested files into its managed media library. SMB/WebDAV
  credential management and a server-side file browser are not implemented.
- `extension`: an existing `.mornye-ext` package executed by the repository's
  Rust/QuickJS runtime. Packages and settings are installed separately per user.
  Only the operator can configure packages, worker executable and settings files.

Example additional source in an account's list:

```json
{
  "id": "my-provider",
  "name": "My provider",
  "type": "extension",
  "provider_id": "example.audio",
  "package": "/etc/music/private/example.audio.mornye-ext",
  "settings_file": "/etc/music/private/alice-provider.json",
  "qualities": ["LOSSLESS"]
}
```

Use the installed package's actual manifest name and quality identifiers.
The settings file is a JSON object of the extension's setting values, such as
credentials established using its supported account flow. It is merged into
the account's encrypted runtime settings. No provider-specific checks are
introduced in the app. Extensions requiring interactive WebView/device auth
are not automatically compatible with headless operation. Unsupported host
requirements fail the job; test each intended extension before enabling it.
The worker runs FFmpeg host commands and supports the existing `ffmpeg.mov_key`
decryption descriptor. Other decryption strategies fail without publication.

Build and test the worker with the repository-pinned Rust toolchain:

```bash
cd rust_backend
cargo build --locked -p mornye-extensions --bin music-extension-worker
cd ..
python3 server/tests/http_test.py --build server/build \
  --worker rust_backend/target/debug/music-extension-worker
```

The HTTP test generates a tiny local audio fixture and a generic extension;
it does not download music from external providers or use real credentials.
MP3, FLAC and raw AAC retain their containers. Other supported formats are
converted to FLAC on the server before publication. This may increase server
storage for lossy inputs; it does not increase their original audio quality.

## API and app

| Method | Route | Purpose |
| --- | --- | --- |
| POST | `/v1/auth/login` | Username/password to device session |
| POST | `/v1/auth/refresh` | Rotate refresh and access tokens |
| POST | `/v1/auth/logout` | Revoke device session and its media tickets |
| GET | `/v1/sources` | Account's configured sources and qualities |
| POST | `/v1/playback/prepare` | Return existing audio or queue preparation |
| GET | `/v1/downloads?offset=0` | Account's jobs, 100 per page |
| GET | `/v1/downloads/{id}` | State, byte progress and error code |
| POST | `/v1/downloads/{id}/cancel` | Cancel a queued or active job |
| GET | `/v1/tracks?offset=0` | Ready tracks, 100 per page |
| GET | `/v1/tracks/{id}` | Track metadata |
| POST | `/v1/assets/{id}/playback-ticket` | One-hour bearer playback URL |
| GET, HEAD | `/v1/media/{ticket}` | Audio, supports a single byte range |
| GET | `/health` | Process health |

Authenticated requests use `Authorization: Bearer <access_token>`. Preparation:

```json
{
  "source": {"connection_id": "collection", "path": "Artist/Track.flac"},
  "quality": "original",
  "title": "Track",
  "artist": "Artist"
}
```

For URL sources replace `path` with `url`; for extensions use `track_id`.
Preparation returns 202 while pending and 200 when ready, with an `id` and
`state`. Deduplication is per user, source, track and quality. Repeating a
failed or cancelled request retries it after cleanup. States are `queued`,
`resolving`, `downloading`, `processing`, `ready`, `failed`, `cancelled`.
No API response exposes server paths, source credentials or extension keys.

In LibreMusic open Settings > Music server, enter the HTTPS origin and sign in.
Select a source and enter its URL, relative path or provider track ID. The
track's "Listen" button and menu action prepare it on the server and start
streaming when it is ready. If needed, sign in first; the requested track is
retained. A server error or missing source never falls back to a local download.
Listen uses the matching extension source's first configured quality; the
server screen allows manual selection. "Download" always uses the existing
local queue and quality picker, independently of the server connection.
Preparation continues with the app closed. Refresh the server library to see
completed jobs. Pressing Play resolves a fresh ticket from the stable account
and asset identity. There is no offline save action in this screen.

Use "Add to library (streaming)" in a track's menu to prepare it on the server
and add it to the app's main Library without starting playback. Ready tracks on
the server screen also have an Add to library button. Only metadata and the
stable `musicserver://` reference are stored in the app's `local_library.db`;
audio stays on the server. Repeated adds are idempotent per account and asset.
Library playback obtains a fresh ticket, including after an app restart, and
does not substitute a matching local file. Server references remain indexed
while offline and are not removed by missing-file cleanup. The selection is
local to this app installation; it is not a cross-device favorites sync.

## Operational limits

One process owns the database and runs one download at a time, alternating
between users when possible. Queue and byte limits are configurable. Restart
requeues interrupted jobs up to three attempts; interrupted audio transfers
restart from the beginning. Source errors remain visible until explicitly
retried. Only complete files are atomically published; unfinished files are
not served. Nginx transfers media without buffering whole files in the API
process. The service is not a progressive proxy for incomplete provider downloads.

The initial API does not include account deletion, media deletion, shared
playlists, live provider search or an extension installation UI. Account and
source provisioning is operator-managed. Real provider compatibility and
playback on Android/iOS require validation in the target deployment.
