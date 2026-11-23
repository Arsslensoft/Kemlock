import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';

/// How far the page behind a dialog or sheet is blurred, as the web app's
/// backdrop does it (`backdrop-filter: blur(3px)`).
const scrimBlurSigma = 3.0;

/// Blurs the page behind a modal [barrier] as the route [animation] runs,
/// so the blur comes and goes with the scrim's colour.
class BlurredBarrier extends StatelessWidget {
  const BlurredBarrier({super.key, required this.animation, required this.barrier});

  final Animation<double> animation;
  final Widget barrier;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: barrier,
    builder: (context, child) {
      final sigma = scrimBlurSigma * animation.value.clamp(0.0, 1.0);
      return BackdropFilter(
        enabled: sigma > 0.01,
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: child,
      );
    },
  );
}
