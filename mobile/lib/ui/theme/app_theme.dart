import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

export 'tokens.dart';

/// Geist, as `FONT_SANS` in `theme.ts`.
const fontSans = 'Geist';

/// Geist Mono, as `FONT_MONO`: codes, counts and anything with tabular figures.
const fontMono = 'GeistMono';

/// The corner radius of buttons, fields, alerts and menus: `shape.borderRadius`.
const appRadius = 14.0;

/// The type scale of `theme.ts`, under MUI's variant names, so
/// `<Typography variant="body2">` becomes `Text(..., style: AppType.body2)`.
/// The styles carry no colour: text takes `text.primary` from the page
/// unless a colour is merged in. Letter spacing in `em` is turned into
/// pixels at each size; the variants `theme.ts` leaves alone keep MUI's.
abstract final class AppType {
  static const h1 = TextStyle(fontFamily: fontSans, fontSize: 36, fontWeight: FontWeight.w600, height: 1, letterSpacing: -1.26);
  static const h2 = TextStyle(fontFamily: fontSans, fontSize: 30, fontWeight: FontWeight.w600, height: 1.1, letterSpacing: -1.05);
  static const h3 = TextStyle(fontFamily: fontSans, fontSize: 21, fontWeight: FontWeight.w600, height: 1.2, letterSpacing: -0.42);
  static const h4 = TextStyle(fontFamily: fontSans, fontSize: 19, fontWeight: FontWeight.w600, height: 1.25, letterSpacing: -0.285);
  static const h5 = TextStyle(fontFamily: fontSans, fontSize: 17, fontWeight: FontWeight.w600, height: 1.3, letterSpacing: -0.17);
  static const h6 = TextStyle(fontFamily: fontSans, fontSize: 15, fontWeight: FontWeight.w600, height: 1.35, letterSpacing: -0.15);
  static const subtitle1 = TextStyle(fontFamily: fontSans, fontSize: 15, fontWeight: FontWeight.w600, height: 1.75, letterSpacing: -0.15);
  static const subtitle2 = TextStyle(fontFamily: fontSans, fontSize: 13, fontWeight: FontWeight.w600, height: 1.57, letterSpacing: 0.09);
  static const body1 = TextStyle(fontFamily: fontSans, fontSize: 15, fontWeight: FontWeight.w400, height: 1.5, letterSpacing: 0.14);
  static const body2 = TextStyle(fontFamily: fontSans, fontSize: 14, fontWeight: FontWeight.w400, height: 1.5, letterSpacing: 0.15);
  static const caption = TextStyle(fontFamily: fontSans, fontSize: 12.5, fontWeight: FontWeight.w400, height: 1.45, letterSpacing: 0.42);

  /// Small spaced capitals; MUI upper-cases them, so callers pass the text
  /// through `toUpperCase()`.
  static const overline = TextStyle(fontFamily: fontSans, fontSize: 12, fontWeight: FontWeight.w600, height: 1.4, letterSpacing: 0.96);
  static const button = TextStyle(fontFamily: fontSans, fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0);

  /// Geist Mono with tabular figures, for codes and counts.
  static TextStyle mono({double? fontSize, FontWeight? fontWeight, Color? color}) => TextStyle(
    fontFamily: fontMono,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

extension AppThemeContext on BuildContext {
  /// The palette: primary, warning, error, text, divider and the rest.
  AppPalette get palette => Theme.of(this).extension<AppPalette>()!;

  /// The extra tokens: raised, line2, faint, accentText, scrim and the rest.
  BmcTokens get bmc => Theme.of(this).extension<BmcTokens>()!;
}

/// MUI's `size="large"` for a button: merge it into a button's style.
const largeButtonStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(64, 56)),
  shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18)))),
  textStyle: WidgetStatePropertyAll(TextStyle(fontFamily: fontSans, fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0)),
);

/// MUI's `size="small"` for a button: merge it into a button's style.
const smallButtonStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(48, 34)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
  shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(11)))),
  textStyle: WidgetStatePropertyAll(TextStyle(fontFamily: fontSans, fontSize: 13.5, fontWeight: FontWeight.w600, letterSpacing: 0)),
);

