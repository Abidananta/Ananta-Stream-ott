import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ExoPlayer (AndroidX Media3) playback engine - the same engine family that
/// TiviMate uses. The decoding itself runs natively (see
/// android_template/AnantaExoPlayer.kt); frames are delivered to Flutter
/// through a GPU texture, so the Ananta OTT UI, overlays, PiP and remote
/// handling are completely unchanged.
///
/// [AnantaPlayerController] keeps the exact API the app already used, so no
/// screen needed to be redesigned.
const MethodChannel _exoChannel = MethodChannel('com.ananta.ott/exo');

/// Native -> Dart events are routed to the controller that owns the player id.
final Map<int, AnantaPlayerController> _exoControllers = <int, AnantaPlayerController>{};
bool _exoRouterReady = false;

void _ensureExoRouter() {
  if (_exoRouterReady) return;
  _exoRouterReady = true;
  _exoChannel.setMethodCallHandler((call) async {
    if (call.method != 'event') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final id = (args['id'] as num?)?.toInt();
    if (id == null) return null;
    _exoControllers[id]?._onNativeEvent(Map<Object?, Object?>.from(args));
    return null;
  });
}

class AnantaPlayerValue {
  final AnantaPlayerController owner;
  const AnantaPlayerValue(this.owner);
  bool get isInitialized => owner._opened;
  bool get hasError => owner._error != null;
  String? get errorDescription => owner._error;
  bool get isPlaying => owner._playing;
  bool get isBuffering => owner._buffering;
  Duration get position => owner._position;
  bool get isCompleted => owner._ended;
  double get aspectRatio {
    final s = owner.displaySize;
    return s.width > 0 && s.height > 0 ? s.width / s.height : 16 / 9;
  }
}

class AnantaPlayerController {
  final Uri uri;
  final Map<String, String> httpHeaders;

  /// Decoded video size (drives the HD/FHD/4K badge).
  final ValueNotifier<Size> videoSize = ValueNotifier<Size>(Size.zero);

  /// Live decoder / format diagnostics from the native player.
  final ValueNotifier<String> diagNotifier = ValueNotifier<String>('');
  final List<String> _diag = <String>[];

  /// True while the stream is rebuffering (drives the on-screen badge).
  final ValueNotifier<bool> bufferingNotifier = ValueNotifier<bool>(false);

  /// Size to draw at, i.e. [videoSize] corrected by the pixel aspect ratio.
  Size displaySize = Size.zero;

  /// Texture id Flutter draws the video frames from (null until initialized).
  int? textureId;
  final ValueNotifier<int?> textureNotifier = ValueNotifier<int?>(null);

  int? _id;
  bool _opened = false;
  bool _buffering = false;
  bool _playing = false;
  bool _ended = false;
  bool _disposed = false;
  bool _hasVideo = true;
  bool _ready = false;
  String? _error;
  Duration _position = Duration.zero;
  Completer<void>? _readyCompleter;

  AnantaPlayerController.networkUrl(this.uri, {this.httpHeaders = const {}, dynamic videoPlayerOptions});

  /// Last native playback error (decoder / network), if any.
  String? get lastError => _error;
  String get diagText => _diag.join('\n');

  AnantaPlayerValue get value => AnantaPlayerValue(this);

  Future<void> initialize() async {
    _ensureExoRouter();
    try {
      final res = await _exoChannel.invokeMapMethod<String, dynamic>('create', <String, dynamic>{
        'url': uri.toString(),
        'headers': httpHeaders,
      });
      if (res == null) throw PlatformException(code: 'NO_PLAYER', message: 'ExoPlayer could not be created');
      final id = (res['id'] as num).toInt();
      if (_disposed) {
        // Disposed while the native player was being created.
        unawaited(_exoChannel.invokeMethod<void>('dispose', <String, dynamic>{'id': id}));
        throw StateError('Player disposed during initialize');
      }
      _id = id;
      _exoControllers[id] = this;
      textureId = (res['textureId'] as num).toInt();
      textureNotifier.value = textureId;
      _opened = true;
    } catch (e) {
      _error = e.toString();
      rethrow;
    }
  }

