import 'dart:ui';

import 'package:flutter/material.dart';

/// Glassmorphism ("frosted glass") building blocks used across the app.
///
/// * [Glass]         – rounded frosted card (optional live blur).
/// * [GlassPanel]    – full-height side panel (TV sidebar / EPG).
/// * [GlassBackdrop] – soft colour glow behind every screen, so the glass has
///                     something to refract and reads as glass, not as grey.
///
/// Live blur ([BackdropFilter]) costs GPU time, so it is only used on a few
/// big surfaces (app bar, search bar, dialogs, TV panels, player controls).
/// List items use the gradient + border look without a per-item blur.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 16,
    this.blur = 0,
    this.opacity = 0.10,
    this.tint = Colors.white,
    this.borderOpacity = 0.20,
    this.padding,
    this.margin,
  });

  final Widget child;
  final double radius;

  /// Gaussian blur sigma of what is behind the glass (0 = no live blur).
  final double blur;

  /// Strength of the tint (0.05 very clear … 0.6 almost solid).
  final double opacity;
  final Color tint;
  final double borderOpacity;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    Widget surface = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        // Light enters from the top-left: brighter top edge, clearer bottom.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tint.withOpacity((opacity + 0.08).clamp(0.0, 1.0)),
            tint.withOpacity((opacity * 0.6).clamp(0.0, 1.0)),
          ],
        ),
        border: Border.all(color: Colors.white.withOpacity(borderOpacity), width: 1),
      ),
      child: child,
    );
    if (blur > 0) {
      surface = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: surface,
      );
    }
    final clipped = ClipRRect(borderRadius: borderRadius, child: surface);
    return margin == null ? clipped : Padding(padding: margin!, child: clipped);
  }
}

/// Full-height frosted panel (TV channel rail / programme guide).
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.blur = 14,
    this.rightBorder = true,
  });

  final Widget child;
  final double blur;
  final bool rightBorder;

  @override
  Widget build(BuildContext context) {
    Widget panel = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF1B1840).withOpacity(0.74),
            const Color(0xFF0B0A1E).withOpacity(0.66),
          ],
        ),
        border: rightBorder
            ? Border(right: BorderSide(color: Colors.white.withOpacity(0.18)))
            : null,
      ),
      child: child,
    );
    if (blur > 0) {
      panel = ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: panel,
        ),
      );
    }
    return panel;
  }
}

/// Dark gradient with soft coloured glows. Sits under every page (see the
/// MaterialApp builder), so transparent scaffolds show it.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key});

  Widget _orb(Alignment alignment, double size, Color color) {
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color.withOpacity(0.55), color.withOpacity(0.0)],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D0B26), Color(0xFF080815)],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _orb(const Alignment(1.1, -0.85), 420, const Color(0xFF7C4DFF)),
            _orb(const Alignment(-1.2, -0.1), 380, const Color(0xFF2979FF)),
            _orb(const Alignment(0.9, 0.95), 400, const Color(0xFFE040FB)),
          ],
        ),
      ),
    );
  }
}
