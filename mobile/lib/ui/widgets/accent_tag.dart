import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The small Azure tag beside a title or a value, such as the "v6" of a key. [label]
/// is the word on it; it is shown in capitals.
class AccentTag extends StatelessWidget {
  const AccentTag({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular(6)),
      // As wide as the word, wherever it is put.
      child: Center(
        widthFactor: 1,
        child: Text(
          label.toUpperCase(),
          maxLines: 1,
          style: TextStyle(
            fontFamily: fontSans,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.42,
            height: 1,
            color: b.accentText,
          ),
        ),
      ),
    );
  }
}
