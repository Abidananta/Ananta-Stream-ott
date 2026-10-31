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
    final tau = 2 * math.pi;

    // Whole logo floats up/down and tilts slightly, like a hovering icon.
    canvas.save();
    canvas.translate(0, math.sin(t * tau) * s * 0.025);
    canvas.translate(s * 0.46, s * 0.62);
    canvas.rotate(math.sin(t * tau + 1.2) * 0.045);
    canvas.translate(-s * 0.46, -s * 0.62);

    // ---- Antenna (V shape with ball tips) ---------------------------------
    final base = Offset(s * 0.49, s * 0.42);
    final wig = math.sin(t * 2 * tau);
    final leftTip = Offset(s * 0.28 + s * 0.012 * wig, s * 0.25 - s * 0.008 * wig);
    final rightTip = Offset(s * 0.65 - s * 0.012 * wig, s * 0.22 + s * 0.008 * wig);
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
    canvas.drawCircle(rightTip, s * 0.05, Paint()..color = Color.lerp(_violet, const Color(0xFFFF6FD8), pulse)!);

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

    // ---- Broadcast ripples: soft rings expanding from the antenna tip -------
    for (var i = 0; i < 2; i++) {
      final p = (t * 2 + i * 0.5) % 1.0;
      canvas.drawCircle(
        rightTip,
        s * (0.06 + 0.30 * p),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.016
          ..color = const Color(0xFFFF6FD8).withOpacity(0.5 * (1 - p)),
      );
    }

    // ---- Twinkling sparkles ---------------------------------------------------
    void sparkle(Offset c, double r, double phase) {
      final a = math.max(0.0, math.sin((t * 3 + phase) * tau));
      if (a <= 0.02) return;
      final rr = r * (0.5 + 0.7 * a);
      final paint = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = s * 0.018
        ..color = Colors.white.withOpacity(0.9 * a);
      canvas.drawLine(c.translate(-rr, 0), c.translate(rr, 0), paint);
      canvas.drawLine(c.translate(0, -rr), c.translate(0, rr), paint);
    }
    sparkle(Offset(s * 0.08, s * 0.30), s * 0.06, 0.0);
    sparkle(Offset(s * 0.93, s * 0.50), s * 0.05, 0.37);
    sparkle(Offset(s * 0.40, s * 0.08), s * 0.045, 0.71);

    // ---- Soft rotating colour halo behind the whole logo --------------------
    final haloRect = Rect.fromLTWH(-s * 0.05, s * 0.05, s * 1.1, s * 1.0);
    canvas.drawOval(
      haloRect,
      Paint()
        ..shader = SweepGradient(
          colors: [
            const Color(0xFF8F7BFF).withOpacity(0.55),
            const Color(0xFFFF6FD8).withOpacity(0.5),
            const Color(0xFF4FD8FF).withOpacity(0.5),
            const Color(0xFF8F7BFF).withOpacity(0.55),
          ],
          transform: GradientRotation(t * 2 * math.pi),
        ).createShader(haloRect)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.14),
    );

    // ---- TV body ------------------------------------------------------------
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.03, s * 0.42, s * 0.86, s * 0.50),
      Radius.circular(s * 0.16),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(-0.6 + 0.4 * math.sin(t * 2 * math.pi), -1),
          end: Alignment(1 - 0.4 * math.sin(t * 2 * math.pi), 1),
          colors: [
            Color.lerp(const Color(0xFFAFA0FF), const Color(0xFFFF9BE4), pulse)!,
            Color.lerp(_violetDeep, const Color(0xFF4F8BFF), pulse)!,
          ],
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
    // Diagonal shine that sweeps across the screen.
    final sx = s * (-0.2 + 1.2 * ((t * 1.0) % 1.0));
    canvas.drawRect(
      Rect.fromLTWH(sx, s * 0.45, s * 0.12, s * 0.45),
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white.withOpacity(0), Colors.white.withOpacity(0.28), Colors.white.withOpacity(0)],
        ).createShader(Rect.fromLTWH(sx, s * 0.45, s * 0.12, s * 0.45)),
    );
    // Faint scanlines that crawl down the screen.
    final lineGap = s * 0.045;
    final off = (t * 2 % 1.0) * lineGap;
    final linePaint = Paint()
      ..strokeWidth = s * 0.008
      ..color = Colors.white.withOpacity(0.07);
    for (var y = s * 0.485 + off; y < s * 0.86; y += lineGap) {
      canvas.drawLine(Offset(s * 0.10, y), Offset(s * 0.82, y), linePaint);
    }
    canvas.restore();

    // Play triangle.
    final k = s * (0.095 + 0.012 * pulse);
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
    canvas.restore();
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
          final blink = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * 4 * math.pi));
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
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(right: 5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFFF4F6B).withOpacity(blink),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFF4F6B).withOpacity(0.6 * blink),
                          blurRadius: 5,
                        ),
                      ],
                    ),
                  ),
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
