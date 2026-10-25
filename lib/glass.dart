import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Shared "liquid glass" look for the whole app.
///
/// * [Glass]            – frosted panel (blur + tinted gradient + light edge).
/// * [GlassBackground]  – soft aurora backdrop that the glass panels pick up.
/// * [GlassChip]        – pill used for categories.
///
/// Live blur ([BackdropFilter]) is only used on large, few panels. Long lists
/// use blur: 0, which still looks frosted over the aurora background but costs
/// almost nothing on low-end phones and TV boxes.

const Color kGlassAccent = Color(0xFF9B87FF);
const Color kGlassBase = Color(0xFF090914);
const Color kGlassTint = Color(0xFF2A2646);

class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 16,
    this.borderRadius,
    this.padding,
    this.margin,
    this.tint = kGlassTint,
    this.strength = 1.0,
    this.blur = 16,
    this.borderColor,
    this.borderWidth = 1,
    this.glow,
    this.glowBlur = 18,
  });

  final Widget child;
  final double radius;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color tint;

  /// Multiplies the opacity of the glass tint (1 = default).
  final double strength;

  /// Gaussian blur sigma of the content behind the glass. 0 disables the
  /// (expensive) live blur.
  final double blur;
  final Color? borderColor;
  final double borderWidth;

  /// Optional coloured glow around the panel (used for focus / selection).
  final Color? glow;
  final double glowBlur;

  @override
  Widget build(BuildContext context) {
    final r = borderRadius ?? BorderRadius.circular(radius);
    final topAlpha = (0.66 * strength).clamp(0.0, 1.0).toDouble();
    final bottomAlpha = (0.36 * strength).clamp(0.0, 1.0).toDouble();
    // The top-left corner is lit a little (white sheen) like real glass.
    final top = Color.alphaBlend(
      Colors.white.withOpacity(0.13),
      tint.withOpacity(topAlpha),
    );
    final bottom = tint.withOpacity(bottomAlpha);
    final decoration = BoxDecoration(
      borderRadius: r,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [top, bottom],
      ),
      border: Border.all(
        color: borderColor ?? Colors.white.withOpacity(0.17),
        width: borderWidth,
      ),
    );
    final padded = padding == null ? child : Padding(padding: padding!, child: child);
    final body = DecoratedBox(decoration: decoration, child: padded);
    Widget glass = ClipRRect(
      borderRadius: r,
      child: blur > 0
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: body,
            )
          : body,
    );
    if (glow != null) {
      glass = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: r,
          boxShadow: [BoxShadow(color: glow!, blurRadius: glowBlur)],
        ),
        child: glass,
      );
    }
    if (margin != null) glass = Padding(padding: margin!, child: glass);
    return glass;
  }
}

/// Dark base with soft coloured light orbs. Static, so it is painted once.
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF15112B), kGlassBase, Color(0xFF0B0A1C)],
                  ),
                ),
              ),
              _Orb(alignment: Alignment(-1.15, -0.85), size: 420, color: Color(0xFF7C5CFF), opacity: 0.46),
              _Orb(alignment: Alignment(1.25, -0.15), size: 360, color: Color(0xFF2E7DFF), opacity: 0.30),
              _Orb(alignment: Alignment(-0.55, 1.2), size: 440, color: Color(0xFFFF4FA3), opacity: 0.22),
            ],
          ),
        ),
        child,
      ],
    );
  }
}

class _Orb extends StatelessWidget {
  const _Orb({
    required this.alignment,
    required this.size,
    required this.color,
    required this.opacity,
  });
  final Alignment alignment;
  final double size;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: alignment,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color.withOpacity(opacity), color.withOpacity(0)],
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass pill (category chips etc.).
class GlassChip extends StatelessWidget {
  const GlassChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: 22,
      blur: 0,
      tint: selected ? kGlassAccent : kGlassTint,
      strength: selected ? 1.15 : 0.75,
      borderColor: selected ? Colors.white.withOpacity(0.55) : null,
      glow: selected ? kGlassAccent.withOpacity(0.38) : null,
      glowBlur: 14,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


/// Round glass button used in the app bar (heart, bell, refresh).
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color = Colors.white,
    this.glow,
    this.badge = 0,
    this.busy = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color color;

