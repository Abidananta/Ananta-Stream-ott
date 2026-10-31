import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Animated "TV streaming" logo drawn entirely in code (no image): a violet
/// retro TV with a play button, V-shaped antenna and signal waves that pulse
/// outwards. Matches the original Ananta OTT app-bar logo.
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
    duration: const Duration(milliseconds: 2400),
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

  static const Color _violet = Color(0xFF8F7BFF);
  static const Color _violetLight = Color(0xFFB9ABFF);
  static const Color _violetDeep = Color(0xFF6E5BE0);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);

    // ---- Antenna (V shape with ball tips) ---------------------------------
    final base = Offset(s * 0.49, s * 0.42);
    final leftTip = Offset(s * 0.28, s * 0.25);
    final rightTip = Offset(s * 0.65, s * 0.22);
    final stick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s * 0.05
      ..color = _violetLight;
    canvas.drawLine(base, leftTip, stick);
    canvas.drawLine(base, rightTip, stick);
    canvas.drawCircle(leftTip, s * 0.04, Paint()..color = const Color(0xFFD9D1FF));
    // The right ball glows with the broadcast pulse.
    canvas.drawCircle(
      rightTip,
      s * (0.075 + 0.02 * pulse),
      Paint()
        ..color = _violet.withOpacity(0.25 + 0.2 * pulse)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.04),
    );
    canvas.drawCircle(rightTip, s * 0.05, Paint()..color = _violet);

    // ---- Signal waves going out of the right antenna ----------------------
    for (var i = 0; i < 3; i++) {
      // Each wave lights up in turn, travelling outwards.
      final phase = (t * 3 - i) % 3.0;
      final glow = phase < 1.0 ? math.sin(phase * math.pi) : 0.0;
      final r = s * (0.11 + 0.085 * i);
      final alpha = (0.28 - 0.05 * i) + 0.62 * glow;
      canvas.drawArc(
        Rect.fromCircle(center: rightTip, radius: r),
        -math.pi * 0.43,
        math.pi * 0.46,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = s * 0.038
          ..color = _violetLight.withOpacity(alpha.clamp(0.0, 1.0)),
      );
    }

    // ---- TV body ------------------------------------------------------------
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.03, s * 0.42, s * 0.86, s * 0.50),
      Radius.circular(s * 0.16),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFAFA0FF), _violetDeep],
        ).createShader(body.outerRect),
    );

    // Dark screen with a soft glow behind the play button.
    final screen = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.10, s * 0.485, s * 0.72, s * 0.37),
      Radius.circular(s * 0.11),
    );
    canvas.drawRRect(screen, Paint()..color = const Color(0xFF2B2745));
    canvas.save();
    canvas.clipRRect(screen);
    final center = Offset(s * 0.46, s * 0.67);
    canvas.drawCircle(
      center,
      s * (0.30 + 0.04 * pulse),
      Paint()
        ..shader = RadialGradient(
          colors: [
            _violet.withOpacity(0.55 + 0.15 * pulse),
            _violet.withOpacity(0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: s * 0.34)),
    );
    canvas.restore();

    // Play triangle.
    final k = s * 0.095;
    final tri = Path()
      ..moveTo(center.dx - k * 0.75, center.dy - k * 1.05)
      ..lineTo(center.dx + k * 1.1, center.dy)
      ..lineTo(center.dx - k * 0.75, center.dy + k * 1.05)
      ..close();
    canvas.drawPath(
      tri,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Color(0xFFD9D1FF)],
        ).createShader(Rect.fromCircle(center: center, radius: k * 1.3)),
    );

    // Feet.
    final foot = Paint()..color = _violetDeep;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(s * 0.20, s * 0.92, s * 0.13, s * 0.045), Radius.circular(s * 0.02)),
      foot,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(s * 0.58, s * 0.92, s * 0.13, s * 0.045), Radius.circular(s * 0.02)),
      foot,
    );
  }

  @override
  bool shouldRepaint(covariant _TvLogoPainter old) => old.t != t;
}
