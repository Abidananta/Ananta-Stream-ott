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
    final inner = BorderRadius.circular((radius - 1).clamp(0, 999).toDouble());
    // Frosted body: light enters from the top-left (brighter top edge).
    final body = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: inner,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tint.withOpacity((opacity + 0.09).clamp(0.0, 1.0)),
            tint.withOpacity((opacity * 0.55).clamp(0.0, 1.0)),
          ],
        ),
      ),
      child: child,
    );
    // Specular sheen over the upper part of the glass + a faint bottom bounce.
    final sheen = Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: inner,
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x2EFFFFFF), Color(0x08FFFFFF), Color(0x00FFFFFF), Color(0x0FB9A8FF)],
              stops: [0.0, 0.32, 0.62, 1.0],
            ),
          ),
        ),
      ),
    );
    Widget surface = Stack(children: [sheen, body]);
    if (blur > 0) {
      surface = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: surface,
      );
    }
    surface = ClipRRect(borderRadius: inner, child: surface);
    // Gradient hairline border (bright top-left, soft bottom-right) = polished
    // glass edge, with a soft drop shadow lifting the card off the background.
    Widget card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.28),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withOpacity((borderOpacity + 0.30).clamp(0.0, 1.0)),
            Colors.white.withOpacity(borderOpacity * 0.35),
            const Color(0xFFB9A8FF).withOpacity(borderOpacity * 0.9),
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: Padding(padding: const EdgeInsets.all(1), child: surface),
    );
    card = RepaintBoundary(child: card);
    return margin == null ? card : Padding(padding: margin!, child: card);
  }
}

/// Full-height frosted panel (TV channel rail / programme guide).
/// Live backdrop blur of the TV panels (sidebar / guide). Set to 0 to turn the
/// blur off on slow TV boxes.
class GlassConfig {
  GlassConfig._();
  static const double tvPanelBlur = 14; // frosted glass; set to 0 on very slow TV boxes
}

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.blur = GlassConfig.tvPanelBlur,
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
            const Color(0xFF1B1840).withOpacity(blur > 0 ? 0.74 : 0.93),
            const Color(0xFF0B0A1E).withOpacity(blur > 0 ? 0.66 : 0.90),
          ],
        ),
        border: rightBorder
            ? Border(right: BorderSide(color: const Color(0xFFD9D0FF).withOpacity(0.30)))
            : null,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x22FFFFFF), Color(0x00FFFFFF), Color(0x14B9A8FF)],
                  stops: [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
          child,
        ],
      ),
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
            colors: [Color(0xFF110D2E), Color(0xFF070712)],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _orb(const Alignment(1.1, -0.85), 420, const Color(0xFF7C4DFF)),
            _orb(const Alignment(-1.2, -0.1), 380, const Color(0xFF2979FF)),
            _orb(const Alignment(0.9, 0.95), 400, const Color(0xFFE040FB)),
            _orb(const Alignment(-0.3, 1.2), 340, const Color(0xFF00B8D4)),
          ],
        ),
      ),
    );
  }
}
