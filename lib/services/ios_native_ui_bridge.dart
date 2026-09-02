import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;

import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart'
    as im_proto
    show Offset;
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show Mode, ReplyInfo;
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/grpc/im.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/grpc/bilibili/im/type.pb.dart' show MsgType;
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/fan.dart';
import 'package:PiliPlus/http/follow.dart';
import 'package:PiliPlus/http/dynamics.dart';
import 'package:PiliPlus/http/danmaku.dart';
import 'package:PiliPlus/http/login.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/http/msg.dart';
import 'package:PiliPlus/http/reply.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/member/contribute_type.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/app_sign.dart';
import 'package:dio/dio.dart';
import 'package:PiliPlus/models/common/dynamic/dynamics_type.dart';
import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/models/common/search/search_type.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/pages/dynamics/controller.dart';
import 'package:PiliPlus/pages/dynamics_tab/controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/services/native_danmaku_settings.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/native_playback_source.dart';
import 'package:PiliPlus/utils/native_cdn_latency.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:protobuf/protobuf.dart' show PbMap;

/// Keeps the native iOS front-end attached to the existing Flutter services.
///
/// Only JSON-compatible view data crosses this channel. Authentication,
/// cookies, CSRF signing, routing, player setup, and all mutations continue to
/// run through the original Dart implementation.
final class IOSNativeUIBridge {
  IOSNativeUIBridge(this.mainController);

  static const MethodChannel _channel = MethodChannel('piliglass/native_ui');

  final MainController mainController;
  final _danmakuSettings = NativeDanmakuSettings();
  final List<Worker> _workers = <Worker>[];
  final _cdnLatency = NativeCDNLatency(probe: measureCdnDownloadSpeed);
  List<String> _latencySampleURLs = [];
  DateTime? _latencySampleTime;
  Future<Map<String, dynamic>>? _latencyTest;
  Timer? _snapshotTimer;
  bool _disposed = false;
  String? _nativeLoginAuthCode;
  bool _nativePlayerShellActive = false;
  PbMap<int, im_proto.Offset>? _nativeSessionOffsets;

  static const _fetchResultTTL = Duration(minutes: 30);
  final Map<String, ({DateTime at, Map<String, dynamic> data})> _fetchCache = {};
  final Map<String, Future<Map<String, dynamic>>> _inFlightFetches = {};

