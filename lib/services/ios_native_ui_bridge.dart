import 'dart:async';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/models/common/dynamic/dynamics_type.dart';
import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/models/common/search/search_type.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/pages/dynamics/controller.dart';
import 'package:PiliPlus/pages/dynamics_tab/controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// Keeps the native iOS front-end attached to the existing Flutter services.
///
/// Only JSON-compatible view data crosses this channel. Authentication,
/// cookies, CSRF signing, routing, player setup, and all mutations continue to
/// run through the original Dart implementation.
final class IOSNativeUIBridge {
  IOSNativeUIBridge(this.mainController);

  static const MethodChannel _channel = MethodChannel('piliglass/native_ui');

  final MainController mainController;
  final List<Worker> _workers = <Worker>[];
  Timer? _snapshotTimer;
  bool _disposed = false;

  late final RcmdController _homeController =
      Get.putOrFind<RcmdController>(RcmdController.new);
  late final DynamicsController _dynamicsController =
      Get.putOrFind<DynamicsController>(DynamicsController.new);
  late final DynamicsTabController _dynamicsTabController =
      Get.putOrFind<DynamicsTabController>(
        () => DynamicsTabController(dynamicsType: DynamicsTabType.all),
        tag: DynamicsTabType.all.name,
      );
  late final MineController _mineController =
      Get.putOrFind<MineController>(MineController.new);

