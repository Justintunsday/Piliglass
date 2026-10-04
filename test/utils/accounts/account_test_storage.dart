import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// Real Hive storage, initialized before the anonymous account reads Pref.
class AccountTestStorage {
  final Directory directory;

  AccountTestStorage._(this.directory);

  static Future<AccountTestStorage> open({
    Iterable<LoginAccount> initialAccounts = const [],
  }) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final directory = await Directory.systemTemp.createTemp(
      'piliplus-account-test-',
    );
    Hive.init(directory.path);
    GStorage.regAdapter();
    GStorage.setting = await Hive.openBox<dynamic>('setting');
    GStorage.localCache = await Hive.openBox<dynamic>('localCache');
    await GStorage.setting.putAll({
      SettingBoxKey.retryCount: 0,
      SettingBoxKey.enableHttp2: false,
      SettingBoxKey.enableSystemProxy: false,
    });
    await GStorage.localCache.put(LocalCacheKey.buvid, 'account-test-buvid');
    if (initialAccounts.isNotEmpty) {
      final initialBox = await Hive.openBox<LoginAccount>('account');
      await initialBox.putAll({
        for (final account in initialAccounts) '${account.mid}': account,
      });
      await initialBox.close();
    }
    await Accounts.init();

    // clear/reset can activate buvid. Initialize Request before replacing its
    // late-final Dio's adapter, and keep these side effects off the network.
    Request();
    Request.dio.httpClientAdapter.close(force: true);
    Request.dio
      ..httpClientAdapter = _ActivationAdapter()
      ..interceptors.clear();
    return AccountTestStorage._(directory);
  }

  Future<void> reset() async {
    await Accounts.clear();
    AnonymousAccount().activated = true;
  }

  Future<void> close() async {
    Request.dio.close(force: true);
    await Hive.close();
    await directory.delete(recursive: true);
  }
}

class _ActivationAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => Future.value(
    ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    ),
  );

  @override
  void close({bool force = false}) {}
}
