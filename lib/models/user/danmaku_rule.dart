import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/models/user/danmaku_block.dart';

class RuleFilter {
  static final _regExp = RegExp(r'^/(.*)/$');

  static RegExp? compile(String pattern) {
    final normalized = _regExp.matchAsPrefix(pattern)?.group(1) ?? pattern;
    if (normalized.isEmpty) return null;
    try {
      return RegExp(normalized, caseSensitive: false);
    } on FormatException {
      // A malformed remote rule must not prevent the player from opening.
      return null;
    }
  }

  List<String> dmFilterString = [];
  List<RegExp> dmRegExp = [];
  Set<String> dmUid = {};

  int count = 0;

  RuleFilter(this.dmFilterString, this.dmRegExp, this.dmUid, [int? count]) {
    this.count =
        count ?? dmFilterString.length + dmRegExp.length + dmUid.length;
  }

  RuleFilter.fromRuleTypeEntries(List<List<SimpleRule>> rules) {
    dmFilterString = rules[0]
        .map((e) => e.filter)
        .where((e) => e.isNotEmpty)
        .toList();

    dmRegExp = rules[1]
        .map((e) => compile(e.filter))
        .whereType<RegExp>()
        .toList();

    dmUid = rules[2].map((e) => e.filter).toSet();

    count = dmFilterString.length + dmRegExp.length + dmUid.length;
  }

  RuleFilter.empty();

  bool remove(DanmakuElem elem) {
    return dmUid.contains(elem.midHash) ||
        dmFilterString.any((i) => elem.content.contains(i)) ||
        dmRegExp.any((i) => i.hasMatch(elem.content));
  }
}
