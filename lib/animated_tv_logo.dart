import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Small animated "TV streaming" logo drawn entirely in code (no image):
/// a glowing TV screen with a pulsing play button and live signal waves.
class AnimatedTvLogo extends StatefulWidget {
  const AnimatedTvLogo({super.key, this.size = 44});
  final double size;

  @override
  State<AnimatedTvLogo> createState() => _AnimatedTvLogoState();
}

class _AnimatedTvLogoState extends State<AnimatedTvLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(painter: _TvLogoPainter(_c.value)),
        ),
      ),
    );
  }
}

class _TvLogoPainter extends CustomPainter {
  _TvLogoPainter(this.t);
  final double t;

  static const Color _accent = Color(0xFF9B87FF);
  static const Color _accentLight = Color(0xFFD6CCFF);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);

    // Soft glow behind the set.
    canvas.drawCircle(
      Offset(s / 2, s * 0.58),
      s * (0.42 + 0.04 * pulse),
      Paint()
        ..color = _accent.withOpacity(0.16 + 0.10 * pulse)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.18),
    );

    // Antenna / live signal waves.
    final ax = s / 2;
    final ay = s * 0.20;
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final r = s * (0.07 + 0.16 * p);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = s * 0.035
        ..color = _accentLight.withOpacity((1 - p) * 0.9);
      canvas.drawArc(
        Rect.fromCircle(center: Offset(ax, ay), radius: r),
        -math.pi * 0.85,
        math.pi * 0.7,
        false,
        paint,
      );
    }
    canvas.drawCircle(Offset(ax, ay), s * 0.03, Paint()..color = _accentLight);

    // TV body.
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.10, s * 0.30, s * 0.80, s * 0.55),
      Radius.circular(s * 0.14),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3B2F8F), Color(0xFF14102E)],
        ).createShader(body.outerRect),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.045
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_accentLight, _accent],
        ).createShader(body.outerRect),
    );

    // Screen with a sweeping highlight.
    final screen = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.19, s * 0.38, s * 0.62, s * 0.39),
      Radius.circular(s * 0.08),
    );
    canvas.save();
    canvas.clipRRect(screen);
    canvas.drawRRect(screen, Paint()..color = const Color(0xFF0B0920));
    final sweepX = s * (-0.3 + 1.3 * t);
    canvas.drawRect(
      Rect.fromLTWH(sweepX, s * 0.38, s * 0.14, s * 0.39),
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.white.withOpacity(0),
            Colors.white.withOpacity(0.18),
            Colors.white.withOpacity(0),
          ],
        ).createShader(Rect.fromLTWH(sweepX, 0, s * 0.14, s)),
    );
    canvas.restore();

    // Pulsing play triangle.
    final cx = s * 0.51;
    final cy = s * 0.575;
    final k = s * (0.095 + 0.012 * pulse);
    final tri = Path()
      ..moveTo(cx - k * 0.7, cy - k)
      ..lineTo(cx + k * 1.1, cy)
      ..lineTo(cx - k * 0.7, cy + k)
      ..close();
    canvas.drawPath(
      tri,
      Paint()
        ..shader = const LinearGradient(
          colors: [Colors.white, _accentLight],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: k * 1.2)),
    );

    // Stand.
    final stand = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s * 0.05
      ..color = _accent;
    canvas.drawLine(Offset(s * 0.32, s * 0.93), Offset(s * 0.68, s * 0.93), stand);
  }

  @override
  bool shouldRepaint(covariant _TvLogoPainter old) => old.t != t;
}
