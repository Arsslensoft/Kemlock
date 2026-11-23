import 'package:flutter/material.dart';

/// The ground colour of each scheme, for native chrome that is painted
/// before the theme is (the status bar, the launch screen). `GROUND` in
/// `theme.ts`.
abstract final class Ground {
  static const dark = Color(0xFF0A0B0D);
  static const light = Color(0xFFF4F4F1);

  static Color of(Brightness brightness) => brightness == Brightness.dark ? dark : light;
}

/// The palette of `theme.ts`, slot for slot as MUI names them: Graphite
/// ground and Azure accent, one set per scheme. Read it with
/// `context.palette`, so `color: 'text.secondary'` in the web app becomes
/// `context.palette.textSecondary` here.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.primary,
    required this.primaryLight,
    required this.primaryDark,
    required this.onPrimary,
    required this.secondary,
    required this.onSecondary,
    required this.info,
    required this.onInfo,
    required this.success,
    required this.onSuccess,
    required this.warning,
    required this.onWarning,
    required this.error,
    required this.onError,
    required this.background,
    required this.paper,
    required this.text,
    required this.textSecondary,
    required this.textDisabled,
    required this.divider,
    required this.hover,
    required this.selected,
    required this.focus,
    required this.active,
    required this.disabled,
    required this.disabledBackground,
  });

  static const dark = AppPalette(
    brightness: Brightness.dark,
    primary: Color(0xFF5AA9FF),
    primaryLight: Color(0xFF7DBBFF),
    primaryDark: Color(0xFF2F8CF0),
    onPrimary: Color(0xFF051220),
    secondary: Color(0xFF9BA0A8),
    onSecondary: Color(0xFF0A0B0D),
    info: Color(0xFF5AA9FF),
    onInfo: Color(0xFF051220),
    success: Color(0xFF5AA9FF),
    onSuccess: Color(0xFF051220),
    warning: Color(0xFFFFA24C),
    onWarning: Color(0xFF1A0E02),
    error: Color(0xFFFF6B5E),
    onError: Color(0xFF1F0604),
    background: Ground.dark,
    paper: Color(0xFF131417),
    text: Color(0xFFF3F4F6),
    textSecondary: Color(0xFF9BA0A8),
    textDisabled: Color.fromRGBO(243, 244, 246, 0.38),
    divider: Color.fromRGBO(255, 255, 255, 0.07),
    hover: Color.fromRGBO(255, 255, 255, 0.05),
    selected: Color.fromRGBO(90, 169, 255, 0.14),
    focus: Color.fromRGBO(90, 169, 255, 0.2),
    active: Color(0xFFFFFFFF),
    disabled: Color.fromRGBO(255, 255, 255, 0.3),
    disabledBackground: Color.fromRGBO(255, 255, 255, 0.12),
  );

  static const light = AppPalette(
    brightness: Brightness.light,
    primary: Color(0xFF1F6FEB),
    primaryLight: Color(0xFF5AA9FF),
    primaryDark: Color(0xFF1559C7),
    onPrimary: Color(0xFFFFFFFF),
    secondary: Color(0xFF50555D),
    onSecondary: Color(0xFFFFFFFF),
    info: Color(0xFF1F6FEB),
    onInfo: Color(0xFFFFFFFF),
    success: Color(0xFF1F6FEB),
    onSuccess: Color(0xFFFFFFFF),
    warning: Color(0xFF9A4A06),
    onWarning: Color(0xFFFFFFFF),
    error: Color(0xFFB42318),
    onError: Color(0xFFFFFFFF),
    background: Ground.light,
    paper: Color(0xFFFFFFFF),
    text: Color(0xFF0D0E10),
    textSecondary: Color(0xFF50555D),
    textDisabled: Color.fromRGBO(13, 14, 16, 0.38),
    divider: Color.fromRGBO(12, 13, 16, 0.07),
    hover: Color.fromRGBO(12, 13, 16, 0.04),
    selected: Color.fromRGBO(31, 111, 235, 0.1),
    focus: Color.fromRGBO(31, 111, 235, 0.16),
    active: Color.fromRGBO(0, 0, 0, 0.54),
    disabled: Color.fromRGBO(0, 0, 0, 0.26),
    disabledBackground: Color.fromRGBO(0, 0, 0, 0.12),
  );

  static AppPalette of(Brightness brightness) => brightness == Brightness.dark ? dark : light;

  final Brightness brightness;

  /// `primary.main`: Azure, for filled buttons, the switch track and links.
  final Color primary;
  final Color primaryLight;
  final Color primaryDark;

  /// `primary.contrastText`: ink on a primary fill.
  final Color onPrimary;
  final Color secondary;
  final Color onSecondary;
  final Color info;
  final Color onInfo;
  final Color success;
  final Color onSuccess;
  final Color warning;
  final Color onWarning;
  final Color error;
  final Color onError;

  /// `background.default`: the page, as [Ground].
  final Color background;

  /// `background.paper`: cards, sheets and dialogs.
  final Color paper;

  /// `text.primary`.
  final Color text;

  /// `text.secondary`.
  final Color textSecondary;

  /// `text.disabled`.
  final Color textDisabled;
  final Color divider;

  /// `action.hover`: the tint of a row or button under the finger.
  final Color hover;

  /// `action.selected`.
  final Color selected;

  /// `action.focus`.
  final Color focus;

  /// `action.active`, `action.disabled` and `action.disabledBackground`:
  /// MUI's own values, which `theme.ts` leaves as they are. Icon buttons
  /// take [active]; disabled filled buttons take the other two.
  final Color active;
  final Color disabled;
  final Color disabledBackground;

  bool get isDark => brightness == Brightness.dark;

  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      primary: l(primary, other.primary),
      primaryLight: l(primaryLight, other.primaryLight),
      primaryDark: l(primaryDark, other.primaryDark),
      onPrimary: l(onPrimary, other.onPrimary),
      secondary: l(secondary, other.secondary),
      onSecondary: l(onSecondary, other.onSecondary),
      info: l(info, other.info),
      onInfo: l(onInfo, other.onInfo),
      success: l(success, other.success),
      onSuccess: l(onSuccess, other.onSuccess),
      warning: l(warning, other.warning),
      onWarning: l(onWarning, other.onWarning),
      error: l(error, other.error),
      onError: l(onError, other.onError),
      background: l(background, other.background),
      paper: l(paper, other.paper),
      text: l(text, other.text),
      textSecondary: l(textSecondary, other.textSecondary),
      textDisabled: l(textDisabled, other.textDisabled),
      divider: l(divider, other.divider),
      hover: l(hover, other.hover),
      selected: l(selected, other.selected),
      focus: l(focus, other.focus),
      active: l(active, other.active),
      disabled: l(disabled, other.disabled),
      disabledBackground: l(disabledBackground, other.disabledBackground),
    );
  }
}

