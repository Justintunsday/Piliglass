/// Orders candidates without modifying signed URLs, keeping every fallback.
List<String> nativePlaybackUrls(
  Iterable<String> urls, {
  required String preferredUrl,
  required bool preferSelectedSource,
}) {
  final raw = urls.where((url) => url.isNotEmpty).toList();
  if (raw.isEmpty) return const [];
  return <String>{
    if (preferSelectedSource && preferredUrl.isNotEmpty) preferredUrl,
    raw.first,
    if (preferredUrl.isNotEmpty) preferredUrl,
    ...raw.skip(1),
  }.toList();
}

/// The live player appends the stream path and signature to this origin.
/// Reject full stream URLs, credentials and queries rather than corrupt them.
String? normalizeLiveCDN(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      RegExp(r'[\s%]').hasMatch(uri.host) ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
    throw const FormatException('请输入 CDN 域名或 http(s) 地址，不要包含路径、参数或账号');
  }
  return uri.origin;
}
