import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Animated "TV streaming" logo drawn entirely in code (no image): a violet
/// retro TV on standby (still) with a play button, a glassy shine that slides
/// over its screen and Wi-Fi style signal waves above the antennas.
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

    // The TV itself stands still (standby). Only two things move: the signal
    // waves above the antennas and one glassy shine sliding over the screen.

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
    canvas.drawCircle(rightTip, s * 0.05, Paint()..color = _violet);

    // ---- Wi-Fi style signal waves above both antennas ----------------------
    // Arcs light up one after another, travelling outwards like a signal.
    void waves(Offset tip, double centerAngle) {
      for (var i = 0; i < 3; i++) {
        final phase = (t * 3 - i) % 3.0;
        final glow = phase < 1.0 ? math.sin(phase * math.pi) : 0.0;
        final r = s * (0.10 + 0.075 * i);
        final alpha = 0.12 + 0.80 * glow;
        canvas.drawArc(
          Rect.fromCircle(center: tip, radius: r),
          centerAngle - math.pi * 0.24,
          math.pi * 0.48,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = s * 0.036
            ..color = _violetLight.withOpacity(alpha.clamp(0.0, 1.0)),
        );
      }
    }
    waves(leftTip, -math.pi * 0.75);
    waves(rightTip, -math.pi * 0.25);

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

    // Dark screen with a soft (static) glow behind the play button.
    final screenRect = Rect.fromLTWH(s * 0.10, s * 0.485, s * 0.72, s * 0.37);
    final screen = RRect.fromRectAndRadius(screenRect, Radius.circular(s * 0.11));
    canvas.drawRRect(screen, Paint()..color = const Color(0xFF2B2745));
    canvas.save();
    canvas.clipRRect(screen);
    final center = Offset(s * 0.46, s * 0.67);
    canvas.drawCircle(
      center,
      s * 0.32,
      Paint()
        ..shader = RadialGradient(
          colors: [_violet.withOpacity(0.6), _violet.withOpacity(0)],
        ).createShader(Rect.fromCircle(center: center, radius: s * 0.34)),
    );
    canvas.restore();

    // Play triangle (static).
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

    // Glassy diagonal shine sliding across the screen (over the play icon),
    // then a short pause before the next pass.
    final p = (t / 0.7).clamp(0.0, 1.0);
    if (p < 1.0) {
      final eased = Curves.easeInOut.transform(p);
      final bandW = s * 0.22;
      final x = screenRect.left - bandW + (screenRect.width + bandW * 2) * eased;
      canvas.save();
      canvas.clipRRect(screen);
      canvas.translate(x + bandW / 2, screenRect.center.dy);
      canvas.transform(Matrix4.skewX(-0.45).storage);
      final band = Rect.fromCenter(center: Offset.zero, width: bandW, height: screenRect.height * 1.4);
      canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
            colors: [
              Colors.white.withOpacity(0),
              Colors.white.withOpacity(0.38),
              Colors.white.withOpacity(0.10),
              Colors.white.withOpacity(0),
            ],
            stops: const [0.0, 0.45, 0.75, 1.0],
          ).createShader(band),
      );
      canvas.restore();
    }

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


/// App-bar title: "Ananta OTT" with a light shimmer sweeping across it and a
/// blinking red LIVE dot, same text and colours as before.
class AnimatedBrandTitle extends StatefulWidget {
  const AnimatedBrandTitle({super.key});

  @override
  State<AnimatedBrandTitle> createState() => _AnimatedBrandTitleState();
}

class _AnimatedBrandTitleState extends State<AnimatedBrandTitle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          // Shimmer travels left -> right during the first 55% of the loop.
          final p = (t / 0.55).clamp(0.0, 1.0);
          final x = -0.4 + 1.8 * p;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShaderMask(
                shaderCallback: (rect) => LinearGradient(
                  colors: const [Colors.white, Color(0xFFD6CCFF), Color(0xFFAA98FF)],
                ).createShader(rect),
                child: ShaderMask(
                  blendMode: BlendMode.srcATop,
                  shaderCallback: (rect) => LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.white.withOpacity(0),
                      Colors.white.withOpacity(p >= 1.0 ? 0 : 0.95),
                      Colors.white.withOpacity(0),
                    ],
                    stops: [
                      (x - 0.18).clamp(0.0, 1.0),
                      x.clamp(0.0, 1.0),
                      (x + 0.18).clamp(0.0, 1.0),
                    ],
                  ).createShader(rect),
                  child: const Text(
                    'Ananta OTT',
                    style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                      height: 1.05,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'LIVE TV  •  STREAMING',
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.6,
                      color: Color(0xAAC9BEFF),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
