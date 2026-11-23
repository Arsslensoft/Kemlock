import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'scrim.dart';

/// The widest a dialog gets (MUI's `maxWidth="xs"`).
const dialogMaxWidth = 444.0;

/// Opens [builder]'s dialog over the blurred scrim, fading in over .225s
/// and out over .195s as MUI's dialogs do. Tapping the scrim dismisses it
/// unless [barrierDismissible] is false. Resolves to what the dialog pops
/// with. Build the dialog itself with [AppDialog].
Future<T?> showAppDialog<T>(BuildContext context, {required WidgetBuilder builder, bool barrierDismissible = true}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push(
    _AppDialogRoute<T>(
      context: context,
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor: context.bmc.scrim,
      barrierDismissible: barrierDismissible,
    ),
  );
}

class _AppDialogRoute<T> extends DialogRoute<T> {
  _AppDialogRoute({required super.context, required super.builder, super.themes, super.barrierColor, super.barrierDismissible})
    : super(
        animationStyle: AnimationStyle(duration: Motion.dialogIn, curve: Ease.inOut, reverseCurve: Ease.inOut.flipped),
      );

  @override
  Duration get reverseTransitionDuration => Motion.dialogOut;

  @override
  Widget buildModalBarrier() => BlurredBarrier(animation: animation!, barrier: super.buildModalBarrier());
}

/// The app's dialog: paper with 28px corners, a line2 edge and the floating
/// shadow, as wide as the screen allows up to 444px with 32px around it.
/// [heading] sits at the top (a [DialogHeading]), [content] below it
/// scrolls when the dialog runs out of room, and [actions] line up at the
/// bottom right. [semanticLabel] names the dialog for screen readers,
/// usually its title.
class AppDialog extends StatelessWidget {
  const AppDialog({super.key, this.heading, required this.content, this.actions = const [], this.semanticLabel, this.contentPadding});

  final Widget? heading;
  final Widget content;
  final List<Widget> actions;
  final String? semanticLabel;

  /// Around [content]; by default 24 at the sides, 16 below, and 8 above
  /// unless it follows a heading (MUI's DialogContent).
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    const radius = BorderRadius.all(Radius.circular(28));
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(32),
      shape: const RoundedRectangleBorder(borderRadius: radius),
      clipBehavior: Clip.none,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        scopesRoute: true,
        namesRoute: true,
        label: semanticLabel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: dialogMaxWidth),
          child: SizedBox(
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(color: p.paper, borderRadius: radius, boxShadow: b.shadow),
              position: DecorationPosition.background,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: b.line2),
                ),
                position: DecorationPosition.foreground,
                child: ClipRRect(
                  borderRadius: radius,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ?heading,
                      Flexible(
                        child: SingleChildScrollView(
                          padding: contentPadding ?? EdgeInsets.fromLTRB(24, heading == null ? 8 : 0, 24, 16),
                          child: DefaultTextStyle.merge(
                            style: AppType.body1.copyWith(color: p.text),
                            child: content,
                          ),
                        ),
                      ),
                      if (actions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                          // The web app's 6px gap, on top of MUI's 8px between actions.
                          child: Wrap(alignment: WrapAlignment.end, spacing: 14, runSpacing: 8, children: actions),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
