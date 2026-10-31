import 'package:flutter/material.dart';

/// Circular channel logo with a transparent background.
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

class _LogoBadgeState extends State<LogoBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
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
    final dim = _loaded!;
    final aspect = dim.h == 0 ? 1.0 : dim.w / dim.h;
    final nearSquare = aspect > 0.85 && aspect < 1.18;
    final image = Image(
      image: widget.image!,
      fit: nearSquare ? BoxFit.cover : BoxFit.contain,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
    );
    // Round / square logos fill the circle exactly; wide or tall logos are
    // fitted inside the circle's inscribed square so nothing leaves the circle.
    return SizedBox.expand(
      key: const ValueKey('logo'),
      child: nearSquare
          ? image
          : Padding(padding: EdgeInsets.all(widget.size * 0.17), child: image),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final showLogo = _loaded != null && !_failed;
    const ring = 2.5;
    // Same design as the original list: a glass gradient ring with the logo
    // inside the circle on a transparent background.
    return Container(
      width: s,
      height: s,
      padding: const EdgeInsets.all(ring),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: widget.selected
              ? [Colors.white.withOpacity(0.9), widget.accent]
              : [Colors.white.withOpacity(0.55), widget.accent.withOpacity(0.25)],
        ),
        boxShadow: widget.selected
            ? [BoxShadow(color: widget.accent.withOpacity(0.5), blurRadius: 12)]
            : null,
      ),
      child: ClipOval(
        clipBehavior: Clip.antiAlias,
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
    );
  }
}

/// Tiny value holder so we don't need dart:ui just for the pixel size.
class ui_Image {
  final int w;
  final int h;
  const ui_Image(this.w, this.h);
}