/// The extra design tokens that MUI's palette has no slot for, `palette.bmc`
/// in `theme.ts`. Read them with `context.bmc`.
@immutable
class BmcTokens extends ThemeExtension<BmcTokens> {
  const BmcTokens({
    required this.raised,
    required this.sunken,
    required this.line2,
    required this.faint,
    required this.accentText,
    required this.accentSoft,
    required this.accentLine,
    required this.warnSoft,
    required this.dangerSoft,
    required this.glass,
    required this.scrim,
    required this.thumb,
    required this.shadow,
    required this.glow,
    required this.ambient,
    required this.ambient2,
    required this.sheen,
    required this.neonHot,
  });

  static const dark = BmcTokens(
    raised: Color(0xFF1C1D21),
    sunken: Color(0xFF060607),
    line2: Color.fromRGBO(255, 255, 255, 0.12),
    faint: Color(0xFF868B94),
    accentText: Color(0xFF7DBBFF),
    accentSoft: Color.fromRGBO(90, 169, 255, 0.14),
    accentLine: Color.fromRGBO(90, 169, 255, 0.45),
    warnSoft: Color.fromRGBO(255, 162, 76, 0.13),
    dangerSoft: Color.fromRGBO(255, 107, 94, 0.12),
    glass: Color.fromRGBO(24, 25, 29, 0.72),
    scrim: Color.fromRGBO(0, 0, 0, 0.55),
    thumb: Color(0xFF2A2C31),
    // 0 18px 40px rgba(0, 0, 0, 0.45)
    shadow: [BoxShadow(color: Color.fromRGBO(0, 0, 0, 0.45), offset: Offset(0, 18), blurRadius: 40)],
    glow: Color.fromRGBO(90, 169, 255, 0.38),
    ambient: Color.fromRGBO(90, 169, 255, 0.2),
    ambient2: Color.fromRGBO(125, 187, 255, 0.1),
    sheen: Color.fromRGBO(255, 255, 255, 0.5),
    neonHot: Color(0xFFD6ECFF),
  );

