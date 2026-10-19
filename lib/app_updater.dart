import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Update dialog that downloads the new APK inside the same dialog (animated
/// progress bar, no extra window) and then hands it to Android's installer.
/// Installing over the existing app keeps all data (no uninstall needed) as
/// long as the APK is signed with the same key.
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    super.key,
    required this.version,
    required this.notes,
    required this.downloadUrl,
    required this.fallbackUrl,
  });

  final String version;
  final String notes;
  final String downloadUrl;
  final String fallbackUrl;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

enum _Phase { idle, downloading, installing, needPermission, error }

class _UpdateDialogState extends State<UpdateDialog>
    with WidgetsBindingObserver {
  static const MethodChannel _installer =
      MethodChannel('com.ananta.ott/installer');

  _Phase _phase = _Phase.idle;
  double _progress = 0;
  int _received = 0;
  int _total = 0;
  String _error = '';
  http.Client? _client;
  bool _cancelled = false;
  String? _apkPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelled = true;
    _client?.close();
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

  Future<void> _start() async {
    if (_phase == _Phase.downloading || _phase == _Phase.installing) return;
    if (!Platform.isAndroid) {
      await _openBrowser();
      return;
    }
    if (_apkPath != null && File(_apkPath!).existsSync()) {
      await _install();
      return;
    }
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _received = 0;
      _total = 0;
      _error = '';
      _cancelled = false;
    });
    final client = http.Client();
    _client = client;
    IOSink? sink;
    File? file;
    try {
      final request = http.Request('GET', Uri.parse(widget.downloadUrl));
      request.headers['User-Agent'] = 'AnantaOTT-Updater/1.0';
      final response =
          await client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw Exception('Server returned HTTP ${response.statusCode}');
      }
      _total = response.contentLength ?? 0;
      file = File('${Directory.systemTemp.path}/ananta_update.apk');
      if (file.existsSync()) file.deleteSync();
      sink = file.openWrite();
      await for (final chunk in response.stream) {
        if (_cancelled) throw const _Cancelled();
        sink.add(chunk);
        _received += chunk.length;
        if (!mounted) return;
        setState(() {
          _progress = _total > 0 ? _received / _total : 0;
        });
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (_total > 0 && _received < _total) {
        throw Exception('Download incomplete');
      }
      _apkPath = file.path;
      if (!mounted) return;
      setState(() => _progress = 1);
      await _install();
    } on _Cancelled {
      try { await sink?.close(); } catch (_) {}
      try { file?.deleteSync(); } catch (_) {}
    } catch (e) {
      try { await sink?.close(); } catch (_) {}
      try { file?.deleteSync(); } catch (_) {}
      _apkPath = null;
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = 'Download failed. Check your internet and try again.';
      });
      debugPrint('Update download error: $e');
    } finally {
      client.close();
      _client = null;
    }
  }

  Future<void> _install() async {
    final path = _apkPath;
    if (path == null || !mounted) return;
    setState(() => _phase = _Phase.installing);
    try {
      final result =
          await _installer.invokeMethod<String>('installApk', {'path': path});
      if (!mounted) return;
      if (result == 'permission') {
        setState(() => _phase = _Phase.needPermission);
      } else {
        // Android's installer is now open. Keep the dialog so the user can
        // retry if they dismiss the installer.
        setState(() => _phase = _Phase.idle);
      }
    } catch (e) {
      debugPrint('Install launch error: $e');
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = 'Could not start the installer.';
      });
    }
  }

  Future<void> _openBrowser() async {
    final uri = Uri.tryParse(widget.fallbackUrl);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final busy = _phase == _Phase.downloading || _phase == _Phase.installing;
    final percent = (_progress * 100).clamp(0, 100).toStringAsFixed(0);
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('Ananta OTT update available'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('A new version (${widget.version}) is available.\n\n'
                  '${widget.notes}'),
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: _phase == _Phase.idle
                    ? Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          'Your data and settings are kept. Android will ask '
                          'you to confirm the update.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: _statusArea(percent),
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _phase == _Phase.installing
                ? null
                : () {
                    if (_phase == _Phase.downloading) {
                      _cancelled = true;
                      _client?.close();
                      setState(() => _phase = _Phase.idle);
                    } else {
                      Navigator.of(context).pop();
                    }
                  },
            child: Text(_phase == _Phase.downloading ? 'Cancel' : 'Later'),
          ),
          FilledButton(
            onPressed: busy ? null : _start,
            child: Text(_phase == _Phase.error
                ? 'Retry'
                : _phase == _Phase.needPermission
                    ? 'Continue'
                    : 'Download update'),
          ),
        ],
      ),
    );
  }

  Widget _statusArea(String percent) {
    switch (_phase) {
      case _Phase.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: _progress),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                builder: (_, value, __) => LinearProgressIndicator(
                  value: _total > 0 ? value : null,
                  minHeight: 10,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _total > 0
                  ? 'Downloading… $percent%  (${_mb(_received)} / ${_mb(_total)} MB)'
                  : 'Downloading… ${_mb(_received)} MB',
              style: Theme.of(context).textTheme.bodySmall,
            ),
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
            Text('Opening installer…',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      case _Phase.needPermission:
        return Text(
          'Allow "Install unknown apps" for Ananta OTT in the settings screen '
          'that opened, go back, and the update will continue.',
          style: Theme.of(context).textTheme.bodySmall,
        );
      case _Phase.error:
        return Text(_error,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.error));
      case _Phase.idle:
        return const SizedBox.shrink();
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