  void _onNativeEvent(Map<Object?, Object?> e) {
    if (_disposed) return;
    switch (e['type']) {
      case 'state':
        _buffering = e['buffering'] == true;
        if (bufferingNotifier.value != _buffering) bufferingNotifier.value = _buffering;
        _playing = e['playing'] == true;
        _ended = e['ended'] == true;
        _ready = e['ready'] == true;
        _hasVideo = e['hasVideo'] != false;
        if (_ready) _error = null;
        if (_ready && !_hasVideo) _completeReady();
        break;
      case 'size':
        final w = (e['width'] as num?)?.toDouble() ?? 0;
        final h = (e['height'] as num?)?.toDouble() ?? 0;
        final par = (e['par'] as num?)?.toDouble() ?? 1.0;
        debugPrint('Ananta ExoPlayer video size: ${w.toInt()}x${h.toInt()} (par $par) for $uri');
        displaySize = Size(w * (par > 0 ? par : 1.0), h);
        videoSize.value = Size(w, h);
        if (w > 0 && h > 0) _completeReady();
        break;
      case 'pos':
        _position = Duration(milliseconds: (e['ms'] as num?)?.toInt() ?? 0);
        break;
      case 'info':
        _diag.add((e['message'] as String?) ?? '');
        if (_diag.length > 4) _diag.removeAt(0);
        diagNotifier.value = _diag.join('\n');
        break;
      case 'error':
        _error = (e['message'] as String?) ?? 'Playback error';
        debugPrint('Ananta ExoPlayer error for $uri: $_error');
        _completeReady(); // fail fast instead of waiting for the 12 s timeout
        break;
    }
  }

  void _completeReady() {
    final c = _readyCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Completes when the first video size is known (or the stream is audio only).
  Future<void> waitForVideoReady() {
    if (videoSize.value.width > 0 && videoSize.value.height > 0) return Future<void>.value();
    if (_ready && !_hasVideo) return Future<void>.value();
    return (_readyCompleter ??= Completer<void>()).future;
  }

  Future<void> setVolume(double volume) => _call('setVolume', <String, dynamic>{'volume': volume});
  /// Takes audio focus for this player (done only once it is the visible channel).
  Future<void> setAudioFocus(bool enabled) => _call('setAudioFocus', <String, dynamic>{'enabled': enabled});
  Future<void> play() => _call('play');
  Future<void> pause() => _call('pause');

  Future<void> _call(String method, [Map<String, dynamic>? extra]) async {
    final id = _id;
    if (id == null || _disposed) return;
    try {
      await _exoChannel.invokeMethod<void>(method, <String, dynamic>{'id': id, ...?extra});
    } catch (e) {
      debugPrint('ExoPlayer $method failed: $e');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final id = _id;
    _id = null;
    if (id != null) {
      _exoControllers.remove(id);
      try {
        // Stops playback and releases the decoder so audio never lingers.
        await _exoChannel.invokeMethod<void>('dispose', <String, dynamic>{'id': id});
      } catch (e) {
        debugPrint('Player dispose error: $e');
      }
    }
    _readyCompleter = null;
    textureNotifier.value = null;
  }
}

/// Draws the ExoPlayer texture with the same fit logic as before: fill the box
/// when the source is close to it, otherwise keep the picture undistorted.
class VideoPlayer extends StatelessWidget {
  final AnantaPlayerController controller;
  const VideoPlayer(this.controller, {super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          return ValueListenableBuilder<int?>(
            valueListenable: controller.textureNotifier,
            builder: (context, textureId, _) {
              if (textureId == null) return const SizedBox.expand();
              return ValueListenableBuilder<Size>(
                valueListenable: controller.videoSize,
                builder: (context, rawSize, __) {
                  final size = controller.displaySize;
                  final hasSize = size.width > 0 && size.height > 0;
                  final srcAspect = hasSize ? size.width / size.height : 16 / 9;
                  final boxAspect = constraints.hasBoundedWidth &&
                          constraints.hasBoundedHeight &&
                          constraints.maxHeight > 0
                      ? constraints.maxWidth / constraints.maxHeight
                      : srcAspect;
                  final mismatch = boxAspect / srcAspect;
                  final fit = (mismatch >= 0.7 && mismatch <= 1.5) ? BoxFit.fill : BoxFit.contain;
                  return ClipRect(
                    child: SizedBox.expand(
                      child: hasSize
                          ? FittedBox(
                              fit: fit,
                              child: SizedBox(
                                width: size.width,
                                height: size.height,
                                child: Texture(textureId: textureId),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  );
                },
              );
            },
          );
        },
      );
}
