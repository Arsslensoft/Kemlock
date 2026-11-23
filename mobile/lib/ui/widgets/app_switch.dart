import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/effects.dart';

/// The app's switch: Material's, as the theme paints it, with a soft accent
/// glow round its track while it is on. The glow stands still and is the
/// same under reduced motion; the thumb and the track's colour say whether
/// the switch is on, with or without it.
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged});

  final bool value;

  /// Called with the new value; null turns the switch off for touches.
  final ValueChanged<bool>? onChanged;

  /// The size and corners of Material's track.
  static const _track = Size(52, 32);

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      IgnorePointer(
        child: SizedBox.fromSize(
          size: _track,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_track.height / 2),
              boxShadow: value && onChanged != null ? StandingGlow.toggle(context.bmc) : null,
            ),
          ),
        ),
      ),
      Switch(value: value, onChanged: onChanged),
    ],
  );
}
