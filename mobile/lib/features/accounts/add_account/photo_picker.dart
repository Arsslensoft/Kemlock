import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../i18n/messages.dart';
import '../../../platform/files.dart';
import '../../../platform/scanner_source.dart';
import '../../../ui/ui.dart';

/// The Photo tab: a dashed drop zone that picks a picture from the phone's
/// photos and reads the QR code in it, then a tip for moving from another
/// phone. `PhotoPicker` in `AddAccountDialog.tsx`.
class PhotoPicker extends ConsumerStatefulWidget {
  const PhotoPicker({super.key, required this.onDecoded, required this.onFailed, this.error});

  /// The text of the QR code in the picture.
  final ValueChanged<String> onDecoded;

  /// The picture held no QR code that could be read.
  final VoidCallback onFailed;
  final String? error;

  @override
  ConsumerState<PhotoPicker> createState() => _PhotoPickerState();
}

class _PhotoPickerState extends ConsumerState<PhotoPicker> {
  bool _busy = false;
  bool _pressed = false;

  Future<void> _pick() async {
    if (_busy) return;
    final reader = ref.read(qrImageReaderProvider);
    final files = ref.read(fileServiceProvider);
    // The reader takes a path, so the picker's copy stays until the code is read
    final picked = await files.pickImage(keepFile: true);
    if (picked == null) return;
    final String? data;
    try {
      if (!mounted) return;
      setState(() => _busy = true);
      final path = picked.path;
      data = path == null ? null : await reader.decode(path);
    } finally {
      // A picture of a QR code holds the account's secret: no copy of it stays in the cache
      await files.forget(picked);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (data != null && data.isNotEmpty) {
      widget.onDecoded(data);
    } else {
      widget.onFailed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          enabled: !_busy,
          label: context.t('qrScanner.chooseImage'),
          hint: context.t('qrScanner.uploadHint'),
          onTap: _busy ? null : () => unawaited(_pick()),
          excludeSemantics: true,
          child: PressScale(
            enabled: !_busy,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _busy ? null : () => unawaited(_pick()),
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              child: AnimatedOpacity(
                opacity: _busy ? .6 : 1,
                duration: Motion.colour,
                child: TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: _pressed ? b.accentLine : b.line2),
                  duration: Motion.reduced(context) ? Duration.zero : Motion.colour,
                  builder: (context, color, child) => CustomPaint(
                    foregroundPainter: _DashedBorderPainter(color: color ?? b.line2, radius: 30),
                    child: child,
                  ),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 300),
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(color: b.raised, borderRadius: BorderRadius.circular(30)),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ExcludeSemantics(
                          child: Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular(20)),
                            child: Icon(Icons.image_rounded, size: 28, color: b.accentText),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          context.t('qrScanner.chooseImage'),
                          textAlign: TextAlign.center,
                          style: AppType.h5.copyWith(color: p.text),
                        ),
                        const SizedBox(height: 12),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 260),
                          child: Text(
                            context.t('qrScanner.uploadHint'),
                            textAlign: TextAlign.center,
                            style: AppType.body2.copyWith(color: p.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: AppAlert(severity: AlertSeverity.error, child: Text(widget.error!)),
          ),
        Container(
          margin: const EdgeInsets.only(top: 14),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: p.divider),
          ),
          child: Row(
            children: [
              ExcludeSemantics(child: Icon(Icons.swap_horiz_rounded, color: b.accentText)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(context.t('addAccount.photo.transferTip'), style: AppType.body2.copyWith(color: p.textSecondary)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A 1.5px dashed outline round a rounded rectangle, as CSS's `dashed` border.
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    const width = 1.5;
    const dash = 6.0;
    const gap = 5.0;
    final rect = (Offset.zero & size).deflate(width / 2);
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(math.max(0, radius - width / 2))));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        canvas.drawPath(metric.extractPath(d, math.min(d + dash, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color || old.radius != radius;
}
