import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'glass.dart';

/// Polls the announcement manifest (notice.json in the repository) through the
/// native side and slides a glass banner down from the top of the screen.
/// While the app is in the background / PiP the native side posts a normal
/// heads-up system notification instead.
class NoticeService {
  NoticeService._();
  static final NoticeService instance = NoticeService._();

  static const MethodChannel _channel = MethodChannel('com.ananta.ott/notice');

  /// Number of notifications not yet seen in the list (bell badge).
  final ValueNotifier<int> unread = ValueNotifier<int>(0);

  Future<List<Map<String, dynamic>>> loadHistory() async {
    try {
      final raw = await _channel.invokeMethod<String>('getHistory') ?? '[]';
      final list = jsonDecode(raw);
      if (list is List) {
        return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (e) {
      debugPrint('Notice history failed: $e');
    }
    return [];
  }

  Future<void> refreshUnread() async {
    try {
      final lastRead = (await _channel.invokeMethod<num>('getLastRead'))?.toInt() ?? 0;
      final items = await loadHistory();
      unread.value = items
          .where((e) => ((e['time'] as num?)?.toInt() ?? 0) > lastRead)
          .length;
    } catch (_) {}
  }

  Future<void> markAllRead() async {
    try {
      await _channel.invokeMethod<void>('markRead');
    } catch (_) {}
    unread.value = 0;
  }

  Future<void> clearAll() async {
    try {
      await _channel.invokeMethod<void>('clearHistory');
    } catch (_) {}
    unread.value = 0;
  }

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
        unawaited(refreshUnread());
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
    unawaited(refreshUnread());
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
      unawaited(refreshUnread());
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
    _auto = Timer(const Duration(seconds: 16), _close);
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
                _auto = Timer(const Duration(seconds: 16), _close);
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


/// Bell icon for the app bar: opens the list of all received notifications.
class NoticeBell extends StatelessWidget {
  const NoticeBell({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    return ValueListenableBuilder<int>(
      valueListenable: NoticeService.instance.unread,
      builder: (context, count, _) => GlassIconButton(
        tooltip: 'Notifications',
        onPressed: () => showNoticeList(context),
        icon: count > 0
            ? Icons.notifications_active_rounded
            : Icons.notifications_none_rounded,
        color: Colors.white,
        glow: count > 0 ? const Color(0xFFFFB84D) : null,
        badge: count,
        anim: GlassIconAnim.ring,
      ),
    );
  }
}

String _ago(int ms) {
  final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.day}/${d.month}/${d.year}';
}

Future<void> showNoticeList(BuildContext context) async {
  final svc = NoticeService.instance;
  unawaited(svc.markAllRead());
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withOpacity(0.18),
    transitionDuration: const Duration(milliseconds: 380),
    pageBuilder: (_, __, ___) => const _NoticeListSheet(),
    transitionBuilder: (_, anim, __, child) {
      final curved = CurvedAnimation(
          parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      // Slides DOWN from the top of the screen.
      return SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero).animate(curved),
        child: FadeTransition(opacity: anim, child: child),
      );
    },
  );
}

class _NoticeListSheet extends StatefulWidget {
  const _NoticeListSheet();
  @override
  State<_NoticeListSheet> createState() => _NoticeListSheetState();
}

class _NoticeListSheetState extends State<_NoticeListSheet> {
  List<Map<String, dynamic>>? _items;

  @override
  void initState() {
    super.initState();
    NoticeService.instance.loadHistory().then((v) {
      if (mounted) setState(() => _items = v);
    });
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.hasScheme) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final h = media.size.height;
    final items = _items;
    return Align(
      alignment: Alignment.topCenter,
      child: Material(
        type: MaterialType.transparency,
        child: GestureDetector(
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -300) Navigator.of(context).maybePop();
          },
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 11, sigmaY: 11),
              child: Container(
                width: double.infinity,
                constraints: BoxConstraints(maxHeight: h * 0.78),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withOpacity(0.15),
                      const Color(0xFF7C5CFF).withOpacity(0.08),
                      Colors.white.withOpacity(0.03),
                    ],
                  ),
                  border: Border(
                    bottom: BorderSide(color: Colors.white.withOpacity(0.42), width: 1.2),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF9B87FF).withOpacity(0.25),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: media.padding.top + 10),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 10, 6),
                      child: Row(
                        children: [
                          const Icon(Icons.notifications_active_rounded,
                              color: Color(0xFFFFD27A), size: 22),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Notifications',
                              style: TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white),
                            ),
                          ),
                          if (items != null && items.isNotEmpty)
                            TextButton(
                              onPressed: () async {
                                await NoticeService.instance.clearAll();
                                if (mounted) setState(() => _items = []);
                              },
                              child: const Text('Clear all'),
                            ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: items == null
                          ? const Padding(
                              padding: EdgeInsets.all(40),
                              child: Center(child: CircularProgressIndicator()),
                            )
                          : items.isEmpty
                              ? const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 40),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.notifications_off_outlined,
                                          size: 44, color: Colors.white54),
                                      SizedBox(height: 10),
                                      Text('No notifications yet',
                                          style: TextStyle(color: Colors.white60)),
                                    ],
                                  ),
                                )
                              : ListView.separated(
                                  shrinkWrap: true,
                                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
                                  itemCount: items.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (_, i) => _tile(items[i]),
                                ),
                    ),
                    // grab handle (drag up to close)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10, top: 2),
                      child: Container(
                        width: 44,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white38,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> n) {
    final title = '${n['title'] ?? ''}';
    final body = '${n['body'] ?? ''}';
    final image = '${n['image'] ?? ''}';
    final url = '${n['url'] ?? ''}';
    final time = (n['time'] as num?)?.toInt() ?? 0;
    // Compact card (about channel-card size, slightly taller): thumbnail on
    // the left, title + 2 lines of text on the right.
    return GestureDetector(
      onTap: url.isEmpty ? null : () => _open(url),
      child: Container(
        constraints: const BoxConstraints(minHeight: 84),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(0.16),
              Colors.white.withOpacity(0.04),
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.30)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 12, offset: const Offset(0, 4)),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 64,
                height: 64,
                child: image.isEmpty
                    ? Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [
                            const Color(0xFF9B87FF).withOpacity(0.55),
                            const Color(0xFFFF6FB1).withOpacity(0.35),
                          ]),
                        ),
                        child: const Icon(Icons.notifications_rounded, color: Colors.white, size: 28),
                      )
                    : CachedNetworkImage(
                        imageUrl: image,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(color: Colors.white.withOpacity(0.06)),
                        errorWidget: (_, __, ___) => Container(
                          color: Colors.white.withOpacity(0.06),
                          child: const Icon(Icons.image_not_supported_outlined, color: Colors.white38),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(_ago(time), style: const TextStyle(fontSize: 11, color: Colors.white54)),
                    ],
                  ),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, height: 1.25, color: Colors.white70),
                    ),
                  ],
                  if (url.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    const Row(
                      children: [
                        Icon(Icons.open_in_new_rounded, size: 12, color: Color(0xFF9B87FF)),
                        SizedBox(width: 4),
                        Text('Open link', style: TextStyle(fontSize: 11, color: Color(0xFF9B87FF))),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
