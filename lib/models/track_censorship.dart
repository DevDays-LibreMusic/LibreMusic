/// `clean` means non-explicit metadata or an edited title marker. A naturally
/// non-explicit song is not necessarily censored; only an exact explicit
/// counterpart can establish an alternative recording.
enum TrackCensorship { explicit, clean, unknown }

final _censorshipMarker = RegExp(
  r'(?:[\(\[]\s*(explicit|clean|edited|censored|uncensored)(?:\s+(?:version|edit))?\s*[\)\]]|(?:\s+[-–—:]\s*)(explicit|clean|edited|censored|uncensored)(?:\s+(?:version|edit))?\s*$)',
  caseSensitive: false,
);

TrackCensorship censorshipFor({bool? explicit, required String title}) {
  if (explicit != null) {
    return explicit ? TrackCensorship.explicit : TrackCensorship.clean;
  }
  final match = _censorshipMarker.firstMatch(title);
  if (match == null) return TrackCensorship.unknown;
  final marker = (match.group(1) ?? match.group(2))!.toLowerCase();
  return switch (marker) {
    'explicit' || 'uncensored' => TrackCensorship.explicit,
    'clean' || 'edited' || 'censored' => TrackCensorship.clean,
    _ => TrackCensorship.unknown,
  };
}

String withoutCensorshipMarker(String title) => title
    .replaceAll(_censorshipMarker, '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
