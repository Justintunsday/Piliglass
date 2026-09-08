import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:intl/intl.dart' show DateFormat;

abstract final class DateFormatUtils {
  static final shortFormat = DateFormat('MM-dd');
  static final longFormat = DateFormat('yyyy-MM-dd');
  static final _shortFormatD = DateFormat('MM-dd HH:mm');
  static final longFormatD = DateFormat('yyyy-MM-dd HH:mm');
  static final longFormatDs = DateFormat('yyyy-MM-dd HH:mm:ss');

  /// The native iOS surface and the Flutter bridge both follow the same
  /// supported-language fallback: Chinese wins when it appears before English
  /// in the user's preferences, and English is the fallback for other locales.
  /// Keep this check in one place for relative dates and compact counts sent to
  /// native views.
  static bool get isEnglish {
    if (!Platform.isIOS) return false;
    for (final locale in ui.PlatformDispatcher.instance.locales) {
      final languageCode = locale.languageCode.toLowerCase();
      if (languageCode == 'en') return true;
      if (languageCode == 'zh') return false;
    }
    return true;
  }

  static String _minutesAgo(int value) =>
      isEnglish ? '$value ${value == 1 ? 'minute' : 'minutes'} ago' : '$value分钟前';

  static String _hoursAgo(int value) =>
      isEnglish ? '$value ${value == 1 ? 'hour' : 'hours'} ago' : '$value小时前';

  static String dateFormat(
    int? time, {
    DateFormat? short,
    DateFormat? long,
  }) {
    if (time == null || time == 0) {
      return '';
    }

    final now = DateTime.now();
    final date = DateTime.fromMillisecondsSinceEpoch(time * 1000);
    final diff = now.difference(date);

    final diffInMins = diff.inMinutes;
    if (diffInMins < 1) return isEnglish ? 'Just now' : '刚刚';
    if (diffInMins < 60) return _minutesAgo(diffInMins);

    final diffInHours = diff.inHours;
    if (diffInHours < 24) return _hoursAgo(diffInHours);

    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(date.year, date.month, date.day);
    final dayDiff = today.difference(dateDay).inDays;
    if (dayDiff == 1) {
      return '${isEnglish ? 'Yesterday' : '昨天'} ${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';
    }
    if (dayDiff < 4) {
      return isEnglish
          ? '$dayDiff ${dayDiff == 1 ? 'day' : 'days'} ago'
          : '$dayDiff天前';
    }
    final DateFormat sdf = now.year == date.year
        ? short ?? shortFormat
        : long ?? longFormat;
    return sdf.format(date);
  }

  static String _twoDigits(int n) => n.toString().padLeft(2, '0');

  static String chatFormat(int? time, {bool isHistory = false}) {
    if (time == null || time == 0) {
      return '';
    }

    final now = DateTime.now();
    final date = DateTime.fromMillisecondsSinceEpoch(time * 1000);

    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(date.year, date.month, date.day);
    if (today == dateDay) {
      return '${isHistory && !isEnglish ? '今天 ' : isHistory ? 'Today ' : ''}${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';
    }
    final isYesterday = today.subtract(const Duration(days: 1)) == dateDay;
    if (isYesterday) {
      return '${isEnglish ? 'Yesterday' : '昨天'} ${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';
    }
    if (isHistory) {
      final DateFormat sdf = now.year == date.year
          ? _shortFormatD
          : longFormatD;
      return sdf.format(date);
    }
    return longFormatD.format(date);
  }

  static String format(int? time, {DateFormat? format}) {
    if (time == null || time == 0) {
      return '';
    }
    final date = DateTime.fromMillisecondsSinceEpoch(time * 1000);
    return (format ?? longFormatD).format(date);
  }

  /// Server reply controls are commonly localized Chinese strings. When the
  /// app is English, use the numeric timestamp if the server text still
  /// contains Chinese; user-authored text is never passed through this helper.
  static String localizedServerTime(String? serverText, int? timestamp) {
    if (serverText != null && serverText.isNotEmpty) {
      final containsChinese = serverText.runes.any(
        (rune) => rune >= 0x4E00 && rune <= 0x9FFF,
      );
      if (!isEnglish || !containsChinese) return serverText;
    }
    return format(timestamp);
  }
}
