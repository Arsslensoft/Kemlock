import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import 'master_password.dart';

/// The strength levels; passing every check is the top one.
const strengthIds = [
  'setup.strength.veryWeak',
  'setup.strength.weak',
  'setup.strength.fair',
  'setup.strength.strong',
  'setup.strength.veryStrong',
];

/// Which of the five checks [password] passes (12 characters or more, an
/// upper-case letter, a lower-case one, a digit and a symbol), and how many.
({int score, List<bool> passed}) passwordScore(String password) {
  final passed = [
    masterPasswordLongEnough(password),
    RegExp('[A-Z]').hasMatch(password),
    RegExp('[a-z]').hasMatch(password),
    RegExp(r'\d').hasMatch(password),
    RegExp('[^A-Za-z0-9]').hasMatch(password),
  ];
  return (score: passed.where((ok) => ok).length, passed: passed);
}

/// How strong the meter says [password] is, as an index into [strengthIds],
/// and how many of its five bars are lit. The score runs 0 to 5 over the
/// five levels, so passing every check is "very strong". A password shorter
/// than a master password may be ([masterPasswordLongEnough]) is never
/// called more than "fair", whatever else it has: `Abc1!` passes four checks
/// and falls to a guesser in no time.
({int level, int bars}) passwordStrength(String password) {
  final score = passwordScore(password).score;
  if (!masterPasswordLongEnough(password)) return (level: math.min(score, 2), bars: math.min(score, 2));
  return (level: math.min(score, strengthIds.length - 1), bars: score);
}

/// [password]'s level in [strengthIds], as [passwordStrength] gives it.
int strengthLevel(String password) => passwordStrength(password).level;

/// The colour [password]'s strength is written in: faint when empty, the
/// error colour when very weak or weak, the warning colour when fair, the
/// accent above.
Color strengthColor(BuildContext context, String password) {
  if (password.isEmpty) return context.bmc.faint;
  final level = strengthLevel(password);
  return level <= 1
      ? context.palette.error
      : level == 2
      ? context.palette.warning
      : context.bmc.accentText;
}

/// Five bars that fill with [password]'s score in its colour, each a little
/// after the one before, and its strength in words beside them, read out as
/// it changes.
class PasswordStrengthBar extends StatelessWidget {
  const PasswordStrengthBar({super.key, required this.password});

  final String password;

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    final score = passwordStrength(password).bars;
    final color = strengthColor(context, password);
    final reduced = Motion.reduced(context);
    return Row(
      children: [
        for (var i = 0; i < 5; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: i < score ? color : b.line2),
              // .35s, each bar 40ms after the one before
              duration: reduced ? Duration.zero : Duration(milliseconds: 350 + i * 40),
              curve: Interval(i * 40 / (350 + i * 40), 1, curve: Ease.css),
              builder: (context, color, _) => Container(
                height: 5,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
              ),
            ),
          ),
        ],
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 92),
          child: Semantics(
            liveRegion: true,
            child: AnimatedDefaultTextStyle(
              duration: reduced ? Duration.zero : const Duration(milliseconds: 300),
              style: TextStyle(fontFamily: fontSans, fontSize: 13, fontWeight: FontWeight.w600, color: color),
              child: Text(password.isEmpty ? '' : context.t(strengthIds[strengthLevel(password)]), textAlign: TextAlign.right),
            ),
          ),
        ),
      ],
    );
  }
}
