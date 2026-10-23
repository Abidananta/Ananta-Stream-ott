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
  String _version = '1.1.9';

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
        transitionDuration: const Duration(milliseconds: 350),
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Decode the logo before the first animated frame so the pop-in never
    // stalls on image decoding (the main cause of a laggy start on TV boxes).
    precacheImage(const AssetImage('assets/ananta_launcher_icon.png'), context);
  }

  // Everything that moves is driven by transforms / opacity of layers that are
  // painted ONCE (RepaintBoundary + static children). The old version rebuilt
  // the whole tree every frame and re-rasterised a 100px blurred box-shadow,
  // which is very slow on TV GPUs.
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final logo = (math.min(size.width, size.height) * 0.62).clamp(180.0, 420.0);
    final popScale = Tween<double>(begin: 0.3, end: 1).animate(
        CurvedAnimation(parent: _intro, curve: Curves.easeOutBack));
    final fade = CurvedAnimation(
        parent: _intro, curve: const Interval(0, 0.5, curve: Curves.easeOut));
    final textFade = CurvedAnimation(
        parent: _intro, curve: const Interval(0.55, 1, curve: Curves.easeIn));
    final breathe = Tween<double>(begin: 0.97, end: 1.03).animate(
        CurvedAnimation(parent: _loop, curve: _SineCurve()));
    final glowScale = Tween<double>(begin: 0.95, end: 1.08).animate(
        CurvedAnimation(parent: _loop, curve: _SineCurve()));

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: SizedBox(
                  width: logo * 1.5,
                  height: logo * 1.5,
                  child: RepaintBoundary(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        for (var i = 0; i < 2; i++) _ring(logo, i / 2),
                        // Soft glow: a pre-drawn radial gradient that is only
                        // scaled, never re-blurred.
                        FadeTransition(
                          opacity: fade,
                          child: ScaleTransition(
                            scale: glowScale,
                            child: RepaintBoundary(
                              child: Container(
                                width: logo * 1.35,
                                height: logo * 1.35,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    colors: [
                                      Color(0x669B87FF),
                                      Color(0x229B87FF),
                                      Color(0x009B87FF),
                                    ],
                                    stops: [0.45, 0.72, 1.0],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Logo: pop-in + gentle breathing.
                        FadeTransition(
                          opacity: fade,
                          child: ScaleTransition(
                            scale: popScale,
                            child: ScaleTransition(
                              scale: breathe,
                              child: RepaintBoundary(
                                child: Image.asset(
                                  'assets/ananta_launcher_icon.png',
                                  width: logo,
                                  height: logo,
                                  fit: BoxFit.contain,
                                  filterQuality: FilterQuality.medium,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, __, ___) =>
                                      const SizedBox.shrink(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
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
                    RepaintBoundary(child: _LoadingBar(controller: _loop)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Expanding ripple: scale + fade of a static ring (no per-frame layout).
  Widget _ring(double logo, double phase) {
    final anim = CurvedAnimation(parent: _loop, curve: _PhaseCurve(phase));
    return RepaintBoundary(
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.45, end: 0.0).animate(anim),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.8, end: 1.5).animate(anim),
          child: Container(
            width: logo,
            height: logo,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF9B87FF), width: 2),
            ),
          ),
        ),
      ),
    );
  }
}

/// 0 → 1 → 0 smooth loop (sine), so repeating controllers have no jump.
class _SineCurve extends Curve {
  @override
  double transformInternal(double t) => 0.5 - 0.5 * math.cos(t * 2 * math.pi);
}

/// Same 0..1 ramp as the loop, shifted by [phase] (wraps around).
class _PhaseCurve extends Curve {
  const _PhaseCurve(this.phase);
  final double phase;
  @override
  double transformInternal(double t) => (t + phase) % 1.0;
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
