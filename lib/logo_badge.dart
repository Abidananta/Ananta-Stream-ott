import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Circular channel logo on a white plate inside a soft lavender ring.
///
/// * Until the logo has loaded (or if it is missing / fails) a soft animated
///   play icon is shown inside the circle.
/// * As soon as the image is ready the play icon cross-fades into the logo.
/// * Roughly square logos (e.g. round channel badges) fill the circle exactly;
///   wide or tall logos are shown whole (never cropped) with a little padding.
class LogoBadge extends StatefulWidget {
  final ImageProvider? image;
  final double size;
  final bool selected;
  final Color accent;
  const LogoBadge({
    super.key,
    required this.image,
    required this.size,
    required this.accent,
    this.selected = false,
  });

  @override
  State<LogoBadge> createState() => _LogoBadgeState();
}

class _LogoBadgeState extends State<LogoBadge> with TickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
  // Continuously rotating colour ring around the logo circle.
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3600))..repeat();
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui_Image? _loaded;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant LogoBadge old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _resolve();
  }

  void _resolve() {
    _detach();
    _loaded = null;
    _failed = false;
    final provider = widget.image;
    if (provider == null) return;
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() => _loaded = ui_Image(info.image.width, info.image.height));
        _pulse.stop();
      },
      onError: (_, __) {
        if (mounted) setState(() => _failed = true);
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _detach() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    _pulse.dispose();
    _spin.dispose();
    super.dispose();
  }

  Widget _placeholder() {
    final s = widget.size;
    return AnimatedBuilder(
      key: const ValueKey('ph'),
      animation: _pulse,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_pulse.value);
        return Stack(
          alignment: Alignment.center,
          children: [
            // expanding ring
            Container(
              width: s * (0.50 + 0.38 * t),
              height: s * (0.50 + 0.38 * t),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: widget.accent.withOpacity(0.55 * (1 - t)), width: 1.6),
              ),
            ),
            Container(
              width: s * 0.5,
              height: s * 0.5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.accent.withOpacity(0.18 + 0.12 * t),
              ),
            ),
            Transform.scale(
              scale: 0.9 + 0.2 * t,
              child: Icon(Icons.play_arrow_rounded, color: Colors.white.withOpacity(0.75 + 0.25 * t), size: s * 0.42),
            ),
          ],
        );
      },
    );
  }

  Widget _logo() {
    // Logo always sits whole inside the white plate (never cropped, never
    // outside the circle), with breathing room like the TV version.
    return Padding(
      key: const ValueKey('logo'),
      padding: EdgeInsets.all(widget.size * 0.12),
      child: Image(
        image: widget.image!,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final showLogo = _loaded != null && !_failed;
    final sel = widget.selected;
    final ring = s * 0.055; // soft lavender ring, same look as the TV list
    return Container(
      width: s,
      height: s,
      padding: EdgeInsets.all(ring),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: sel
              ? [Colors.white, widget.accent, const Color(0xFFB9A7FF)]
              : [const Color(0xFFD9D0FF), const Color(0xFF9F8FE6), const Color(0xFF7A68C8)],
        ),
        boxShadow: [
          BoxShadow(
            color: widget.accent.withOpacity(sel ? 0.65 : 0.30),
            blurRadius: sel ? 16 : 10,
            spreadRadius: sel ? 1 : 0,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipOval(
        clipBehavior: Clip.antiAlias,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: showLogo
                ? const RadialGradient(
                    center: Alignment(-0.3, -0.4),
                    radius: 1.0,
                    colors: [Color(0xFFFFFFFF), Color(0xFFF1EEFF)],
                  )
                : const RadialGradient(
                    colors: [Color(0xFF2A2552), Color(0xFF1B1836)],
                  ),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOut,
            layoutBuilder: (current, previous) => Stack(
              fit: StackFit.expand,
              alignment: Alignment.center,
              children: [...previous, if (current != null) current],
            ),
            child: showLogo ? _logo() : _placeholder(),
          ),
        ),
      ),
    );
  }
}

/// Tiny value holder so we don't need dart:ui just for the pixel size.
class ui_Image {
  final int w;
  final int h;
  const ui_Image(this.w, this.h);
}
