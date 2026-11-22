import 'dart:async';

import 'package:dio/dio.dart';
import 'package:http2/http2.dart';

class RetryInterceptor extends Interceptor {
  final Dio _client;
  final int _count;
  final int _delay;

  RetryInterceptor(this._client, this._count, this._delay);

  int get count => _count;
  int get delayMilliseconds => _delay;
  bool isBoundTo(Dio client) => identical(_client, client);

  static ({String path, Uri uri}) resolveRedirect(Uri source, String location) {
    final uri = Uri.parse(location);
    if (uri.hasScheme) return (path: location, uri: uri);
    final target = source.resolveUri(uri);
    return (path: target.toString(), uri: target);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.responseType == ResponseType.stream) {
      return handler.next(err);
    }
    if (err.response != null) {
      final options = err.requestOptions;
      if (options.followRedirects && options.maxRedirects > 0) {
        final status = err.response!.statusCode;
        if (status != null && 300 <= status && status < 400) {
          final location = err.response!.headers.value('location');
          if (location != null) {
            final target = resolveRedirect(options.uri, location);
            (options..path = target.path).maxRedirects--;
            if (status == 303) {
              options
                ..data = null
                ..method = 'GET';
            }
            _client
                .fetch(options)
                .then(
                  (i) => handler.resolve(
                    i
                      ..redirects.add(
                        RedirectRecord(status, options.method, target.uri),
                      )
                      ..isRedirect = true,
                  ),
                )
                .onError<DioException>((error, _) => handler.next(error));
            return;
          }
        }
      }
      return handler.next(err);
    } else {
      switch (err.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.unknown:
          if ((err.requestOptions.extra['_rt'] ??= 0) < _count &&
              err.error
                  is! TransportConnectionException // 网络中断, 此时请求可能已经被服务器所接收
                  ) {
            Timer(
              Duration(
                milliseconds: ++err.requestOptions.extra['_rt'] * _delay,
              ),
              () => _client
                  .fetch(err.requestOptions)
                  .then(handler.resolve)
                  .onError<DioException>((error, _) => handler.reject(error)),
            );
          } else {
            handler.next(err);
          }
          return;
        default:
          return handler.next(err);
      }
    }
  }

  RetryInterceptor copyWith({Dio? client, int? count, int? delay}) =>
      .new(client ?? _client, count ?? _count, delay ?? _delay);
}
