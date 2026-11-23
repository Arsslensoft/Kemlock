import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/effects.dart';
import '../theme/motion.dart';
import 'scrim.dart';

/// The widest a sheet gets; on a tablet it sits centred.
const sheetMaxWidth = 560.0;

/// The radius of a sheet's top corners.
const sheetRadius = 32.0;

/// Opens [builder]'s content in the app's bottom sheet: paper with a grab
/// handle, 32px top corners and a hairline along its top edge, over the
/// blurred scrim. Drag it down or tap outside to dismiss. It slides up over
/// .56s on [Ease.sheet] and away in .28s. [label] names the sheet for
/// screen readers. Resolves to what the sheet pops with.
///
/// It opens on the root navigator, as dialogs do, so a sheet opened from a
/// tab's page covers the floating tab bar too.
///
/// The content is as tall as it needs, up to 40px short of the screen (or
/// the status bar); make it scroll when it can be longer. The home bar's
/// inset and the keyboard are padded below it.
Future<T?> showAppBottomSheet<T>(
  BuildContext context, {
  required String label,
  required WidgetBuilder builder,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final localizations = MaterialLocalizations.of(context);
  return navigator.push(
    _AppSheetRoute<T>(
      builder: (context) => AppBottomSheet(
        label: label,
        child: Builder(builder: builder),
      ),
      capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierLabel: localizations.scrimLabel,
      barrierOnTapHint: localizations.scrimOnTapHint(label),
      modalBarrierColor: context.bmc.scrim,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
    ),
  );
}

class _AppSheetRoute<T> extends ModalBottomSheetRoute<T> {
  _AppSheetRoute({
    required super.builder,
    super.capturedThemes,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.modalBarrierColor,
    super.isDismissible,
    super.enableDrag,
  }) : super(
         isScrollControlled: true,
         backgroundColor: Colors.transparent,
         elevation: 0,
         clipBehavior: Clip.none,
         showDragHandle: false,
         constraints: const BoxConstraints(maxWidth: sheetMaxWidth),
         sheetAnimationStyle: AnimationStyle(
           duration: Motion.sheetIn,
           reverseDuration: Motion.sheetOut,
           curve: Ease.sheet,
           // A reverse curve runs on the way back from 1 to 0, so the exit's
           // ease-in is flipped to start slow and speed away.
           reverseCurve: Ease.exit.flipped,
         ),
       );

  @override
  Widget buildModalBarrier() => BlurredBarrier(animation: animation!, barrier: super.buildModalBarrier());
}

/// The sheet itself: paper, the top corners, the hairline, the shadow cast
/// upwards and the grab handle above [child]. [showAppBottomSheet] puts it
/// in a route; on its own it is for previews and tests.
class AppBottomSheet extends StatelessWidget {
  const AppBottomSheet({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final p = context.palette;
    final b = context.bmc;
    // `max-height: calc(100dvh - 40px)`, kept clear of the status bar too.
    final maxHeight = media.size.height - math.max(40, media.viewPadding.top);
    const radius = BorderRadius.vertical(top: Radius.circular(sheetRadius));
    return Semantics(
      container: true,
      explicitChildNodes: true,
      scopesRoute: true,
      namesRoute: true,
      label: label,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: p.paper,
            borderRadius: radius,
            // 0 -20px 60px rgba(0,0,0,.35)
            boxShadow: const [BoxShadow(color: Color.fromRGBO(0, 0, 0, 0.35), offset: Offset(0, -20), blurRadius: 60)],
          ),
          child: CustomPaint(
            foregroundPainter: _TopEdgePainter(color: b.line2, radius: sheetRadius),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.passthrough,
                children: [
                  // Inside the clip, so the light stays within the sheet's rounded top, and under the content.
                  const Positioned.fill(child: AmbientLight()),
                  Material(
                    type: MaterialType.transparency,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: media.padding.bottom + media.viewInsets.bottom),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SheetHandle(),
                          Flexible(child: child),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The grab handle at the top of a sheet: a 38 by 5 pill in line2.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Center(
      child: Container(
        width: 38,
        height: 5,
        margin: const EdgeInsets.only(top: 10),
        decoration: BoxDecoration(color: context.bmc.line2, borderRadius: BorderRadius.circular(3)),
      ),
    ),
  );
}

/// The 1px line along a sheet's top edge and round its top corners
/// (`border-top` on a box with rounded corners).
class _TopEdgePainter extends CustomPainter {
  const _TopEdgePainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(radius, size.width / 2);
    final path = Path()
      ..moveTo(0.5, r)
      ..arcToPoint(Offset(r, 0.5), radius: Radius.circular(r - 0.5))
      ..lineTo(size.width - r, 0.5)
      ..arcToPoint(Offset(size.width - 0.5, r), radius: Radius.circular(r - 0.5));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_TopEdgePainter old) => old.color != color || old.radius != radius;
}