/// The colours of a contained button in another hue, like MUI's
/// `color="error"`: [background] behind [foreground], darkening to
/// [pressed] under the finger.
ButtonStyle filledButtonColors({required Color background, required Color foreground, Color? pressed}) => ButtonStyle(
  backgroundColor: WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.disabled)) return null;
    if (pressed != null && (states.contains(WidgetState.pressed) || states.contains(WidgetState.hovered))) return pressed;
    return background;
  }),
  foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? null : foreground),
);

/// The Material theme for a scheme, built from the tokens of `theme.ts`.
/// Material's own widgets are set to look like the MUI overrides there:
/// no ripples, radius 14, hairline borders and Geist.
ThemeData buildAppTheme(Brightness brightness) {
  final p = AppPalette.of(brightness);
  final b = BmcTokens.of(brightness);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.primary,
    onPrimary: p.onPrimary,
    primaryContainer: Color.alphaBlend(b.accentSoft, p.paper),
    onPrimaryContainer: b.accentText,
    secondary: p.secondary,
    onSecondary: p.onSecondary,
    tertiary: p.warning,
    onTertiary: p.onWarning,
    error: p.error,
    onError: p.onError,
    errorContainer: Color.alphaBlend(b.dangerSoft, p.paper),
    onErrorContainer: p.error,
    surface: p.paper,
    onSurface: p.text,
    onSurfaceVariant: p.textSecondary,
    surfaceContainerLowest: p.background,
    surfaceContainerLow: p.paper,
    surfaceContainer: p.paper,
    surfaceContainerHigh: b.raised,
    surfaceContainerHighest: b.raised,
    outline: b.line2,
    outlineVariant: p.divider,
    shadow: const Color(0xFF000000),
    scrim: b.scrim,
    inverseSurface: p.text,
    onInverseSurface: p.background,
    inversePrimary: p.isDark ? p.primaryDark : p.primaryLight,
    surfaceTint: Colors.transparent,
  );

  RoundedRectangleBorder rounded(double radius, [BorderSide side = BorderSide.none]) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: side);

  final textTheme = TextTheme(
    displayLarge: AppType.h1,
    displayMedium: AppType.h2,
    displaySmall: AppType.h3,
    headlineLarge: AppType.h2,
    headlineMedium: AppType.h3,
    headlineSmall: AppType.h4,
    titleLarge: AppType.h5,
    titleMedium: AppType.h6,
    titleSmall: AppType.subtitle2,
    bodyLarge: AppType.body1,
    bodyMedium: AppType.body2,
    bodySmall: AppType.caption.copyWith(color: p.textSecondary),
    labelLarge: AppType.button,
    labelMedium: const TextStyle(fontFamily: fontSans, fontSize: 13.5, fontWeight: FontWeight.w600),
    labelSmall: AppType.overline,
  ).apply(bodyColor: p.text, displayColor: p.text);

  // MUI buttons: no ripple, no elevation, radius 14, 44 tall with 18 at the sides.
  ButtonStyle buttonBase(Color foreground) => ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18, vertical: 6)),
    shape: WidgetStatePropertyAll(rounded(appRadius)),
    textStyle: const WidgetStatePropertyAll(AppType.button),
    elevation: const WidgetStatePropertyAll(0),
    splashFactory: NoSplash.splashFactory,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    animationDuration: const Duration(milliseconds: 250),
    foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? p.disabled : foreground),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed) || states.contains(WidgetState.hovered)) return foreground.withValues(alpha: 0.06);
      if (states.contains(WidgetState.focused)) return p.focus;
      return null;
    }),
  );

  // Contained: primary, darkening to primary.dark under the finger.
  final contained = buttonBase(p.onPrimary).copyWith(
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return p.disabledBackground;
      if (states.contains(WidgetState.pressed) || states.contains(WidgetState.hovered)) return p.primaryDark;
      return p.primary;
    }),
    overlayColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.focused) ? p.focus : null),
  );

  // Outlined fields: line2, a 1px Azure line and a 4px soft halo when focused.
  OutlineInputBorder outline(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(15),
    borderSide: BorderSide(color: color),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: fontSans,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    scaffoldBackgroundColor: p.background,
    canvasColor: p.background,
    cardColor: p.paper,
    dividerColor: p.divider,
    disabledColor: p.textDisabled,
    hintColor: p.textSecondary,
    // MUI's ButtonBase has its ripple turned off; rows tint with action.hover instead.
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: p.hover,
    hoverColor: p.hover,
    focusColor: p.focus,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    extensions: [p, b],
    iconTheme: IconThemeData(color: p.text, size: 24),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: AppType.h5.copyWith(color: p.text),
      systemOverlayStyle: p.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    filledButtonTheme: FilledButtonThemeData(style: contained),
    elevatedButtonTheme: ElevatedButtonThemeData(style: contained),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: buttonBase(p.primary).copyWith(
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(color: states.contains(WidgetState.disabled) ? p.disabledBackground : b.line2),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: buttonBase(p.primary)),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? p.disabled : p.active),
        splashFactory: NoSplash.splashFactory,
        animationDuration: const Duration(milliseconds: 250),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed) || states.contains(WidgetState.hovered)) return p.hover;
          if (states.contains(WidgetState.focused)) return p.focus;
          return null;
        }),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.primary,
      foregroundColor: p.onPrimary,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      splashColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: p.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: rounded(appRadius),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.paper,
      surfaceTintColor: Colors.transparent,
      // Material draws elevation, not a CSS shadow; AppDialog draws the real one.
      elevation: 24,
      shadowColor: b.shadow.first.color,
      shape: rounded(28, BorderSide(color: b.line2)),
      barrierColor: b.scrim,
      insetPadding: const EdgeInsets.all(32),
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 444),
      titleTextStyle: AppType.h4.copyWith(color: p.text, letterSpacing: -0.285),
      contentTextStyle: AppType.body1.copyWith(color: p.textSecondary),
      actionsPadding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.paper,
      modalBackgroundColor: p.paper,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: b.scrim,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: true,
      dragHandleColor: b.line2,
      dragHandleSize: const Size(38, 5),
      constraints: const BoxConstraints(maxWidth: 560),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
    ),
    inputDecorationTheme: InputDecorationTheme(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16.5),
      labelStyle: AppType.body1.copyWith(color: p.textSecondary),
      floatingLabelStyle: WidgetStateTextStyle.resolveWith(
        (states) => AppType.body1.copyWith(
          color: states.contains(WidgetState.error)
              ? p.error
              : states.contains(WidgetState.focused)
              ? p.primary
              : p.textSecondary,
        ),
      ),
      hintStyle: AppType.body1.copyWith(color: p.text.withValues(alpha: p.isDark ? 0.5 : 0.42)),
      helperStyle: AppType.caption.copyWith(color: p.textSecondary, fontSize: 12, letterSpacing: 0.4),
      errorStyle: AppType.caption.copyWith(color: p.error, fontSize: 12, letterSpacing: 0.4),
      prefixIconColor: p.textSecondary,
      suffixIconColor: p.textSecondary,
      border: outline(b.line2),
      enabledBorder: outline(b.line2),
      disabledBorder: outline(p.disabledBackground),
      errorBorder: outline(p.error),
      focusedBorder: HaloInputBorder(
        borderSide: BorderSide(color: b.accentLine),
        halo: b.accentSoft,
      ),
      focusedErrorBorder: HaloInputBorder(
        borderSide: BorderSide(color: p.error),
        halo: b.accentSoft,
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(cursorColor: p.primary, selectionColor: b.accentSoft, selectionHandleColor: p.primary),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Color(0xFFFFFFFF)),
      trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? p.primary : b.line2),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      // An empty icon keeps the thumb at 24 in both states, as the web app's switch has it.
      thumbIcon: const WidgetStatePropertyAll(Icon(null)),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? p.primary : Colors.transparent),
      checkColor: WidgetStatePropertyAll(p.onPrimary),
      side: BorderSide(color: p.textSecondary, width: 2),
      splashRadius: 0,
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? p.primary : p.textSecondary),
      splashRadius: 0,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.selected,
      selectedColor: b.accentSoft,
      labelStyle: TextStyle(fontFamily: fontSans, fontSize: 13, fontWeight: FontWeight.w500, color: p.text),
      side: BorderSide(color: b.line2),
      shape: const StadiumBorder(),
      checkmarkColor: b.accentText,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: b.raised,
        border: Border.all(color: b.line2),
        borderRadius: BorderRadius.circular(10),
      ),
      textStyle: TextStyle(fontFamily: fontSans, fontSize: 12.5, color: p.text),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.primary,
      linearTrackColor: b.raised,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 6,
      borderRadius: BorderRadius.circular(3),
      trackGap: 0,
      stopIndicatorColor: Colors.transparent,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.primary,
      unselectedLabelColor: p.textSecondary,
      labelStyle: AppType.button,
      unselectedLabelStyle: AppType.button,
      dividerColor: Colors.transparent,
      indicatorSize: TabBarIndicatorSize.tab,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: p.primary, width: 3),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
      ),
      splashFactory: NoSplash.splashFactory,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    toggleButtonsTheme: ToggleButtonsThemeData(
      borderRadius: BorderRadius.circular(appRadius),
      borderColor: b.line2,
      selectedBorderColor: b.line2,
      color: p.textSecondary,
      selectedColor: b.accentText,
      fillColor: b.accentSoft,
      textStyle: const TextStyle(fontFamily: fontSans, fontWeight: FontWeight.w600),
      splashColor: Colors.transparent,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStatePropertyAll(BorderSide(color: b.line2)),
        backgroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? b.accentSoft : null),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? b.accentText : p.textSecondary,
        ),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: fontSans, fontWeight: FontWeight.w600)),
        shape: WidgetStatePropertyAll(rounded(appRadius)),
        splashFactory: NoSplash.splashFactory,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: b.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: b.shadow.first.color,
      shape: rounded(appRadius, BorderSide(color: b.line2)),
      textStyle: AppType.body1.copyWith(color: p.text),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(b.raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(12),
        shadowColor: WidgetStatePropertyAll(b.shadow.first.color),
        shape: WidgetStatePropertyAll(rounded(appRadius, BorderSide(color: b.line2))),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: rounded(appRadius),
      iconColor: p.textSecondary,
      textColor: p.text,
      titleTextStyle: AppType.body1.copyWith(color: p.text),
      subtitleTextStyle: AppType.body2.copyWith(color: p.textSecondary),
    ),
    drawerTheme: DrawerThemeData(backgroundColor: p.paper, surfaceTintColor: Colors.transparent),
    dividerTheme: DividerThemeData(color: p.divider, thickness: 1, space: 1),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: b.raised,
      contentTextStyle: TextStyle(fontFamily: fontSans, fontSize: 14, fontWeight: FontWeight.w500, color: p.text),
      actionTextColor: b.accentText,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 98),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(23),
        side: BorderSide(color: b.line2),
      ),
    ),
    sliderTheme: SliderThemeData(activeTrackColor: p.primary, inactiveTrackColor: b.line2, thumbColor: p.primary),
  );
}

