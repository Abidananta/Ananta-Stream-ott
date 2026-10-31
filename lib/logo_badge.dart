
import 'dart:ui' as ui show Image, ImageByteFormat;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Circular channel logo, transparent background, inside an accent-colour ring.
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

  /// Ring colour #85819c, used by every logo ring in the app.
  static const Color kRingColor = Color(0xFF85819C);

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
  // Spinning ring shown around the circle while the logo is still loading.
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
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
    if (provider == null) {
      _spin.stop();
      return;
    }
    if (!_spin.isAnimating) _spin.repeat();
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (info, _) async {
        final img = info.image;
        final round = await _hasTransparentCorners(img);
        if (!mounted || _stream != stream) return;
        setState(() => _loaded = ui_Image(img.width, img.height, round));
        _pulse.stop();
        _spin.stop();
      },
      onError: (_, __) {
        if (mounted) setState(() => _failed = true);
        _spin.stop();
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  /// True when the four corners of the logo are transparent, i.e. the logo is
  /// itself round (like the Star Sports badges) and can fill the circle fully.
  static Future<bool> _hasTransparentCorners(ui.Image img) async {
    try {
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return false;
      final w = img.width, h = img.height;
      if (w < 6 || h < 6) return false;
      int alphaAt(int x, int y) => data.getUint8((y * w + x) * 4 + 3);
      const m = 2;
      return alphaAt(m, m) < 64 &&
          alphaAt(w - 1 - m, m) < 64 &&
          alphaAt(m, h - 1 - m) < 64 &&
          alphaAt(w - 1 - m, h - 1 - m) < 64;
    } catch (_) {
      return false;
    }
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

  // Neutral dark greys (no blue) for the loading state and the ring.
  // Ring colour #85819c everywhere (loading, loaded and selected).
  Color get _darkAccent => LogoBadge.kRingColor;
  static const Color _ringGrey = LogoBadge.kRingColor;
  static const Color _ringGreySelected = LogoBadge.kRingColor;

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
                border: Border.all(color: _darkAccent.withOpacity(0.9 * (1 - t) + 0.1), width: 1.8),
              ),
            ),
            Container(
              width: s * 0.5,
              height: s * 0.5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _darkAccent.withOpacity(0.30 + 0.15 * t),
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
    final dim = _loaded!;
    final aspect = dim.h == 0 ? 1.0 : dim.w / dim.h;
    final nearSquare = aspect > 0.85 && aspect < 1.18;
    // Round logos (transparent corners) fill the circle exactly. Every other
    // logo is scaled so its whole rectangle (diagonal) fits inside the circle:
    // nothing is ever cut off or drawn outside the ring.
    if (nearSquare && dim.round) {
      return SizedBox.expand(
        key: const ValueKey('logo'),
        child: Image(
          image: widget.image!,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
        ),
      );
    }
    return LayoutBuilder(
      key: const ValueKey('logo'),
      builder: (context, c) {
        final d = c.biggest.shortestSide * 0.96;
        final h = d / math.sqrt(1 + aspect * aspect);
        final w = h * aspect;
        return Center(
          child: SizedBox(
            width: w,
            height: h,
            child: Image(
              image: widget.image!,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final showLogo = _loaded != null && !_failed;
    final sel = widget.selected;
    // Clean look: a thin solid ring, no gradient, no glow. The logo fills the
    // circle (74 px badge) on a transparent background.
    final ring = s * 0.04;
    if (!showLogo) {
      // Loading: dark, see-through disc inside a dark grey ring that spins.
      return AnimatedBuilder(
        animation: _spin,
        builder: (context, child) => Container(
          width: s,
          height: s,
          padding: EdgeInsets.all(s * 0.05),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              colors: [
                _darkAccent.withOpacity(0.2),
                _darkAccent,
                _darkAccent.withOpacity(0.85),
                _darkAccent.withOpacity(0.12),
              ],
              stops: const [0.0, 0.55, 0.8, 1.0],
              transform: GradientRotation(_spin.value * 6.2831853),
            ),
          ),
          child: child,
        ),
        child: ClipOval(
          clipBehavior: Clip.antiAlias,
          // Darker, see-through grey plate with a soft blur while loading.
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: ColoredBox(
              color: const Color(0xFF14131C).withOpacity(0.72),
              child: _placeholder(),
            ),
          ),
        ),
      );
    }
    return Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Dark, see-through plate (shows while the logo loads) - never grey.
        color: showLogo ? Colors.transparent : Colors.black.withOpacity(0.42),
        border: Border.all(
          color: sel ? _ringGreySelected : _ringGrey,
          width: ring,
        ),
      ),
      child: ClipOval(
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Dark, transparent, blurred base: shown while the logo loads and
            // behind any logo that has no white background of its own.
            BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: ColoredBox(color: Colors.black.withOpacity(0.38)),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOut,
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.expand,
                alignment: Alignment.center,
                children: [...previous, if (current != null) current],
              ),
              child: showLogo ? _logo() : _placeholder(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tiny value holder so we don't need dart:ui just for the pixel size.
class ui_Image {
  final int w;
  final int h;
  final bool round;
  const ui_Image(this.w, this.h, [this.round = false]);
}
