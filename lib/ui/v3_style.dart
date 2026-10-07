import 'package:flutter/material.dart';

/// Shared visual language for V4.  Keep product screens on these tokens instead
/// of inventing one-off colours, radii or spacing values.
class V3Style {
  // Brand
  // RELIQ 2026 brand palette — taken from the supplied identity artwork.
  static const brandDark = Color(0xFF1C2D30);
  static const brandDarkSoft = Color(0xFF263B3F);
  static const lime = Color(0xFFE1FF05);
  static const limeSoft = Color(0xFFF5FFC2);

  // Backward-compatible token names used across existing screens.
  // Primary UI actions stay dark for accessibility; lime is the signature accent.
  static const navyDeep = brandDark;
  static const navy = brandDark;
  static const navySoft = brandDarkSoft;
  static const blue = Color(0xFF11908C);
  static const blueDark = Color(0xFF075056);
  static const blueSoft = Color(0xFFE8F5F4);
  static const gold = lime;
  static const goldLight = lime;

  // Semantic accents — used consistently throughout cards, chips and actions.
  static const success = Color(0xFF16845B);
  static const successSoft = Color(0xFFE8F7F0);
  static const warning = Color(0xFFB7791F);
  static const warningSoft = Color(0xFFFFF5DF);
  static const danger = Color(0xFFC2414B);
  static const dangerSoft = Color(0xFFFDECEF);
  static const info = Color(0xFF2878B8);
  static const infoSoft = Color(0xFFE9F4FB);
  static const purple = Color(0xFF7656C7);
  static const purpleSoft = Color(0xFFF1EDFB);
  static const teal = Color(0xFF11908C);
  static const tealSoft = Color(0xFFE5F5F4);

  // Surfaces / typography
  static const background = Color(0xFFF7F9F9);
  static const surfaceSoft = Color(0xFFFFFFFF);
  static const line = Color(0xFFDDE5E6);
  static const muted = Color(0xFF66777A);
  static const ink = brandDark;
  static const sidebarText = Color(0xFFE4ECE8);
  static const sidebarMuted = Color(0xFFAABAB6);

  // Layout tokens
  static const double radiusSm = 8;
  static const double radiusMd = 11;
  static const double radiusLg = 15;
  static const double radiusXl = 18;
  static const double pageGap = 16;
  static const EdgeInsets pagePadding = EdgeInsets.all(22);
  static const EdgeInsets cardPadding = EdgeInsets.all(16);

  static Color rowStripe(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0x6B1A3335)
          : const Color(0xA8F4F8F5);

  static Color tableHeader(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xC21A3335)
          : const Color(0xDCF1F5F2);

  /// Theme-aware secondary text. Prefer this over the legacy static `muted`
  /// token for readable body/help text in both light and dark mode.
  static Color mutedFor(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant;

  /// Accessible RELIQ accent for labels/indicators. Electric lime is reserved
  /// for dark surfaces; light mode uses deep teal for sufficient contrast.
  static Color labelAccent(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? lime : const Color(0xFF11908C);

  static Color lineFor(BuildContext context) => Theme.of(context).dividerColor;

  static Color softFor(Color accent, {required bool dark}) {
    if (dark) return accent.withValues(alpha: .15);
    if (accent == success) return successSoft;
    if (accent == warning) return warningSoft;
    if (accent == danger) return dangerSoft;
    if (accent == info) return infoSoft;
    if (accent == purple) return purpleSoft;
    if (accent == teal) return tealSoft;
    return blueSoft;
  }

  static BoxDecoration sidebarDecoration() => const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [brandDark, Color(0xFF142326)],
        ),
      );

  static BoxDecoration goldLogoDecoration() => BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [goldLight, gold],
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Color(0x24000000), blurRadius: 18, offset: Offset(0, 7)),
        ],
      );
}