  static const light = BmcTokens(
    raised: Color(0xFFEDEDE9),
    sunken: Color(0xFFE4E4DF),
    line2: Color.fromRGBO(12, 13, 16, 0.13),
    faint: Color(0xFF63686F),
    accentText: Color(0xFF1559C7),
    accentSoft: Color.fromRGBO(31, 111, 235, 0.1),
    accentLine: Color.fromRGBO(31, 111, 235, 0.45),
    warnSoft: Color.fromRGBO(180, 83, 9, 0.1),
    dangerSoft: Color.fromRGBO(200, 50, 31, 0.08),
    glass: Color.fromRGBO(255, 255, 255, 0.78),
    scrim: Color.fromRGBO(20, 20, 18, 0.28),
    thumb: Color(0xFFFFFFFF),
    // 0 14px 36px rgba(12, 13, 16, 0.12)
    shadow: [BoxShadow(color: Color.fromRGBO(12, 13, 16, 0.12), offset: Offset(0, 14), blurRadius: 36)],
    // The mockups are drawn dark only; these are set by openspec add-visual-effects, design decision 4.
    glow: Color.fromRGBO(31, 111, 235, 0.26),
    ambient: Color.fromRGBO(31, 111, 235, 0.09),
    ambient2: Color.fromRGBO(31, 111, 235, 0.05),
    sheen: Color.fromRGBO(255, 255, 255, 0.45),
    neonHot: Color(0xFF5AA9FF),
  );

  static BmcTokens of(Brightness brightness) => brightness == Brightness.dark ? dark : light;

  /// A surface one step up from paper: icon tiles, segmented tracks, toasts.
  final Color raised;

  /// A surface one step down from the page.
  final Color sunken;

  /// The stronger hairline: outlined fields and buttons, dialog edges.
  final Color line2;

  /// Text and icons that step back further than `text.secondary`.
  final Color faint;

  /// Azure as text: readable on the page and on [accentSoft].
  final Color accentText;

  /// Azure as a tint behind icons, selections and info alerts.
  final Color accentSoft;
  final Color accentLine;
  final Color warnSoft;
  final Color dangerSoft;

  /// Frosted surfaces that float over the page.
  final Color glass;

  /// The veil behind dialogs and sheets.
  final Color scrim;

  /// The sliding thumb of a segmented control.
  final Color thumb;

  /// The drop shadow of floating surfaces: dialogs, popovers, toasts.
  final List<BoxShadow> shadow;

  /// The accent as light: a glow at its fullest, and the standing glows of
  /// `effects.dart`.
  final Color glow;

  /// The middle of the first ambient light behind a page or a sheet, and
  /// of the second, fainter one behind a page.
  final Color ambient;
  final Color ambient2;

  /// The band of light that crosses a main button.
  final Color sheen;

  /// The bright point of the light that travels a card's border.
  final Color neonHot;

  @override
  BmcTokens copyWith() => this;

  @override
  BmcTokens lerp(covariant BmcTokens? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return BmcTokens(
      raised: l(raised, other.raised),
      sunken: l(sunken, other.sunken),
      line2: l(line2, other.line2),
      faint: l(faint, other.faint),
      accentText: l(accentText, other.accentText),
      accentSoft: l(accentSoft, other.accentSoft),
      accentLine: l(accentLine, other.accentLine),
      warnSoft: l(warnSoft, other.warnSoft),
      dangerSoft: l(dangerSoft, other.dangerSoft),
      glass: l(glass, other.glass),
      scrim: l(scrim, other.scrim),
      thumb: l(thumb, other.thumb),
      shadow: BoxShadow.lerpList(shadow, other.shadow, t)!,
      glow: l(glow, other.glow),
      ambient: l(ambient, other.ambient),
      ambient2: l(ambient2, other.ambient2),
      sheen: l(sheen, other.sheen),
      neonHot: l(neonHot, other.neonHot),
    );
  }
}
