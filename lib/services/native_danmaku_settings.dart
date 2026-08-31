import 'dart:convert';

import 'package:PiliPlus/http/danmaku_block.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/user/danmaku_block.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:synchronized/synchronized.dart';

/// Native UI uses the same preferences and authenticated API as the Dart UI.
/// Keep server IDs (the old compiled RuleFilter cache does not retain them).
final class NativeDanmakuSettings {
  final _lock = Lock();
  static const _cachePrefix = 'nativeDanmakuRulesV1';
  String get _owner => Accounts.main.isLogin ? '${Accounts.main.mid}' : 'guest';

  List<Map<String, dynamic>> _rules(String owner) => (GStorage.localCache.get(
    '$_cachePrefix:$owner',
    defaultValue: <dynamic>[],
  ) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Map<String, dynamic> _snapshot(String owner) => {
    'state': 'success',
    'owner': owner,
    'loggedIn': Accounts.main.isLogin,
    'blockTypes': Pref.danmakuBlockType.toList(),
    'weight': Pref.danmakuWeight,
    'area': Pref.danmakuShowArea,
    'opacity': Pref.danmakuOpacity,
    'fontScale': Pref.danmakuFontScale,
    'duration': Pref.danmakuDuration,
    'strokeWidth': Pref.danmakuStrokeWidth,
    'rules': _rules(owner),
  };

  Future<Map<String, dynamic>> handle(
    Map<dynamic, dynamic> args,
  ) => _lock.synchronized(() async {
    final owner = _owner;
    try {
      final action = args['action'] ?? 'load';
      if (action != 'load' && action != 'save' && args['owner'] != owner) {
        throw const FormatException('账号已切换，请重新加载');
      }
      // Adopt the pre-native compiled cache exactly once. It has no server
      // IDs, so imported entries remain local and can be removed offline.
      if (!GStorage.localCache.containsKey('$_cachePrefix:migrated')) {
        final legacy = Pref.danmakuFilterRule;
        var id = -DateTime.now().microsecondsSinceEpoch;
        final imported = <Map<String, dynamic>>[];
        void add(int type, Iterable<String> filters) {
          for (final filter in filters.where((e) => e.isNotEmpty)) {
            imported.add({
              'id': id--,
              'type': type,
              'filter': filter,
              'imported': true,
            });
          }
        }

        add(0, legacy.dmFilterString);
        add(1, legacy.dmRegExp.map((e) => e.pattern));
        add(2, legacy.dmUid);
        await GStorage.localCache.put('$_cachePrefix:$owner', imported);
        await GStorage.localCache.put('$_cachePrefix:migrated', true);
      }
      if (_owner != owner) throw const FormatException('账号已切换，请重新加载');
      if (action == 'save') {
        final blocks = (args['blockTypes'] as List?)?.cast<int>();
        if (blocks == null || blocks.any((v) => ![2, 4, 5, 6, 7].contains(v))) {
          throw const FormatException('无效的弹幕类型');
        }
        num value(String key, num min, num max) {
          final v = args[key];
          if (v is! num || !v.isFinite || v < min || v > max) {
            throw FormatException('无效的弹幕参数：$key');
          }
          return v;
        }

        await GStorage.setting.putAll({
          SettingBoxKey.danmakuBlockType: blocks.toSet().toList(),
          SettingBoxKey.danmakuWeight: value('weight', 0, 11).toInt(),
          SettingBoxKey.danmakuShowArea: value('area', 0.25, 1).toDouble(),
          SettingBoxKey.danmakuOpacity: value('opacity', 0, 1).toDouble(),
          SettingBoxKey.danmakuFontScale: value(
            'fontScale',
            0.5,
            2.5,
          ).toDouble(),
          SettingBoxKey.danmakuDuration: value('duration', 1, 20).toDouble(),
          SettingBoxKey.danmakuStrokeWidth: value(
            'strokeWidth',
            0,
            3,
          ).toDouble(),
        });
      } else if (action != 'load') {
        final rules = _rules(owner);
        if (action == 'sync') {
          if (!Accounts.main.isLogin) throw const FormatException('请先登录账号');
          final result = await DanmakuFilterHttp.danmakuFilter();
          if (result case Success(:final response)) {
            // Preserve local rules. A failed fetch never erases the cache.
            rules.removeWhere((e) => (e['id'] as int) >= 0);
            final cloudRules = [
              ...response.rule,
              ...response.rule1,
              ...response.rule2,
            ].map(_json).toList();
            rules.removeWhere(
              (local) =>
                  local['imported'] == true &&
                  cloudRules.any(
                    (remote) =>
                        remote['type'] == local['type'] &&
                        remote['filter'] == local['filter'],
                  ),
            );
            rules.addAll(cloudRules);
          } else {
            throw FormatException(result.toString());
          }
        } else if (action == 'delete') {
          final id = args['id'];
          final index = rules.indexWhere((e) => e['id'] == id);
          if (index < 0) throw const FormatException('规则已变更，请刷新后重试');
          if ((id as int) >= 0) {
            if (!Accounts.main.isLogin) throw const FormatException('请先登录账号');
            final result = await DanmakuFilterHttp.danmakuFilterDel(ids: id);
            if (!result.isSuccess) throw FormatException(result.toString());
          }
          rules.removeAt(index);
        } else if (action == 'add' || action == 'edit') {
          final type = args['type'];
          var filter = (args['filter'] as String? ?? '').trim();
          if (type is! int || type < 0 || type > 2 || filter.isEmpty) {
            throw const FormatException('请输入有效的屏蔽规则');
          }
          if (type == 1) {
            if (filter.startsWith('/') &&
                filter.endsWith('/') &&
                filter.length > 1) {
              filter = filter.substring(1, filter.length - 1);
            }
            if (filter.isEmpty) throw const FormatException('正则表达式不能为空');
            RegExp(filter, caseSensitive: false);
          } else if (type == 2) {
            if (!RegExp(r'^[1-9]\d*$').hasMatch(filter)) {
              throw const FormatException('UID 必须是正整数');
            }
            filter = getCrc32(ascii.encode(filter), 0).toRadixString(16);
          }
          final oldIndex = rules.indexWhere((e) => e['id'] == args['id']);
          if (action == 'edit' &&
              (oldIndex < 0 || rules[oldIndex]['type'] == 2)) {
            throw const FormatException('该规则不可编辑，请删除后重新添加');
          }
          if (rules.any((e) => e['type'] == type && e['filter'] == filter)) {
            throw const FormatException('规则已存在');
          }
          // New rules stay local until explicitly added to the account.
          // Editing local data is atomic; cloud edits add first so a failed
          // validation/request cannot destroy the original rule.
          // Some platforms have a coarse wall clock. Derive the next ID from
          // persisted IDs as well, so rapid edits cannot delete another rule.
          var localId = -DateTime.now().microsecondsSinceEpoch;
          for (final rule in rules) {
            final id = rule['id'] as int;
            if (id <= localId) localId = id - 1;
          }
          var added = <String, dynamic>{
            'id': localId,
            'type': type,
            'filter': filter,
          };
          final old = oldIndex < 0 ? null : rules[oldIndex];
          final cloud =
              args['cloud'] == true || (old != null && (old['id'] as int) >= 0);
          if (cloud) {
            if (!Accounts.main.isLogin) throw const FormatException('请先登录账号');
            final result = await DanmakuFilterHttp.danmakuFilterAdd(
              filter: filter,
              type: type,
            );
            if (result case Success(:final response)) {
              added = _json(response);
            } else {
              throw FormatException(result.toString());
            }
            if (old != null && (old['id'] as int) >= 0) {
              if (_owner != owner) throw const FormatException('账号已切换，请重新同步');
              final deleted = await DanmakuFilterHttp.danmakuFilterDel(
                ids: old['id'] as int,
              );
              if (!deleted.isSuccess) {
                rules.add(added);
                await GStorage.localCache.put('$_cachePrefix:$owner', rules);
                if (_owner != owner) throw const FormatException('账号已切换，请重新加载');
                await _publishRules(owner);
                return {..._snapshot(owner), 'warning': '新规则已添加，旧规则删除失败，请重试删除'};
              }
            }
          }
          if (oldIndex >= 0) rules.removeAt(oldIndex);
          rules.add(added);
        } else {
          throw const FormatException('未知的弹幕设置操作');
        }
        await GStorage.localCache.put('$_cachePrefix:$owner', rules);
      }
      if (_owner != owner) throw const FormatException('账号已切换，请重新加载');
      await _publishRules(owner);
      return _snapshot(owner);
    } catch (error) {
      return {
        'state': 'error',
        'error': error is FormatException ? error.message : '弹幕设置操作失败，请重试',
      };
    }
  });

  Future<void> _publishRules(String owner) async {
    final entries = List.generate(3, (_) => <SimpleRule>[]);
    for (final rule in _rules(owner)) {
      entries[rule['type'] as int].add(SimpleRule.fromJson(rule));
    }
    await GStorage.localCache.put(
      LocalCacheKey.danmakuFilterRules,
      RuleFilter.fromRuleTypeEntries(entries),
    );
  }

  static Map<String, dynamic> _json(SimpleRule rule) => {
    'id': rule.id,
    'type': rule.type,
    'filter': rule.filter,
  };
}
