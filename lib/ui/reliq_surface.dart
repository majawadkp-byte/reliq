import 'dart:ui';
import 'package:flutter/material.dart';

/// RELIQ V2.2 visual-system primitives.  Keep business screens theme-aware by
/// asking these helpers for semantic surfaces instead of hard-coding white/black.
class ReliqSurface {
  ReliqSurface._();

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;
  static Color glass(BuildContext context, {double? opacity}) => isDark(context)
      ? const Color(0xFF0C2226).withValues(alpha: opacity ?? .78)
      : const Color(0xFFFFFFFF).withValues(alpha: opacity ?? .88);
  static Color glassStrong(BuildContext context) => isDark(context)
      ? const Color(0xFF0B2024).withValues(alpha: .91)
      : const Color(0xFFFFFFFF).withValues(alpha: .94);
  static Color glassBorder(BuildContext context) => isDark(context)
      ? Colors.white.withValues(alpha: .12)
      : const Color(0xFFDDE5E6).withValues(alpha: .95);
  static Color textPrimary(BuildContext context) =>
      isDark(context) ? const Color(0xFFF5F8F7) : const Color(0xFF1C2D30);
  static Color textSecondary(BuildContext context) =>
      isDark(context) ? const Color(0xFFB8C9C8) : const Color(0xFF66777A);
  static Color textMuted(BuildContext context) =>
      isDark(context) ? const Color(0xFF829A99) : const Color(0xFF66777A);
  static Color input(BuildContext context) => isDark(context)
      ? const Color(0xFF071A1E).withValues(alpha: .54)
      : const Color(0xFFFFFFFF).withValues(alpha: .90);

  static const BoxShadow darkShadow = BoxShadow(
      color: Color(0x42000000), blurRadius: 30, offset: Offset(0, 14));
  static const BoxShadow lightShadow = BoxShadow(
      color: Color(0x160A2929), blurRadius: 30, offset: Offset(0, 14));
}

class ReliqGlass extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;
  final bool strong;
  final bool clip;
  final bool reflective;
  final double reflectionStrength;

  const ReliqGlass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 18,
    this.blur = 18,
    this.strong = false,
    this.clip = true,
    this.reflective = true,
    this.reflectionStrength = .55,
  });

  @override
  Widget build(BuildContext context) {
    final dark = ReliqSurface.isDark(context);
    final decoration = BoxDecoration(
      color: strong
          ? ReliqSurface.glassStrong(context)
          : ReliqSurface.glass(context),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: ReliqSurface.glassBorder(context)),
      boxShadow: [dark ? ReliqSurface.darkShadow : ReliqSurface.lightShadow],
    );
    Widget body = Container(
      decoration: decoration,
      child: Stack(fit: StackFit.passthrough, children: [
        if (reflective)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: dark
                        ? [
                            Colors.white
                                .withValues(alpha: .10 * reflectionStrength),
                            Colors.white
                                .withValues(alpha: .015 * reflectionStrength),
                            const Color(0xFFE1FF05)
                                .withValues(alpha: .025 * reflectionStrength),
                          ]
                        : [
                            Colors.white
                                .withValues(alpha: .72 * reflectionStrength),
                            Colors.white
                                .withValues(alpha: .08 * reflectionStrength),
                            const Color(0xFF11908C)
                                .withValues(alpha: .018 * reflectionStrength),
                          ],
                    stops: const [0, .46, 1],
                  ),
                ),
              ),
            ),
          ),
        if (reflective)
          Positioned(
            left: radius * .55,
            right: radius * .55,
            top: 0,
            height: 1,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      Colors.white.withValues(
                          alpha: (dark ? .30 : .84) * reflectionStrength),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
        Padding(padding: padding, child: child),
      ]),
    );
    if (!clip || blur <= 0) return body;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur), child: body),
    );
  }
}

/// Clean operational workspace background. The abstract RELIQ artwork is
/// reserved for authentication/branding screens so dense POS, reports and
/// accounting pages stay calm and highly readable.
class ReliqWorkspaceBackground extends StatelessWidget {
  final Widget child;
  const ReliqWorkspaceBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = ReliqSurface.isDark(context);
    return ColoredBox(
      color: dark ? const Color(0xFF07191D) : const Color(0xFFF7F9F9),
      child: child,
    );
  }
}

class ReliqBrandLockup extends StatelessWidget {
  final bool compact;
  final Color? textColor;
  const ReliqBrandLockup({super.key, this.compact = false, this.textColor});

  @override
  Widget build(BuildContext context) {
    // Use the approved horizontal logo artwork as-is. The brand guideline
    // explicitly prohibits recolouring or recreating the lockup in another
    // typeface, so the login never synthesizes the wordmark from Text widgets.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final asset = dark
        ? 'assets/branding/reliq_logo_white.png'
        : 'assets/branding/reliq_logo.png';
    final height = compact ? 42.0 : 78.0;
    return Image.asset(asset,
        height: height, fit: BoxFit.contain, alignment: Alignment.centerLeft);
  }
}
