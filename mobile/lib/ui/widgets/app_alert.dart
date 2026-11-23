import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/effects.dart';

/// How serious an [AppAlert] is.
enum AlertSeverity { error, warning, info, success }

/// A soft-tinted message box, MUI's standard `<Alert>` as `theme.ts` paints
/// it: red on dangerSoft for errors, the warning colour on warnSoft, and
/// Azure on accentSoft for info and success, with radius 14. [icon]
/// replaces the severity's own. With [onClose] a close button sits at the
/// right, named [closeLabel] for screen readers. With [glow] an information
/// alert has a 1px accent line inside its edge and a [Glow] that swells
/// round it every 3.4 seconds; the other severities never glow.
class AppAlert extends StatelessWidget {
  const AppAlert({super.key, required this.severity, required this.child, this.icon, this.onClose, this.closeLabel, this.glow = false})
    : assert(onClose == null || closeLabel != null, 'A close button needs a closeLabel');

  final AlertSeverity severity;

  /// The message; usually a [Text], set in body2.
  final Widget child;
  final Widget? icon;
  final VoidCallback? onClose;
  final String? closeLabel;

  /// Whether an information alert glows. Only decoration: the alert says
  /// what it says without it.
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final (background, foreground, iconColor) = switch (severity) {
      AlertSeverity.error => (b.dangerSoft, p.error, p.error),
      AlertSeverity.warning => (b.warnSoft, p.warning, p.warning),
      AlertSeverity.info => (b.accentSoft, b.accentText, p.info),
      AlertSeverity.success => (b.accentSoft, b.accentText, p.success),
    };
    final defaultIcon = switch (severity) {
      AlertSeverity.error => Icons.error_outline,
      AlertSeverity.warning => Icons.report_problem_outlined,
      AlertSeverity.info => Icons.info_outline,
      AlertSeverity.success => Icons.check_circle_outline,
    };
    final glows = glow && severity == AlertSeverity.info;
    final radius = BorderRadius.circular(appRadius);
    final alert = Semantics(
      container: true,
      liveRegion: severity == AlertSeverity.error,
      child: Container(
        padding: EdgeInsets.fromLTRB(16, 6, onClose == null ? 16 : 8, 6),
        decoration: BoxDecoration(color: background, borderRadius: radius),
        // Painted over the box, so the line takes no room from the message.
        foregroundDecoration: glows
            ? BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: b.accentLine),
              )
            : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 7, 12, 7),
                child: IconTheme.merge(
                  data: IconThemeData(size: 22, color: iconColor.withValues(alpha: iconColor.a * 0.9)),
                  child: icon ?? Icon(defaultIcon),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: DefaultTextStyle.merge(
                  style: AppType.body2.copyWith(color: foreground),
                  child: child,
                ),
              ),
            ),
            if (onClose != null)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 4),
                child: IconButton(
                  onPressed: onClose,
                  padding: const EdgeInsets.all(5),
                  constraints: const BoxConstraints.tightFor(width: 30, height: 30),
                  style: IconButton.styleFrom(foregroundColor: foreground, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  icon: Icon(Icons.close_rounded, size: 20, semanticLabel: closeLabel),
                ),
              ),
          ],
        ),
      ),
    );
    return glows ? Glow(borderRadius: radius, period: const Duration(milliseconds: 3400), child: alert) : alert;
  }
}
