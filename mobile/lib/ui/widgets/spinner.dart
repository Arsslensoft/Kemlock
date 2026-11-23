import 'package:flutter/material.dart';

import '../theme/motion.dart';

/// A small spinner for work of unknown length. Under reduced motion it
/// holds still, as [Motion.reduced] asks of every loop.
class Spinner extends StatelessWidget {
  const Spinner({super.key, this.size = 18, this.strokeWidth = 2, this.color});

  final double size;
  final double strokeWidth;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Motion.reduced(context)
        ? ExcludeSemantics(
            child: CircularProgressIndicator(value: 0.3, strokeWidth: strokeWidth, color: color),
          )
        : CircularProgressIndicator(strokeWidth: strokeWidth, color: color),
  );
}
