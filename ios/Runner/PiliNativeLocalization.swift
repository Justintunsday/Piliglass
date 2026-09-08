import Foundation

/// Returns a native UI string from the app's current iOS localization.
///
/// The Chinese source text remains the key so an untranslated Chinese install
/// keeps the existing copy. iOS selects `en.lproj` when English is selected in
/// the system or in the per-app language settings.
@inline(__always)
func piliLocalized(_ key: String) -> String {
  NSLocalizedString(key, tableName: "Localizable", bundle: .main, value: key, comment: "")
}

func piliNativeIsEnglish() -> Bool {
  let preferred = Bundle.main.preferredLocalizations.first
    ?? Locale.preferredLanguages.first
    ?? "zh-Hans"
  return preferred.lowercased().hasPrefix("en")
}

/// Localizes a format string while preserving the caller's numeric arguments.
func piliLocalizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
  let locale = piliNativeIsEnglish() ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
  return String(format: piliLocalized(key), locale: locale, arguments: arguments)
}

/// Localizes app-owned messages received from the Flutter bridge.
///
/// Call only for app-owned labels and status/error messages. Never pass
/// user-authored titles, comments, names or chat content to this function.
func piliLocalizedDisplay(_ value: String) -> String {
  let exact = piliLocalized(value)
  if exact != value { return exact }

  // A few bridge errors append an underlying error after an app-owned prefix.
  // Translate the prefix and preserve the diagnostic detail.
  let prefixes = [
    "Aether 视频轨道载入失败：",
    "AetherEngine 初始化失败：",
    "音轨播放失败：",
    "聊天记录加载失败：",
    "加载失败：",
    "登录状态检查失败：",
    "消息加载失败：",
    "离线缓存读取失败：",
    "缓存操作失败：",
    "离线视频打开失败：",

  ]
  for prefix in prefixes where value.hasPrefix(prefix) {
    return piliLocalized(prefix) + value.dropFirst(prefix.count)
  }
  return value
}

func piliNativeMessageIsError(_ value: String) -> Bool {
  let lowercased = value.lowercased()
  return value.contains("失败")
    || value.contains("错误")
    || value.contains("登录")
    || lowercased.contains("failed")
    || lowercased.contains("error")
    || lowercased.contains("sign in")
}
