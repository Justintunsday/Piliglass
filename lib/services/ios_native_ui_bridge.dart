import 'dart:async';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show Mode, ReplyInfo;
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/fan.dart';
import 'package:PiliPlus/http/follow.dart';
import 'package:PiliPlus/http/dynamics.dart';
import 'package:PiliPlus/http/login.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/http/msg.dart';
import 'package:PiliPlus/http/reply.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/dynamic/dynamics_type.dart';
import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/models/common/search/search_type.dart';
import 'package:PiliPlus/models/common/setting_type.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/pages/about/view.dart';
import 'package:PiliPlus/pages/dynamics/controller.dart';
import 'package:PiliPlus/pages/dynamics_tab/controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/pages/setting/common_setting.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/webdav/view.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/video_utils.dart';
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
  String? _nativeLoginAuthCode;

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
      case 'loadVideoDetail':
        return _loadVideoDetail(_arguments(call));
      case 'loadNativePlayback':
        return _loadNativePlayback(_arguments(call));
      case 'playVideo':
        return _playVideo(_arguments(call));
      case 'performVideoAction':
        return _performVideoAction(_arguments(call));
      case 'changeNativeVideoPart':
        return _changeNativeVideoPart(_arguments(call));
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
      case 'openSettingsSection':
        return _openSettingsSection(_arguments(call));
      case 'searchVideos':
        return _searchVideos(_arguments(call));
      case 'loadNativeLibrary':
        return _loadNativeLibrary(_arguments(call));
      case 'loadNativeProfile':
        return _loadNativeProfile(_arguments(call));
      case 'setNativeProfileFollow':
        return _setNativeProfileFollow(_arguments(call));
      case 'startNativeLogin':
        return _startNativeLogin();
      case 'pollNativeLogin':
        return _pollNativeLogin();
      case 'loadNativeMessages':
        return _loadNativeMessages(_arguments(call));
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

  Future<Map<String, dynamic>> _loadVideoDetail(
    Map<dynamic, dynamic> arguments,
  ) async {
    var bvid = _nonEmpty(arguments['bvid']?.toString());
    final aid = _asInt(arguments['aid']);
    if (bvid == null && aid != null) bvid = IdUtils.av2bv(aid);
    if (bvid == null) {
      return const {'state': 'error', 'error': '缺少视频编号'};
    }

    final tagRequest = UserHttp.videoTags(bvid: bvid);
    final result = await VideoHttp.videoIntro(bvid: bvid);
    var tags = const [];
    try {
      tags = (await tagRequest).dataOrNull ?? const [];
    } catch (_) {
      // Tags are optional; a tag endpoint failure must not hide the intro.
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
          'copyrightText': response.copyright == 1 ? '自制' : '转载',
          'isVertical': response.dimension?.isVertical ?? false,
          'argueMessage': response.argueInfo?.argueMsg ?? '',
          'collectionTitle': response.ugcSeason?.title ?? '',
          'collectionCount': response.ugcSeason?.sections?.fold<int>(
                0,
                (count, section) => count + (section.episodes?.length ?? 0),
              ) ??
              0,
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

  Future<void> _playVideo(Map<dynamic, dynamic> arguments) async {
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    final aid = _asInt(arguments['aid']);
    final part = _asInt(arguments['part']);
    if (bvid == null && aid == null) return;
    await PiliScheme.videoPush(
      aid,
      bvid,
      part: part?.toString(),
    );
  }

  Future<Map<String, dynamic>> _loadNativePlayback(
    Map<dynamic, dynamic> arguments,
  ) async {
    final cid = _asInt(arguments['cid']);
    var aid = _asInt(arguments['aid']);
    final bvid = _nonEmpty(arguments['bvid']?.toString());
    if (aid == null && bvid != null) aid = IdUtils.bv2av(bvid);
    final quality = _asInt(arguments['quality']) ?? 80;
    if (cid == null || cid <= 0 || aid == null || aid <= 0) {
      return const {'state': 'error', 'error': '播放参数不完整'};
    }

    final result = await VideoHttp.tvPlayUrl(
      cid: cid,
      objectId: aid,
      playurlType: 1,
      qn: quality,
    );
    return switch (result) {
      Loading() => const {'state': 'loading'},
      Error(:final errMsg, :final code) => {
        'state': 'error',
        'error': errMsg ?? '播放地址获取失败',
        'code': ?code,
      },
      Success(:final response) => () {
        final segments = response.durl ?? const [];
        final urls = segments
            .where((segment) => segment.playUrls.isNotEmpty)
            .map((segment) => VideoUtils.getCdnUrl(segment.playUrls))
            .where((url) => url.isNotEmpty)
            .toList();
        if (urls.isEmpty) {
          return const {
            'state': 'error',
            'error': '原生播放器暂时无法解析该视频格式',
          };
        }
        return {
          'state': 'success',
          'urls': urls,
          'quality': response.quality ?? quality,
          'qualityText': response.acceptDesc?.isNotEmpty == true
              ? response.acceptDesc!.first.toString()
              : '${response.quality ?? quality}P',
          'duration': response.timeLength ?? 0,
          'segmentCount': urls.length,
        };
      }(),
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
            ? const {
                'state': 'success',
                'message': '已添加到稍后再看',
              }
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

  static const List<Map<String, dynamic>> _nativeSettingDefinitions = [
    {
      'key': SettingBoxKey.enableShowDanmaku,
      'title': '显示弹幕',
      'subtitle': '播放器中加载并显示弹幕',
      'group': '播放与弹幕',
      'icon': 'text.bubble',
      'default': true,
    },
    {
      'key': SettingBoxKey.enableTapDm,
      'title': '点击弹幕',
      'subtitle': '点击弹幕后悬停并显示操作菜单',
      'group': '播放与弹幕',
      'icon': 'hand.tap',
      'default': true,
    },
    {
      'key': SettingBoxKey.autoPlayEnable,
      'title': '自动播放',
      'subtitle': '进入播放页后自动开始播放',
      'group': '播放与弹幕',
      'icon': 'play.circle',
      'default': false,
    },
    {
      'key': SettingBoxKey.enableQuickDouble,
      'title': '双击快退/快进',
      'subtitle': '左侧双击快退，右侧双击快进',
      'group': '播放与弹幕',
      'icon': 'gobackward.10',
      'default': true,
    },
    {
      'key': SettingBoxKey.enableSlideVolumeBrightness,
      'title': '滑动调节亮度和音量',
      'subtitle': '在播放器左右区域上下滑动',
      'group': '播放与弹幕',
      'icon': 'slider.vertical.3',
      'default': true,
    },
    {
      'key': SettingBoxKey.enableSlideFS,
      'title': '滑动进入或退出全屏',
      'subtitle': '在播放器中间区域上下滑动',
      'group': '播放与弹幕',
      'icon': 'arrow.up.and.down',
      'default': true,
    },
    {
      'key': SettingBoxKey.showFsLockBtn,
      'title': '全屏显示锁定按钮',
      'subtitle': '锁定后避免误触播放器控件',
      'group': '播放与弹幕',
      'icon': 'lock',
      'default': true,
    },
    {
      'key': SettingBoxKey.showFsScreenshotBtn,
      'title': '全屏显示截图按钮',
      'subtitle': '在完整播放器中显示截图入口',
      'group': '播放与弹幕',
      'icon': 'camera',
      'default': true,
    },
    {
      'key': SettingBoxKey.showBatteryLevel,
      'title': '全屏显示电池电量',
      'subtitle': '横屏播放时展示当前电量',
      'group': '播放与弹幕',
      'icon': 'battery.50',
      'default': true,
    },
    {
      'key': SettingBoxKey.enableAutoEnter,
      'title': '播放时自动全屏',
      'subtitle': '视频开始播放时自动进入全屏',
      'group': '播放与弹幕',
      'icon': 'arrow.up.left.and.arrow.down.right',
      'default': false,
    },
    {
      'key': SettingBoxKey.enableAutoExit,
      'title': '结束后退出全屏',
      'subtitle': '视频播放完成时恢复竖屏详情页',
      'group': '播放与弹幕',
      'icon': 'arrow.down.right.and.arrow.up.left',
      'default': true,
    },
    {
      'key': SettingBoxKey.continuePlayInBackground,
      'title': '后台继续播放',
      'subtitle': 'App 进入后台后不自动暂停',
      'group': '播放与弹幕',
      'icon': 'waveform',
      'default': false,
    },
    {
      'key': SettingBoxKey.enableBackgroundPlay,
      'title': '后台音频服务',
      'subtitle': '提升后台播放与系统控制兼容性',
      'group': '播放与弹幕',
      'icon': 'airplayaudio',
      'default': true,
    },
    {
      'key': SettingBoxKey.showFSActionItem,
      'title': '全屏显示互动按钮',
      'subtitle': '显示点赞、投币和收藏等操作',
      'group': '播放与弹幕',
      'icon': 'hand.thumbsup',
      'default': true,
    },
    {
      'key': SettingBoxKey.enableOnlineTotal,
      'title': '显示同时观看人数',
      'subtitle': '在播放器标题区域显示在线人数',
      'group': '播放与弹幕',
      'icon': 'person.2',
      'default': false,
    },
    {
      'key': SettingBoxKey.enableLongShowControl,
      'title': '延长控件显示时间',
      'subtitle': '将播放控件显示时间延长到 30 秒',
      'group': '播放与弹幕',
      'icon': 'timer',
      'default': false,
    },
    {
      'key': SettingBoxKey.tempPlayerConf,
      'title': '播放器设置仅当前生效',
      'subtitle': '部分播放设置退出当前视频后恢复',
      'group': '播放与弹幕',
      'icon': 'gearshape.2',
      'default': false,
    },
    {
      'key': SettingBoxKey.showViewPoints,
      'title': '显示视频分段信息',
      'subtitle': '在详情和进度中显示视频章节',
      'group': '视频详情',
      'icon': 'list.number',
      'default': true,
    },
    {
      'key': SettingBoxKey.showRelatedVideo,
      'title': '显示相关视频',
      'subtitle': '在视频详情中显示相关推荐',
      'group': '视频详情',
      'icon': 'rectangle.stack',
      'default': true,
    },
    {
      'key': SettingBoxKey.showVideoReply,
      'title': '显示视频评论',
      'subtitle': '在视频详情中加载评论',
      'group': '视频详情',
      'icon': 'bubble.left.and.bubble.right',
      'default': true,
    },
    {
      'key': SettingBoxKey.showBangumiReply,
      'title': '显示番剧评论',
      'subtitle': '在番剧详情中加载评论',
      'group': '视频详情',
      'icon': 'tv',
      'default': true,
    },
    {
      'key': SettingBoxKey.alwaysExpandIntroPanel,
      'title': '默认展开简介',
      'subtitle': '进入详情时完整展示视频简介',
      'group': '视频详情',
      'icon': 'text.alignleft',
      'default': false,
    },
    {
      'key': SettingBoxKey.expandIntroPanelH,
      'title': '横屏自动展开简介',
      'subtitle': '横屏详情页默认展开完整简介',
      'group': '视频详情',
      'icon': 'rectangle.expand.vertical',
      'default': false,
    },
    {
      'key': SettingBoxKey.showArgueMsg,
      'title': '显示视频警告信息',
      'subtitle': '展示视频争议或警告说明',
      'group': '视频详情',
      'icon': 'exclamationmark.triangle',
      'default': true,
    },
    {
      'key': SettingBoxKey.reverseFromFirst,
      'title': '倒序播放从首集开始',
      'subtitle': '分 P 或合集倒序时自动切到首集',
      'group': '视频详情',
      'icon': 'arrow.up.arrow.down',
      'default': true,
    },
    {
      'key': SettingBoxKey.continuePlayingPart,
      'title': '显示继续播放分 P 提示',
      'subtitle': '进入视频时提示上次播放的分 P',
      'group': '视频详情',
      'icon': 'bookmark',
      'default': true,
    },
    {
      'key': SettingBoxKey.showSeekPreview,
      'title': '拖动时显示预览图',
      'subtitle': '拖动进度时显示视频缩略图',
      'group': '视频详情',
      'icon': 'photo.on.rectangle',
      'default': true,
    },
    {
      'key': SettingBoxKey.showDmChart,
      'title': '显示高能进度条',
      'subtitle': '根据弹幕数量展示高能趋势',
      'group': '视频详情',
      'icon': 'chart.line.uptrend.xyaxis',
      'default': false,
    },
    {
      'key': SettingBoxKey.appRcmd,
      'title': '使用 App 端推荐',
      'subtitle': '修改后下次启动生效',
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
      'key': SettingBoxKey.savedRcmdTip,
      'title': '显示上次看到位置',
      'subtitle': '在推荐流中标记上次刷新位置',
      'group': '推荐与搜索',
      'icon': 'mappin',
      'default': true,
    },
    {
      'key': SettingBoxKey.searchSuggestion,
      'title': '搜索建议',
      'subtitle': '输入搜索词时显示建议',
      'group': '推荐与搜索',
      'icon': 'magnifyingglass',
      'default': true,
    },
    {
      'key': SettingBoxKey.recordSearchHistory,
      'title': '记录搜索历史',
      'subtitle': '在本机保存搜索历史',
      'group': '推荐与搜索',
      'icon': 'clock.arrow.circlepath',
      'default': true,
    },
    {
      'key': SettingBoxKey.removeSafeArea,
      'title': '播放页移除安全边距',
      'subtitle': '让横屏播放内容延伸到屏幕边缘',
      'group': '外观与界面',
      'icon': 'rectangle.inset.filled',
      'default': false,
    },
    {
      'key': SettingBoxKey.darkVideoPage,
      'title': '播放页使用深色主题',
      'subtitle': '视频详情页固定使用深色外观',
      'group': '外观与界面',
      'icon': 'moon',
      'default': false,
    },
    {
      'key': SettingBoxKey.floatingNavBar,
      'title': '悬浮底栏',
      'subtitle': '使用悬浮样式的主导航栏',
      'group': '外观与界面',
      'icon': 'dock.rectangle',
      'default': false,
      'needsRestart': true,
    },
    {
      'key': SettingBoxKey.hideTopBar,
      'title': '首页顶栏随滚动收起',
      'subtitle': '滚动首页列表时隐藏顶部栏',
      'group': '外观与界面',
      'icon': 'arrow.up.to.line',
      'default': true,
      'needsRestart': true,
    },
    {
      'key': SettingBoxKey.hideBottomBar,
      'title': '首页底栏随滚动收起',
      'subtitle': '滚动首页列表时隐藏底部栏',
      'group': '外观与界面',
      'icon': 'arrow.down.to.line',
      'default': true,
      'needsRestart': true,
    },
    {
      'key': SettingBoxKey.dynamicsShowAllFollowedUp,
      'title': '动态页显示全部关注 UP',
      'subtitle': '不只显示最近更新的 UP 主',
      'group': '外观与界面',
      'icon': 'person.3',
      'default': false,
      'needsRestart': true,
    },
    {
      'key': SettingBoxKey.expandDynLivePanel,
      'title': '展开正在直播列表',
      'subtitle': '动态页默认展开直播中的 UP 主',
      'group': '外观与界面',
      'icon': 'dot.radiowaves.left.and.right',
      'default': false,
      'needsRestart': true,
    },
    {
      'key': SettingBoxKey.showDecorate,
      'title': '显示头像与动态装饰',
      'subtitle': '展示头像框、评论和动态装饰',
      'group': '通用功能',
      'icon': 'person.crop.circle.badge.checkmark',
      'default': true,
      'needsRestart': true,
    },
    {
      'key': SettingBoxKey.showMedal,
      'title': '显示粉丝勋章',
      'subtitle': '在支持的评论和直播区域展示勋章',
      'group': '通用功能',
      'icon': 'medal',
      'default': true,
      'needsRestart': true,
    },
    {
      'key': SettingBoxKey.enableLivePhoto,
      'title': '预览 Live Photo',
      'subtitle': '以动态形式预览 Live Photo',
      'group': '通用功能',
      'icon': 'livephoto',
      'default': true,
      'needsRestart': true,
    },
    {
      'key': SettingBoxKey.openInBrowser,
      'title': '使用外部浏览器打开链接',
      'subtitle': '网页链接交给系统默认浏览器处理',
      'group': '通用功能',
      'icon': 'safari',
      'default': false,
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
    if (key == SettingBoxKey.enableBackgroundPlay) {
      videoPlayerServiceHandler?.enableBackgroundPlay = value;
    } else if (key == SettingBoxKey.enableSaveLastData) {
      _homeController
        ..enableSaveLastData = value
        ..lastRefreshAt = null;
    } else if (key == SettingBoxKey.savedRcmdTip) {
      _homeController
        ..savedRcmdTip = value
        ..lastRefreshAt = null;
    } else if (key == SettingBoxKey.checkDynamic) {
      mainController.checkDynamic = value;
    }
    return _nativeSettingsSnapshot();
  }

  Future<void> _openSettingsSection(Map<dynamic, dynamic> arguments) async {
    final section = arguments['section']?.toString();
    final type = switch (section) {
      'privacy' => SettingType.privacySetting,
      'recommend' => SettingType.recommendSetting,
      'video' => SettingType.videoSetting,
      'player' => SettingType.playSetting,
      'style' => SettingType.styleSetting,
      'extra' => SettingType.extraSetting,
      _ => null,
    };
    if (type != null) {
      await Get.to(() => CommonSetting(settingType: type));
    } else if (section == 'webdav') {
      await Get.to(() => const WebDavSettingPage());
    } else if (section == 'about') {
      await Get.to(() => const AboutPage());
    }
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

  Future<Map<String, dynamic>> _loadNativeDynamicDetail(
    Map<dynamic, dynamic> arguments,
  ) async {
    final id = _nonEmpty(arguments['id']?.toString());
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
    final id = _nonEmpty(arguments['id']?.toString());
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
    final id = _nonEmpty(arguments['id']?.toString());
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
        return {
          'state': 'success',
          'url': response.url,
          'expiresIn': 180,
        };
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
        return {
          'state': 'success',
          'message': '登录成功',
          'mid': account.mid,
        };
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

  Future<Map<String, dynamic>> _loadNativeMessages(
    Map<dynamic, dynamic> arguments,
  ) async {
    if (!Accounts.main.isLogin) {
      return const {'state': 'error', 'error': '请先登录账号'};
    }
    final kind = arguments['kind']?.toString() ?? 'reply';
    try {
      if (kind == 'reply') {
        final result = await MsgHttp.msgFeedReplyMe();
        return switch (result) {
          Loading() => const {'state': 'loading'},
          Error(:final errMsg) => {
            'state': 'error',
            'error': errMsg ?? '回复消息加载失败',
          },
          Success(:final response) => {
            'state': 'success',
            'items': (response.items ?? const []).asMap().entries.map((entry) {
              final item = entry.value;
              return {
                'id': item.id?.toString() ?? 'reply-${entry.key}',
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
        final result = await MsgHttp.msgFeedAtMe();
        return switch (result) {
          Loading() => const {'state': 'loading'},
          Error(:final errMsg) => {
            'state': 'error',
            'error': errMsg ?? '@消息加载失败',
          },
          Success(:final response) => {
            'state': 'success',
            'items': (response.items ?? const []).asMap().entries.map((entry) {
              final item = entry.value;
              return {
                'id': item.id?.toString() ?? 'at-${entry.key}',
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
        final result = await MsgHttp.msgFeedLikeMe();
        return switch (result) {
          Loading() => const {'state': 'loading'},
          Error(:final errMsg) => {
            'state': 'error',
            'error': errMsg ?? '点赞消息加载失败',
          },
          Success(:final response) => () {
            final items = [
              ...?response.latest?.items,
              ...?response.total?.items,
            ];
            return {
              'state': 'success',
              'items': items.asMap().entries.map((entry) {
                final item = entry.value;
                final users = item.users ?? const [];
                return {
                  'id': item.id?.toString() ?? 'like-${entry.key}',
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

      final result = await MsgHttp.msgFeedNotify();
      return switch (result) {
        Loading() => const {'state': 'loading'},
        Error(:final errMsg) => {
          'state': 'error',
          'error': errMsg ?? '系统通知加载失败',
        },
        Success(:final response) => {
          'state': 'success',
          'items': (response ?? const []).asMap().entries.map((entry) {
            final item = entry.value;
            return {
              'id': item.id?.toString() ?? 'system-${entry.key}',
              'author': item.title ?? '系统通知',
              'body': item.content ?? '',
              'context': '',
              'time': item.timeAt ?? '',
              'badge': '系统',
            };
          }).toList(),
        },
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
      offset: null,
      cursorNext: null,
    );
    if (grpcResult case Success(:final response)) {
      final replies = <ReplyInfo>[
        if (response.hasUpTop()) response.upTop,
        ...response.replies,
      ];
      return {
        'state': 'success',
        'total': response.hasSubjectControl()
            ? response.subjectControl.count.toInt()
            : replies.length,
        'hasMore': !response.cursor.isEnd,
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
      nextOffset: '',
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
        final replies = <dynamic>[
          ...?response.topReplies,
          ...?response.replies,
        ];
        return {
          'state': 'success',
          'total': response.cursor?.allCount ?? replies.length,
          'hasMore': response.cursor?.isEnd != true,
          'items': replies.asMap().entries.map((entry) {
            final item = entry.value;
            return {
              'id': item.rpid?.toString() ?? 'comment-${entry.key}',
              'rpid': item.rpid,
              'memberId': _asInt(item.member?.mid),
              'author': item.member?.uname ?? '用户',
              'avatar': _normalizeURL(item.member?.avatar),
              'message': item.content?.message ?? '',
              'time': item.replyControl?.timeDesc ??
                  DateFormatUtils.format(item.ctime),
              'location': item.replyControl?.location ?? '',
              'like': item.like ?? 0,
              'liked': item.action == 1,
              'replyCount': item.rcount ?? item.replies?.length ?? 0,
              'level': item.member?.levelInfo?.currentLevel ?? 0,
              'pictures': (item.content?.pictures ?? const [])
                  .map((picture) => _normalizeURL(picture.imgSrc))
                  .whereType<String>()
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
    if (oid == null || oid <= 0 || root == null || root <= 0) {
      return const {'state': 'error', 'error': '二级评论参数无效'};
    }
    final result = await ReplyGrpc.detailList(
      type: type,
      oid: oid,
      root: root,
      rpid: 0,
      mode: Mode.MAIN_LIST_TIME,
      offset: null,
    );
    return switch (result) {
      Success(:final response) => {
        'state': 'success',
        'total': response.root.count.toInt(),
        'items': response.root.replies.asMap().entries.map((entry) {
          return _grpcCommentMap(entry.value, entry.key);
        }).toList(),
      },
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
          .map((picture) => _normalizeURL(picture.imgSrc))
          .whereType<String>()
          .toList(),
      'emotes': content.emotes.entries.map((entry) {
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
      }).where((emote) => emote['url'] != null).toList(),
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
          final total = item.totalBytes > 0 ? item.totalBytes : item.guessedTotalBytes;
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
                    (item.covers?.isNotEmpty == true ? item.covers!.first : null),
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
        'hasMore': (response.list?.isNotEmpty ?? false) &&
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

  Future<Map<String, dynamic>> _loadNativeFavoriteFolders(int page) async {
    final result = await FavHttp.userfavFolder(
      pn: page,
      ps: 20,
      mid: Accounts.main.mid,
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
        : await FollowHttp.followings(
            vmid: Accounts.main.mid,
            pn: page,
          );
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
        'hasMore': (response.list?.isNotEmpty ?? false) &&
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
        'hasMore': (response.medias?.isNotEmpty ?? false) &&
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
        'aid': _asInt(archive?.aid),
        'commentOid': _asInt(item.basic?.commentIdStr),
        'commentType': _asInt(item.basic?.commentType),
        'like': _asInt(stat?.like?.count) ?? 0,
        'liked': stat?.like?.status == true,
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
