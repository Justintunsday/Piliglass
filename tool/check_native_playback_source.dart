// Run with: dart tool/check_native_playback_source.dart
import '../lib/utils/native_playback_source.dart';

void expectEqual(Object? actual, Object? expected, String description) {
  if (actual != expected) {
    throw StateError('$description: expected $expected, got $actual');
  }
}

void main() {
  const raw = 'https://origin.example/video?sign=a%2Fb&deadline=123';
  const backup = 'https://backup.example/video?sign=a%2Fb&deadline=123';
  const selected = 'https://selected.example/video?sign=a%2Fb&deadline=123';
  expectEqual(
    nativePlaybackUrls(
      [raw, backup, raw, ''],
      preferredUrl: selected,
      preferSelectedSource: false,
    ).join('|'),
    [raw, selected, backup].join('|'),
    'Automatic mode keeps signed origin first and removes duplicates',
  );
  expectEqual(
    nativePlaybackUrls(
      [raw, backup],
      preferredUrl: selected,
      preferSelectedSource: true,
    ).join('|'),
    [selected, raw, backup].join('|'),
    'Manual CDN is used before the unchanged fallback URLs',
  );
  expectEqual(
    nativePlaybackUrls(
      [raw, backup],
      preferredUrl: backup,
      preferSelectedSource: true,
    ).join('|'),
    [backup, raw].join('|'),
    'Independent audio prioritizes its backup without duplicating it',
  );
  expectEqual(
    nativePlaybackUrls([], preferredUrl: selected, preferSelectedSource: true).isEmpty,
    true,
    'No invented track when the API returns no URLs',
  );
  expectEqual(normalizeLiveCDN('  '), null, 'Blank restores automatic live routing');
  expectEqual(normalizeLiveCDN('cdn.example'), 'https://cdn.example', 'Default to HTTPS');
  expectEqual(normalizeLiveCDN(' https://cdn.example/ '), 'https://cdn.example', 'Trim input and slash');
  expectEqual(normalizeLiveCDN('http://cdn.example:8080'), 'http://cdn.example:8080', 'Keep valid ports');
  for (final invalid in [
    'https://cdn.example/live/stream.flv',
    'https://cdn.example?token=secret',
    'https://cdn.example#fragment',
    'https://user:password@cdn.example',
    'ftp://cdn.example',
    'https://',
    'https://bad host.example',
    'https://cdn.example:99999',
  ]) {
    try {
      normalizeLiveCDN(invalid);
    } on FormatException {
      continue;
    }
    throw StateError('Invalid live origin was accepted: $invalid');
  }
  print('Native playback source checks passed.');
}
