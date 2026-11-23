import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/effects.dart';
import '../theme/loop.dart';
import '../theme/motion.dart';

/// A bar that shows how much of [total] is used: a 6-high rounded track in
/// `raised`, and over it a filled part in the accent with a soft glow, as
/// wide as [value] is of [total]. When it is first shown the filled part
/// grows from empty over .9 seconds, after .5; under reduced motion it
/// shows its value at once. It fills from the start edge, so from the
/// right where text runs right to left.
///
/// [semanticsLabel] says the value in words, such as "7 of 100 passkeys
/// used", and is all a screen reader is given: the bar itself is a picture.
/// A [value] below 0 or above [total] is drawn as 0 or as a full bar, and a
/// [total] of 0 as an empty one.
class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.value, required this.total, required this.semanticsLabel});

  final num value;
  final num total;
  final String semanticsLabel;

  static const height = 6.0;

  /// The part of the bar that is filled, from 0 to 1.
  static double fractionOf(num value, num total) => total <= 0 ? 0 : (value / total).clamp(0.0, 1.0).toDouble();

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    final fraction = fractionOf(value, total);
    const radius = BorderRadius.all(Radius.circular(height / 2));
    return Semantics(
      container: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          width: double.infinity,
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(color: b.raised, borderRadius: radius),
            child: EffectOnce(
              duration: const Duration(milliseconds: 900),
              delay: const Duration(milliseconds: 500),
              builder: (context, progress) => Align(
                alignment: AlignmentDirectional.centerStart,
                child: FractionallySizedBox(
                  widthFactor: fraction * Ease.roll.transform(progress).clamp(0.0, 1.0),
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.palette.primary,
                      borderRadius: radius,
                      boxShadow: fraction > 0 ? StandingGlow.bar(b) : null,
                    ),
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