/// An outlined field's border with a soft ring around it, as the web app
/// draws a focused field: a 1px line inside a 4px [halo]
/// (`box-shadow: 0 0 0 4px accentSoft`). The ring fades in with the line.
class HaloInputBorder extends OutlineInputBorder {
  const HaloInputBorder({
    super.borderSide,
    super.borderRadius = const BorderRadius.all(Radius.circular(15)),
    required this.halo,
    this.haloWidth = 4,
  });

  final Color halo;
  final double haloWidth;

  @override
  HaloInputBorder copyWith({BorderSide? borderSide, BorderRadius? borderRadius, double? gapPadding}) => HaloInputBorder(
    borderSide: borderSide ?? this.borderSide,
    borderRadius: borderRadius ?? this.borderRadius,
    halo: halo,
    haloWidth: haloWidth,
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is OutlineInputBorder) {
      final from = a is HaloInputBorder ? a.halo : halo.withValues(alpha: 0);
      return HaloInputBorder(
        borderSide: BorderSide.lerp(a.borderSide, borderSide, t),
        borderRadius: BorderRadius.lerp(a.borderRadius, borderRadius, t)!,
        halo: Color.lerp(from, halo, t)!,
        haloWidth: haloWidth,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    if (halo.a > 0) {
      canvas.drawRRect(
        borderRadius.toRRect(rect).inflate(haloWidth / 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = haloWidth
          ..color = halo,
      );
    }
    super.paint(canvas, rect, gapStart: gapStart, gapExtent: gapExtent, gapPercentage: gapPercentage, textDirection: textDirection);
  }

  @override
  bool operator ==(Object other) => other is HaloInputBorder && super == other && other.halo == halo && other.haloWidth == haloWidth;

  @override
  int get hashCode => Object.hash(super.hashCode, halo, haloWidth);
}