  late final RcmdController _homeController = Get.putOrFind<RcmdController>(
    RcmdController.new,
  );
  late final DynamicsController _dynamicsController =
      Get.putOrFind<DynamicsController>(DynamicsController.new);
  late final DynamicsTabController _dynamicsTabController =
      Get.putOrFind<DynamicsTabController>(
        () => DynamicsTabController(dynamicsType: DynamicsTabType.all),
        tag: DynamicsTabType.all.name,
      );
  late final MineController _mineController = Get.putOrFind<MineController>(
    MineController.new,
  );

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
      ever(_dynamicsTabController.loadingState, (_) => _scheduleSnapshot()),
      ever(_mineController.loadingState, (_) => _scheduleSnapshot()),
      ever(_mineController.userInfo, (_) => _scheduleSnapshot()),
      ever(_mineController.userStat, (_) => _scheduleSnapshot()),
      ever(mainController.accountService.isLogin, (_) => _scheduleSnapshot()),
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
      case 'closeNativeVideoPlayer':
        return _closeNativeVideoPlayer();
      case 'setNativePlayerFullscreen':
        return _setNativePlayerFullscreen(_arguments(call));
      case 'loadVideoDetail':
        return _loadVideoDetail(_arguments(call));
      case 'loadVideoDetailExtras':
        return _loadVideoDetailExtras(_arguments(call));
      case 'loadRelatedVideos':
        return _loadRelatedVideos(_arguments(call));
      case 'loadNativePlayback':
        return _loadNativePlayback(_arguments(call));
      case 'loadNativePlaybackMetadata':
        return _loadNativePlaybackMetadata(_arguments(call));
      case 'reportNativePlaybackProgress':
        return _reportNativePlaybackProgress(_arguments(call));
      case 'loadNativeDanmaku':
        return _loadNativeDanmaku(_arguments(call));
      case 'nativeDanmakuSettings':
        return _danmakuSettings.handle(_arguments(call));
      case 'sendNativeDanmaku':
        return _sendNativeDanmaku(_arguments(call));
      case 'playVideo':
        return _playVideo(_arguments(call));
      case 'performVideoAction':
        return _performVideoAction(_arguments(call));
      case 'changeNativeVideoPart':
        return _changeNativeVideoPart(_arguments(call));
      case 'refreshNativePlayerSurface':
        return _refreshNativePlayerSurface(_arguments(call));
      case 'openDynamic':
        return _openDynamic(_arguments(call));
      case 'loadNativeDynamicDetail':
        return _loadNativeDynamicDetail(_arguments(call));
      case 'setNativeDynamicLike':
        return _setNativeDynamicLike(_arguments(call));
      case 'repostNativeDynamic':
        return _repostNativeDynamic(_arguments(call));
      case 'openRoute':
        return _openRoute(_arguments(call));
      case 'loadNativeSettings':
        return _nativeSettingsSnapshot();
      case 'setNativeSetting':
        return _setNativeSetting(_arguments(call));
      case 'setNativeVideoQuality':
        return _setNativeVideoQuality(_arguments(call));
      case 'setNativePlaybackSource':
        return _setNativePlaybackSource(_arguments(call));
      case 'testNativePlaybackSources':
        return _testNativePlaybackSources(_arguments(call));
      case 'searchVideos':
        return _searchVideos(_arguments(call));
      case 'loadNativeLibrary':
        return _loadNativeLibrary(_arguments(call));
      case 'loadNativeProfile':
        return _loadNativeProfile(_arguments(call));
      case 'loadNativeProfileSection':
        return _loadNativeProfileSection(_arguments(call));
      case 'saveNativeProfileSign':
        return _saveNativeProfileSign(_arguments(call));
      case 'loadNativeProfileVideos':
        return _loadNativeProfileVideos(_arguments(call));
      case 'setNativeProfileFollow':
        return _setNativeProfileFollow(_arguments(call));
      case 'startNativeLogin':
        return _startNativeLogin();
      case 'pollNativeLogin':
        return _pollNativeLogin();
      case 'loadNativeMessages':
        return _loadNativeMessages(_arguments(call));
      case 'loadNativeChat':
        return _loadNativeChat(_arguments(call));
      case 'sendNativeChatMessage':
        return _sendNativeChatMessage(_arguments(call));
      case 'sendNativeChatImage':
        return _sendNativeChatImage(_arguments(call));
      case 'recallNativeChatMessage':
        return _recallNativeChatMessage(_arguments(call));
      case 'loadNativeComments':
        return _loadNativeComments(_arguments(call));
      case 'setNativeCommentLike':
        return _setNativeCommentLike(_arguments(call));
      case 'publishNativeComment':
        return _publishNativeComment(_arguments(call));
      case 'loadNativeCommentReplies':
        return _loadNativeCommentReplies(_arguments(call));
      case 'loadNativeDownloads':
        return _loadNativeDownloads();
      // Pre-warm playback URLs and subtitle files while the native shell shows
      // the detail page. Responses are memoized for _fetchResultTTL so the
      // later loadNativePlayback/loadNativePlaybackMetadata calls become
      // instant cache hits.
      case 'preloadNativePlayback':
        unawaited(
          () async {
            final arguments = _arguments(call);
            final cid = _asInt(arguments['cid']);
            if (cid == null || cid <= 0) return;
            await Future.wait([
              _loadNativePlayback(arguments),
              _loadNativePlaybackMetadata(arguments),
            ]);
          }(),
        );
        return const {'state': 'started'};
      // Fired the moment a card is tapped, before the detail request returns:
      // resolves the cid through the shared (memoized) detail fetch, then
      // warms playback URLs and subtitle files. The later loadVideoDetail /
      // loadNativePlayback calls hit the same in-flight or cached result.
      case 'preloadNativePlaybackByBvid':
        unawaited(
          () async {
            final arguments = _arguments(call);
            final bvid = _nonEmpty(arguments['bvid']?.toString());
            if (bvid == null || bvid.isEmpty) return;
            final detail = await _loadVideoDetail({'bvid': bvid});
            if (detail['state'] != 'success') return;
            final video = (detail['video'] as Map?) ?? const {};
            final cid = video['cid'];
            if (cid is! int || cid <= 0) return;
            final playbackArguments = {'bvid': bvid, 'cid': cid};
            await Future.wait([
              _loadNativePlayback(playbackArguments),
              _loadNativePlaybackMetadata(playbackArguments),
            ]);
          }(),
        );
        return const {'state': 'started'};
      // Kept for older native shells that still emit this action.
      case 'openSearch':
        return _openRoute(const {'route': '/search'});
      default:
        throw MissingPluginException(
          'Unknown native UI method: ${call.method}',
        );
    }
  }

  Map<String, dynamic>? _cachedFetch(String key) {
    final entry = _fetchCache[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) > _fetchResultTTL) {
      _fetchCache.remove(key);
      return null;
    }
    return entry.data;
  }

  Future<Map<String, dynamic>> _dedupedFetch(
    String key,
    Future<Map<String, dynamic>> Function() loader,
  ) async {
    final cached = _cachedFetch(key);
    if (cached != null) return cached;
    final inFlight = _inFlightFetches[key];
    if (inFlight != null) return inFlight;
    final future = loader();
    _inFlightFetches[key] = future;
    try {
      final data = await future;
      if (data['state'] == 'success') {
        _fetchCache[key] = (at: DateTime.now(), data: data);
      }
      return data;
    } finally {
      _inFlightFetches.remove(key);
    }
  }

  String _playbackCacheKey(Map<dynamic, dynamic> arguments) {
    var aid = _asInt(arguments['aid']);
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    if (aid == null && bvid != null) aid = IdUtils.bv2av(bvid);
    final cid = _asInt(arguments['cid']);
    final quality =
        _asInt(arguments['quality']) ??
        GStorage.setting.get(
          SettingBoxKey.defaultVideoQa,
          defaultValue: VideoQuality.super8k.code,
        );
    return 'playback:$aid:$cid:$quality';
  }

  /// Bounded parallel low-volume sample across the CDN candidates. Returns
  /// the fastest CDN name, or null when nothing completed in time. This runs
  /// only when no cached 3-minute ranking exists, and only for the current
  /// request; the result is used to lead with a good primary URL instead of
  /// paying a full decoder reload when the default one is throttled.
  Future<String?> _fastestCdnName(Iterable<String> urls) async {
    final candidates = _latencyCandidates(urls);
    if (candidates.isEmpty) return null;
    final speeds = <String, double>{};
    await Future.wait(
      candidates.entries.map((entry) async {
        final uri = Uri.tryParse(entry.value);
        if (uri == null || !uri.hasAuthority) return;
        try {
          final measurement = await measureCdnDownloadSpeed(
            uri,
            maxBytes: 128 * 1024,
            timeout: const Duration(milliseconds: 900),
          );
          if (measurement.status == 'ok' &&
              (measurement.megabytesPerSecond ?? 0) > 0) {
            speeds[entry.key] = measurement.megabytesPerSecond!;
          }
        } catch (_) {
          /* A failed sample simply means this CDN is not picked. */
        }
      }),
    );
    String? best;
    double? fastest;
    for (final entry in speeds.entries) {
      if (fastest == null || entry.value > fastest) {
        fastest = entry.value;
        best = entry.key;
      }
    }
    return best;
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

  Future<Map<String, dynamic>> _openVideo(
    Map<dynamic, dynamic> arguments,
  ) async {
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    final aid = _asInt(arguments['aid']);
    if (bvid == null && aid == null) {
      return const {'state': 'error', 'error': '缺少视频编号'};
    }
    _nativePlayerShellActive = true;
    unawaited(() async {
      await PiliScheme.videoPush(
        aid,
        bvid,
        extraArguments: const {'nativeShell': true},
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (_disposed || !_nativePlayerShellActive) return;
      if (Get.currentRoute != '/videoV') {
        _nativePlayerShellActive = false;
        _channel.invokeMethod<void>('nativePlayerFailed', '原版播放器启动失败');
      }
    }());
    return const {'state': 'starting'};
  }

  Future<Map<String, dynamic>> _closeNativeVideoPlayer() async {
    _nativePlayerShellActive = false;
    if (Get.currentRoute == '/videoV') {
      Get.back();
      return const {'state': 'success'};
    }
    return const {'state': 'success', 'message': '播放器已经关闭'};
  }

  Future<Map<String, dynamic>> _setNativePlayerFullscreen(
    Map<dynamic, dynamic> arguments,
  ) async {
    final heroTag = _nonEmpty(arguments['heroTag']?.toString());
    final fullscreen = arguments['fullscreen'] == true;
    try {
      final controller = Get.find<UgcIntroController>(tag: heroTag);
      controller.videoDetailCtr.plPlayerController.triggerFullScreen(
        status: fullscreen,
      );
      return const {'state': 'success'};
    } catch (_) {
      return const {'state': 'error', 'error': '原版播放器尚未就绪'};
    }
  }

  Future<Map<String, dynamic>> _loadVideoDetailExtras(
    Map<dynamic, dynamic> arguments,
  ) async {
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    if (bvid == null) return const {'state': 'error'};
    final extras = <String, dynamic>{'state': 'success', 'bvid': bvid};
    // Neither optional endpoint delays the CID/play URL needed for playback.
    await Future.wait([
      () async {
        try {
          final result = await UserHttp.videoTags(bvid: bvid);
          final tags = result.dataOrNull;
          if (tags != null) {
            extras['tags'] = tags
                .where((item) => item.tagName?.isNotEmpty == true)
                .map(
                  (item) => {
                    'id': item.tagId,
                    'name': item.tagName,
                    'type': item.tagType,
                  },
                )
                .toList();
          }
        } catch (_) {
          /* Optional metadata remains retryable via refresh. */
        }
      }(),
      () async {
        if (!Accounts.main.isLogin) return;
        try {
          final result = await VideoHttp.videoRelation(bvid: bvid);
          final relation = result.dataOrNull;
          if (relation != null) {
            extras.addAll({
              'relationLoaded': true,
              'liked': relation.like ?? false,
              'coinCount': relation.coin?.toInt() ?? 0,
              'favorited': relation.favorite ?? false,
            });
          }
        } catch (_) {
          /* A relationship failure must not stop playback. */
        }
      }(),
    ]);
    return extras;
  }

  Future<Map<String, dynamic>> _loadVideoDetail(
    Map<dynamic, dynamic> arguments,
  ) {
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    final aid = _asInt(arguments['aid']);
    return _dedupedFetch(
      'detail:${bvid ?? 'av$aid'}',
      () => _loadVideoDetailUncached(arguments),
    );
  }

  Future<Map<String, dynamic>> _loadVideoDetailUncached(
    Map<dynamic, dynamic> arguments,
  ) async {
    var bvid = _nonEmpty(arguments['bvid']?.toString());
    final aid = _asInt(arguments['aid']);
    if (bvid == null && aid != null) bvid = IdUtils.av2bv(aid);
    if (bvid == null) {
      return const {'state': 'error', 'error': '缺少视频编号'};
    }

    final fast = arguments['fast'] == true;
    final tagRequest = !fast ? UserHttp.videoTags(bvid: bvid) : null;
    final relationRequest = !fast && Accounts.main.isLogin
        ? VideoHttp.videoRelation(bvid: bvid)
        : null;
    final result = await VideoHttp.videoIntro(bvid: bvid);
    var tags = const [];
    try {
      tags = tagRequest == null
          ? const []
          : (await tagRequest).dataOrNull ?? const [];
    } catch (_) {
      // Tags are optional; a tag endpoint failure must not hide the intro.
    }
    dynamic relation;
    try {
      relation = relationRequest == null
          ? null
          : (await relationRequest).dataOrNull;
    } catch (_) {
      // Relationship state is optional; keep the detail usable offline.
    }
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '视频简介加载失败',
        'code': ?code,
      },
      Success(:final response) => {
        'state': 'success',
        'video': {
          'aid': response.aid ?? aid,
          'bvid': response.bvid ?? bvid,
          'cid': response.cid,
          'title': response.title ?? arguments['title']?.toString() ?? '',
          'cover': _normalizeURL(
            response.pic ?? arguments['cover']?.toString(),
          ),
          'duration': response.duration ?? 0,
          'durationText': _durationText(response.duration ?? 0),
          'owner': response.owner?.name ?? '',
          'ownerId': response.owner?.mid,
          'ownerFace': _normalizeURL(response.owner?.face),
          'description': response.desc ?? '',
          'pubdate': response.pubdate,
          'pubdateText': DateFormatUtils.format(response.pubdate),
          'view': response.stat?.view ?? 0,
          'viewText': _compactNumber(response.stat?.view),
          'danmaku': response.stat?.danmaku ?? 0,
          'danmakuText': _compactNumber(response.stat?.danmaku),
          'reply': response.stat?.reply ?? 0,
          'like': response.stat?.like ?? 0,
          'coin': response.stat?.coin.toInt() ?? 0,
          'favorite': response.stat?.favorite ?? 0,
          'share': response.stat?.share ?? 0,
          'liked': relation?.like ?? false,
          'coinCount': relation?.coin?.toInt() ?? 0,
          'favorited': relation?.favorite ?? false,
          'relationLoaded': relation != null,
          'copyrightText': response.copyright == 1 ? '自制' : '转载',
          'isVertical': response.dimension?.isVertical ?? false,
          'argueMessage': response.argueInfo?.argueMsg ?? '',
          'collectionTitle': response.ugcSeason?.title ?? '',
          'collectionId': response.ugcSeason?.id,
          'collectionCount':
              response.ugcSeason?.sections?.fold<int>(
                0,
                (count, section) => count + (section.episodes?.length ?? 0),
              ) ??
              0,
          'collectionItems': (response.ugcSeason?.sections ?? const [])
              .expand((section) => section.episodes ?? const [])
              .toList()
              .asMap()
              .entries
              .map((entry) {
                final item = entry.value;
                return {
                  'id':
                      item.bvid ??
                      item.aid?.toString() ??
                      'collection-${entry.key}',
                  'aid': item.aid ?? item.arc?.aid,
                  'bvid': item.bvid,
                  'title': item.arc?.title ?? item.title ?? '未命名视频',
                  'cover': _normalizeURL(item.arc?.pic),
                  'owner': item.arc?.author?.name ?? '',
                  'viewText': _compactNumber(item.arc?.stat?.view),
                  'danmakuText': _compactNumber(item.arc?.stat?.danmaku),
                  'durationText': _durationText(
                    item.arc?.duration ?? item.page?.duration ?? 0,
                  ),
                };
              })
              .toList(),
          'redirectURL': response.redirectUrl,
          'tags': tags
              .where((item) => item.tagName?.isNotEmpty == true)
              .map(
                (item) => {
                  'id': item.tagId,
                  'name': item.tagName,
                  'type': item.tagType,
                },
              )
              .toList(),
          'staff': (response.staff ?? const [])
              .where((item) => item.name?.isNotEmpty == true)
              .map(
                (item) => {
                  'id': item.mid,
                  'name': item.name,
                  'title': item.title,
                  'face': _normalizeURL(item.face),
                },
              )
              .toList(),
          'pages': (response.pages ?? const [])
              .asMap()
              .entries
              .map(
                (entry) => {
                  'index': entry.key + 1,
                  'cid': entry.value.cid,
                  'title': entry.value.part ?? 'P${entry.key + 1}',
                  'duration': entry.value.duration ?? 0,
                  'durationText': _durationText(entry.value.duration ?? 0),
                  'cover': _normalizeURL(entry.value.firstFrame),
                },
              )
              .toList(),
        },
      },
    };
  }

  Future<Map<String, dynamic>> _loadRelatedVideos(
    Map<dynamic, dynamic> arguments,
  ) async {
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    if (bvid == null) {
      return const {'state': 'error', 'error': '缺少视频编号'};
    }

    final result = await VideoHttp.relatedVideoList(bvid: bvid);
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg) => {'state': 'error', 'error': errMsg ?? '相关推荐加载失败'},
      Success(:final response) => {
        'state': 'success',
        'items': (response ?? const []).asMap().entries.map((entry) {
          final item = entry.value;
          return {
            'id': item.bvid ?? item.aid?.toString() ?? 'related-${entry.key}',
            'aid': item.aid,
            'bvid': item.bvid,
            'title': item.title,
            'cover': _normalizeURL(item.cover),
            'owner': item.owner.name ?? '',
            'viewText': _compactNumber(item.stat.view),
            'danmakuText': _compactNumber(item.stat.danmu),
            'durationText': _durationText(item.duration),
          };
        }).toList(),
      },
    };
  }

  Future<void> _playVideo(Map<dynamic, dynamic> arguments) async {
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    final aid = _asInt(arguments['aid']);
    final part = _asInt(arguments['part']);
    if (bvid == null && aid == null) return;
    await PiliScheme.videoPush(aid, bvid, part: part?.toString());
  }

  Future<Map<String, dynamic>> _loadNativePlayback(
    Map<dynamic, dynamic> arguments,
  ) => _dedupedFetch(
    _playbackCacheKey(arguments),
    () => _loadNativePlaybackUncached(arguments),
  );

  Future<Map<String, dynamic>> _loadNativePlaybackUncached(
    Map<dynamic, dynamic> arguments,
  ) async {
    final cid = _asInt(arguments['cid']);
    var aid = _asInt(arguments['aid']);
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    if (aid == null && bvid != null) aid = IdUtils.bv2av(bvid);
    final quality =
        _asInt(arguments['quality']) ??
        GStorage.setting.get(
          SettingBoxKey.defaultVideoQa,
          defaultValue: VideoQuality.super8k.code,
        );
    if (cid == null || cid <= 0 || aid == null || aid <= 0) {
      return const {'state': 'error', 'error': '播放参数不完整'};
    }

    // Use the same DASH-capable request as the original Flutter player.
    // The TV endpoint only exposes legacy muxed streams for many videos and
    // therefore silently drops 4K, HDR and Dolby Vision representations.
    final result = await VideoHttp.videoUrl(
      avid: aid,
      bvid: bvid,
      cid: cid,
      qn: quality,
      tryLook:
          !Accounts.get(AccountType.video).isLogin &&
          GStorage.setting.get(SettingBoxKey.p1080, defaultValue: true) == true,
      videoType: VideoType.ugc,
    );
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '播放地址获取失败',
        'code': ?code,
      },
      Success(:final response) => await () async {
        final nativePlaybackExtras = <String, dynamic>{
          'resumeAt': response.lastPlayTime,
        };

        String? automaticSource;
        final automatic =
            GStorage.setting.get(SettingBoxKey.CDNService) == null;
        Future<void> prepareSource(Iterable<String> urls) async {
          _latencySampleURLs = urls.where((url) => url.isNotEmpty).toList();
          _latencySampleTime = DateTime.now();
          if (automatic) {
            automaticSource = _cdnLatency.choose(
              _latencyCandidates(_latencySampleURLs),
            );
            // No fresh ranking yet: run one bounded parallel sample (≈≤0.9 s)
            // so the primary URL is the fastest host instead of a throttled
            // default that would trigger a full decoder reload on retry.
            if (automaticSource == null) {
              automaticSource = await _fastestCdnName(_latencySampleURLs);
            }
          }
        }

        List<String> nativeTrackUrls(
          Iterable<String> urls, {
          bool isAudio = false,
        }) {
          final rawUrls = urls.where((url) => url.isNotEmpty).toList();
          if (rawUrls.isEmpty) return const [];
          final independentAudio = isAudio && VideoUtils.disableAudioCDN;
          // A measured automatic source or an explicit user choice wins.
          // All original signed URLs remain available as fallbacks.
          return nativePlaybackUrls(
            rawUrls,
            preferredUrl: VideoUtils.getCdnUrl(
              rawUrls,
              isAudio: isAudio,
              defaultCDNService: independentAudio
                  ? CDNService.backupUrl
                  : automaticSource == null
                  ? null
                  : CDNService.values.byName(automaticSource!),
            ),
            preferSelectedSource:
                independentAudio || !automatic || automaticSource != null,
          );
        }

        final qualityValues = response.acceptQuality ?? const <int>[];
        final qualityDescriptions = response.acceptDesc ?? const [];
        final formatByQuality = {
          for (final format in response.supportFormats ?? const [])
            if (format.quality != null) format.quality!: format,
        };
        final qualities = <Map<String, dynamic>>[];
        for (var index = 0; index < qualityValues.length; index++) {
          final value = qualityValues[index];
          final format = formatByQuality[value];
          qualities.add({
            'value': value,
            'label':
                format?.newDesc ??
                format?.displayDesc ??
                (index < qualityDescriptions.length
                    ? qualityDescriptions[index].toString()
                    : '${value}P'),
            'codecs': format?.codecs ?? const <String>[],
            'hdr': value == 125 || value == 126 || value == 129,
          });
        }

        final dash = response.dash;
        if (dash?.video?.isNotEmpty == true) {
          final videos = dash!.video!;
          final requested = videos
              .where((item) => item.quality.code == quality)
              .toList();
          final actualQuality = requested.isNotEmpty
              ? quality
              : response.quality ?? videos.first.quality.code;
          final candidates = videos
              .where((item) => item.quality.code == actualQuality)
              .toList();
          if (candidates.isEmpty) candidates.add(videos.first);
          final isHdr =
              actualQuality == 125 ||
              actualQuality == 126 ||
              actualQuality == 129;
          final isDolbyVision = actualQuality == 126;
          final preferHevc = isHdr || actualQuality >= 120;
          int codecRank(dynamic item) {
            final codec = item.codecs?.toString().toLowerCase() ?? '';
            // Bilibili exposes Dolby Vision as its own dvh1/dvhe DASH
            // representation. It must win for quality 126; treating it as an
            // unknown codec silently selected the plain HEVC fallback instead.
            if (codec.startsWith('dvh1') || codec.startsWith('dvhe')) {
              return isDolbyVision ? 0 : 1;
            }
            if (codec.startsWith('hvc1') || codec.startsWith('hev1')) {
              return isDolbyVision ? 1 : (preferHevc ? 0 : 1);
            }
            if (codec.startsWith('avc1')) {
              return isDolbyVision ? 3 : (preferHevc ? 2 : 0);
            }
            if (codec.startsWith('av01')) return 3;
            return 4;
          }

          candidates.sort((a, b) => codecRank(a).compareTo(codecRank(b)));
          final selectedVideo = candidates.first;
          await prepareSource(selectedVideo.playUrls);
          final videoUrls = <String>[];
          for (final candidate in candidates) {
            for (final url in nativeTrackUrls(candidate.playUrls)) {
              if (!videoUrls.contains(url)) videoUrls.add(url);
            }
          }
          final videoUrl = videoUrls.firstOrNull ?? '';

          final audioCandidates = [...?dash.audio];
          if (audioCandidates.isNotEmpty) {
            audioCandidates.sort((a, b) {
              int rank(dynamic item) {
                final codec = item.codecs?.toString().toLowerCase() ?? '';
                if (codec.startsWith('mp4a')) return 0;
                if (codec.contains('ec-3') || codec.contains('ac-3')) return 1;
                return 2;
              }

              final codecOrder = rank(a).compareTo(rank(b));
              if (codecOrder != 0) return codecOrder;
              return (b.bandWidth ?? 0).compareTo(a.bandWidth ?? 0);
            });
          }
          final audioUrls = <String>[];
          for (final candidate in audioCandidates) {
            for (final url in nativeTrackUrls(
              candidate.playUrls,
              isAudio: true,
            )) {
              if (!audioUrls.contains(url)) audioUrls.add(url);
            }
          }
          final audioUrl = audioUrls.firstOrNull;
          if (videoUrl.isEmpty) {
            return const {'state': 'error', 'error': '4K/HDR 视频轨地址为空'};
          }
          final durationMs = (dash.duration ?? 0) * 1000;
          final format = formatByQuality[actualQuality];
          return {
            'state': 'success',
            'streamKind': 'dash',
            'segments': [
              {
                'url': videoUrl,
                'audioURL': audioUrl,
                'videoURLs': videoUrls,
                'audioURLs': audioUrls,
                'duration': durationMs,
                'codec': selectedVideo.codecs ?? '',
                'width': selectedVideo.width ?? 0,
                'height': selectedVideo.height ?? 0,
                'quality': actualQuality,
                'hdr': isHdr,
              },
            ],
            'urls': [videoUrl],
            'quality': actualQuality,
            'qualityText':
                format?.newDesc ?? format?.displayDesc ?? '${actualQuality}P',
            'qualities': qualities,
            'duration': durationMs,
            'segmentCount': 1,
            'isHDR': isHdr,
            'codec': selectedVideo.codecs ?? '',
            'width': selectedVideo.width ?? 0,
            'height': selectedVideo.height ?? 0,
            ...nativePlaybackExtras,
          };
        }

        final sourceSegments = response.durl ?? const [];
        if (sourceSegments.isNotEmpty) {
          await prepareSource(sourceSegments.first.playUrls);
        }
        final segments = sourceSegments
            .where((segment) => segment.playUrls.isNotEmpty)
            .map((segment) {
              final urls = nativeTrackUrls(segment.playUrls);
              return {
                'url': urls.firstOrNull ?? '',
                'videoURLs': urls,
                'duration': segment.length ?? 0,
                'size': segment.size ?? 0,
              };
            })
            .where((segment) => (segment['url'] as String).isNotEmpty)
            .toList();
        if (segments.isEmpty) {
          return const {'state': 'error', 'error': '原生播放器暂时无法解析该视频格式'};
        }
        final currentQuality = response.quality ?? quality;
        final currentQualityIndex = qualityValues.indexOf(currentQuality);
        return {
          'state': 'success',
          'segments': segments,
          // Kept for one release so older native shells still understand this
          // response while the custom UIKit player consumes `segments`.
          'urls': segments.map((segment) => segment['url']).toList(),
          'quality': currentQuality,
          'qualityText':
              currentQualityIndex >= 0 &&
                  currentQualityIndex < qualityDescriptions.length
              ? qualityDescriptions[currentQualityIndex].toString()
              : '${currentQuality}P',
          'qualities': qualities,
          'duration': response.timeLength ?? 0,
          'segmentCount': segments.length,
          'streamKind': 'progressive',
          'isHDR': false,
          ...nativePlaybackExtras,
        };
      }(),
    };
  }

  Future<Map<String, dynamic>> _loadNativePlaybackMetadata(
    Map<dynamic, dynamic> arguments,
  ) {
    var aid = _asInt(arguments['aid']);
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    if (aid == null && bvid != null) aid = IdUtils.bv2av(bvid);
    final cid = _asInt(arguments['cid']);
    return _dedupedFetch(
      'metadata:$aid:$cid',
      () => _loadNativePlaybackMetadataUncached(arguments),
    );
  }

  Future<Map<String, dynamic>> _loadNativePlaybackMetadataUncached(
    Map<dynamic, dynamic> arguments,
  ) async {
    final cid = _asInt(arguments['cid']);
    var aid = _asInt(arguments['aid']);
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    if (aid == null && bvid != null) aid = IdUtils.bv2av(bvid);
    if (cid == null || cid <= 0 || aid == null || aid <= 0) {
      return const {'state': 'error', 'error': '播放参数不完整'};
    }

    final subtitleRows = <Map<String, dynamic>>[];
    int? lastPlayCid;
    final playInfoResult = await VideoHttp.playInfo(
      aid: aid.toString(),
      bvid: bvid,
      cid: cid,
    );
    if (playInfoResult case Success(:final response)) {
      lastPlayCid = response.lastPlayCid;
      for (final item in response.subtitle?.subtitles ?? const []) {
        final rawUrl = item.subtitleUrl ?? item.subtitleUrlV2;
        if (rawUrl == null || rawUrl.isEmpty) continue;
        subtitleRows.add({
          'id': '${item.lan}-${subtitleRows.length}',
          'label': item.lanDoc ?? item.lan,
          'language': item.lan,
          'url': rawUrl,
          'isAI': item.isAi,
        });
      }
    }
    if (subtitleRows.isEmpty && !Accounts.main.isLogin) {
      final dmView = await DmGrpc.dmView(aid, cid);
      if (dmView case Success(:final response) when response.hasSubtitle()) {
        for (final item in response.subtitle.subtitles) {
          if (item.subtitleUrl.isEmpty) continue;
          subtitleRows.add({
            'id': '${item.lan}-${subtitleRows.length}',
            'label': item.lanDoc,
            'language': item.lan,
            'url': item.subtitleUrl,
            'isAI': item.lan.startsWith('ai'),
          });
        }
      }
    }
    subtitleRows.sort((a, b) {
      final aLanguage = a['language'] as String? ?? '';
      final bLanguage = b['language'] as String? ?? '';
      final zhOrder = bLanguage.contains('zh') ? 1 : 0;
      final otherZhOrder = aLanguage.contains('zh') ? 1 : 0;
      if (zhOrder != otherZhOrder) return zhOrder - otherZhOrder;
      return (a['isAI'] == true ? 1 : 0) - (b['isAI'] == true ? 1 : 0);
    });
    if (subtitleRows.isNotEmpty) {
      final subtitleDirectory = Directory(
        '${Directory.systemTemp.path}/piliglass-native-subtitles/$aid-$cid',
      );
      try {
        if (!await subtitleDirectory.exists()) {
          await subtitleDirectory.create(recursive: true);
        }
        final preparedRows = await Future.wait(
          subtitleRows.asMap().entries.map((entry) async {
            final row = entry.value;
            final rawUrl = row['url'] as String;
            final file = File(
              '${subtitleDirectory.path}/subtitle-'
              '${base64Url.encode(utf8.encode(rawUrl)).replaceAll(RegExp(r'[^A-Za-z0-9]'), '').substring(0, 24)}'
              '.vtt',
            );
            if (await file.exists()) {
              return <String, dynamic>{...row, 'localPath': file.path};
            }
            try {
              final subtitleUrl = rawUrl.replaceFirst(RegExp(r'^https?:'), '');
              final content = await VideoHttp.getSubtitles(subtitleUrl)
                  .timeout(const Duration(seconds: 4));
              if (content == null || content.isEmpty) return null;
              await file.writeAsString(content, flush: false);
              return <String, dynamic>{...row, 'localPath': file.path};
            } catch (_) {
              return null;
            }
          }),
        );
        subtitleRows
          ..clear()
          ..addAll(preparedRows.whereType<Map<String, dynamic>>());
      } catch (_) {
        subtitleRows.clear();
      }
    }
    final subtitlePreference = GStorage.setting.get(
      SettingBoxKey.subtitlePreferenceV2,
      defaultValue: 0,
    );
    String? defaultSubtitleId;
    if (subtitleRows.isNotEmpty && subtitlePreference != 0) {
      final firstIsAI = subtitleRows.first['isAI'] == true;
      if (subtitlePreference == 1 || !firstIsAI) {
        defaultSubtitleId = subtitleRows.first['id'] as String;
      }
    }
    return {
      'state': 'success',
      'lastPlayCid': lastPlayCid,
      'subtitles': subtitleRows,
      'defaultSubtitleId': defaultSubtitleId,
    };
  }

  Future<Map<String, dynamic>> _reportNativePlaybackProgress(
    Map<dynamic, dynamic> arguments,
  ) async {
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    final cid = _asInt(arguments['cid']);
    final progress = _asInt(arguments['progress']);
    if (!Accounts.heartbeat.isLogin ||
        bvid == null ||
        cid == null ||
        progress == null ||
        progress < 0) {
      return const {'state': 'ignored'};
    }
    try {
      await VideoHttp.heartBeat(
        bvid: bvid,
        cid: cid,
        progress: progress,
        videoType: VideoType.ugc,
      );
      return const {'state': 'success'};
    } catch (error) {
      return {'state': 'error', 'error': error.toString()};
    }
  }

  Future<Map<String, dynamic>> _loadNativeDanmaku(
    Map<dynamic, dynamic> arguments,
  ) async {
    final cid = _asInt(arguments['cid']);
    final segmentIndex = _asInt(arguments['segmentIndex']) ?? 0;
    if (cid == null || cid <= 0 || segmentIndex < 0) {
      return const {'state': 'error', 'error': '弹幕参数不完整'};
    }

    final result = await DmGrpc.dmSegMobile(
      cid: cid,
      segmentIndex: segmentIndex + 1,
    );
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '弹幕加载失败',
        'code': ?code,
      },
      Success(:final response) => {
        'state': 'success',
        'segmentIndex': segmentIndex,
        'closed': response.state == 1,
        'items': response.elems
            .where((item) => item.content.isNotEmpty)
            .map(
              (item) => {
                'id': item.idStr.isNotEmpty ? item.idStr : item.id.toString(),
                'progress': item.progress,
                'mode': item.mode,
                'fontSize': item.fontsize,
                'color': item.color,
                'content': item.content,
                'weight': item.weight,
                'midHash': item.midHash,
                'pool': item.pool,
                'isSelf': item.isSelf,
              },
            )
            .toList(),
      },
    };
  }

  Future<Map<String, dynamic>> _sendNativeDanmaku(
    Map<dynamic, dynamic> arguments,
  ) async {
    final cid = _asInt(arguments['cid']);
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    final content = _nonEmpty(arguments['content']?.toString());
    final progress = _asInt(arguments['progress']) ?? 0;
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }
    if (cid == null || cid <= 0 || bvid == null || content == null) {
      return const {'state': 'error', 'error': '弹幕参数不完整'};
    }

    final result = await DanmakuHttp.shootDanmaku(
      oid: cid,
      bvid: bvid,
      msg: content.length > 100 ? content.substring(0, 100) : content,
      progress: progress < 0 ? 0 : progress,
      mode: 1,
      fontSize: 25,
      color: 0xFFFFFF,
    );
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '弹幕发送失败',
        'code': ?code,
      },
      Success(:final response) => {
        'state': 'success',
        'message': '弹幕发送成功',
        'dmid': response.dmid,
      },
    };
  }

  Future<Map<String, dynamic>> _performVideoAction(
    Map<dynamic, dynamic> arguments,
  ) async {
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    final action = arguments['action']?.toString();
    if (bvid == null || action == null) {
      return const {'state': 'error', 'error': '缺少视频操作参数'};
    }
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }

    switch (action) {
      case 'like':
        final relation = await VideoHttp.videoRelation(bvid: bvid);
        if (relation case Success(:final response)) {
          final liked = response.like == true;
          final result = await VideoHttp.likeVideo(bvid: bvid, type: !liked);
          return switch (result) {
            Success(:final response) => {
              'state': 'success',
              'message': !liked ? response : '已取消点赞',
              'liked': !liked,
            },
            Error(:final errMsg) => {
              'state': 'error',
              'error': errMsg ?? '点赞失败',
            },
            _ => const {'state': 'error', 'error': '点赞失败'},
          };
        }
        return const {'state': 'error', 'error': '点赞状态获取失败'};
      case 'coin':
        final result = await VideoHttp.coinVideo(bvid: bvid, multiply: 1);
        return switch (result) {
          Success() => const {'state': 'success', 'message': '投币成功'},
          Error(:final errMsg) => {'state': 'error', 'error': errMsg ?? '投币失败'},
          _ => const {'state': 'error', 'error': '投币失败'},
        };
      case 'favorite':
        final aid = IdUtils.bv2av(bvid);
        final folders = await FavHttp.videoInFolder(
          mid: Accounts.main.mid,
          rid: aid,
          type: 2,
        );
        if (folders case Success(:final response)) {
          final list = response.list ?? const [];
          final selected = list.where((item) => item.favState == 1).toList();
          final result = selected.isNotEmpty
              ? await FavHttp.unfavAll(rid: aid, type: 2)
              : list.isEmpty
              ? const Error('没有可用的收藏夹')
              : await FavHttp.favVideo(
                  resources: '$aid:2',
                  addIds: list.first.id.toString(),
                );
          return switch (result) {
            Success() => {
              'state': 'success',
              'message': selected.isNotEmpty ? '已取消收藏' : '已收藏到默认收藏夹',
              'favorite': selected.isEmpty,
            },
            Error(:final errMsg) => {
              'state': 'error',
              'error': errMsg ?? '收藏失败',
            },
            _ => const {'state': 'error', 'error': '收藏失败'},
          };
        }
        return const {'state': 'error', 'error': '收藏夹加载失败'};
      case 'share':
        return {
          'state': 'success',
          'message': '分享链接已准备',
          'shareURL': 'https://www.bilibili.com/video/$bvid',
        };
      case 'triple':
        final result = await VideoHttp.ugcTriple(bvid: bvid);
        return switch (result) {
          Success(:final response) => {
            'state': 'success',
            'message': '一键三连成功',
            'like': response.like == true,
            'coin': response.coin == true,
            'favorite': response.fav == true,
            'coinCount': response.multiply ?? 0,
          },
          Error(:final errMsg) => {
            'state': 'error',
            'error': errMsg ?? '一键三连失败',
          },
          _ => const {'state': 'error', 'error': '一键三连失败'},
        };
      case 'later':
        final result = await UserHttp.toViewLater(bvid: bvid);
        return result.isSuccess
            ? const {'state': 'success', 'message': '已添加到稍后再看'}
            : const {'state': 'error', 'error': '添加稍后再看失败'};
      default:
        return const {'state': 'error', 'error': '不支持的视频操作'};
    }
  }

  Future<Map<String, dynamic>> _changeNativeVideoPart(
    Map<dynamic, dynamic> arguments,
  ) async {
    final heroTag = _nonEmpty(arguments['heroTag']?.toString());
    final cid = _asInt(arguments['cid']);
    if (heroTag == null || cid == null) {
      return const {'state': 'error', 'error': '分P参数无效'};
    }
    try {
      final controller = Get.find<UgcIntroController>(tag: heroTag);
      final pages = controller.videoDetail.value.pages;
      if (pages == null || pages.isEmpty) {
        return const {'state': 'error', 'error': '分P数据尚未加载'};
      }
      for (final page in pages) {
        if (page.cid == cid) {
          final changed = await controller.onChangeEpisode(page);
          return changed
              ? const {'state': 'success'}
              : const {'state': 'error', 'error': '切换分P失败'};
        }
      }
      return const {'state': 'error', 'error': '没有找到对应分P'};
    } catch (_) {
      return const {'state': 'error', 'error': '播放器简介尚未就绪'};
    }
  }

  Future<Map<String, dynamic>> _refreshNativePlayerSurface(
    Map<dynamic, dynamic> arguments,
  ) async {
    final heroTag = _nonEmpty(arguments['heroTag']?.toString());
    if (heroTag == null) {
      return const {'state': 'error', 'error': '播放器参数无效'};
    }
    try {
      final controller = Get.find<UgcIntroController>(tag: heroTag);
      controller.videoDetailCtr.plPlayerController.refreshVideoTexture();
      return const {'state': 'success'};
    } catch (_) {
      return const {'state': 'error', 'error': '播放器表面尚未就绪'};
    }
  }

  static const List<Map<String, dynamic>> _nativeSettingDefinitions = [
    {
      'key': SettingBoxKey.p1080,
      'title': '免登录 1080P',
      'subtitle': '未登录时仍请求可用的 1080P 视频轨道',
      'group': '音视频与画质',
      'icon': 'rectangle.badge.hd',
      'default': true,
    },
    {
      'key': SettingBoxKey.disableAudioCDN,
      'title': '音频不跟随视频 CDN',
      'subtitle': '音轨直接使用备用地址，可改善部分视频无声问题',
      'group': '音视频与画质',
      'icon': 'waveform.badge.plus',
      'default': false,
    },
    {
      'key': SettingBoxKey.appRcmd,
      'title': '使用 App 端推荐',
      'subtitle': '使用 App 推荐接口；修改后重启客户端生效',
      'group': '推荐与搜索',
      'icon': 'sparkles',
      'default': true,
      'needsRestart': true,
    },
    {
      'key': SettingBoxKey.enableSaveLastData,
      'title': '保留上次推荐内容',
      'subtitle': '下拉刷新时保留上一次推荐',
      'group': '推荐与搜索',
      'icon': 'arrow.clockwise',
      'default': true,
    },
    {
      'key': SettingBoxKey.checkDynamic,
      'title': '检查未读动态',
      'subtitle': '定时更新主界面的动态未读标记',
      'group': '通用功能',
      'icon': 'bell.badge',
      'default': true,
    },
  ];

  Map<String, dynamic> _nativeSettingsSnapshot() => {
    'state': 'success',
    'playbackSource': GStorage.setting.get(SettingBoxKey.CDNService) ?? 'auto',
    'playbackSources': [
      {'value': 'auto', 'label': '自动（选择下载最快的线路）'},
      for (final cdn in CDNService.values)
        {
          'value': cdn.name,
          'label': cdn.desc,
          // Original project's measurement: bytes/µs => MB/s text.
          'speedMBps': _cdnLatency.isFresh
              ? _cdnLatency.measurements[cdn.name]?.megabytesPerSecond
              : null,
          'speedText': _cdnLatency.isFresh
              ? _speedText(_cdnLatency.measurements[cdn.name])
              : null,
          'latencyState': _cdnLatency.isFresh
              ? (_cdnLatency.measurements[cdn.name]?.status ?? 'untested')
              : 'untested',
        },
    ],
    'automaticPlaybackSource': _cdnLatency.bestSource(
      _latencyCandidates(_latencySampleURLs),
    ),
    'liveCDN': GStorage.setting.get(SettingBoxKey.liveCdnUrl) ?? '',
    'defaultVideoQuality': GStorage.setting.get(
      SettingBoxKey.defaultVideoQa,
      defaultValue: VideoQuality.super8k.code,
    ),
    'videoQualities': VideoQuality.values
        .map(
          (quality) => {
            'value': quality.code,
            'label': quality.desc,
            'shortLabel': quality.shortDesc,
          },
        )
        .toList(),
    'items': _nativeSettingDefinitions
        .map(
          (item) => {
            ...item,
            'value': GStorage.setting.get(
              item['key'],
              defaultValue: item['default'],
            ),
          },
        )
        .toList(),
  };

  Future<Map<String, dynamic>> _setNativeSetting(
    Map<dynamic, dynamic> arguments,
  ) async {
    final key = arguments['key']?.toString();
    final isAllowed = _nativeSettingDefinitions.any(
      (item) => item['key'] == key,
    );
    if (!isAllowed || arguments['value'] is! bool) {
      return const {'state': 'error', 'error': '不支持的设置项'};
    }
    final value = arguments['value'] as bool;
    await GStorage.setting.put(key, value);
    if (key == SettingBoxKey.enableSaveLastData) {
      _homeController
        ..enableSaveLastData = value
        ..lastRefreshAt = null;
    } else if (key == SettingBoxKey.checkDynamic) {
      mainController.checkDynamic = value;
    } else if (key == SettingBoxKey.disableAudioCDN) {
      VideoUtils.disableAudioCDN = value;
    }
    return _nativeSettingsSnapshot();
  }

  Future<Map<String, dynamic>> _setNativeVideoQuality(
    Map<dynamic, dynamic> arguments,
  ) async {
    final value = _asInt(arguments['value']);
    if (value == null ||
        !VideoQuality.values.any((quality) => quality.code == value)) {
      return const {'state': 'error', 'error': '不支持的视频分辨率'};
    }
    await GStorage.setting.put(SettingBoxKey.defaultVideoQa, value);
    return _nativeSettingsSnapshot();
  }

  Future<Map<String, dynamic>> _setNativePlaybackSource(
    Map<dynamic, dynamic> arguments,
  ) async {
    final value = arguments['value'];
    if (value is! String) {
      return const {'state': 'error', 'error': '播放源参数无效'};
    }
    switch (arguments['kind']) {
      case 'video':
        if (value == 'auto') {
          await GStorage.setting.delete(SettingBoxKey.CDNService);
          VideoUtils.cdnService = CDNService.backupUrl;
        } else {
          final source = CDNService.values
              .where((cdn) => cdn.name == value)
              .firstOrNull;
          if (source == null) {
            return const {'state': 'error', 'error': '不支持的播放源'};
          }
          await GStorage.setting.put(SettingBoxKey.CDNService, source.name);
          VideoUtils.cdnService = source;
        }
      case 'live':
        final String? origin;
        try {
          origin = normalizeLiveCDN(value);
        } on FormatException catch (error) {
          return {'state': 'error', 'error': error.message};
        }
        if (origin == null) {
          await GStorage.setting.delete(SettingBoxKey.liveCdnUrl);
        } else {
          await GStorage.setting.put(SettingBoxKey.liveCdnUrl, origin);
        }
        VideoUtils.liveCdnUrl = origin;
      default:
        return const {'state': 'error', 'error': '不支持的播放源类型'};
    }
    return _nativeSettingsSnapshot();
  }

  Map<String, String> _latencyCandidates(Iterable<String> urls) {
    final raw = urls.where((url) => url.isNotEmpty).toList();
    if (raw.isEmpty) return const {};
    final candidates = <String, String>{};
    for (final cdn in [
      CDNService.baseUrl,
      CDNService.backupUrl,
      CDNService.ali,
      CDNService.cos,
      CDNService.hw,
      CDNService.akamai,
    ]) {
      final url = VideoUtils.getCdnUrl(raw, defaultCDNService: cdn);
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'https' && uri.scheme != 'http') ||
          uri.host.isEmpty)
        continue;
      // Don't label an unchanged fallback URL as a different CDN's result.
      if (cdn.host != null && uri.host != cdn.host) continue;
      candidates[cdn.name] = url;
    }
    return candidates;
  }

  Future<Map<String, dynamic>> _testNativePlaybackSources(
    Map<dynamic, dynamic> arguments,
  ) async {
    if (_latencyTest != null) return _latencyTest!;
    final request = _runPlaybackSourceTest(force: arguments['force'] == true);
    _latencyTest = request;
    try {
      return await request;
    } finally {
      _latencyTest = null;
    }
  }

  Future<Map<String, dynamic>> _runPlaybackSourceTest({
    required bool force,
  }) async {
    if (!force && _cdnLatency.isFresh && _cdnLatency.measurements.isNotEmpty) {
      await _cdnLatency.test(_latencyCandidates(_latencySampleURLs));
      return _nativeSettingsSnapshot();
    }
    try {
      if (_latencySampleURLs.isEmpty ||
          _latencySampleTime == null ||
          DateTime.now().difference(_latencySampleTime!) >
              const Duration(minutes: 1)) {
        // Same public sample as the original project's CDN settings dialog.
        final sample = await VideoHttp.videoUrl(
          cid: 196018899,
          bvid: 'BV1fK4y1t7hj',
          tryLook: !Accounts.get(AccountType.video).isLogin,
          videoType: VideoType.ugc,
        ).timeout(const Duration(seconds: 6));
        _latencySampleURLs =
            sample.dataOrNull?.dash?.video?.firstOrNull?.playUrls.toList() ??
            [];
        _latencySampleTime = DateTime.now();
      }
      final candidates = _latencyCandidates(_latencySampleURLs);
      if (candidates.isEmpty) {
        return const {'state': 'error', 'error': '暂时无法取得测试视频，请播放一个视频后重试'};
      }
      await _cdnLatency.test(candidates, force: force);
      return _nativeSettingsSnapshot();
    } catch (_) {
      return const {'state': 'error', 'error': '线路检测失败，请检查网络后重试'};
    }
  }

  Future<void> _openDynamic(Map<dynamic, dynamic> arguments) async {
    final id = _numericDynamicID(arguments['id']);
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

  Future<Map<String, dynamic>> _loadNativeDynamicDetail(
    Map<dynamic, dynamic> arguments,
  ) async {
    final id = _numericDynamicID(arguments['id']);
    if (id == null) {
      return const {'state': 'error', 'error': '动态编号无效'};
    }
    final result = await DynamicsHttp.dynamicDetail(id: id);
    return switch (result) {
      Success(:final response) => {
        'state': 'success',
        'dynamic': _dynamicMap(response, 0),
      },
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '动态详情加载失败',
        'code': ?code,
      },
      Loading() => const {'state': 'loading'},
    };
  }

  Future<Map<String, dynamic>> _setNativeDynamicLike(
    Map<dynamic, dynamic> arguments,
  ) async {
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }
    final id = _numericDynamicID(arguments['id']);
    final liked = arguments['liked'] == true;
    if (id == null) {
      return const {'state': 'error', 'error': '动态编号无效'};
    }
    final result = await DynamicsHttp.thumbDynamic(
      dynamicId: id,
      up: liked ? 2 : 1,
    );
    return switch (result) {
      Success() => {'state': 'success', 'liked': !liked},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '动态点赞失败',
        'code': ?code,
      },
      Loading() => const {'state': 'loading'},
    };
  }

  Future<Map<String, dynamic>> _repostNativeDynamic(
    Map<dynamic, dynamic> arguments,
  ) async {
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }
    final id = _numericDynamicID(arguments['id']);
    final message = arguments['message']?.toString().trim() ?? '';
    if (id == null) {
      return const {'state': 'error', 'error': '动态编号无效'};
    }
    final result = await DynamicsHttp.createDynamic(
      mid: Accounts.main.mid,
      dynIdStr: id,
      rawText: message,
    );
    return switch (result) {
      Success(:final response) => {
        'state': 'success',
        'id': response?['dyn_id']?.toString(),
        'message': '转发成功',
      },
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '动态转发失败',
        'code': ?code,
      },
      Loading() => const {'state': 'loading'},
    };
  }

  static const Set<String> _allowedRoutes = {
    '/articleList',
    '/download',
    '/fan',
    '/fav',
    '/favDetail',
    '/follow',
    '/history',
    '/later',
    '/loginPage',
    '/liveRoom',
    '/member',
    '/memberDynamics',
    '/search',
    '/setting',
    '/subscription',
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
    if (route == '/liveRoom') {
      final roomId = _asInt(parameters?['roomId']);
      PageUtils.toLiveRoom(roomId);
      return;
    }
    await Get.toNamed(route, parameters: parameters, preventDuplicates: false);
  }

  Future<Map<String, dynamic>> _searchVideos(
    Map<dynamic, dynamic> arguments,
  ) async {
    final keyword = _nonEmpty(arguments['keyword']?.toString());
    if (keyword == null) {
      return const {'state': 'success', 'items': <Map<String, dynamic>>[]};
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
        'hasMore':
            (response.list?.isNotEmpty ?? false) &&
            page * 20 < (response.numResults ?? 0),
        'items': (response.list ?? const [])
            .asMap()
            .entries
            .map((entry) => _videoMap(entry.value, entry.key))
            .toList(),
      },
    };
  }

  Future<Map<String, dynamic>> _loadNativeLibrary(
    Map<dynamic, dynamic> arguments,
  ) async {
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }

    final kind = arguments['kind']?.toString();
    final page = _asInt(arguments['page']) ?? 1;
    try {
      return switch (kind) {
        'history' => await _loadNativeHistory(arguments),
        'later' => await _loadNativeLater(page),
        'favorites' => await _loadNativeFavoriteFolders(page),
        'favoriteDetail' => await _loadNativeFavoriteDetail(arguments, page),
        'following' => await _loadNativeRelations(page, followers: false),
        'followers' => await _loadNativeRelations(page, followers: true),
        'subscriptions' => await _loadNativeSubscriptions(page),
        'subscriptionDetail' => await _loadNativeSubscriptionDetail(
          arguments,
          page,
        ),
        _ => const {'state': 'error', 'error': '暂不支持的原生列表'},
      };
    } catch (error) {
      return {'state': 'error', 'error': '加载失败：$error'};
    }
  }

  Future<Map<String, dynamic>> _loadNativeProfileSection(
    Map<dynamic, dynamic> arguments,
  ) async {
    final mid = _asInt(arguments['mid']);
    if (mid == null || mid <= 0) {
      return const {'state': 'error', 'error': '用户参数无效'};
    }
    final page = (_asInt(arguments['page']) ?? 1).clamp(1, 10000);
    switch (arguments['kind']) {
      case 'favorites':
        return _loadNativeFavoriteFolders(page, mid: mid);
      case 'dynamics':
        final result = await MemberHttp.memberDynamic(
          mid: mid,
          offset: arguments['offset']?.toString() ?? '',
        );
        return switch (result) {
          Success(:final response) => {
            'state': 'success',
            'offset': response.offset ?? '',
            'hasMore':
                response.hasMore == true &&
                response.offset?.isNotEmpty == true &&
                response.offset != '-1',
            'items': (response.items ?? const <DynamicItemModel>[])
                .asMap()
                .entries
                .map((entry) => _dynamicMap(entry.value, entry.key))
                .toList(),
          },
          Error(:final errMsg) => {
            'state': 'error',
            'error': errMsg ?? '动态加载失败',
          },
          Loading() => const {'state': 'loading'},
        };
      case 'bangumi':
        final result = await MemberHttp.spaceArchive(
          type: ContributeType.bangumi,
          mid: mid,
          pn: page,
        );
        return switch (result) {
          Success(:final response) => {
            'state': 'success',
            'hasMore': (response.item?.length ?? 0) >= 20,
            'items': (response.item ?? const []).asMap().entries.map((entry) {
              final item = entry.value;
              return {
                'id': 'bangumi-${item.param ?? entry.key}',
                'kind': 'bangumi',
                'title': item.title,
                'subtitle': item.label ?? item.styles ?? '',
                'cover': _normalizeURL(item.cover),
                'bvid': item.bvid,
                'url': item.uri,
              };
            }).toList(),
          },
          Error(:final errMsg) => {
            'state': 'error',
            'error': errMsg ?? '追番加载失败',
          },
          Loading() => const {'state': 'loading'},
        };
      default:
        return const {'state': 'error', 'error': '不支持的主页内容'};
    }
  }

  Future<Map<String, dynamic>> _saveNativeProfileSign(
    Map<dynamic, dynamic> arguments,
  ) async {
    final mid = _asInt(arguments['mid']);
    final sign = arguments['sign'];
    if (!Accounts.main.isLogin || mid != Accounts.main.mid) {
      return const {'state': 'error', 'error': '只能编辑当前账号资料'};
    }
    if (sign is! String || sign.runes.length > 70) {
      return const {'state': 'error', 'error': '个性签名最多 70 字'};
    }
    final key = Accounts.main.accessKey;
    if (key == null || key.isEmpty)
      return const {'state': 'error', 'error': '请重新登录后再编辑资料'};
    final data = <String, String>{
      'access_key': key,
      'build': '2001100',
      'c_locale': 'zh_CN',
      'channel': 'master',
      'mobi_app': 'android_hd',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statistics,
      'user_sign': sign,
    };
    AppSign.appSign(data);
    final result = await Request().post(
      '/x/member/app/sign/update',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    return result.data['code'] == 0
        ? const {'state': 'success'}
        : {
            'state': 'error',
            'error': result.data['message']?.toString() ?? '保存失败',
          };
  }

  Future<Map<String, dynamic>> _loadNativeProfile(
    Map<dynamic, dynamic> arguments,
  ) async {
    final mid = _asInt(arguments['mid']);
    if (mid == null || mid <= 0) {
      return const {'state': 'error', 'error': '用户参数无效'};
    }
    final result = await MemberHttp.space(mid: mid);
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '个人空间加载失败',
        'code': ?code,
      },
      Success(:final response) => () {
        final card = response.card;
        final videos = response.archive?.item ?? const [];
        return {
          'state': 'success',
          'profile': {
            'mid': mid,
            'name': card?.name ?? '用户 $mid',
            'face': _normalizeURL(card?.face),
            'topImage': _normalizeURL(response.images?.imgUrl),
            'sign': card?.sign ?? '',
            'location': card?.prInfo?.content ?? '',
            'level': card?.levelInfo?.currentLevel ?? 0,
            'followers': card?.fans ?? 0,
            'following': card?.attention ?? 0,
            'likes': card?.likes?.likeNum ?? 0,
            'official': card?.officialVerify?.desc ?? '',
            'vip': (card?.vip?.status ?? 0) > 0,
            'isSelf': mid == Accounts.main.mid,
            'isFollowing': card?.relation?.isFollow == 1,
            'videoCount': response.archive?.count ?? videos.length,
            'tags': (card?.spaceTag ?? const [])
                .map((item) => item.title)
                .whereType<String>()
                .where((item) => item.isNotEmpty)
                .toList(),
            'videos': videos.asMap().entries.map((entry) {
              final item = entry.value;
              final bvid = _nonEmpty(item.bvid);
              final aid = bvid == null ? null : IdUtils.bv2av(bvid);
              return {
                'id': bvid ?? 'profile-video-${entry.key}',
                'aid': aid,
                'bvid': bvid,
                'title': item.title,
                'cover': _normalizeURL(item.cover),
                'owner': card?.name ?? '',
                'viewText': _compactNumber(item.stat.view),
                'danmakuText': _compactNumber(item.stat.danmu),
                'durationText': _durationText(item.duration),
              };
            }).toList(),
          },
        };
      }(),
    };
  }

  Future<Map<String, dynamic>> _setNativeProfileFollow(
    Map<dynamic, dynamic> arguments,
  ) async {
    final mid = _asInt(arguments['mid']);
    final follow = arguments['follow'] == true;
    if (mid == null || mid <= 0 || mid == Accounts.main.mid) {
      return const {'state': 'error', 'error': '不能修改该用户的关注状态'};
    }
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }
    final result = await VideoHttp.relationMod(
      mid: mid,
      act: follow ? 1 : 2,
      reSrc: 11,
    );
    return result.isSuccess
        ? {
            'state': 'success',
            'isFollowing': follow,
            'message': follow ? '关注成功' : '已取消关注',
          }
        : const {'state': 'error', 'error': '关注状态修改失败'};
  }

  Future<Map<String, dynamic>> _loadNativeProfileVideos(
    Map<dynamic, dynamic> arguments,
  ) async {
    final mid = _asInt(arguments['mid']);
    final page = _asInt(arguments['page']) ?? 1;
    if (mid == null || mid <= 0 || page <= 0) {
      return const {'state': 'error', 'error': '用户投稿参数无效'};
    }

    final result = await MemberHttp.searchArchive(mid: mid, ps: 30, pn: page);
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '用户投稿加载失败',
        'code': ?code,
      },
      Success(:final response) => () {
        final videos = response.list?.vlist ?? const [];
        final total = response.page?.count ?? videos.length;
        return {
          'state': 'success',
          'page': page,
          'total': total,
          'hasMore': videos.isNotEmpty && page * 30 < total,
          'items': videos.asMap().entries.map((entry) {
            final item = entry.value;
            final bvid = _nonEmpty(item.bvid);
            return {
              'id':
                  bvid ??
                  item.aid?.toString() ??
                  'profile-video-$page-${entry.key}',
              'aid': item.aid,
              'bvid': bvid,
              'title': item.title,
              'cover': _normalizeURL(item.cover),
              'owner': item.owner.name ?? '',
              'viewText': _compactNumber(item.stat.view),
              'danmakuText': _compactNumber(item.stat.danmu),
              'durationText': _durationText(item.duration),
            };
          }).toList(),
        };
      }(),
    };
  }

  Future<Map<String, dynamic>> _startNativeLogin() async {
    final result = await LoginHttp.getHDcode();
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '登录二维码获取失败',
        'code': ?code,
      },
      Success(:final response) => () {
        _nativeLoginAuthCode = response.authCode;
        return {'state': 'success', 'url': response.url, 'expiresIn': 180};
      }(),
    };
  }

  Future<Map<String, dynamic>> _pollNativeLogin() async {
    final authCode = _nativeLoginAuthCode;
    if (authCode == null || authCode.isEmpty) {
      return const {'state': 'expired', 'message': '二维码已失效，请刷新'};
    }
    try {
      final result = await LoginHttp.codePoll(authCode);
      if (result['status'] == true) {
        final data = result['data'] as Map;
        final cookieInfo = data['cookie_info']?['cookies'] as List?;
        if (cookieInfo == null) {
          return const {'state': 'error', 'message': '登录接口未返回身份信息'};
        }
        final account = LoginAccount(
          BiliCookieJar.fromList(cookieInfo),
          data['access_token']?.toString(),
          data['refresh_token']?.toString(),
        );
        for (final type in AccountType.values) {
          await Accounts.set(type, account);
        }
        await AnonymousAccount().delete();
        _nativeLoginAuthCode = null;
        await _mineController.onRefresh();
        _scheduleSnapshot();
        return {'state': 'success', 'message': '登录成功', 'mid': account.mid};
      }
      final code = _asInt(result['code']);
      if (code == 86038) {
        _nativeLoginAuthCode = null;
        return const {'state': 'expired', 'message': '二维码已过期，请刷新'};
      }
      return {
        'state': 'waiting',
        'message': result['msg']?.toString() ?? '等待扫码确认',
        'code': ?code,
      };
    } catch (error) {
      return {'state': 'error', 'message': '登录状态检查失败：$error'};
    }
  }

  Future<Map<String, dynamic>> _loadNativeSessions({
    required bool refresh,
  }) async {
    if (refresh) {
      _nativeSessionOffsets = null;
    }
    final result = await ImGrpc.sessionMain(
      offset: refresh ? null : _nativeSessionOffsets,
    );
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg) => {'state': 'error', 'error': errMsg ?? '私信会话加载失败'},
      Success(:final response) => () {
        _nativeSessionOffsets = response.paginationParams.offsets;
        return {
          'state': 'success',
          'hasMore': response.paginationParams.hasMore,
          'items': response.sessions.asMap().entries.map((entry) {
            final item = entry.value;
            final avatarItem = item.sessionInfo.avatar;
            final layers = avatarItem.fallbackLayers.layers;
            String? avatar;
            if (layers.isNotEmpty) {
              final resource = layers.first.resource;
              if (resource.hasResImage()) {
                avatar = resource.resImage.imageSrc.remote.url;
              } else if (resource.hasResAnimation()) {
                avatar = resource.resAnimation.webpSrc.remote.url;
              } else if (resource.hasResNativeDraw()) {
                avatar = resource.resNativeDraw.drawSrc.remote.url;
              }
            }
            final talkerId =
                item.id.hasPrivateId() && item.id.privateId.hasTalkerUid()
                ? item.id.privateId.talkerUid.toInt()
                : null;
            final memberId = avatarItem.hasMid()
                ? avatarItem.mid.toInt()
                : null;
            final timestamp = item.hasTimestamp()
                ? (item.timestamp ~/ 1000000).toInt()
                : null;
            final identity =
                talkerId?.toString() ??
                '${item.id.whichId().name}-${item.sessionInfo.sessionName}';
            return {
              'id': 'session-$identity',
              'kind': 'session',
              'talkerId': talkerId,
              'memberId': memberId,
              'author': item.sessionInfo.sessionName,
              'avatar': _normalizeURL(avatar),
              'body': item.msgSummary.rawMsg,
              'context': '',
              'time': DateFormatUtils.dateFormat(timestamp),
              'badge': '',
              'unreadCount': item.hasUnread() ? item.unread.number.toInt() : 0,
              'hasUnread': item.hasUnread() && item.unread.style.value != 0,
              'isMuted': item.isMuted,
              'isPinned': item.isPinned,
              'isLive': item.sessionInfo.isLive,
            };
          }).toList(),
        };
      }(),
    };
  }

  Future<Map<String, dynamic>> _loadNativeChat(
    Map<dynamic, dynamic> arguments,
  ) async {
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }
    final talkerId = _asInt(arguments['talkerId']);
    final endSeqno = _asInt(arguments['endSeqno']);
    if (talkerId == null || talkerId <= 0) {
      return const {'state': 'error', 'error': '私信会话参数无效'};
    }
    try {
      final result = await ImGrpc.syncFetchSessionMsgs(
        talkerId: talkerId,
        beginSeqno: endSeqno == null ? null : Int64.ZERO,
        endSeqno: endSeqno == null ? null : Int64(endSeqno),
      );
      return switch (result) {
        Loading() => const {'state': 'loading'},
        Error(:final errMsg) => {
          'state': 'error',
          'error': errMsg ?? '聊天记录加载失败',
        },
        Success(:final response) => () {
          final messages = response.messages
              .where(
                (item) => item.msgType != MsgType.EN_MSG_TYPE_DRAW_BACK.value,
              )
              .toList();
          final emotes = <String, String>{
            for (final info in response.eInfos)
              if (info.text.isNotEmpty &&
                  (info.gifUrl.isNotEmpty || info.url.isNotEmpty))
                info.text: info.gifUrl.isNotEmpty ? info.gifUrl : info.url,
          };
          final emoteRows = response.eInfos
              .where(
                (info) =>
                    info.text.isNotEmpty &&
                    (info.gifUrl.isNotEmpty || info.url.isNotEmpty),
              )
              .map(
                (info) => {
                  'text': info.text,
                  'url': _normalizeURL(
                    info.gifUrl.isNotEmpty ? info.gifUrl : info.url,
                  ),
                  'size': info.size.clamp(1, 2),
                },
              )
              .where((info) => info['url'] != null)
              .toList();
          if (messages.isNotEmpty) {
            unawaited(() async {
              await MsgHttp.ackSessionMsg(
                talkerId: talkerId,
                ackSeqno: messages.last.msgSeqno.toInt(),
              );
            }());
          }
          return {
            'state': 'success',
            'hasMore': response.hasMore != 0 && messages.isNotEmpty,
            'emotes': emoteRows,
            'nextSeqno': messages.isEmpty
                ? null
                : messages.last.msgSeqno.toInt(),
            'items': messages.asMap().entries.map((entry) {
              final item = entry.value;
              final content = _decodeNativeChatContent(item.content);
              final text = _nativeChatText(
                type: item.msgType,
                content: content,
                raw: item.content,
              );
              final image = _nativeChatImage(item.msgType, content);
              final cover =
                  _nonEmpty(content['cover']?.toString()) ??
                  _nonEmpty(content['thumb']?.toString()) ??
                  _nonEmpty(content['pic_url']?.toString());
              final title =
                  _nonEmpty(content['title']?.toString()) ??
                  _nonEmpty(content['main_title']?.toString());
              return {
                'id': item.msgKey.toString() != '0'
                    ? item.msgKey.toString()
                    : 'chat-${item.msgSeqno}-${entry.key}',
                'msgKey': item.msgKey.toInt(),
                'sequence': item.msgSeqno.toInt(),
                'type': item.msgType,
                'isOwner': item.senderUid.toInt() == Accounts.main.mid,
                'text': text,
                'image': _normalizeURL(image),
                'cover': _normalizeURL(cover),
                'title': title,
                'time': DateFormatUtils.chatFormat(item.timestamp.toInt()),
                'imageWidth': _asDouble(content['width']),
                'imageHeight': _asDouble(content['height']),
                'emote': _normalizeURL(emotes[text]),
                'isSystem': const [10, 11, 13, 16, 18].contains(item.msgType),
                'isRecalled': item.msgStatus == 1,
                'isAutoReply': item.msgSource >= 8 && item.msgSource <= 11,
              };
            }).toList(),
          };
        }(),
      };
    } catch (error) {
      return {'state': 'error', 'error': '聊天记录加载失败：$error'};
    }
  }

  Future<Map<String, dynamic>> _sendNativeChatMessage(
    Map<dynamic, dynamic> arguments,
  ) async {
    final talkerId = _asInt(arguments['talkerId']);
    final receiverId = _asInt(arguments['memberId']) ?? talkerId;
    final message = arguments['message']?.toString().trim() ?? '';
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }
    if (talkerId == null || receiverId == null || message.isEmpty) {
      return const {'state': 'error', 'error': '消息内容或会话参数无效'};
    }
    final result = await ImGrpc.sendMsg(
      senderUid: Accounts.main.mid,
      receiverId: receiverId,
      content: jsonEncode({'content': message}),
      msgType: MsgType.EN_MSG_TYPE_TEXT,
    );
    return switch (result) {
      Success() => const {'state': 'success'},
      Error(:final errMsg) => {'state': 'error', 'error': errMsg ?? '消息发送失败'},
      Loading() => const {'state': 'loading'},
    };
  }

  Future<Map<String, dynamic>> _sendNativeChatImage(
    Map<dynamic, dynamic> arguments,
  ) async {
    final talkerId = _asInt(arguments['talkerId']);
    final receiverId = _asInt(arguments['memberId']) ?? talkerId;
    final path = _nonEmpty(arguments['path']?.toString());
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }
    if (talkerId == null || receiverId == null || path == null) {
      return const {'state': 'error', 'error': '图片或会话参数无效'};
    }
    final upload = await MsgHttp.uploadBfs(path: path, biz: 'im');
    switch (upload) {
      case Loading():
        return const {'state': 'loading'};
      case Error(:final errMsg):
        return {'state': 'error', 'error': errMsg ?? '图片上传失败'};
      case Success(:final response):
        final imageMessage = {
          'url': response.imageUrl,
          'height': response.imageHeight,
          'width': response.imageWidth,
          'imageType': 'jpg',
          'original': 1,
          'size': response.imgSize,
        };
        final send = await ImGrpc.sendMsg(
          senderUid: Accounts.main.mid,
          receiverId: receiverId,
          content: jsonEncode(imageMessage),
          msgType: MsgType.EN_MSG_TYPE_PIC,
        );
        return switch (send) {
          Success() => const {'state': 'success'},
          Error(:final errMsg) => {
            'state': 'error',
            'error': errMsg ?? '图片消息发送失败',
          },
          Loading() => const {'state': 'loading'},
        };
    }
  }

  Future<Map<String, dynamic>> _recallNativeChatMessage(
    Map<dynamic, dynamic> arguments,
  ) async {
    final receiverId =
        _asInt(arguments['memberId']) ?? _asInt(arguments['talkerId']);
    final msgKey = _asInt(arguments['msgKey']);
    if (!Accounts.main.isLogin || receiverId == null || msgKey == null) {
      return const {'state': 'error', 'error': '撤回参数无效'};
    }
    final result = await ImGrpc.sendMsg(
      senderUid: Accounts.main.mid,
      receiverId: receiverId,
      content: '$msgKey',
      msgType: MsgType.EN_MSG_TYPE_DRAW_BACK,
    );
    return switch (result) {
      Success() => const {'state': 'success'},
      Error(:final errMsg) => {'state': 'error', 'error': errMsg ?? '消息撤回失败'},
      Loading() => const {'state': 'loading'},
    };
  }

  Map<String, dynamic> _decodeNativeChatContent(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is Map) {
        return value.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}
    return {'content': raw};
  }

  String _nativeChatText({
    required int type,
    required Map<String, dynamic> content,
    required String raw,
  }) {
    if (type == MsgType.EN_MSG_TYPE_TIP_MESSAGE.value) {
      try {
        final nested = jsonDecode(content['content']?.toString() ?? '[]');
        if (nested is List) {
          return nested
              .map((item) => item is Map ? item['text']?.toString() : null)
              .whereType<String>()
              .join('\n');
        }
      } catch (_) {}
    }
    return _nonEmpty(content['content']?.toString()) ??
        _nonEmpty(content['text']?.toString()) ??
        _nonEmpty(content['title']?.toString()) ??
        _nonEmpty(content['headline']?.toString()) ??
        (type == MsgType.EN_MSG_TYPE_PIC.value ? '[图片]' : raw);
  }

  String? _nativeChatImage(int type, Map<String, dynamic> content) {
    if (type == MsgType.EN_MSG_TYPE_PIC.value ||
        type == MsgType.EN_MSG_TYPE_CUSTOM_FACE.value) {
      return _nonEmpty(content['url']?.toString());
    }
    return null;
  }

  Future<Map<String, dynamic>> _loadNativeMessages(
    Map<dynamic, dynamic> arguments,
  ) async {
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }
    final kind = arguments['kind']?.toString() ?? 'reply';
    final cursor = _asInt(arguments['cursor']);
    final cursorTime = _asInt(arguments['cursorTime']);
    try {
      if (kind == 'sessions') {
        return await _loadNativeSessions(
          refresh: arguments['refresh'] != false,
        );
      }
      if (kind == 'reply') {
        final result = await MsgHttp.msgFeedReplyMe(
          cursor: cursor,
          cursorTime: cursorTime,
        );
        return switch (result) {
          Loading() => const {'state': 'loading'},
          Error(:final errMsg) => {
            'state': 'error',
            'error': errMsg ?? '回复消息加载失败',
          },
          Success(:final response) => {
            'state': 'success',
            'hasMore':
                (response.items?.isNotEmpty ?? false) &&
                response.cursor?.isEnd != true,
            'nextCursor': response.cursor?.id,
            'nextCursorTime': response.cursor?.time,
            'items': (response.items ?? const []).asMap().entries.map((entry) {
              final item = entry.value;
              return {
                'id': item.id?.toString() ?? 'reply-${entry.key}',
                'kind': 'reply',
                'author': item.user?.nickname ?? '用户',
                'memberId': item.user?.mid,
                'avatar': _normalizeURL(item.user?.avatar),
                'body': item.item?.rootReplyContent ?? '回复了你',
                'context': item.item?.sourceContent ?? '',
                'time': DateFormatUtils.format(item.replyTime),
                'badge': item.counts != null && item.counts! > 1
                    ? '${item.counts} 条回复'
                    : '回复',
              };
            }).toList(),
          },
        };
      }
      if (kind == 'at') {
        final result = await MsgHttp.msgFeedAtMe(
          cursor: cursor,
          cursorTime: cursorTime,
        );
        return switch (result) {
          Loading() => const {'state': 'loading'},
          Error(:final errMsg) => {
            'state': 'error',
            'error': errMsg ?? '@消息加载失败',
          },
          Success(:final response) => {
            'state': 'success',
            'hasMore':
                (response.items?.isNotEmpty ?? false) &&
                response.cursor?.isEnd != true,
            'nextCursor': response.cursor?.id,
            'nextCursorTime': response.cursor?.time,
            'items': (response.items ?? const []).asMap().entries.map((entry) {
              final item = entry.value;
              return {
                'id': item.id?.toString() ?? 'at-${entry.key}',
                'kind': 'at',
                'author': item.user?.nickname ?? '用户',
                'memberId': item.user?.mid,
                'avatar': _normalizeURL(item.user?.avatar),
                'body': '在内容中提到了你',
                'context': item.item?.sourceContent ?? '',
                'cover': _normalizeURL(item.item?.image),
                'time': DateFormatUtils.format(item.atTime),
                'badge': '@我',
              };
            }).toList(),
          },
        };
      }
      if (kind == 'like') {
        final result = await MsgHttp.msgFeedLikeMe(
          cursor: cursor,
          cursorTime: cursorTime,
        );
        return switch (result) {
          Loading() => const {'state': 'loading'},
          Error(:final errMsg) => {
            'state': 'error',
            'error': errMsg ?? '点赞消息加载失败',
          },
          Success(:final response) => () {
            final items = [
              if (cursor == null) ...?response.latest?.items,
              ...?response.total?.items,
            ];
            return {
              'state': 'success',
              'hasMore':
                  items.isNotEmpty && response.total?.cursor?.isEnd != true,
              'nextCursor': response.total?.cursor?.id,
              'nextCursorTime': response.total?.cursor?.time,
              'items': items.asMap().entries.map((entry) {
                final item = entry.value;
                final users = item.users ?? const [];
                return {
                  'id': item.id?.toString() ?? 'like-${entry.key}',
                  'kind': 'like',
                  'author': users
                      .map((user) => user.nickname)
                      .whereType<String>()
                      .take(3)
                      .join('、'),
                  'avatar': _normalizeURL(
                    users.isEmpty ? null : users.first.avatar,
                  ),
                  'body': '赞了你的内容',
                  'context': item.item?.title ?? '',
                  'cover': _normalizeURL(item.item?.image),
                  'time': DateFormatUtils.format(item.likeTime),
                  'badge': item.counts != null && item.counts! > 1
                      ? '${item.counts} 个赞'
                      : '点赞',
                };
              }).toList(),
            };
          }(),
        };
      }

      final result = await MsgHttp.msgFeedNotify(cursor: cursor);
      return switch (result) {
        Loading() => const {'state': 'loading'},
        Error(:final errMsg) => {
          'state': 'error',
          'error': errMsg ?? '系统通知加载失败',
        },
        Success(:final response) => () {
          final items = response ?? const [];
          return {
            'state': 'success',
            'hasMore': items.length >= 20,
            'nextCursor': items.isEmpty ? null : items.last.cursor,
            'items': items.asMap().entries.map((entry) {
              final item = entry.value;
              return {
                'id': item.id?.toString() ?? 'system-${entry.key}',
                'kind': 'system',
                'author': item.title ?? '系统通知',
                'body': item.content ?? '',
                'context': '',
                'time': item.timeAt ?? '',
                'badge': '系统',
              };
            }).toList(),
          };
        }(),
      };
    } catch (error) {
      return {'state': 'error', 'error': '消息加载失败：$error'};
    }
  }

  Future<Map<String, dynamic>> _loadNativeComments(
    Map<dynamic, dynamic> arguments,
  ) async {
    final oid = _asInt(arguments['oid']);
    final type = _asInt(arguments['type']) ?? 1;
    final page = _asInt(arguments['page']) ?? 1;
    final offset = _nonEmpty(arguments['offset']?.toString());
    if (oid == null || oid <= 0) {
      return const {'state': 'error', 'error': '评论参数无效'};
    }

    // The original Flutter comment page uses ReplyGrpc.mainList. Its
    // Content.emotes map carries the image URL and display size for every
    // bracketed emote in the message; the legacy web model below does not.
    final grpcResult = await ReplyGrpc.mainList(
      oid: oid,
      type: type,
      mode: Mode.MAIN_LIST_HOT,
      offset: offset,
      cursorNext: null,
    );
    if (grpcResult case Success(:final response)) {
      final nextOffset = response.hasPaginationReply()
          ? _nonEmpty(response.paginationReply.nextOffset)
          : null;
      final replies = <ReplyInfo>[
        if (page == 1 && response.hasUpTop()) response.upTop,
        ...response.replies,
      ];
      return {
        'state': 'success',
        'total': response.hasSubjectControl()
            ? response.subjectControl.count.toInt()
            : replies.length,
        'hasMore':
            replies.isNotEmpty && !response.cursor.isEnd && nextOffset != null,
        'nextOffset': nextOffset,
        'items': replies.asMap().entries.map((entry) {
          return _grpcCommentMap(entry.value, entry.key);
        }).toList(),
      };
    }

    // Keep the previous web request as a compatibility fallback if gRPC is
    // unavailable. Plain comments will still load instead of failing entirely.
    final result = await ReplyHttp.replyList(
      isLogin: Accounts.main.isLogin,
      oid: oid,
      nextOffset: offset ?? '',
      type: type,
      page: page,
      sort: 1,
    );
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '评论加载失败',
        'code': ?code,
      },
      Success(:final response) => () {
        final nextOffset = _nonEmpty(
          response.cursor?.paginationReply?.nextOffset,
        );
        final replies = <dynamic>[
          if (page == 1) ...?response.topReplies,
          ...?response.replies,
        ];
        return {
          'state': 'success',
          'total': response.cursor?.allCount ?? replies.length,
          'hasMore':
              replies.isNotEmpty &&
              response.cursor?.isEnd != true &&
              (Accounts.main.isLogin || nextOffset != null),
          'nextOffset': nextOffset,
          'items': replies.asMap().entries.map((entry) {
            final item = entry.value;
            return {
              'id': item.rpid?.toString() ?? 'comment-${entry.key}',
              'rpid': item.rpid,
              'memberId': _asInt(item.member?.mid),
              'author': item.member?.uname ?? '用户',
              'avatar': _normalizeURL(item.member?.avatar),
              'message': item.content?.message ?? '',
              'time':
                  item.replyControl?.timeDesc ??
                  DateFormatUtils.format(item.ctime),
              'location': item.replyControl?.location ?? '',
              'like': item.like ?? 0,
              'liked': item.action == 1,
              'replyCount': item.rcount ?? item.replies?.length ?? 0,
              'level': item.member?.levelInfo?.currentLevel ?? 0,
              'pictures': (item.content?.pictures ?? const [])
                  .map(
                    (picture) => {
                      'url': _normalizeURL(picture.imgSrc),
                      'width': picture.imgWidth ?? 0,
                      'height': picture.imgHeight ?? 0,
                    },
                  )
                  .where((picture) => picture['url'] != null)
                  .toList(),
            };
          }).toList(),
        };
      }(),
    };
  }

  Future<Map<String, dynamic>> _setNativeCommentLike(
    Map<dynamic, dynamic> arguments,
  ) async {
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }
    final oid = _asInt(arguments['oid']);
    final rpid = _asInt(arguments['rpid']);
    final type = _asInt(arguments['type']) ?? 1;
    final liked = arguments['liked'] == true;
    if (oid == null || rpid == null) {
      return const {'state': 'error', 'error': '评论操作参数无效'};
    }
    final result = await ReplyHttp.likeReply(
      type: type,
      oid: oid,
      rpid: rpid,
      action: liked ? 0 : 1,
    );
    return result.isSuccess
        ? {'state': 'success', 'liked': !liked}
        : const {'state': 'error', 'error': '评论点赞失败'};
  }

  Future<Map<String, dynamic>> _publishNativeComment(
    Map<dynamic, dynamic> arguments,
  ) async {
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }
    final oid = _asInt(arguments['oid']);
    final type = _asInt(arguments['type']) ?? 17;
    final root = _asInt(arguments['root']);
    final parent = _asInt(arguments['parent']);
    final message = arguments['message']?.toString().trim() ?? '';
    if (oid == null || oid <= 0 || message.isEmpty) {
      return const {'state': 'error', 'error': '评论内容或参数无效'};
    }
    if (message.length > 1000) {
      return const {'state': 'error', 'error': '评论不能超过 1000 个字符'};
    }
    final result = await VideoHttp.replyAdd(
      type: type,
      oid: oid,
      message: message,
      root: root,
      parent: parent,
    );
    return switch (result) {
      Success(:final response) => {
        'state': 'success',
        'message': root != null && root > 0 ? '回复成功' : '评论成功',
        if (response != null) 'comment': _grpcCommentMap(response, 0),
      },
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '评论发布失败',
        'code': ?code,
      },
      Loading() => const {'state': 'loading'},
    };
  }

  Future<Map<String, dynamic>> _loadNativeCommentReplies(
    Map<dynamic, dynamic> arguments,
  ) async {
    final oid = _asInt(arguments['oid']);
    final type = _asInt(arguments['type']) ?? 17;
    final root = _asInt(arguments['root']);
    final offset = _nonEmpty(arguments['offset']?.toString());
    if (oid == null || oid <= 0 || root == null || root <= 0) {
      return const {'state': 'error', 'error': '二级评论参数无效'};
    }
    final result = await ReplyGrpc.detailList(
      type: type,
      oid: oid,
      root: root,
      rpid: 0,
      mode: Mode.MAIN_LIST_TIME,
      offset: offset,
    );
    return switch (result) {
      Success(:final response) => () {
        final replies = response.root.replies;
        final nextOffset = response.hasPaginationReply()
            ? _nonEmpty(response.paginationReply.nextOffset)
            : null;
        return {
          'state': 'success',
          'total': response.root.count.toInt(),
          'hasMore':
              replies.isNotEmpty &&
              !response.cursor.isEnd &&
              nextOffset != null,
          'nextOffset': nextOffset,
          'items': replies.asMap().entries.map((entry) {
            return _grpcCommentMap(entry.value, entry.key);
          }).toList(),
        };
      }(),
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '二级评论加载失败',
        'code': ?code,
      },
      Loading() => const {'state': 'loading'},
    };
  }

  Map<String, dynamic> _grpcCommentMap(ReplyInfo item, int index) {
    final content = item.content;
    final control = item.replyControl;
    final member = item.member;
    return {
      'id': item.id.toString().isEmpty ? 'comment-$index' : item.id.toString(),
      'rpid': item.id.toInt(),
      'memberId': item.mid.toInt(),
      'author': member.name.isEmpty ? '用户' : member.name,
      'avatar': _normalizeURL(member.face),
      'message': content.message,
      'time': control.timeDesc.isNotEmpty
          ? control.timeDesc
          : DateFormatUtils.format(item.ctime.toInt()),
      'location': control.location,
      'like': item.like.toInt(),
      'liked': control.action.toInt() == 1,
      'replyCount': item.count.toInt(),
      'level': member.level.toInt(),
      'pictures': content.pictures
          .map(
            (picture) => {
              'url': _normalizeURL(picture.imgSrc),
              'width': picture.imgWidth,
              'height': picture.imgHeight,
            },
          )
          .where((picture) => picture['url'] != null)
          .toList(),
      'emotes': content.emotes.entries
          .map((entry) {
            final emote = entry.value;
            final source = emote.hasWebpUrl() && emote.webpUrl.isNotEmpty
                ? emote.webpUrl
                : emote.hasGifUrl() && emote.gifUrl.isNotEmpty
                ? emote.gifUrl
                : emote.url;
            return {
              'text': entry.key,
              'url': _normalizeURL(source),
              'size': emote.size.toInt().clamp(1, 2),
            };
          })
          .where((emote) => emote['url'] != null)
          .toList(),
    };
  }

  Future<Map<String, dynamic>> _loadNativeDownloads() async {
    try {
      final service = Get.find<DownloadService>();
      await service.waitForInitialization;
      final items = [...service.downloadList, ...service.waitDownloadQueue];
      return {
        'state': 'success',
        'items': items.asMap().entries.map((entry) {
          final item = entry.value;
          final total = item.totalBytes > 0
              ? item.totalBytes
              : item.guessedTotalBytes;
          final progress = total > 0 ? item.downloadedBytes / total : 0.0;
          return {
            'id': '${item.cid}-${entry.key}',
            'aid': item.avid,
            'bvid': item.bvid,
            'title': item.showTitle,
            'subtitle': item.title,
            'cover': _normalizeURL(item.cover),
            'owner': item.ownerName ?? '',
            'progress': progress.clamp(0.0, 1.0),
            'progressText': item.isCompleted
                ? '已缓存'
                : '${(progress * 100).round()}%',
            'badge': item.qualityPithyDescription,
          };
        }).toList(),
      };
    } catch (error) {
      return {'state': 'error', 'error': '离线缓存读取失败：$error'};
    }
  }

  Future<Map<String, dynamic>> _loadNativeHistory(
    Map<dynamic, dynamic> arguments,
  ) async {
    final result = await UserHttp.historyList(
      type: 'all',
      max: _asInt(arguments['max']),
      viewAt: _asInt(arguments['viewAt']),
    );
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '观看记录加载失败',
        'code': ?code,
      },
      Success(:final response) => () {
        final rows = response.list ?? const [];
        return {
          'state': 'success',
          'title': '观看记录',
          'hasMore': rows.isNotEmpty,
          'nextMax': rows.isEmpty ? null : rows.last.history.oid,
          'nextViewAt': rows.isEmpty ? null : rows.last.viewAt,
          'items': rows.asMap().entries.map((entry) {
            final item = entry.value;
            final progress = item.progress;
            final duration = item.duration ?? 0;
            final progressText = progress == -1
                ? '已看完'
                : progress != null && progress > 0
                ? '${_durationText(progress)}/${_durationText(duration)}'
                : '';
            return {
              'id': 'history-${item.kid ?? entry.key}',
              'kind': 'video',
              'title': item.title ?? '未命名内容',
              'subtitle': item.authorName ?? item.showTitle ?? '',
              'cover': _normalizeURL(
                _nonEmpty(item.cover) ??
                    (item.covers?.isNotEmpty == true
                        ? item.covers!.first
                        : null),
              ),
              'aid': item.history.oid,
              'bvid': _nonEmpty(item.history.bvid),
              'durationText': _durationText(duration),
              'progressText': progressText,
              'progress': progress == -1 || duration <= 0
                  ? (progress == -1 ? 1.0 : 0.0)
                  : (progress ?? 0) / duration,
              'badge': item.badge ?? '',
              'viewText': '',
              'danmakuText': '',
              'fallbackRoute': '/history',
            };
          }).toList(),
        };
      }(),
    };
  }

  Future<Map<String, dynamic>> _loadNativeLater(int page) async {
    final result = await UserHttp.seeYouLater(page: page);
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '稍后再看加载失败',
        'code': ?code,
      },
      Success(:final response) => {
        'state': 'success',
        'title': '稍后再看',
        'hasMore':
            (response.list?.isNotEmpty ?? false) &&
            page * 20 < (response.count ?? 0),
        'items': (response.list ?? const []).asMap().entries.map((entry) {
          final item = entry.value;
          final duration = item.duration ?? 0;
          final progress = item.progress ?? 0;
          return {
            'id': 'later-${item.aid ?? entry.key}',
            'kind': 'video',
            'title': item.title ?? '未命名视频',
            'subtitle': item.owner?.name ?? item.subtitle ?? '',
            'cover': _normalizeURL(item.pic),
            'aid': item.aid,
            'bvid': _nonEmpty(item.bvid),
            'durationText': _durationText(duration),
            'progressText': progress > 0 && duration > 0
                ? '${_durationText(progress)}/${_durationText(duration)}'
                : '',
            'progress': duration > 0 ? progress / duration : 0.0,
            'badge': item.pgcLabel ?? '',
            'viewText': _compactNumber(item.stat?.view),
            'danmakuText': _compactNumber(item.stat?.danmaku),
            'fallbackRoute': '/later',
          };
        }).toList(),
      },
    };
  }

  Future<Map<String, dynamic>> _loadNativeFavoriteFolders(
    int page, {
    int? mid,
  }) async {
    final result = await FavHttp.userfavFolder(
      pn: page,
      ps: 20,
      mid: mid ?? Accounts.main.mid,
    );
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '收藏夹加载失败',
        'code': ?code,
      },
      Success(:final response) => {
        'state': 'success',
        'title': '我的收藏',
        'hasMore': response.hasMore ?? false,
        'items': (response.list ?? const []).asMap().entries.map((entry) {
          final item = entry.value;
          return {
            'id': 'folder-${item.id}',
            'kind': 'folder',
            'title': item.title,
            'subtitle': item.intro ?? item.upper?.name ?? '',
            'cover': _normalizeURL(item.cover),
            'folderId': item.id,
            'trailingText': '${item.mediaCount} 个内容',
            'badge': item.attr == 23 ? '私密' : '',
            'fallbackRoute': '/fav',
          };
        }).toList(),
      },
    };
  }

  Future<Map<String, dynamic>> _loadNativeFavoriteDetail(
    Map<dynamic, dynamic> arguments,
    int page,
  ) async {
    final mediaId = _asInt(arguments['mediaId']);
    if (mediaId == null) {
      return const {'state': 'error', 'error': '收藏夹参数无效'};
    }
    final result = await FavHttp.userFavFolderDetail(
      mediaId: mediaId,
      pn: page,
      ps: 20,
    );
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '收藏夹内容加载失败',
        'code': ?code,
      },
      Success(:final response) => {
        'state': 'success',
        'title': response.info?.title ?? '收藏夹',
        'subtitle': response.info?.intro ?? '',
        'hasMore': response.hasMore ?? false,
        'items': (response.medias ?? const []).asMap().entries.map((entry) {
          final item = entry.value;
          return {
            'id': 'favorite-${item.id ?? entry.key}',
            'kind': 'video',
            'title': item.title ?? '未命名内容',
            'subtitle': item.upper?.name ?? item.intro ?? '',
            'cover': _normalizeURL(item.cover),
            'aid': item.id,
            'bvid': _nonEmpty(item.bvid),
            'durationText': _durationText(item.duration ?? 0),
            'progressText': '',
            'progress': 0.0,
            'badge': item.attr == 9 ? '已失效' : '',
            'viewText': _compactNumber(item.cntInfo?.play),
            'danmakuText': _compactNumber(item.cntInfo?.danmaku),
            'fallbackRoute': '/favDetail',
            'fallbackParameters': {'mediaId': mediaId.toString()},
          };
        }).toList(),
      },
    };
  }

  Future<Map<String, dynamic>> _loadNativeRelations(
    int page, {
    required bool followers,
  }) async {
    final result = followers
        ? await FanHttp.fans(
            vmid: Accounts.main.mid,
            pn: page,
            orderType: 'attention',
          )
        : await FollowHttp.followings(vmid: Accounts.main.mid, pn: page);
    final pageTitle = followers ? '粉丝' : '关注';
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '$pageTitle列表加载失败',
        'code': ?code,
      },
      Success(:final response) => {
        'state': 'success',
        'title': pageTitle,
        'subtitle': '共 ${response.total ?? 0} 人',
        'hasMore':
            (response.list?.isNotEmpty ?? false) &&
            page * 20 < (response.total ?? 0),
        'items': (response.list ?? const []).asMap().entries.map((entry) {
          final item = entry.value;
          return {
            'id': '${followers ? 'follower' : 'following'}-${item.mid}',
            'kind': 'member',
            'title': item.uname ?? '用户 ${item.mid}',
            'subtitle': item.sign ?? '',
            'cover': _normalizeURL(item.face),
            'memberId': item.mid,
            'badge': item.officialVerify?.desc ?? '',
            'fallbackRoute': '/member',
            'fallbackParameters': {'mid': item.mid.toString()},
          };
        }).toList(),
      },
    };
  }

  Future<Map<String, dynamic>> _loadNativeSubscriptions(int page) async {
    final result = await UserHttp.userSubFolder(
      mid: Accounts.main.mid,
      pn: page,
      ps: 20,
    );
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '订阅加载失败',
        'code': ?code,
      },
      Success(:final response) => {
        'state': 'success',
        'title': '我的订阅',
        'hasMore': response.hasMore ?? false,
        'items': (response.list ?? const []).asMap().entries.map((entry) {
          final item = entry.value;
          final typeText = switch (item.type) {
            11 => '收藏夹',
            21 => '合集',
            _ => '订阅',
          };
          return {
            'id': 'subscription-${item.id ?? entry.key}',
            'kind': 'subscription',
            'title': item.title ?? '未命名订阅',
            'subtitle': item.upper?.name ?? item.intro ?? '',
            'cover': _normalizeURL(item.cover),
            'folderId': item.id,
            'folderType': item.type,
            'trailingText': '${item.mediaCount ?? 0} 个视频',
            'badge': item.state == 1 ? '已失效' : typeText,
            'fallbackRoute': '/subscription',
          };
        }).toList(),
      },
    };
  }

  Future<Map<String, dynamic>> _loadNativeSubscriptionDetail(
    Map<dynamic, dynamic> arguments,
    int page,
  ) async {
    final id = _asInt(arguments['mediaId']);
    if (id == null) {
      return const {'state': 'error', 'error': '订阅参数无效'};
    }
    final result = await FavHttp.favSeasonList(id: id, ps: 20, pn: page);
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '订阅内容加载失败',
        'code': ?code,
      },
      Success(:final response) => {
        'state': 'success',
        'title': response.info?.title ?? '订阅内容',
        'subtitle': response.info?.intro ?? '',
        'hasMore':
            (response.medias?.isNotEmpty ?? false) &&
            page * 20 < (response.info?.mediaCount ?? 0),
        'items': (response.medias ?? const []).asMap().entries.map((entry) {
          final item = entry.value;
          return {
            'id': 'subscription-video-${item.id ?? entry.key}',
            'kind': 'video',
            'title': item.title ?? '未命名视频',
            'subtitle': '',
            'cover': _normalizeURL(item.cover),
            'aid': item.id,
            'bvid': _nonEmpty(item.bvid),
            'durationText': _durationText(item.duration ?? 0),
            'viewText': _compactNumber(item.cntInfo?.play),
            'danmakuText': _compactNumber(item.cntInfo?.danmaku),
            'fallbackRoute': '/subscription',
          };
        }).toList(),
      },
    };
  }

  Map<String, dynamic> _snapshot() => {
    'home': _listState(_homeController.loadingState.value, _videoMap),
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
        'pubdateText': DateFormatUtils.format(_asInt(item.pubdate)),
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

  Map<String, dynamic> _dynamicMap(dynamic value, int index) {
    if (value is! DynamicItemModel) {
      return {
        'id': '',
        'author': '',
        'title': '',
        'body': '',
        'pictures': const <Map<String, dynamic>>[],
      };
    }
    final item = value;
    final modules = item.modules;
    final moduleDynamic = modules.moduleDynamic;
    final major = moduleDynamic?.major;
    final author = modules.moduleAuthor;
    final stat = modules.moduleStat;

    // This follows the original dynamic widgets: text comes from desc/opus,
    // while picture dynamics render every opus pic using `url`.
    final archive =
        major?.archive ?? major?.ugcSeason ?? major?.pgc ?? major?.courses;
    final opus = major?.opus;
    final pictures = <Map<String, dynamic>>[];
    for (final picture in opus?.pics ?? const <OpusPicModel>[]) {
      final url = _normalizeURL(picture.url ?? picture.src);
      if (url == null) continue;
      pictures.add({
        'url': url,
        'width': picture.width ?? 0,
        'height': picture.height ?? 0,
      });
    }

    final subscriptionLive =
        major?.subscriptionNew?.liveRcmd?.content?.livePlayInfo;
    final title = _firstNonEmpty([
      opus?.title,
      archive?.title,
      major?.liveRcmd?.title,
      major?.live?.title,
      subscriptionLive?.title,
      major?.medialist?.title,
      major?.music?.title,
      modules.moduleTag?.text,
    ]);
    final body = _firstNonEmpty([
      moduleDynamic?.desc?.text,
      opus?.summary?.text,
    ]);
    final cover = _firstNonEmpty([
      archive?.cover,
      pictures.isEmpty ? null : pictures.first['url']?.toString(),
      major?.liveRcmd?.cover,
      major?.live?.cover,
      subscriptionLive?.cover,
      major?.medialist?.cover,
      major?.music?.cover,
    ]);
    final id = _firstNonEmpty([item.idStr?.toString(), item.fallback?.id]);

    return {
      // Keep the transport ID empty when the API did not provide one. Swift
      // has its own UI identity and must never send a synthetic ID to Bilibili.
      'id': id,
      'type': item.type ?? '',
      'author': author?.name ?? '',
      'authorId': author?.mid,
      'avatar': _normalizeURL(author?.face),
      'time': author?.pubTime ?? '',
      'title': title ?? '',
      'body': body ?? '',
      'emotes':
          (moduleDynamic?.desc?.richTextNodes ??
                  opus?.summary?.richTextNodes ??
                  const <RichTextNodeItem>[])
              .where(
                (node) =>
                    node.emoji?.url != null &&
                    (node.text ?? node.origText)?.isNotEmpty == true,
              )
              .map(
                (node) => {
                  'text': node.text ?? node.origText,
                  'url': _normalizeURL(node.emoji?.url),
                  'size': node.emoji?.size.toInt() ?? 1,
                },
              )
              .toList(),
      'repostText': item.type == 'DYNAMIC_TYPE_FORWARD'
          ? _firstNonEmpty([
                  item.orig?.modules.moduleDynamic?.desc?.text,
                  item.orig?.modules.moduleDynamic?.major?.opus?.summary?.text,
                  item.orig?.modules.moduleDynamic?.major?.archive?.title,
                ]) ??
                '源动态不可见'
          : null,
      'cover': _normalizeURL(cover),
      'coverWidth': pictures.isEmpty ? 0 : pictures.first['width'],
      'coverHeight': pictures.isEmpty ? 0 : pictures.first['height'],
      'pictures': pictures,
      'bvid': archive?.bvid,
      'aid': archive?.aid,
      'commentOid': _asInt(item.basic?.commentIdStr),
      'commentType': item.basic?.commentType,
      'like': stat?.like?.count ?? 0,
      'liked': stat?.like?.status == true,
      'comment': stat?.comment?.count ?? 0,
      'forward': stat?.forward?.count ?? 0,
    };
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
    if (_nativePlayerShellActive) {
      if (!visible) return;
      _nativePlayerShellActive = false;
      _channel.invokeMethod<void>('nativePlayerClosed');
    }
    _channel.invokeMethod<void>('setChromeVisible', visible);
    if (visible) _scheduleSnapshot();
  }

  void dispose() {
    _disposed = true;
    _nativePlayerShellActive = false;
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

  static double? _asDouble(dynamic value) => switch (value) {
    num value => value.toDouble(),
    String value => double.tryParse(value),
    _ => null,
  };

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty || trimmed == 'null'
        ? null
        : trimmed;
  }

  static String? _numericDynamicID(dynamic value) {
    final id = _nonEmpty(value?.toString());
    if (id == null || !RegExp(r'^\d+$').hasMatch(id)) return null;
    return id;
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

  String? _speedText(NativeCDNMeasurement? measurement) {
    final speed = measurement?.megabytesPerSecond;
    if (speed == null || speed <= 0 || !speed.isFinite) return null;
    return '${speed.toStringAsPrecision(3)}MB/s';
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
