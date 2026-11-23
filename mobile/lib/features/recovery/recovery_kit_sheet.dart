import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/providers.dart';
import '../../core/time.dart';
import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../platform/printer.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_store.dart';
import '../settings/auto_lock.dart';
import 'kit_printout.dart';
import 'recovery_shares.dart';
import 'recovery_sheet_layout.dart';

/// Makes, shows, prints and replaces the open vault's Recovery Kit,
/// `RecoveryKitDialog.tsx`.
Future<void> showRecoveryKitSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('recovery.kit.title'), builder: (_) => const RecoveryKitSheet());

/// Makes the new kit a replacement of the vault's key pair needs, of
/// [threshold] and [shares] as the old one was (openspec:
/// replace-vault-key-pair, decision 4): shows and prints its pieces as the
/// sheet does, and resolves to its key once the person says they saved every
/// piece, or to null. Nothing is saved, the replacement does that at its
/// commit.
Future<RecoveryKey?> showReplacementKitSheet(BuildContext context, {required int threshold, required int shares}) =>
    showAppBottomSheet<RecoveryKey>(
      context,
      label: context.t('recovery.kit.title'),
      builder: (_) => RecoveryKitSheet(replacement: (threshold: threshold, shares: shares)),
    );

enum _Step { status, choose, pieces }

enum _Who { me, people }

/// The sheet's three steps. With a kit, it first says when the kit was made
/// and how it was split, and offers to remove or replace it. Making one
/// asks who keeps it: one piece for the user, or pieces split between
/// people they trust ("any 2 of 3"). A new kit's pieces
/// are then shown one at a time, as a QR code and as text, and printed one
/// page per piece. The pieces exist only on screen and on paper: once the
/// sheet closes nothing keeps them.
class RecoveryKitSheet extends ConsumerStatefulWidget {
  const RecoveryKitSheet({super.key, this.replacement});

  /// The shape of the kit a key replacement makes, which the sheet makes at
  /// once and hands back, unsaved, rather than keeping ([showReplacementKitSheet]).
  final ({int threshold, int shares})? replacement;

  @override
  ConsumerState<RecoveryKitSheet> createState() => _RecoveryKitSheetState();
}

class _RecoveryKitSheetState extends ConsumerState<RecoveryKitSheet> {
  late RecoveryKitInfo? _info = ref.read(vaultStoreProvider).recoveryKitInfo();
  late _Step _step = _info == null ? _Step.choose : _Step.status;
  _Who _who = _Who.me;
  int _shares = 3;
  int _threshold = 2;
  List<String> _pieces = const [];
  int _shown = 0;
  bool _withCodes = false;
  bool _busy = false;
  bool _printing = false;

  /// The message id of what went wrong, or null.
  String? _error;

