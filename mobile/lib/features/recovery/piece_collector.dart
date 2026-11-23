import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../scan/qr_viewfinder.dart';
import 'recovery_shares.dart';

/// Collects a Recovery Kit's pieces one at a time, scanned from their QR
/// codes or typed (or pasted) in, `PieceCollector.tsx`.
///
/// It says how many pieces are in out of how many the kit needs, shows
/// each one as a chip, and says what is wrong with a piece it refuses: not
/// a piece, a typo, another kit's or one already in. Once enough pieces of
/// one kit are in, [onKey] gets the kit's id and the key they rebuild.
/// A caller that tries the key and fails gives the collector a new key to
/// start it over.
class PieceCollector extends StatefulWidget {
  const PieceCollector({super.key, required this.onKey, this.busy = false});

  /// Called once enough pieces of one kit are in.
  final void Function(String kitId, Uint8List key) onKey;

  /// Turns the inputs off while the caller tries the key.
  final bool busy;

  @override
  State<PieceCollector> createState() => _PieceCollectorState();
}

class _PieceCollectorState extends State<PieceCollector> {
  final _text = TextEditingController();
  var _pieces = const <KitPiece>[];

  /// The message id of what is wrong with the last piece, or null.
  String? _error;

  /// The camera is looking for a piece's QR code.
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    // Add piece turns on and off with the field's text.
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _take(String input) {
    final List<KitPiece> next;
    try {
      next = addPiece(_pieces, parsePiece(input));
    } catch (error) {
      final problem = error is PieceError ? error.problem : PieceProblem.format;
      setState(() => _error = 'recovery.piece.error.${problem.name}');
      return;
    }
    final done = next.length >= next.first.threshold;
    setState(() {
      _error = null;
      _pieces = next;
      _text.clear();
      if (done) _scanning = false;
    });
    if (done) widget.onKey(next.first.kitId, rebuildKey(next));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final needed = _pieces.isEmpty ? null : _pieces.first.threshold;
    final canAdd = !widget.busy && _text.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            needed == null
                ? context.t('recovery.collect.start')
                : context.t('recovery.collect.progress', {'count': _pieces.length, 'needed': needed}),
            style: AppType.body2.copyWith(color: p.textSecondary),
          ),
        ),
        if (_pieces.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final piece in _pieces)
                PopIn(
                  key: ValueKey(piece.index),
                  child: PieceChip(label: context.t('recovery.collect.piece', {'index': piece.index, 'shares': piece.shares})),
                ),
            ],
          ),
        ],
        if (_error != null) ...[const SizedBox(height: 12), AppAlert(severity: AlertSeverity.error, child: Text(context.t(_error!)))],
        const SizedBox(height: 12),
        if (_scanning) ...[
          // A new viewfinder for each piece, so the next one can be the same paper held up again.
          // Short enough to leave Stop scanning in sight on a phone.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: QrViewfinder(key: ValueKey(_pieces.length), onScan: _take),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() => _scanning = false),
            style: TextButton.styleFrom(foregroundColor: p.text),
            child: Text(context.t('recovery.collect.stopScan')),
          ),
        ] else ...[
          TextField(
            controller: _text,
            enabled: !widget.busy,
            minLines: 2,
            maxLines: 5,
            keyboardType: TextInputType.multiline,
            autocorrect: false,
            enableSuggestions: false,
            spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
            style: AppType.mono(fontSize: 13, color: p.text),
            decoration: InputDecoration(labelText: context.t('recovery.collect.field'), hintText: 'BMCKIT1-…'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: canAdd ? () => _take(_text.text) : null,
                  icon: const Icon(Icons.add_rounded),
                  label: Text(context.t('recovery.collect.add')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: widget.busy ? null : () => setState(() => _scanning = true),
                  style: FilledButton.styleFrom(backgroundColor: b.accentSoft, foregroundColor: b.accentText),
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: Text(context.t('recovery.collect.scan')),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A collected piece, "Piece 2 of 3": an outlined Azure chip, MUI's
/// `<Chip color="primary" variant="outlined">`.
class PieceChip extends StatelessWidget {
  const PieceChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: b.accentLine),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          label,
          maxLines: 1,
          style: TextStyle(fontFamily: fontSans, fontSize: 13, fontWeight: FontWeight.w500, color: b.accentText),
        ),
      ),
    );
  }
}