  void start() {
    // Initialize the original controllers before installing observers. Their
    // normal query methods remain the sole source of data for the native UI.
    _homeController;
    _dynamicsController;
    _dynamicsTabController;
    _mineController;

    _channel.setMethodCallHandler(_handleNativeCall);
    _workers.addAll([
      ever(mainController.selectedIndex, (int index) {
        _channel.invokeMethod<void>('setSelectedIndex', index);
      }),
      ever(mainController.dynCount, _syncDynamicBadge),
      ever(_homeController.loadingState, (_) => _scheduleSnapshot()),
      ever(
        _dynamicsTabController.loadingState,
        (_) => _scheduleSnapshot(),
      ),
      ever(_mineController.loadingState, (_) => _scheduleSnapshot()),
      ever(_mineController.userInfo, (_) => _scheduleSnapshot()),
      ever(_mineController.userStat, (_) => _scheduleSnapshot()),
      ever(
        mainController.accountService.isLogin,
        (_) => _scheduleSnapshot(),
      ),
    ]);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      _channel.invokeMethod<void>('configure', {
        'titles': mainController.navigationBars.map((e) => e.label).toList(),
        'selectedIndex': mainController.selectedIndex.value,
        'minimumIOSVersion': 15,
        'mode': 'native-root-flutter-features',
      });
      _syncDynamicBadge(mainController.dynCount.value);
      _pushSnapshot();
    });
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'selectTab':
        final index = _asInt(call.arguments);
        if (index != null &&
            index >= 0 &&
            index < mainController.navigationBars.length) {
          mainController.setIndex(index);
        }
        return null;
      case 'requestSnapshot':
        return _snapshot();
      case 'refreshSection':
        return _refreshSection(_arguments(call)['section']?.toString());
      case 'loadMore':
        return _loadMore(_arguments(call)['section']?.toString());
      case 'openVideo':
        return _openVideo(_arguments(call));
      case 'openDynamic':
        return _openDynamic(_arguments(call));
      case 'openRoute':
        return _openRoute(_arguments(call));
      case 'searchVideos':
        return _searchVideos(_arguments(call));
      // Kept for older native shells that still emit this action.
      case 'openSearch':
        return _openRoute(const {'route': '/search'});
      default:
        throw MissingPluginException('Unknown native UI method: ${call.method}');
    }
  }

  Future<Map<String, dynamic>> _refreshSection(String? section) async {
    switch (section) {
      case 'home':
        await _homeController.onRefresh();
        break;
      case 'dynamics':
        await _dynamicsController.singleRefresh();
        await _dynamicsTabController.onRefresh();
        break;
      case 'mine':
        await _mineController.onRefresh();
        break;
      default:
        await Future.wait<void>([
          _homeController.onRefresh(),
          _dynamicsTabController.onRefresh(),
          _mineController.onRefresh(),
        ]);
    }
    return _snapshot();
  }

  Future<Map<String, dynamic>> _loadMore(String? section) async {
    if (section == 'home') {
      await _homeController.onLoadMore();
    } else if (section == 'dynamics') {
      await _dynamicsTabController.onLoadMore();
    }
    return _snapshot();
  }

  Future<void> _openVideo(Map<dynamic, dynamic> arguments) async {
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    final aid = _asInt(arguments['aid']);
    if (bvid == null && aid == null) return;
    await PiliScheme.videoPush(aid, bvid);
  }

  Future<void> _openDynamic(Map<dynamic, dynamic> arguments) async {
    final id = _nonEmpty(arguments['id']?.toString());
    if (id == null) return;

    final items = _dynamicsTabController.loadingState.value.dataOrNull;
    if (items != null) {
      for (final item in items) {
        if (item.idStr.toString() == id) {
          await PageUtils.pushDynDetail(item, isPush: true);
          return;
        }
      }
    }
    await PageUtils.pushDynFromId(id: id);
  }

  static const Set<String> _allowedRoutes = {
    '/articleList',
    '/download',
    '/fan',
    '/fav',
    '/follow',
    '/history',
    '/later',
    '/loginPage',
    '/member',
    '/memberDynamics',
    '/myReply',
    '/search',
    '/setting',
    '/subscription',
    '/whisper',
  };

  Future<void> _openRoute(Map<dynamic, dynamic> arguments) async {
    final route = arguments['route']?.toString();
    if (route == null || !_allowedRoutes.contains(route)) return;

    final rawParameters = arguments['parameters'];
    Map<String, String>? parameters;
    if (rawParameters is Map) {
      parameters = rawParameters.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    }
    await Get.toNamed(
      route,
      parameters: parameters,
      preventDuplicates: false,
    );
  }

  Future<Map<String, dynamic>> _searchVideos(
    Map<dynamic, dynamic> arguments,
  ) async {
    final keyword = _nonEmpty(arguments['keyword']?.toString());
    if (keyword == null) {
      return const {
        'state': 'success',
        'items': <Map<String, dynamic>>[],
      };
    }

    final page = _asInt(arguments['page']) ?? 1;
    final result = await SearchHttp.searchByType<SearchVideoData>(
      searchType: SearchType.video,
      keyword: keyword,
      page: page,
      onSuccess: (_) {},
    );

    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '搜索失败',
        'code': ?code,
      },
      Success(:final response) => {
        'state': 'success',
        'total': response.numResults ?? 0,
        'items': (response.list ?? const [])
            .asMap()
            .entries
            .map((entry) => _videoMap(entry.value, entry.key))
            .toList(),
      },
    };
  }

  Map<String, dynamic> _snapshot() => {
    'home': _listState(
      _homeController.loadingState.value,
      _videoMap,
    ),
    'dynamics': _listState(
      _dynamicsTabController.loadingState.value,
      _dynamicMap,
    ),
    'account': _accountMap(),
    'selectedIndex': mainController.selectedIndex.value,
    'dynamicBadge': mainController.dynCount.value,
    'generatedAt': DateTime.now().millisecondsSinceEpoch,
  };

  Map<String, dynamic> _listState(
    LoadingState state,
    Map<String, dynamic> Function(dynamic item, int index) convert,
  ) {
    return switch (state) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '加载失败',
        'code': ?code,
      },
      Success(:final response) => {
        'state': 'success',
        'items': response is List
            ? response
                  .asMap()
                  .entries
                  .map((entry) => convert(entry.value, entry.key))
                  .toList()
            : <Map<String, dynamic>>[],
      },
    };
  }

  Map<String, dynamic> _videoMap(dynamic item, int index) {
    try {
      final aid = _asInt(item.aid);
      final bvid = _nonEmpty(item.bvid?.toString());
      final title = item.title?.toString() ?? '';
      final owner = item.owner;
      final stat = item.stat;
      final duration = _asInt(item.duration) ?? 0;
      return {
        'id': bvid ?? aid?.toString() ?? 'video-$index',
        'aid': ?aid,
        'bvid': ?bvid,
        'title': title,
        'cover': _normalizeURL(item.cover?.toString()),
        'owner': owner.name?.toString() ?? '',
        'ownerId': _asInt(owner.mid),
        'view': _asInt(stat.view) ?? 0,
        'viewText': _compactNumber(_asInt(stat.view)),
        'danmakuText': _compactNumber(_asInt(stat.danmu)),
        'duration': duration,
        'durationText': _durationText(duration),
      };
    } catch (_) {
      return {
        'id': 'video-$index',
        'title': '暂不支持的内容',
        'owner': '',
        'viewText': '',
        'durationText': '',
      };
    }
  }

  Map<String, dynamic> _dynamicMap(dynamic item, int index) {
    try {
      final moduleDynamic = item.modules.moduleDynamic;
      final major = moduleDynamic?.major;
      final author = item.modules.moduleAuthor;

      final archive =
          major?.archive ?? major?.ugcSeason ?? major?.pgc ?? major?.courses;
      final opus = major?.opus;
      final live = major?.liveRcmd ?? major?.live;

      final title = _firstNonEmpty([
        opus?.title?.toString(),
        archive?.title?.toString(),
        live?.title?.toString(),
        major?.medialist?.title?.toString(),
        major?.music?.title?.toString(),
      ]);
      final body = _firstNonEmpty([
        moduleDynamic?.desc?.text?.toString(),
        opus?.summary?.text?.toString(),
      ]);
      final cover = _firstNonEmpty([
        archive?.cover?.toString(),
        opus?.pics?.isNotEmpty == true
            ? (opus.pics.first.src ?? opus.pics.first.url)?.toString()
            : null,
        live?.cover?.toString(),
        major?.medialist?.cover?.toString(),
        major?.music?.cover?.toString(),
      ]);
      final stat = item.modules.moduleStat;
      final id = item.idStr?.toString() ?? 'dynamic-$index';

      return {
        'id': id,
        'type': item.type?.toString() ?? '',
        'author': author?.name?.toString() ?? '',
        'authorId': _asInt(author?.mid),
        'avatar': _normalizeURL(author?.face?.toString()),
        'time': author?.pubTime?.toString() ?? '',
        'title': title ?? '',
        'body': body ?? '',
        'cover': _normalizeURL(cover),
        'bvid': archive?.bvid?.toString(),
        'like': _asInt(stat?.like?.count) ?? 0,
        'comment': _asInt(stat?.comment?.count) ?? 0,
        'forward': _asInt(stat?.forward?.count) ?? 0,
      };
    } catch (_) {
      return {
        'id': 'dynamic-$index',
        'author': '',
        'title': '',
        'body': '暂不支持的动态类型',
      };
    }
  }

  Map<String, dynamic> _accountMap() {
    final info = _mineController.userInfo.value;
    final stat = _mineController.userStat.value;
    final level = info.levelInfo;
    return {
      'state': mainController.accountService.isLogin.value
          ? 'success'
          : 'loggedOut',
      'isLogin': mainController.accountService.isLogin.value,
      'mid': info.mid,
      'name': info.uname ?? '点击登录',
      'face': _normalizeURL(info.face),
      'money': info.money ?? 0,
      'level': level?.currentLevel ?? 0,
      'currentExp': level?.currentExp ?? 0,
      'nextExp': level?.nextExp ?? 0,
      'vip': (info.vipStatus ?? 0) > 0,
      'following': stat.following ?? 0,
      'followers': stat.follower ?? 0,
      'dynamics': stat.dynamicCount ?? 0,
      'favoriteCount': _mineController.favFolderCount ?? 0,
      'avatarFallback': mainController.accountService.face.value,
    };
  }

  void _scheduleSnapshot() {
    if (_disposed) return;
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer(const Duration(milliseconds: 120), _pushSnapshot);
  }

  void _pushSnapshot() {
    if (_disposed) return;
    _channel.invokeMethod<void>('updateSnapshot', _snapshot());
  }

  void _syncDynamicBadge(int count) {
    final index = mainController.navigationBars.indexOf(
      NavigationBarType.dynamics,
    );
    if (index < 0 || _disposed) return;
    _channel.invokeMethod<void>('setBadge', {
      'index': index,
      'value': count <= 0 ? '' : (count > 99 ? '99+' : count.toString()),
    });
  }

  void setNativeRootVisible(bool visible) {
    if (_disposed) return;
    _channel.invokeMethod<void>('setChromeVisible', visible);
    if (visible) _scheduleSnapshot();
  }

  void dispose() {
    _disposed = true;
    _snapshotTimer?.cancel();
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    _channel.setMethodCallHandler(null);
  }

  static Map<dynamic, dynamic> _arguments(MethodCall call) =>
      call.arguments is Map ? call.arguments as Map : const {};

  static int? _asInt(dynamic value) => switch (value) {
    int value => value,
    num value => value.toInt(),
    String value => int.tryParse(value),
    _ => null,
  };

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty || trimmed == 'null'
        ? null
        : trimmed;
  }

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (_nonEmpty(value) case final result?) return result;
    }
    return null;
  }

  static String? _normalizeURL(String? value) {
    final url = _nonEmpty(value);
    if (url == null) return null;
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('http://')) {
      return 'https://${url.substring('http://'.length)}';
    }
    return url;
  }

  static String _compactNumber(int? value) {
    if (value == null || value <= 0) return '';
    if (value >= 100000000) {
      return '${(value / 100000000).toStringAsFixed(1)}亿';
    }
    if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
    return value.toString();
  }

  static String _durationText(int seconds) {
    if (seconds <= 0) return '';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remain = seconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${remain.toString().padLeft(2, '0')}';
    }
    return '$minutes:${remain.toString().padLeft(2, '0')}';
  }
}