  /// A key replacement's new kit, until the person has saved its pieces.
  RecoveryKey? _replacementKit;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final shape = widget.replacement;
    if (shape == null) return;
    final made = makeKit(shape.threshold, shape.shares);
    final createdAt = isoString(ref.read(clockProvider)());
    _replacementKit = RecoveryKey(kitId: made.kitId, key: made.key, threshold: shape.threshold, shares: shape.shares, createdAt: createdAt);
    _info = RecoveryKitInfo(kitId: made.kitId, threshold: shape.threshold, shares: shape.shares, createdAt: createdAt);
    _pieces = made.pieces;
    _step = _Step.pieces;
  }

  void _close() {
    if (!_busy) Navigator.of(context).pop();
  }

  void _setShares(int shares) => setState(() {
    _shares = shares;
    _threshold = math.min(_threshold, shares);
  });

  Future<void> _make() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = ref.read(vaultControllerProvider).session;
      if (session == null) throw StateError('The vault is locked.');
      final mine = _who == _Who.me;
      final threshold = mine ? 1 : _threshold;
      final shares = mine ? 1 : _shares;
      final kit = makeKit(threshold, shares);
      final store = ref.read(vaultStoreProvider);
      await store.setRecoveryKey(
        session,
        RecoveryKey(kitId: kit.kitId, key: kit.key, threshold: threshold, shares: shares, createdAt: isoString(ref.read(clockProvider)())),
      );
      if (!mounted) return;
      setState(() {
        _pieces = kit.pieces;
        _shown = 0;
        _info = store.recoveryKitInfo();
        _step = _Step.pieces;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'recovery.kit.error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remove() {
    try {
      ref.read(vaultStoreProvider).removeRecoveryKey();
    } on SafetyNetError {
      // The only way back into a vault that needs its key (openspec: add-security-key-unlock, decision 8)
      return setState(() => _error = 'unlockMethod.recovery.lastWayBack');
    }
    setState(() {
      _info = null;
      _step = _Step.choose;
    });
  }

  /// When the kit was made, as `dateStyle: 'medium'` writes it: "Oct 16, 2026".
  String _createdOn(BuildContext context) {
    final info = _info;
    if (info == null) return '';
    final made = DateTime.tryParse(info.createdAt);
    if (made == null) return '';
    return DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(made.toLocal());
  }

  List<({String name, List<String> codes})> _unusedCodes() => [
    for (final service in ref.read(vaultControllerProvider).backupServices)
      if (service.codes.where((c) => !c.used).isNotEmpty)
        (name: service.serviceName, codes: [for (final c in service.codes.where((c) => !c.used)) c.code]),
  ];

  KitPrintout _printout(BuildContext context) {
    final total = _pieces.length;
    final needed = _info?.threshold ?? 1;
    final vault = ref.read(vaultControllerProvider).vault.name ?? context.t('vaults.defaultName');
    return KitPrintout(
      pages: [
        for (final (i, piece) in _pieces.indexed)
          (title: context.t('recovery.print.title', {'index': i + 1, 'total': total, 'vault': vault}), piece: piece),
      ],
      meta: context.t('recovery.print.meta', {'date': _createdOn(context), 'needed': needed, 'total': total}),
      howTo: context.t('recovery.print.howTo', {'needed': needed}),
      codesTitle: context.t('recovery.print.codes'),
      codes: total == 1 && _withCodes ? _unusedCodes() : const [],
    );
  }

  /// Prints a page per piece through the system's print dialog, or, on a
  /// phone that can't print, hands the PDF to the share sheet.
  Future<void> _print() async {
    if (_printing) return;
    final printout = _printout(context);
    final printer = ref.read(printerProvider);
    final files = ref.read(fileServiceProvider);
    final holds = ref.read(autoLockHoldsProvider);
    setState(() => _printing = true);
    try {
      final fonts = await KitPdfFonts.load();
      Future<Uint8List> layout(PdfPageFormat format) => buildKitPdf(printout, format, fonts);
      if (await printer.canPrint()) {
        // The print dialog hides the app; it mustn't lock behind it.
        await holds.withHeld(() => printer.printPdf(name: 'Kemlock Recovery Kit', layout: layout));
      } else {
        await files.shareFile('kemlock-recovery-kit.pdf', await layout(PdfPageFormat.a4), mimeType: 'application/pdf');
      }
    } catch (_) {
      // The dialog failed to open; nothing was printed, and the pieces are still on screen to print again.
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasCodes = ref.watch(vaultControllerProvider.select((s) => s.backupServices.any((x) => x.codes.any((c) => !c.used))));
    final body = AppType.body2.copyWith(color: p.textSecondary);
    final info = _info;
    final total = _pieces.length;
    final kitThreshold = info?.threshold ?? 1;
    final error = _error == null ? null : AppAlert(severity: AlertSeverity.error, child: Text(context.t(_error!)));

    final (List<Widget> content, Widget? leading, List<Widget> actions) = switch (_step) {
      _Step.status when info != null => (
        [
          Text(
            context.t(info.shares == 1 ? 'recovery.kit.status.me' : 'recovery.kit.status.people', {
              'date': _createdOn(context),
              'needed': info.threshold,
              'total': info.shares,
            }),
            style: body,
          ),
          AppAlert(severity: AlertSeverity.info, child: Text(context.t('recovery.kit.replaceHint'))),
        ],
        TextButton(
          onPressed: _remove,
          style: TextButton.styleFrom(foregroundColor: p.error),
          child: Text(context.t('recovery.kit.remove')),
        ),
        [
          InkTextButton(label: context.t('export.close'), onPressed: _close),
          FilledButton(onPressed: () => setState(() => _step = _Step.choose), child: Text(context.t('recovery.kit.replace'))),
        ],
      ),
      _Step.pieces when total > 0 => (
        [
          Text(
            context.t(total == 1 ? 'recovery.kit.pieces.me' : 'recovery.kit.pieces.people', {'needed': kitThreshold, 'total': total}),
            style: body,
          ),
          _PieceView(piece: _pieces[_shown], label: context.t('recovery.collect.piece', {'index': _shown + 1, 'shares': total})),
          if (total > 1)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(onPressed: _shown == 0 ? null : () => setState(() => _shown--), child: Text(context.t('qrExport.prev'))),
                TextButton(onPressed: _shown == total - 1 ? null : () => setState(() => _shown++), child: Text(context.t('qrExport.next'))),
              ],
            ),
          if (total == 1 && hasCodes)
            CheckboxListTile(
              value: _withCodes,
              onChanged: (value) => setState(() => _withCodes = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              title: Text(context.t('recovery.kit.withCodes'), style: AppType.body1.copyWith(color: p.text)),
            ),
          AppAlert(severity: AlertSeverity.info, child: Text(context.t('recovery.kit.onceHint'))),
          if (_replacementKit != null)
            CheckboxListTile(
              value: _saved,
              onChanged: (value) => setState(() => _saved = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              title: Text(context.t('recovery.kit.replacement.saved'), style: AppType.body1.copyWith(color: p.text)),
            ),
        ],
        TextButton.icon(
          onPressed: _printing ? null : _print,
          icon: const Icon(Icons.print_rounded),
          label: Text(context.t('recovery.kit.print', {'total': total})),
        ),
        switch (_replacementKit) {
          final kit? => [
            InkTextButton(label: context.t('changePw.cancel'), onPressed: _close),
            FilledButton(
              onPressed: _saved ? () => Navigator.of(context).pop(kit) : null,
              child: Text(context.t('recovery.kit.replacement.use')),
            ),
          ],
          null => [FilledButton(onPressed: _close, child: Text(context.t('enableBiometric.done')))],
        },
      ),
      _ => (
        [
          Text(context.t('recovery.kit.body'), style: body),
          Semantics(
            container: true,
            explicitChildNodes: true,
            role: SemanticsRole.radioGroup,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _WhoOption(
                  selected: _who == _Who.me,
                  icon: Icons.person_outline_rounded,
                  title: context.t('recovery.kit.me'),
                  body: context.t('recovery.kit.me.body'),
                  onSelect: () => setState(() => _who = _Who.me),
                ),
                const SizedBox(height: 8),
                _WhoOption(
                  selected: _who == _Who.people,
                  icon: Icons.groups_outlined,
                  title: context.t('recovery.kit.people'),
                  body: context.t('recovery.kit.people.body'),
                  onSelect: () => setState(() => _who = _Who.people),
                ),
              ],
            ),
          ),
          if (_who == _Who.people)
            Row(
              children: [
                Expanded(
                  child: _NumberField(
                    label: context.t('recovery.kit.shares'),
                    value: _shares,
                    options: [for (var n = 2; n <= maxPieces; n++) n],
                    onChanged: _setShares,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _NumberField(
                    // Started over with the kept choice when fewer pieces cut it down.
                    key: ValueKey(_shares),
                    label: context.t('recovery.kit.needed'),
                    value: _threshold,
                    options: [for (var n = 2; n <= _shares; n++) n],
                    onChanged: (n) => setState(() => _threshold = n),
                  ),
                ),
              ],
            ),
          AppAlert(
            severity: AlertSeverity.warning,
            child: Text(context.t('recovery.kit.warning', {'needed': _who == _Who.me ? 1 : _threshold})),
          ),
        ],
        null,
        [
          InkTextButton(label: context.t('changePw.cancel'), onPressed: _busy ? null : _close),
          FilledButton(onPressed: _busy ? null : _make, child: Text(context.t('recovery.kit.make'))),
        ],
      ),
    };

    return PopScope(
      canPop: !_busy,
      child: RecoverySheetLayout(
        title: context.t('recovery.kit.title'),
        content: GapColumn(children: [?error, ...content]),
        leading: leading,
        actions: actions,
      ),
    );
  }
}

