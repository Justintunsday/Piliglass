import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

enum IOSNativePlayerControlKind { header, bottom }

/// Hosts a UIKit control bar while retaining the original Flutter bar as a
/// live fallback. Playback, video rendering and danmaku remain in Flutter.
class IOSNativePlayerControlBar extends StatefulWidget {
  const IOSNativePlayerControlBar({
    super.key,
    required this.kind,
    required this.controller,
    required this.fallback,
    this.title = '',
    this.onBack,
    this.onHome,
    this.onShowSettings,
  });

  final IOSNativePlayerControlKind kind;
  final PlPlayerController controller;
  final Widget fallback;
  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onHome;
  final VoidCallback? onShowSettings;

  @override
  State<IOSNativePlayerControlBar> createState() =>
      _IOSNativePlayerControlBarState();
}

class _IOSNativePlayerControlBarState
    extends State<IOSNativePlayerControlBar> {
  static int _nextChannelId = 0;

  late final String _channelName;
  late final MethodChannel _channel;
  late final List<Worker> _workers;
  bool _nativeReady = false;

  @override
  void initState() {
    super.initState();
    final channelId = _nextChannelId++;
    _channelName = 'piliglass/native_player_controls/$channelId';
    _channel = MethodChannel(_channelName)
      ..setMethodCallHandler(_handleNativeCall);
    _workers = <Worker>[
      ever(widget.controller.playerStatus, (_) => _pushState()),
      ever(widget.controller.position, (_) => _pushState()),
      ever(widget.controller.buffered, (_) => _pushState()),
      ever(widget.controller.duration, (_) => _pushState()),
      ever(widget.controller.isFullScreen, (_) => _pushState()),
      ever(widget.controller.enableShowDanmaku, (_) => _pushState()),
      ever(widget.controller.isBuffering, (_) => _pushState()),
    ];
  }

  @override
  void didUpdateWidget(covariant IOSNativePlayerControlBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title) {
      _pushState();
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'ready':
        if (mounted && !_nativeReady) {
          setState(() => _nativeReady = true);
        }
        await _pushState();
      case 'action':
        final arguments = Map<String, Object?>.from(
          call.arguments as Map? ?? const <String, Object?>{},
        );
        await _handleAction(arguments);
    }
  }

  Future<void> _handleAction(Map<String, Object?> arguments) async {
    final action = arguments['name'];
    switch (action) {
      case 'back':
        widget.onBack?.call();
      case 'home':
        widget.onHome?.call();
      case 'settings':
        widget.onShowSettings?.call();
      case 'togglePlay':
        widget.controller.controls = true;
        await widget.controller.onDoubleTapCenter();
      case 'beginSeek':
        widget.controller
          ..controls = true
          ..isSeeking.value = true;
      case 'seek':
        final seconds = (arguments['value'] as num?)?.round();
        if (seconds != null) {
          widget.controller.position.value = seconds;
          await widget.controller.seekTo(
            Duration(seconds: seconds),
            isSeek: false,
          );
        }
        widget.controller.onSeekEnd();
      case 'toggleFullscreen':
        widget.controller.controls = true;
        await widget.controller.triggerFullScreen(
          status: !widget.controller.isFullScreen.value,
        );
      case 'toggleDanmaku':
        final enabled = !widget.controller.enableShowDanmaku.value;
        widget.controller.enableShowDanmaku.value = enabled;
        if (!widget.controller.tempPlayerConf) {
          await GStorage.setting.put(
            SettingBoxKey.enableShowDanmaku,
            enabled,
          );
        }
        widget.controller.controls = true;
    }
  }

  Future<void> _pushState() async {
    if (!_nativeReady) return;
    try {
      await _channel.invokeMethod<void>('updateState', <String, Object>{
        'isPlaying': widget.controller.playerStatus.value.isPlaying,
        'isBuffering': widget.controller.isBuffering.value,
        'position': widget.controller.position.value,
        'buffered': widget.controller.buffered.value,
        'duration': widget.controller.duration.value,
        'isFullscreen': widget.controller.isFullScreen.value,
        'danmakuEnabled': widget.controller.enableShowDanmaku.value,
        'title': widget.title,
      });
    } on PlatformException {
      if (mounted && _nativeReady) {
        setState(() => _nativeReady = false);
      }
    } on MissingPluginException {
      if (mounted && _nativeReady) {
        setState(() => _nativeReady = false);
      }
    }
  }

  @override
  void dispose() {
    for (final worker in _workers) {
      worker.dispose();
    }
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        IgnorePointer(
          ignoring: _nativeReady,
          child: AnimatedOpacity(
            opacity: _nativeReady ? 0 : 1,
            duration: const Duration(milliseconds: 160),
            child: widget.fallback,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_nativeReady,
            child: AnimatedOpacity(
              opacity: _nativeReady ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: UiKitView(
                viewType: 'piliglass/native_player_controls',
                creationParams: <String, Object>{
                  'channel': _channelName,
                  'kind': widget.kind.name,
                },
                creationParamsCodec: const StandardMessageCodec(),
                gestureRecognizers:
                    <Factory<OneSequenceGestureRecognizer>>{
                      Factory<EagerGestureRecognizer>(
                        EagerGestureRecognizer.new,
                      ),
                    },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
