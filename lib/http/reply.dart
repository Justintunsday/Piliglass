import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/emote/data.dart';
import 'package:PiliPlus/models_new/emote/package.dart';
import 'package:PiliPlus/models_new/reply/data.dart';
import 'package:PiliPlus/models_new/reply2reply/data.dart';
import 'package:PiliPlus/models_new/reply_interaction/data.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

abstract final class ReplyHttp {
  static final Options options = Options(
    headers: {...Constants.baseHeaders, 'cookie': ''},
    extra: {'account': const NoAccount()},
  );

  static Future<LoadingState<ReplyData>> replyList({
    required bool isLogin,
    required int oid,
    required String nextOffset,
    required int type,
    required int page,
    int sort = 1,
  }) async {
    final res = !isLogin
        ? await Request().get(
            '${Api.replyList}/main',
            queryParameters: {
              'oid': oid,
              'type': type,
              'pagination_str':
                  '{"offset":"${nextOffset.replaceAll('"', '\\"')}"}',
              'mode': sort + 2, //2:按时间排序；3：按热度排序
            },
            options: !isLogin ? options : null,
          )
        : await Request().get(
            Api.replyList,
            queryParameters: {
              'oid': oid,
              'type': type,
              'sort': sort,
              'pn': page,
              'ps': 20,
            },
            options: !isLogin ? options : null,
          );
    if (res.data['code'] == 0) {
      return Success(ReplyData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<ReplyReplyData>> replyReplyList({
    required bool isLogin,
    required int oid,
    required int root,
    required int pageNum,
    required int type,
    bool isCheck = false,
  }) async {
    final res = await Request().get(
      Api.replyReplyList,
      queryParameters: {
        'oid': oid,
        'root': root,
        'pn': pageNum,
        'type': type,
        'sort': 1,
        if (isLogin) 'csrf': Accounts.main.csrf,
      },
      options: !isLogin ? options : null,
    );
    if (res.data['code'] == 0) {
      ReplyReplyData replyData = ReplyReplyData.fromJson(res.data['data']);
      return Success(replyData);
    } else {
      return Error(
        isCheck
            ? '${res.data['code']}${res.data['message']}'
            : res.data['message'],
      );
    }
  }

  static Future<LoadingState<void>> hateReply({
    required int type,
    required int action,
    required int oid,
    required int rpid,
  }) async {
    final res = await Request().post(
      Api.hateReply,
      data: {
        'type': type,
        'oid': oid,
        'rpid': rpid,
        'action': action,
        'csrf': Accounts.main.csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  // 评论点赞
  static Future<LoadingState<void>> likeReply({
    required int type,
    required int oid,
    required int rpid,
    required int action,
  }) async {
    final res = await Request().post(
      Api.likeReply,
      data: {
        'type': type,
        'oid': oid,
        'rpid': rpid,
        'action': action,
        'csrf': Accounts.main.csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<List<Package>?>> getEmoteList({
    String? business,
  }) async {
    final scene = business ?? 'reply';
    final res = await Request().get(
      Api.myEmote,
      queryParameters: {
        'business': scene,
        'web_location': '333.1245',
      },
    );
    if (res.data['code'] == 0) {
      final packages = _parseEmotePackages(res.data['data']);
      if (packages?.isNotEmpty == true) {
        return Success(packages);
      }
    }

    // Bilibili may return code=0 with packages=null. The settings endpoint
    // still contains the packages added by the signed-in user.
    final settingRes = await Request().get(
      Api.emoteSettingPanel,
      queryParameters: {'business': scene},
    );
    if (settingRes.data['code'] == 0) {
      final data = settingRes.data['data'];
      final packages = data is Map
          ? _parseEmotePackages({
              'packages': data['user_panel_packages'],
            })
          : null;
      if (packages?.isNotEmpty == true) {
        return Success(packages);
      }
    }

    // Keep the original Bilibili face package available even if the account
    // panel is temporarily empty or the session cookie is being refreshed.
    final defaultRes = await Request().get(
      Api.emotePackage,
      queryParameters: {'business': scene, 'ids': 1},
    );
    if (defaultRes.data['code'] == 0) {
      final packages = _parseEmotePackages(defaultRes.data['data']);
      if (packages?.isNotEmpty == true) {
        return Success(packages);
      }
    }

    return Error(
      res.data['message'] ??
          settingRes.data['message'] ??
          defaultRes.data['message'] ??
          '表情包加载失败',
    );
  }

  static List<Package>? _parseEmotePackages(Object? data) {
    if (data is! Map) return null;
    return EmoteModelData.fromJson(Map<String, dynamic>.from(data)).packages;
  }

  static Future<LoadingState<void>> replyTop({
    required Object oid,
    required Object type,
    required Object rpid,
    required bool isUpTop,
  }) async {
    final res = await Request().post(
      Api.replyTop,
      data: {
        'oid': oid,
        'type': type,
        'rpid': rpid,
        'action': isUpTop ? 0 : 1,
        'csrf': Accounts.main.csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> report({
    required Object rpid,
    required Object oid,
    required int reasonType,
    bool banUid = true,
    String? reasonDesc,
  }) async {
    final res = await Request().post(
      Api.replyReport,
      data: {
        'add_blacklist': banUid,
        'csrf': Accounts.main.csrf,
        'gaia_source': 'main_h5',
        'oid': oid,
        'platform': 'android',
        'reason': reasonType,
        'rpid': rpid,
        'scene': 'main',
        'type': 1,
        if (reasonType == 0) 'content': reasonDesc!,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );

    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<ReplyInteractData>> replyInteraction({
    required Object oid,
    required Object type,
  }) async {
    final res = await Request().get(
      Api.replyInteraction,
      queryParameters: {
        'oid': oid,
        'type': type,
        'web_location': 333.1369,
      },
    );
    if (res.data['code'] == 0) {
      try {
        return Success(ReplyInteractData.fromJson(res.data['data']));
      } catch (e) {
        return Error(e.toString());
      }
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> replySubjectModify({
    required int oid,
    required int type,
    required int action,
  }) async {
    final res = await Request().post(
      Api.replySubjectModify,
      data: {
        'oid': oid,
        'type': type,
        'action': action,
        'csrf': Accounts.main.csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      if (res.data['data']?['action_toast'] case final String toast) {
        SmartDialog.showToast(toast);
      }
      return const Success(null);
    } else {
      SmartDialog.showToast(res.data['message'].toString());
      return const Error(null);
    }
  }
}
