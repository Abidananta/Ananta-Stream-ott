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


/// Motion used by [GlassIconButton].
enum GlassIconAnim {
  none,

  /// Elastic pop plus a soft burst ring whenever an active icon switches on
  /// (favourite heart).
  pop,

  /// Gentle bell swing every few seconds while there is something unread.
  ring,

  /// Turns while busy and makes one full turn on tap (refresh).
  spin,
}

/// Round glass button used in the app bar (heart, bell, refresh).
class GlassIconButton extends StatefulWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color = Colors.white,
    this.glow,
    this.badge = 0,
    this.busy = false,
    this.anim = GlassIconAnim.none,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color color;

  /// Coloured halo behind the button (active state).
  final Color? glow;
  final int badge;
  final bool busy;
  final GlassIconAnim anim;

  @override
  State<GlassIconButton> createState() => _GlassIconButtonState();
}

class _GlassIconButtonState extends State<GlassIconButton> with TickerProviderStateMixin {
  static const double _size = 34;
  bool _down = false;

  late final AnimationController _pop =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  late final AnimationController _bell =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 4200));
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    _syncLoops(null);
  }

  @override
  void didUpdateWidget(covariant GlassIconButton old) {
    super.didUpdateWidget(old);
    if (widget.anim == GlassIconAnim.pop && old.icon != widget.icon && widget.glow != null) {
      _pop.forward(from: 0);
    }
    _syncLoops(old);
  }

  void _syncLoops(GlassIconButton? old) {
    if (widget.anim == GlassIconAnim.ring) {
      if (widget.badge > 0) {
        if (!_bell.isAnimating) _bell.repeat();
      } else if (_bell.isAnimating) {
        _bell.stop();
        _bell.value = 0;
      }
    }
    if (widget.anim == GlassIconAnim.spin) {
      if (widget.busy) {
        if (!_spin.isAnimating || old?.busy != true) _spin.repeat();
      } else if (old?.busy == true) {
        // Finish the current turn smoothly instead of snapping back.
        _spin.forward().whenComplete(() {
          if (mounted && !widget.busy) _spin.value = 0;
        });
      }
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    _bell.dispose();
    _spin.dispose();
    super.dispose();
  }

  void _tap() {
    if (widget.anim == GlassIconAnim.spin && !widget.busy) _spin.forward(from: 0);
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.glow != null;
    final base = active ? widget.glow! : kGlassAccent;
    final enabled = widget.onPressed != null;

    final icon = AnimatedBuilder(
      animation: Listenable.merge([_pop, _bell, _spin]),
      builder: (context, _) {
        var scale = 1.0;
        var angle = 0.0;
        var alignment = Alignment.center;
        if (widget.anim == GlassIconAnim.pop && _pop.isAnimating) {
          scale = 0.5 + 0.5 * Curves.elasticOut.transform(_pop.value);
        }
        if (widget.anim == GlassIconAnim.ring && widget.badge > 0) {
          final t = _bell.value;
          if (t < 0.24) {
            final p = t / 0.24;
            angle = math.sin(p * math.pi * 5) * (1 - p) * 0.42;
          }
          alignment = const Alignment(0, -0.7);
        }
        if (widget.anim == GlassIconAnim.spin) {
          angle = _spin.value * 2 * math.pi;
        }
        Widget ic = Icon(
          widget.icon,
          size: 19,
          color: widget.color,
        );
        ic = Transform.rotate(angle: angle, alignment: alignment, child: ic);
        return Transform.scale(scale: scale, child: ic);
      },
    );

    final burst = widget.anim == GlassIconAnim.pop
        ? AnimatedBuilder(
            animation: _pop,
            builder: (context, _) {
              if (!_pop.isAnimating) return const SizedBox.shrink();
              final v = Curves.easeOut.transform(_pop.value);
              return IgnorePointer(
                child: Opacity(
                  opacity: (1 - v).clamp(0.0, 1.0) * 0.8,
                  child: Container(
                    width: _size * (0.9 + 0.9 * v),
                    height: _size * (0.9 + 0.9 * v),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: base, width: 2.2 * (1 - v) + 0.4),
                    ),
                  ),
                ),
              );
            },
          )
        : const SizedBox.shrink();

    // Flat dark circle with a thin light ring and a clean white outline icon
    // (the original Ananta OTT app-bar look).
    final btn = AnimatedScale(
      scale: _down ? 0.9 : 1,
      duration: const Duration(milliseconds: 110),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          burst,
          Container(
            width: _size,
            height: _size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: active
                    ? [base.withOpacity(0.38), base.withOpacity(0.18)]
                    : const [Color(0xFF4A4661), Color(0xFF312E48)],
              ),
              border: Border.all(
                color: active ? base.withOpacity(0.85) : Colors.white.withOpacity(0.32),
                width: 1,
              ),
              boxShadow: active
                  ? [BoxShadow(color: base.withOpacity(0.40), blurRadius: 12)]
                  : null,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                if (widget.busy && widget.anim != GlassIconAnim.spin)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                else
                  icon,
                if (widget.badge > 0)
                  Positioned(
                    right: -3,
                    top: -3,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                      constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF3D71),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: const Color(0xFF1E1A33), width: 1.5),
                      ),
                      child: Text(
                        widget.badge > 9 ? '9+' : '${widget.badge}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 8.5,
                          height: 1.25,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Tooltip(
        message: widget.tooltip ?? '',
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: enabled ? _tap : null,
          behavior: HitTestBehavior.opaque,
          child: Opacity(opacity: !enabled && !widget.busy ? 0.5 : 1, child: btn),
        ),
      ),
    );
  }
}


/// Favourite heart used in channel rows: soft outline when off, glowing pink
/// gradient heart with a small elastic pop when switched on.
class FavoriteHeart extends StatefulWidget {
  const FavoriteHeart({super.key, required this.on, this.size = 20, this.offColor});
  final bool on;
  final double size;
  final Color? offColor;

  @override
  State<FavoriteHeart> createState() => _FavoriteHeartState();
}

class _FavoriteHeartState extends State<FavoriteHeart> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  @override
  void didUpdateWidget(covariant FavoriteHeart old) {
    super.didUpdateWidget(old);
    if (widget.on && !old.on) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final off = widget.offColor ?? Colors.white54;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final scale = _c.isAnimating ? 0.5 + 0.5 * Curves.elasticOut.transform(_c.value) : 1.0;
        final heart = widget.on
            ? Icon(Icons.favorite_rounded, size: widget.size, color: const Color(0xFFFF4F8B))
            : Icon(Icons.favorite_border_rounded, size: widget.size, color: off);
        return Transform.scale(scale: scale, child: heart);
      },
    );
  }
}