  /// Coloured halo behind the button (active state).
  final Color? glow;
  final int badge;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final active = glow != null;
    final btn = Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            (active ? glow! : Colors.white).withOpacity(active ? 0.34 : 0.20),
            (active ? glow! : Colors.white).withOpacity(active ? 0.10 : 0.05),
          ],
        ),
        border: Border.all(
          color: (active ? glow! : Colors.white).withOpacity(active ? 0.65 : 0.26),
        ),
        boxShadow: [
          if (active)
            BoxShadow(color: glow!.withOpacity(0.45), blurRadius: 14, spreadRadius: 0.5),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: kGlassAccent),
                )
              : Icon(icon, size: 20, color: color),
          if (badge > 0)
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFFFF6B8B), Color(0xFFFF3D71)]),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: Colors.white.withOpacity(0.85), width: 1),
                  boxShadow: [
                    BoxShadow(color: const Color(0xFFFF3D71).withOpacity(0.55), blurRadius: 8),
                  ],
                ),
                child: Text(
                  badge > 9 ? '9+' : '$badge',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Tooltip(
        message: tooltip ?? '',
        child: GestureDetector(
          onTap: onPressed,
          behavior: HitTestBehavior.opaque,
          child: Opacity(opacity: onPressed == null && !busy ? 0.5 : 1, child: btn),
        ),
      ),
    );
  }
}


/// Animated "TV streaming" logo: a glowing TV with a pulsing play button,
/// radiating broadcast waves from the antenna and a light sweep over the screen.
class AnimatedTvLogo extends StatefulWidget {
  const AnimatedTvLogo({super.key, this.size = 42});
  final double size;

  @override
  State<AnimatedTvLogo> createState() => _AnimatedTvLogoState();
}

class _AnimatedTvLogoState extends State<AnimatedTvLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => CustomPaint(
            size: Size(widget.size, widget.size),
            painter: _TvLogoPainter(_c.value),
          ),
        ),
      );
}

class _TvLogoPainter extends CustomPainter {
  _TvLogoPainter(this.t);
  final double t;

  // App palette only: accent violet with its light lavender and deep violet tones.
  static const _violet = Color(0xFF9B87FF);
  static const _pink = Color(0xFF7C5CFF); // deep violet
  static const _cyan = Color(0xFFD6CCFF); // light lavender

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 44.0;
    canvas.save();
    canvas.scale(s, s);
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);

    // soft pulsing glow behind the TV
    canvas.drawCircle(
      const Offset(22, 26),
      18,
      Paint()
        ..shader = RadialGradient(colors: [
          _violet.withOpacity(0.38 + 0.2 * pulse),
          _pink.withOpacity(0.10),
          Colors.transparent,
        ]).createShader(Rect.fromCircle(center: const Offset(22, 26), radius: 18)),
    );

    final tv = RRect.fromRectAndRadius(
        const Rect.fromLTWH(4, 16, 36, 25), const Radius.circular(8));
    final grad = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [_cyan, _violet, _pink],
    ).createShader(const Rect.fromLTWH(4, 16, 36, 25));

    // antenna
    final ant = Paint()
      ..shader = grad
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(22, 16), const Offset(14.5, 8), ant);
    canvas.drawLine(const Offset(22, 16), const Offset(30, 8), ant);
    canvas.drawCircle(const Offset(14.5, 8), 1.8, Paint()..color = _cyan);
    canvas.drawCircle(const Offset(30, 8), 1.8, Paint()..color = _pink);

    // broadcast waves from the right antenna tip
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final r = 3 + 10 * p;
      canvas.drawArc(
        Rect.fromCircle(center: const Offset(30, 8), radius: r),
        -math.pi * 0.42,
        math.pi * 0.62,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 1.7
          ..color = _cyan.withOpacity((1 - p) * 0.9),
      );
    }

    // body: glassy fill + gradient outline
    canvas.drawRRect(
      tv,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withOpacity(0.22), _violet.withOpacity(0.12)],
        ).createShader(tv.outerRect),
    );
    canvas.drawRRect(
      tv,
      Paint()
        ..shader = grad
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4,
    );

    // light sweep over the screen
    canvas.save();
    canvas.clipRRect(tv.deflate(2));
    final sweepX = -14 + 64 * ((t * 1.0) % 1.0);
    final sweep = Path()
      ..moveTo(sweepX, 16)
      ..lineTo(sweepX + 8, 16)
      ..lineTo(sweepX - 2, 41)
      ..lineTo(sweepX - 10, 41)
      ..close();
    canvas.drawPath(sweep, Paint()..color = Colors.white.withOpacity(0.20));
    canvas.restore();

    // pulsing play button
    final k = 1 + 0.10 * pulse;
    canvas.save();
    canvas.translate(23, 28.5);
    canvas.scale(k, k);
    final play = Path()
      ..moveTo(-3.8, -5.6)
      ..lineTo(-3.8, 5.6)
      ..lineTo(5.6, 0)
      ..close();
    canvas.drawPath(
      play,
      Paint()
        ..shader = const LinearGradient(
          colors: [Colors.white, Color(0xFFE6DEFF)],
        ).createShader(const Rect.fromLTWH(-4, -6, 10, 12)),
    );
    canvas.restore();

    // tiny stand
    final stand = Paint()
      ..color = _violet.withOpacity(0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(14, 42.5), const Offset(18, 42.5), stand);
    canvas.drawLine(const Offset(26, 42.5), const Offset(30, 42.5), stand);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TvLogoPainter old) => old.t != t;
}