/// One way to keep the kit, as a card the user picks: the icon, the title
/// and what it means. To screen readers it is a radio button in the group
/// of ways.
class _WhoOption extends StatelessWidget {
  const _WhoOption({required this.selected, required this.icon, required this.title, required this.body, required this.onSelect});

  final bool selected;
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    const radius = BorderRadius.all(Radius.circular(16));
    return MergeSemantics(
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        child: PressScale(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onSelect,
              borderRadius: radius,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Ease.out,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: selected ? b.accentSoft : Colors.transparent,
                  borderRadius: radius,
                  border: Border.all(color: selected ? b.accentLine : p.divider, width: 1.5),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(icon, color: b.accentText),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(fontFamily: fontSans, fontSize: 15, fontWeight: FontWeight.w600, height: 1.4, color: p.text),
                          ),
                          const SizedBox(height: 2),
                          Text(body, style: AppType.caption.copyWith(color: p.textSecondary)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A number picked from a menu in an outlined field, MUI's `<TextField select>`.
class _NumberField extends StatelessWidget {
  const _NumberField({super.key, required this.label, required this.value, required this.options, required this.onChanged});

  final String label;
  final int value;
  final List<int> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<int>(
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    dropdownColor: context.bmc.raised,
    borderRadius: BorderRadius.circular(appRadius),
    style: AppType.body1.copyWith(color: context.palette.text),
    items: [for (final n in options) DropdownMenuItem(value: n, child: Text('$n'))],
    onChanged: (n) {
      if (n != null) onChanged(n);
    },
  );
}

/// The piece on show: its QR code on white, which scanners read best, its
/// number, and its text in groups of four, which can be selected and copied.
class _PieceView extends StatelessWidget {
  const _PieceView({required this.piece, required this.label});

  final String piece;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      children: [
        ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(18)),
            child: QrImageView(
              key: ValueKey(piece),
              data: piece,
              size: 196,
              padding: EdgeInsets.zero,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              backgroundColor: const Color(0xFFFFFFFF),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          label,
          textAlign: TextAlign.center,
          style: AppType.subtitle2.copyWith(color: p.text),
        ),
        const SizedBox(height: 8),
        // Selected and copied, the piece goes through the secret clipboard
        SecretSelection(
          child: SelectableText(
            displayPiece(piece),
            textAlign: TextAlign.center,
            style: AppType.mono(fontSize: 12.5, color: p.textSecondary).copyWith(height: 1.5),
            contextMenuBuilder: secretTextMenu,
          ),
        ),
      ],
    );
  }
}
