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


/// Small round glass button used in the app bar (heart, bell, refresh).
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
  State<GlassIconButton> createState() => _GlassIconButtonState();
}

class _GlassIconButtonState extends State<GlassIconButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.glow != null;
    final base = active ? widget.glow! : kGlassAccent;
    final enabled = widget.onPressed != null;
    final btn = AnimatedScale(
      scale: _down ? 0.88 : 1,
      duration: const Duration(milliseconds: 110),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(active ? 0.30 : 0.22),
              base.withOpacity(active ? 0.28 : 0.12),
            ],
          ),
          border: Border.all(
            color: Colors.white.withOpacity(active ? 0.55 : 0.32),
            width: 0.9,
          ),
          boxShadow: [
            BoxShadow(
              color: base.withOpacity(active ? 0.55 : 0.28),
              blurRadius: active ? 12 : 8,
              spreadRadius: active ? 0.5 : 0,
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            // glossy highlight on the upper half
            Positioned(
              top: 1.5,
              left: 4,
              right: 4,
              height: 11,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.white.withOpacity(0.30), Colors.white.withOpacity(0)],
                  ),
                ),
              ),
            ),
            widget.busy
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : ShaderMask(
                    shaderCallback: (r) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white, widget.color],
                    ).createShader(r),
                    child: Icon(widget.icon, size: 17, color: Colors.white),
                  ),
            if (widget.badge > 0)
              Positioned(
                right: -4,
                top: -4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3.5, vertical: 0.5),
                  constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFFFF6B8B), Color(0xFFFF3D71)]),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withOpacity(0.85), width: 0.9),
                    boxShadow: [
                      BoxShadow(color: const Color(0xFFFF3D71).withOpacity(0.55), blurRadius: 6),
                    ],
                  ),
                  child: Text(
                    widget.badge > 9 ? '9+' : '${widget.badge}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: widget.tooltip ?? '',
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: Opacity(opacity: !enabled && !widget.busy ? 0.5 : 1, child: btn),
        ),
      ),
    );
  }
}
