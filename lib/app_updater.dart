import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'glass.dart';

/// Update dialog: downloads the new APK inside the dialog (resumable, with
/// automatic retries) and hands it to Android's PackageInstaller.
///
/// Works with a phone touch screen AND an Android TV remote: the two buttons
/// own their focus nodes, Left/Right move between them and Select/Enter
/// activates the focused one.
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    super.key,
    required this.version,
    required this.notes,
    required this.downloadUrl,
    required this.fallbackUrl,
    this.mirrors = const [],
  });

  final String version;
  final String notes;
  final String downloadUrl;
  final String fallbackUrl;
  final List<String> mirrors;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

enum _Phase { idle, downloading, installing, needPermission, error }

class _UpdateDialogState extends State<UpdateDialog>
    with WidgetsBindingObserver {
  static const MethodChannel _installer =
      MethodChannel('com.ananta.ott/installer');

  // PackageInstaller status codes (android.content.pm.PackageInstaller).
  static const int _stPending = -1;
  static const int _stSuccess = 0;
  static const int _stBlocked = 2;
  static const int _stAborted = 3;
  static const int _stInvalid = 4;
  static const int _stConflict = 5;
  static const int _stStorage = 6;
  static const int _stIncompatible = 7;

  final FocusNode _laterNode = FocusNode(debugLabel: 'update-later');
  final FocusNode _actionNode = FocusNode(debugLabel: 'update-action');

  _Phase _phase = _Phase.idle;
  double _progress = 0;
  int _received = 0;
  int _total = 0;
  String _error = '';
  String _hint = '';
  bool _fatal = false; // retrying cannot help (e.g. signature mismatch)
  bool _permissionAsked = false;
  bool _cancelled = false;
  String? _apkPath;
  HttpClient? _http;
  Timer? _installTimeout;
  DateTime _lastPaint = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _installer.setMethodCallHandler(_onNative);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _installer.setMethodCallHandler(null);
    _installTimeout?.cancel();
    _cancelled = true;
    try {
      _http?.close(force: true);
    } catch (_) {}
    _laterNode.dispose();
    _actionNode.dispose();
    super.dispose();
  }

  // Back from the "Install unknown apps" settings screen: continue install.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _phase == _Phase.needPermission &&
        _apkPath != null) {
      unawaited(_install());
    }
  }

  String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  void _refocus(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && node.canRequestFocus) node.requestFocus();
    });
  }

  // ---------------------------------------------------------------- native

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method != 'installStatus' || !mounted) return null;
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final status = (args['status'] as num?)?.toInt() ?? 1;
    final message = (args['message'] as String?) ?? '';
    _installTimeout?.cancel();
    switch (status) {
      case _stPending:
        setState(() {
          _phase = _Phase.idle;
          _hint = 'Confirm the installation on the Android installer screen.';
        });
        _refocus(_actionNode);
        break;
      case _stSuccess:
        break; // the app is replaced and restarted by Android
      case _stAborted:
        setState(() {
          _phase = _Phase.idle;
          _hint =
              'Installation was cancelled. Press "Install update" to try again.';
        });
        _refocus(_actionNode);
        break;
      default:
        _showInstallFailure(status, message);
    }
    return null;
  }

  void _showInstallFailure(int status, String message) {
    final m = message.toUpperCase();
    var text = 'Install failed ($status): $message';
    var fatal = false;
    var deleteApk = false;
    if (status == _stIncompatible ||
        m.contains('UPDATE_INCOMPATIBLE') ||
        m.contains('SIGNATURE')) {
      text = 'Android refused the update because this APK is signed with a '
          'different key than the installed app. Uninstall Ananta OTT once and '
          'install the new APK; later updates will then work normally.';
      fatal = true;
      deleteApk = true;
    } else if (m.contains('VERSION_DOWNGRADE')) {
      text = 'The installed version is already the same or newer than this '
          'update.';
      fatal = true;
      deleteApk = true;
    } else if (status == _stStorage) {
      text = 'Not enough free storage to install the update. Free some space '
          'and press Retry.';
    } else if (status == _stInvalid || status == _stConflict) {
      text = 'The downloaded file was not accepted by Android. Press Retry to '
          'download it again.';
      deleteApk = true;
    } else if (status == _stBlocked) {
      text = 'The installation was blocked by the device. Allow "Install '
          'unknown apps" for Ananta OTT and press Retry.';
    }
    if (deleteApk) _deleteApk();
    setState(() {
      _phase = _Phase.error;
      _fatal = fatal;
      _error = text;
    });
    _refocus(_actionNode);
  }

  void _deleteApk() {
    final p = _apkPath;
    _apkPath = null;
    if (p == null) return;
    try {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // -------------------------------------------------------------- download

  Future<void> _start() async {
    if (_phase == _Phase.downloading) return;
    if (_fatal || !Platform.isAndroid) {
      await _openBrowser();
      return;
    }
    if (_apkPath != null && File(_apkPath!).existsSync()) {
      await _install();
      return;
    }
    await _downloadAndInstall();
  }

  Future<void> _downloadAndInstall() async {
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _received = 0;
      _total = 0;
      _error = '';
      _hint = '';
      _cancelled = false;
    });
    _refocus(_laterNode);
    try {
      String dir;
      try {
        dir = await _installer.invokeMethod<String>('getCacheDir') ??
            Directory.systemTemp.path;
      } catch (_) {
        dir = Directory.systemTemp.path;
      }
      final file = File('$dir/ananta_update_${widget.version}.apk');
      if (file.existsSync()) file.deleteSync(); // always start clean
      await _downloadWithRetry(file);
      _apkPath = file.path;
      if (!mounted) return;
      _paint(force: true);
      await _install();
    } on _Cancelled {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _hint = '';
      });
      _refocus(_actionNode);
    } catch (e) {
      debugPrint('Update download error: $e');
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = 'Download failed: ${_short(e)}\n'
            'Check your internet connection and press Retry.';
      });
      _refocus(_actionNode);
    }
  }

  String _short(Object e) {
    final s = e.toString().replaceAll('\n', ' ');
    return s.length > 110 ? '${s.substring(0, 110)}…' : s;
  }

  Future<void> _downloadWithRetry(File file) async {
    final urls = <String>[
      widget.downloadUrl,
      ...widget.mirrors,
    ].where((u) => u.trim().isNotEmpty).toList();
    Object? last;
    for (final url in urls) {
      if (file.existsSync()) file.deleteSync();
      for (var attempt = 0; attempt < 5; attempt++) {
        if (_cancelled) throw const _Cancelled();
        try {
          await _fetch(url, file);
          _verify(file);
          return;
        } on _Cancelled {
          rethrow;
        } catch (e) {
          if (_cancelled) throw const _Cancelled();
          last = e;
          debugPrint('Update download attempt ${attempt + 1} failed: $e');
          if (mounted) {
            setState(() => _hint = 'Connection problem, retrying '
                '(${attempt + 1}/5)…');
          }
          await Future<void>.delayed(Duration(seconds: 2 + attempt * 2));
        }
      }
    }
    throw last ?? Exception('No download URL');
  }

  /// One HTTP attempt. Resumes from the partial file with a Range request.
  Future<void> _fetch(String url, File file) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..autoUncompress = false
      ..userAgent = 'AnantaOTT-Updater/2.0';
    _http = client;
    try {
      var have = file.existsSync() ? file.lengthSync() : 0;
      final req = await client.getUrl(Uri.parse(url));
      req.followRedirects = true;
      req.maxRedirects = 8;
      if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode == 416) {
        await res.drain<void>();
        if (file.existsSync()) file.deleteSync();
        throw const HttpException('Range rejected, restarting');
      }
      if (res.statusCode != 200 && res.statusCode != 206) {
        await res.drain<void>();
        throw HttpException('Server returned HTTP ${res.statusCode}');
      }
      final append = res.statusCode == 206 && have > 0;
      if (!append) have = 0;
      final len = res.contentLength;
      _total = len >= 0 ? have + len : 0;
      _received = have;
      final sink =
          file.openWrite(mode: append ? FileMode.append : FileMode.write);
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 25))) {
          if (_cancelled) throw const _Cancelled();
          sink.add(chunk);
          _received += chunk.length;
          _paint();
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (_total > 0 && _received < _total) {
        throw const HttpException('Connection closed early');
      }
    } finally {
      client.close(force: true);
      if (identical(_http, client)) _http = null;
    }
  }

  void _verify(File file) {
    final len = file.lengthSync();
    var ok = len > 1024 * 1024;
    if (ok) {
      final raf = file.openSync();
      try {
        final head = raf.readSync(2);
        ok = head.length == 2 && head[0] == 0x50 && head[1] == 0x4B; // "PK"
      } finally {
        raf.closeSync();
      }
    }
    if (_total > 0 && len != _total) ok = false;
    if (!ok) {
      file.deleteSync();
      throw const HttpException('Downloaded file is not a valid APK');
    }
  }

  void _paint({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastPaint).inMilliseconds < 200) return;
    _lastPaint = now;
    if (!mounted) return;
    setState(() {
      _progress =
          _total > 0 ? (_received / _total).clamp(0.0, 1.0).toDouble() : 0;
    });
  }

  void _cancelDownload() {
    _cancelled = true;
    try {
      _http?.close(force: true);
    } catch (_) {}
  }

  // --------------------------------------------------------------- install

  Future<void> _install() async {
    final path = _apkPath;
    if (path == null || !mounted) return;
    setState(() {
      _phase = _Phase.installing;
      _hint = '';
    });
    try {
      final result = await _installer.invokeMethod<String>('installApk', {
        'path': path,
        // After the user was sent to settings once, do not block on the
        // permission check again (some TV firmwares always report "false").
        'force': _permissionAsked,
      });
      if (!mounted) return;
      if (result == 'permission') {
        _permissionAsked = true;
        setState(() => _phase = _Phase.needPermission);
        _refocus(_actionNode);
      } else if (result == 'session') {
        // Wait for the installer's status callback; fall back to idle if it
        // never arrives.
        _installTimeout?.cancel();
        _installTimeout = Timer(const Duration(seconds: 25), () {
          if (mounted && _phase == _Phase.installing) {
            setState(() => _phase = _Phase.idle);
            _refocus(_actionNode);
          }
        });
      } else {
        setState(() => _phase = _Phase.idle);
        _refocus(_actionNode);
      }
    } on PlatformException catch (e) {
      debugPrint('Install launch error: $e');
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = 'Could not start the installer (${e.code}: '
            '${e.message ?? 'unknown'}).';
      });
      _refocus(_actionNode);
    } catch (e) {
      debugPrint('Install launch error: $e');
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = 'Could not start the installer ($e).';
      });
      _refocus(_actionNode);
    }
  }

  Future<void> _openBrowser() async {
    final uri = Uri.tryParse(widget.fallbackUrl);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  // -------------------------------------------------------------------- UI

  void _onLater() {
    if (_phase == _Phase.downloading) {
      _cancelDownload();
    } else {
      Navigator.of(context).pop();
    }
  }

  bool _isConfirm(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.gameButtonA;

  // TV remote: Left/Right switch between "Later" and the action button,
  // Select/Enter presses the focused one. Handled here (above the buttons) so
  // it works on every TV firmware.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final k = event.logicalKey;
    final isArrow = k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown;
    if (event is KeyDownEvent) {
      if (k == LogicalKeyboardKey.arrowLeft) {
        _laterNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        if (_actionNode.canRequestFocus) _actionNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp ||
          k == LogicalKeyboardKey.arrowDown) {
        if (!_laterNode.hasFocus && !_actionNode.hasFocus) {
          _actionNode.requestFocus();
        }
        return KeyEventResult.handled;
      }
      if (_isConfirm(k)) {
        if (_laterNode.hasFocus) {
          _onLater();
        } else {
          unawaited(_start());
        }
        return KeyEventResult.handled;
      }
    } else if (isArrow || _isConfirm(k)) {
      // Swallow repeat/up events of keys we handle so they never reach the
      // player screen underneath the dialog.
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // Frosted-glass buttons; the focused one gets a thick white ring (TV remote).
  ButtonStyle _glassButton({required bool primary}) => ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(primary
            ? const Color(0xFF9B87FF).withOpacity(0.55)
            : Colors.white.withOpacity(0.09)),
        foregroundColor: const WidgetStatePropertyAll(Colors.white),
        overlayColor: WidgetStatePropertyAll(Colors.white.withOpacity(0.12)),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
        shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
        side: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.focused)
                ? const BorderSide(color: Colors.white, width: 3)
                : BorderSide(color: Colors.white.withOpacity(0.28), width: 1)),
      );

  String get _actionLabel {
    if (_fatal) return 'Open download page';
    switch (_phase) {
      case _Phase.error:
        return 'Retry';
      case _Phase.needPermission:
        return 'Continue';
      default:
        return (_apkPath != null) ? 'Install update' : 'Download update';
    }
  }

  @override
  Widget build(BuildContext context) {
    final downloading = _phase == _Phase.downloading;
    final busy = downloading || _phase == _Phase.installing;
    final percent = (_progress * 100).clamp(0, 100).toStringAsFixed(0);
    final theme = Theme.of(context);
    return PopScope(
      canPop: !downloading,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && downloading) _cancelDownload();
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Glass(
              radius: 28,
              blur: 26,
              opacity: 0.16,
              tint: const Color(0xFF2A2458),
              borderOpacity: 0.30,
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0x40FFFFFF), Color(0x149B87FF)],
                          ),
                          border: Border.all(color: Colors.white.withOpacity(0.38)),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF9B87FF).withOpacity(0.55),
                              blurRadius: 18,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: const Icon(Icons.system_update_rounded,
                            color: Colors.white, size: 25),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text('Ananta OTT update available',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('A new version (${widget.version}) is available.',
                              style: theme.textTheme.bodyLarge
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          Text(widget.notes,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: Colors.white70, height: 1.35)),
                          AnimatedSize(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                            alignment: Alignment.topCenter,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: _statusArea(percent),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        focusNode: _laterNode,
                        style: _glassButton(primary: false),
                        onPressed: _onLater,
                        child: Text(downloading ? 'Cancel' : 'Later'),
                      ),
                      const SizedBox(width: 10),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: busy
                              ? null
                              : const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [Color(0xFFB9A8FF), Color(0xFF7C5CFF), Color(0xFF4FA3FF)],
                                ),
                          boxShadow: busy
                              ? null
                              : [
                                  BoxShadow(
                                    color: const Color(0xFF7C5CFF).withOpacity(0.55),
                                    blurRadius: 16,
                                    offset: const Offset(0, 5),
                                  ),
                                ],
                        ),
                        child: FilledButton(
                          focusNode: _actionNode,
                          autofocus: true,
                          style: _glassButton(primary: true).copyWith(
                            backgroundColor: WidgetStatePropertyAll(
                                busy ? Colors.white.withOpacity(0.10) : Colors.transparent),
                          ),
                          onPressed: busy ? null : () => unawaited(_start()),
                          child: Text(_actionLabel),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusArea(String percent) {
    final small = Theme.of(context).textTheme.bodySmall;
    switch (_phase) {
      case _Phase.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: _progress),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              builder: (_, value, __) => _PremiumProgress(
                value: _total > 0 ? value : null,
                label: _total > 0 ? '$percent%' : '',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _total > 0
                  ? 'Downloading… $percent%  (${_mb(_received)} / ${_mb(_total)} MB)'
                  : 'Downloading… ${_mb(_received)} MB',
              style: small,
            ),
            if (_hint.isNotEmpty) Text(_hint, style: small),
          ],
        );
      case _Phase.installing:
        return Row(
          children: [
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 12),
            Text('Opening installer…', style: small),
          ],
        );
      case _Phase.needPermission:
        return Text(
          'Allow "Install unknown apps" for Ananta OTT in the settings screen '
          'that opened, then come back and press Continue.',
          style: small,
        );
      case _Phase.error:
        return Text(_error,
            style: small?.copyWith(color: Theme.of(context).colorScheme.error));
      case _Phase.idle:
        return Text(
          _hint.isNotEmpty
              ? _hint
              : 'Your data and settings are kept. Android will ask you to '
                  'confirm the update.',
          style: small,
        );
    }
  }
}

/// Glass progress bar: translucent track, glowing violet-to-blue fill with a
/// bright leading edge, and the percentage in a pill at the end.
class _PremiumProgress extends StatelessWidget {
  const _PremiumProgress({required this.value, required this.label});
  final double? value; // null = indeterminate
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 14,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.white.withOpacity(0.10),
              border: Border.all(color: Colors.white.withOpacity(0.22)),
            ),
            padding: const EdgeInsets.all(2),
            child: value == null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: const LinearProgressIndicator(
                      minHeight: 10,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFB9A8FF)),
                    ),
                  )
                : LayoutBuilder(builder: (context, c) {
                    final w = (c.maxWidth * value!.clamp(0.0, 1.0)).clamp(0.0, c.maxWidth);
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: w < 10 && w > 0 ? 10 : w,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          gradient: const LinearGradient(
                            colors: [Color(0xFF9B87FF), Color(0xFF4FC3F7)],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF7C9CFF).withOpacity(0.7),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
          ),
        ),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.white.withOpacity(0.12),
              border: Border.all(color: Colors.white.withOpacity(0.30)),
            ),
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
          ),
        ],
      ],
    );
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
