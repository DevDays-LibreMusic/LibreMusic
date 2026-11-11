# Local recommendation profiles

Profiles are available in Settings > Playback > My recommendations. They build
mixes from downloaded files, enabled local Library sources and durable assets
saved from the connected music server. Selecting a profile for Library Autoplay
applies its filters to future automatic additions. Autoplay itself must also be
enabled.

## Recommendation flow

Home > Recommendation flow offers genre chips from local metadata and four
multi-select mood presets. Genre and mood constraints intersect; selections
within each group are alternatives. Mood is a coarse genre-based heuristic,
not an audio emotion classifier. Unknown genres do not match a selected mood.

Changing chips refreshes the preview after a short debounce. A generation guard
rejects stale responses. Listen to flow saves the reserved `recommendation_flow`
profile, activates it for Autoplay, enables Autoplay, disables shuffle/repeat and
replaces the queue. Filter changes do not interrupt playback until applied.
The additive `moods` JSON field defaults to an empty list in older profiles;
no database schema migration is required.

## Pipeline

`LibraryQueueStore.recommendationPage` reads narrow, seek-paged metadata rows.
SQL applies duration/year/explicit filters; exact genre, artist, directory,
playlist, exclusion and listening-history predicates run before a uniform
500-candidate reservoir. No fallback broadens filters. Selection is ranked in a
worker isolate, deduplicated by normalized artist/title and checked for file
access. Results can contain fewer than the requested 20 songs.

The engine combines familiarity, discovery, artist history, reference-track
metadata and optional existing audio-analysis features. Artist repetition is
penalized while selecting the list. It reuses the bounded logistic ranker from
`autoplay_ranker.dart`; learned multipliers are constrained to 0.5 through 1.5.
A preference set to zero stays zero. An empty history uses initial weights.

`recommendations.db` version 1 stores profiles and at most 2,000 feedback rows
across all profiles. Feedback is scoped to profile ID and settings revision.
A settings edit starts a new learning revision. Reset advances the revision too,
so delayed outcomes cannot restore discarded learning. Playback feedback only
counts remembered suggestions carrying matching provenance. Explicit feedback
works without automatic listening personalization. Automatic feedback requires
that existing Playback setting to be enabled.

`AppSettings.recommendationProfileId` defaults to an empty string for existing
installations. An empty ID preserves ordinary Autoplay. A missing selected
profile fails closed instead of playing unfiltered suggestions.

## Boundaries

- Discovery means songs already in the local Library, not external catalog search.
- Music-server candidates use stored metadata and durable `musicserver://`
  identities. Generation never requests playback tickets; the player obtains a
  short-lived ticket only when a selected track is about to play. Entries from
  another or disconnected server account fail closed.
- Legacy explicit metadata records positive markings, not verified clean status.
  The corresponding filter only excludes marked tracks.
- Repeat windows use existing daily listening statistics; unrecorded plays cannot
  be inferred. Distinct recordings with identical normalized artist/title share
  history and exclusions.
- Folder filters use directory paths or hierarchical SAF document/tree URIs.
  Providers with opaque, non-hierarchical document IDs need a folder membership
  index before their trees can support this filter.
- Playlist membership is matched to local songs by normalized artist/title.
- Preview reference tracks last for that editor session. Autoplay uses the
  current song and queued songs as context.
- Sound matching reads existing features; generating a mix never starts audio
  decoding. Enable audio analysis separately in Playback settings.
- Candidate and outcome buffers are bounded. History aggregates and selected
  playlist membership scale with their stored data. Cold requests scan metadata
  pages, so total I/O scales with Library size.
- The proposed 200 ms / 20 MB device budgets are targets, not measured guarantees.
  Real Android/iOS profiling remains necessary.

Validation covers filter boundaries, unknown metadata, SQL pagination, sparse
matches beyond initial pages, persistence, revision isolation, cancellation,
unavailable files, cold starts, preference weights and editor validation.
