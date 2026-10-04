import 'dart:io';

/// The container shape does not establish whether wire field boundaries survived.
enum SetCookieSource {
  separatedFields,
  dioLegacyPossiblyFolded,
  foundationCombined,
}

enum SetCookieIssueKind { recoveredFold, ambiguousBoundary }

final class SetCookieIssue {
  final SetCookieIssueKind kind;
  final int headerIndex;
  final int offset;

  const SetCookieIssue(this.kind, this.headerIndex, this.offset);
}

final class SetCookieSegment {
  final int headerIndex;
  // Offsets are Dart String code-unit offsets into the unchanged original field.
  final int start;
  final int end;
  final String value;

  const SetCookieSegment(this.headerIndex, this.start, this.end, this.value);
}

final class ParsedSetCookieHeaders {
  final SetCookieSource source;
  final List<String> rawValues;
  final List<SetCookieSegment> segments;
  final List<SetCookieIssue> issues;
  final List<Cookie> cookies;
  final bool cookiesDecoded;

  ParsedSetCookieHeaders._(
    this.source,
    Iterable<String> rawValues,
    Iterable<SetCookieSegment> segments,
    Iterable<SetCookieIssue> issues,
    Iterable<Cookie> cookies,
    this.cookiesDecoded,
  ) : rawValues = List.unmodifiable(rawValues),
      segments = List.unmodifiable(segments),
      issues = List.unmodifiable(issues),
      cookies = List.unmodifiable(cookies);

  // This is a representation gate, not proof of account/transport compatibility.
  bool get nativePersistenceSupported =>
      cookiesDecoded && source != SetCookieSource.dioLegacyPossiblyFolded &&
      !issues.any((issue) => issue.kind == SetCookieIssueKind.ambiguousBoundary);

  List<Cookie> get cookiesForNativePersistence {
    if (!nativePersistenceSupported) {
      throw const UnsupportedSetCookieRepresentation();
    }
    return cookies;
  }
}

final class UnsupportedSetCookieRepresentation implements Exception {
  const UnsupportedSetCookieRepresentation();
  @override
  String toString() => 'Unsupported Set-Cookie representation';
}

/// Decode the whole batch before the caller writes anything into its CookieJar.
/// Malformed segments keep Cookie.fromSetCookieValue's existing error behavior.
ParsedSetCookieHeaders parseResponseCookieHeaders(
  Iterable<String> values, {
  required SetCookieSource source,
}) {
  final rawValues = List<String>.of(values);
  final segments = <SetCookieSegment>[];
  final issues = <SetCookieIssue>[];
  for (var fieldIndex = 0; fieldIndex < rawValues.length; fieldIndex++) {
    final field = rawValues[fieldIndex];
    if (field.isEmpty) continue;
    if (source == SetCookieSource.separatedFields) {
      segments.add(SetCookieSegment(fieldIndex, 0, field.length, field));
      continue;
    }
    var start = 0;
    var lastSemicolon = -1;
    var quotedPair = false;
    for (var offset = 0; offset < field.length; offset++) {
      final code = field.codeUnitAt(offset);
      // Quotes only group the initial cookie-pair. Attribute quotes are literal;
      // Path="/p, b=2" must still be recognized as ambiguous combined input.
      if (code == 34 && lastSemicolon < start) quotedPair = !quotedPair;
      if (quotedPair) continue;
      if (code == 59) lastSemicolon = offset;
      if (code != 44 || !_startsCookiePair(field, offset + 1)) continue;
      issues.add(SetCookieIssue(SetCookieIssueKind.recoveredFold, fieldIndex, offset));
      // A candidate anywhere in an attribute span is conservatively ambiguous:
      // Path/extensions permit commas, and permissive date parsers can ignore
      // trailing tokens. Successful decoding cannot recover original boundaries.
      if (lastSemicolon >= start) {
        issues.add(SetCookieIssue(SetCookieIssueKind.ambiguousBoundary, fieldIndex, offset));
      }
      segments.add(SetCookieSegment(fieldIndex, start, offset, field.substring(start, offset)));
      start = offset + 1;
      lastSemicolon = -1;
    }
    if (start < field.length) {
      segments.add(SetCookieSegment(fieldIndex, start, field.length, field.substring(start)));
    }
  }
  if (source == SetCookieSource.foundationCombined &&
      issues.any((issue) => issue.kind == SetCookieIssueKind.ambiguousBoundary)) {
    // Speculative segments are not actual wire cookies. Keep their ranges for
    // inspection, without throwing or presenting a partially decoded batch.
    return ParsedSetCookieHeaders._(source, rawValues, segments, issues, const [], false);
  }
  final cookies = segments.map((segment) => Cookie.fromSetCookieValue(segment.value)).toList();
  return ParsedSetCookieHeaders._(source, rawValues, segments, issues, cookies, true);
}

bool _startsCookiePair(String field, int offset) {
  while (offset < field.length && _isWhitespace(field.codeUnitAt(offset))) {
    offset++;
  }
  final start = offset;
  while (offset < field.length && _isToken(field.codeUnitAt(offset))) {
    offset++;
  }
  if (offset == start) return false;
  while (offset < field.length && _isWhitespace(field.codeUnitAt(offset))) {
    offset++;
  }
  return offset < field.length && field.codeUnitAt(offset) == 61;
}

bool _isWhitespace(int code) => code == 32 || code == 9;

bool _isToken(int code) =>
    (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) ||
    const [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains(code);
