import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Polls the announcement manifest (notice.json in the repository) through the
/// native side and slides a glass banner down from the top of the screen.
/// While the app is in the background / PiP the native side posts a normal
/// heads-up system notification instead.
class NoticeService {
  NoticeService._();
  static final NoticeService instance = NoticeService._();

  static const MethodChannel _channel = MethodChannel('com.ananta.ott/notice');

  Timer? _timer;
  OverlayEntry? _entry;
  BuildContext? _context;
  bool _busy = false;

  void start(BuildContext context) {
    if (!Platform.isAndroid) return;
    _context = context;
    // Push messages (Firebase) that arrive while the app is open.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'showNotice' && call.arguments is Map) {
        final r = call.arguments as Map;
        final ctx = _context;
        if (ctx != null && ctx.mounted) {
          _show(
            ctx,
            title: '${r['title'] ?? ''}',
            body: '${r['body'] ?? ''}',
            image: '${r['image'] ?? ''}',
            url: '${r['url'] ?? ''}',
          );
        }
      }
      return null;
    });
    _timer?.cancel();
    Future<void>.delayed(const Duration(seconds: 5), _check);
    _timer = Timer.periodic(const Duration(seconds: 45), (_) => _check());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _context = null;
    _channel.setMethodCallHandler(null);
    _dismiss();
  }

  Future<void> _check() async {
    if (_busy || _entry != null) return;
    _busy = true;
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('checkNotice');
      if (r == null) return;
      final ctx = _context;
      if (ctx == null || !ctx.mounted) return;
      _show(
        ctx,
        title: '${r['title'] ?? ''}',
        body: '${r['body'] ?? ''}',
        image: '${r['image'] ?? ''}',
        url: '${r['url'] ?? ''}',
      );
    } catch (e) {
      debugPrint('Notice check failed: $e');
    } finally {
      _busy = false;
    }
  }

  void _show(BuildContext ctx,
      {required String title,
      required String body,
      required String image,
      required String url}) {
    final overlay = Overlay.maybeOf(ctx, rootOverlay: true);
    if (overlay == null) return;
    _dismiss();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _NoticeBanner(
        title: title,
        body: body,
        image: image,
        url: url,
        onClosed: () {
          if (_entry == entry) _entry = null;
          entry.remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  void _dismiss() {
    final e = _entry;
    _entry = null;
    if (e != null) {
      try {
        e.remove();
      } catch (_) {}
    }
  }
}

class _NoticeBanner extends StatefulWidget {
  const _NoticeBanner({
    required this.title,
    required this.body,
    required this.image,
    required this.url,
    required this.onClosed,
  });
  final String title;
  final String body;
  final String image;
  final String url;
  final VoidCallback onClosed;

  @override
  State<_NoticeBanner> createState() => _NoticeBannerState();
}

class _NoticeBannerState extends State<_NoticeBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    reverseDuration: const Duration(milliseconds: 260),
  );
  Timer? _auto;
  double _drag = 0;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    HapticFeedback.lightImpact();
    _anim.forward();
    _auto = Timer(const Duration(seconds: 20), _close);
  }

  @override
  void dispose() {
    _auto?.cancel();
    _anim.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _auto?.cancel();
    if (mounted) {
      try {
        await _anim.reverse();
      } catch (_) {}
    }
    widget.onClosed();
  }

  Future<void> _open() async {
    final uri = Uri.tryParse(widget.url);
    unawaited(_close());
    if (uri != null && uri.hasScheme) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final curved = CurvedAnimation(
        parent: _anim, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn);
    final hasImage = widget.image.isNotEmpty;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, (-1 + curved.value) * (top + 220) + _drag),
          child: Opacity(opacity: _anim.value.clamp(0.0, 1.0), child: child),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, top + 8, 12, 0),
          child: GestureDetector(
            onTap: _open,
            onVerticalDragUpdate: (d) {
              _auto?.cancel();
              setState(() => _drag = (_drag + d.delta.dy).clamp(-300.0, 24.0));
            },
            onVerticalDragEnd: (d) {
              if (_drag < -30 || (d.primaryVelocity ?? 0) < -300) {
                _close();
              } else {
                setState(() => _drag = 0);
                _auto = Timer(const Duration(seconds: 6), _close);
              }
            },
            child: Material(
              type: MaterialType.transparency,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          const Color(0xFF3A3560).withOpacity(0.72),
                          const Color(0xFF15122B).withOpacity(0.62),
                        ],
                      ),
                      border: Border.all(
                          color: Colors.white.withOpacity(0.22), width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.35),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.asset(
                                'assets/ananta_launcher_icon.png',
                                width: 20,
                                height: 20,
                                errorBuilder: (_, __, ___) => const Icon(
                                    Icons.live_tv,
                                    size: 18,
                                    color: Color(0xFF9B87FF)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'ANANTA OTT',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.9,
                                color: Colors.white70,
                              ),
                            ),
                            const Text('  •  now',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.white54)),
                            const Spacer(),
                            GestureDetector(
                              onTap: _close,
                              behavior: HitTestBehavior.opaque,
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(Icons.close_rounded,
                                    size: 18, color: Colors.white60),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (widget.title.isNotEmpty)
                          Text(
                            widget.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        if (widget.body.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            widget.body,
                            maxLines: hasImage ? 2 : 4,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 1.3,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                        if (hasImage) ...[
                          const SizedBox(height: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: AspectRatio(
                              aspectRatio: 16 / 8,
                              child: CachedNetworkImage(
                                imageUrl: widget.image,
                                fit: BoxFit.cover,
                                fadeInDuration:
                                    const Duration(milliseconds: 250),
                                placeholder: (_, __) => Container(
                                    color: Colors.white.withOpacity(0.06)),
                                errorWidget: (_, __, ___) => Container(
                                  color: Colors.white.withOpacity(0.06),
                                  child: const Icon(
                                      Icons.image_not_supported_outlined,
                                      color: Colors.white38),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
