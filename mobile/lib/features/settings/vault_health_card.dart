import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';

/// One line of the [VaultHealthCard]: what is checked, how it stands, and
/// what to do while it isn't right.
@immutable
class HealthItem {
  const HealthItem({required this.id, required this.title, required this.detail, required this.ok, this.action, this.actionWhenOk = false});

  /// Tells the lines apart, such as `recovery` or `backup`.
  final String id;
  final String title;
  final String detail;
  final bool ok;

  /// A button shown while the item is not [ok], such as "Set up", and with [actionWhenOk] while it is too.
  final ({String label, VoidCallback onPressed})? action;

  /// Whether [action] is shown while the item is [ok] as well.
  final bool actionWhenOk;
}

/// The status line for each fifth of the score, from none to all.
const _titles = [
  'settings.health.atRisk',
  'settings.health.atRisk',
  'settings.health.attention',
  'settings.health.good',
  'settings.health.excellent',
];

/// The score ring and the checklist at the top of Settings,
/// `VaultHealthCard.tsx`: each item reflects the vault as it is. The ring
/// and the status turn amber while more than one item is missing.
class VaultHealthCard extends StatelessWidget {
  const VaultHealthCard({super.key, required this.items});

  final List<HealthItem> items;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final score = items.where((item) => item.ok).length;
    final total = items.length;
    final strong = score >= total - 1;
    final status = context.t(_titles[total == 0 ? 4 : (score / total * 4).round()]);
    final colourChange = Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 400);

    return Rise(
      duration: const Duration(milliseconds: 550),
      delay: const Duration(milliseconds: 50),
      child: Container(
        margin: const EdgeInsets.only(top: 22),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: p.paper,
          border: Border.all(color: p.divider),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _ScoreRing(score: score, total: total, color: strong ? b.accentText : p.warning),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(context.t('settings.health.label').toUpperCase(), style: AppType.overline.copyWith(color: b.faint)),
                        ),
                        const SizedBox(height: 2),
                        Semantics(
                          liveRegion: true,
                          child: AnimatedDefaultTextStyle(
                            duration: colourChange,
                            style: AppType.body1.copyWith(
                              fontSize: 19,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.285,
                              height: 1.4,
                              color: strong ? p.text : p.warning,
                            ),
                            child: Text(status),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              for (final item in items) _HealthLine(key: ValueKey(item.id), item: item),
            ],
          ),
        ),
      ),
    );
  }
}

/// The ring that fills with the score, and the score in its middle. The
/// ring draws itself in when it first shows and moves when the score does.
class _ScoreRing extends StatelessWidget {
  const _ScoreRing({required this.score, required this.total, required this.color});

  final int score;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    final track = context.bmc.raised;
    return SizedBox.square(
      dimension: 64,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: ExcludeSemantics(
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: color),
                duration: reduced ? Duration.zero : const Duration(milliseconds: 400),
                builder: (context, color, _) => TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: total == 0 ? 0 : score / total),
                  duration: reduced ? Duration.zero : const Duration(milliseconds: 1200),
                  curve: Ease.out,
                  builder: (context, fraction, _) => CustomPaint(
                    painter: _RingPainter(fraction: fraction, track: track, color: color ?? track),
                  ),
                ),
              ),
            ),
          ),
          Text(
            '$score/$total',
            style: AppType.mono(fontSize: 17, fontWeight: FontWeight.w600, color: context.palette.text),
          ),
        ],
      ),
    );
  }
}

/// A 6px ring of radius 26 in a 64 box: the track all round, and the
/// score's share of it from the top, clockwise, with round ends.
class _RingPainter extends CustomPainter {
  const _RingPainter({required this.fraction, required this.track, required this.color});

  final double fraction;
  final Color track;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 64;
    final center = size.center(Offset.zero);
    final radius = 26 * scale;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6 * scale
      ..color = track;
    canvas.drawCircle(center, radius, paint);
    if (fraction <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction.clamp(0, 1),
      false,
      paint
        ..color = color
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.track != track || old.color != color;
}

/// One item of the checklist: a check or a warning mark, which pops in
/// when it changes, the title over its detail, and its action while it
/// isn't right.
class _HealthLine extends StatelessWidget {
  const _HealthLine({super.key, required this.item});

  final HealthItem item;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final ok = item.ok;
    final action = item.action;
    return Container(
      constraints: const BoxConstraints(minHeight: 50),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.divider)),
      ),
      child: Semantics(
        container: true,
        child: Row(
          children: [
            ExcludeSemantics(
              child: PopIn(
                key: ValueKey(ok),
                child: Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: ok ? p.primary : b.warnSoft, shape: BoxShape.circle),
                  child: Icon(ok ? Icons.check_rounded : Icons.priority_high_rounded, size: 14, color: ok ? p.onPrimary : p.warning),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: AppType.body2.copyWith(fontWeight: FontWeight.w500, color: p.text),
                    ),
                    Text(item.detail, style: AppType.caption.copyWith(color: ok ? p.textSecondary : p.warning)),
                  ],
                ),
              ),
            ),
            if ((!ok || item.actionWhenOk) && action != null) ...[
              const SizedBox(width: 12),
              PressScale(
                child: FilledButton(
                  style: smallButtonStyle.copyWith(
                    shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16)))),
                  ),
                  onPressed: action.onPressed,
                  child: Text(action.label),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
