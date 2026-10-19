import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Animated launch screen: big logo (no white box), glowing rings, then
/// "Developed By Ananta", app version and a loading animation at the bottom.
class AnantaSplashScreen extends StatefulWidget {
  const AnantaSplashScreen({
    super.key,
    required this.next,
    this.duration = const Duration(milliseconds: 3600),
  });
  final WidgetBuilder next;
  final Duration duration;

  @override
  State<AnantaSplashScreen> createState() => _AnantaSplashScreenState();
}

class _AnantaSplashScreenState extends State<AnantaSplashScreen>
    with TickerProviderStateMixin {
  static const Color _bg = Color(0xFF090914);
  late final AnimationController _intro = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..forward();
  late final AnimationController _loop = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400))
    ..repeat();
  String _version = '1.1.6';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted && info.version.isNotEmpty) {
        setState(() => _version = info.version);
      }
    }).catchError((_) {});
    _timer = Timer(widget.duration, _goNext);
  }

  Timer? _timer;

  void _goNext() {
    if (!mounted) return;
    try {
      Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (c, _, __) => widget.next(c),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
      ));
    } catch (e) {
      debugPrint('Splash navigation failed: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _intro.dispose();
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final logo = (math.min(size.width, size.height) * 0.62).clamp(180.0, 420.0);
    final scale = CurvedAnimation(parent: _intro, curve: Curves.elasticOut);
    final fade = CurvedAnimation(
        parent: _intro, curve: const Interval(0, 0.5, curve: Curves.easeOut));
    final textFade = CurvedAnimation(
        parent: _intro, curve: const Interval(0.55, 1, curve: Curves.easeIn));

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_intro, _loop]),
                  builder: (context, _) {
                    final t = _loop.value;
                    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
                    final float = math.sin(t * 2 * math.pi) * 6;
                    return SizedBox(
                      width: logo * 1.5,
                      height: logo * 1.5,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Expanding ripple rings
                          for (var i = 0; i < 3; i++)
                            _ring(logo, (t + i / 3) % 1.0),
                          // Soft pulsing glow
                          Opacity(
                            opacity: fade.value,
                            child: Container(
                              width: logo * (0.95 + 0.08 * pulse),
                              height: logo * (0.95 + 0.08 * pulse),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF9B87FF)
                                        .withOpacity(0.25 + 0.2 * pulse),
                                    blurRadius: 70 + 30 * pulse,
                                    spreadRadius: 6,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // Logo: pop-in + gentle float + slow tilt
                          Transform.translate(
                            offset: Offset(0, float),
                            child: Transform.rotate(
                              angle: (1 - _intro.value) * -0.5 +
                                  math.sin(t * 2 * math.pi) * 0.025,
                              child: Transform.scale(
                                scale: (0.2 + 0.8 * scale.value) *
                                    (1 + 0.025 * pulse),
                                child: Opacity(
                                  opacity: fade.value.clamp(0.0, 1.0),
                                  child: Image.asset(
                                    'assets/ananta_launcher_icon.png',
                                    width: logo,
                                    height: logo,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.high,
                                    errorBuilder: (_, __, ___) =>
                                        const SizedBox.shrink(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            FadeTransition(
              opacity: textFade,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Developed By Ananta',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Version $_version',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 12, letterSpacing: 1),
                    ),
                    const SizedBox(height: 18),
                    _LoadingBar(controller: _loop),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ring(double logo, double p) {
    final d = logo * (0.8 + 0.7 * p);
    return Opacity(
      opacity: (1 - p) * 0.5 * _intro.value,
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF9B87FF), width: 2),
        ),
      ),
    );
  }
}

/// Sliding gradient loading bar shown at the bottom of the splash screen.
class _LoadingBar extends StatelessWidget {
  const _LoadingBar({required this.controller});
  final Animation<double> controller;

  @override
  Widget build(BuildContext context) {
    const w = 160.0, seg = 56.0;
    return Container(
      width: w,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedBuilder(
        animation: controller,
        builder: (_, __) {
          final x = -seg + (w + seg) * Curves.easeInOut.transform(controller.value);
          return Stack(children: [
            Positioned(
              left: x,
              width: seg,
              top: 0,
              bottom: 0,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                      colors: [Color(0xFF9B87FF), Color(0xFF4FC3F7)]),
                  borderRadius: BorderRadius.all(Radius.circular(4)),
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
