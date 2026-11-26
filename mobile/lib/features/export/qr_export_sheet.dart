import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../platform/printer.dart';
import '../../ui/ui.dart';
import '../../vault/qr_transfer.dart';
import '../../vault/vault_controller.dart';
import '../settings/auto_lock.dart';
import '../settings/prefs.dart';
import '../spaces/remembered_export_policies.dart';
import '../vault/owner_check.dart';
import 'qr_printout.dart';
import 'space_export.dart';
import 'transfer_widgets.dart';

/// Shows the open vault as QR codes for another phone, `QRExportDialog.tsx`.
Future<void> showQrExportSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('qrExport.title'), builder: (_) => const QrExportSheet());

/// The side of a code on screen, as the dialog drew it. A full chunk makes a
/// version 40 code at error correction L, the densest there is.
const qrCodeSize = 220.0;

/// The QR export sheet: encrypted by default (PBKDF2 and AES-GCM under an
/// export password typed twice) or plain, then the codes one after another,
/// each numbered, to scan on the other phone or print all at once. Before
/// they are made the person shows it is them ([checkOwner]). An encrypted
/// export counts as the vault's latest backup.
class QrExportSheet extends ConsumerStatefulWidget {
  const QrExportSheet({super.key});

  @override
  ConsumerState<QrExportSheet> createState() => _QrExportSheetState();
}

class _QrExportSheetState extends ConsumerState<QrExportSheet> {
  ExportMode _mode = ExportMode.encrypted;
  String _password = '';
  String _confirm = '';
  bool _loading = false;
  String? _error;

  /// What the codes were made from, once they are; null on the password step.
  QrPrintout? _made;

  /// Whether the encrypted codes left out items of server spaces whose policy isn't known: a partial backup, which Vault
  /// health doesn't count.
  bool _partial = false;
  List<QrCode> _codes = const [];
  int _active = 0;
  bool _printing = false;

  bool get _encrypted => _mode == ExportMode.encrypted;
  bool get _mismatch => _confirm.isNotEmpty && _password != _confirm;
  bool get _canGenerate => !_loading && (!_encrypted || (_password.isNotEmpty && _confirm.isNotEmpty && !_mismatch));

  Future<void> _generate() async {
    if (_loading) return;
    final encrypted = _encrypted;
    final problem = !encrypted
        ? null
        : _password != _confirm
        ? 'export.error.mismatch'
        : _password.length < 8
        ? 'export.error.tooShort'
        : null;
    if (problem != null) {
      setState(() => _error = context.t(problem));
      return;
    }
    // Every code's secret leaves in them, encrypted or not: whoever holds the open vault shows it is them first
    setState(() => _error = null);
    if (!await ref.read(ownerCheckProvider)(context, ref, context.t('export.confirm')) || !mounted) return;
    setState(() => _loading = true);
    // What the vault remembers of the spaces' policies is read as it opens, and the export follows it once it is
    await ref.read(rememberedExportPoliciesProvider.notifier).ready;
    if (!mounted) return;
    final vault = ref.read(vaultControllerProvider);
    // The codes of a space that forbids export, or of a server space whose rules aren't known, stay out
    final exportable = ExportableVault.of(vault, ref.read(spaceExportRuleProvider), codesOnly: true);
    // Codes that leave items out for want of their rules are a partial backup, and no full backup was made
    final partial = encrypted && exportable.unknown > 0;
    final prefs = ref.read(prefsProvider.notifier);
    final now = ref.read(clockProvider)();
    try {
      final chunks = encrypted
          ? await exportVaultQr(exportable.accounts, exportable.backupServices, _password)
          : exportVaultQrPlaintext(exportable.accounts, exportable.backupServices);
      // Feeds the "Encrypted backup" item of Vault health, unless the codes left items out that it couldn't read the rules of
      if (encrypted && !partial) prefs.recordBackup();
      if (!mounted) return;
      setState(() {
        _made = QrPrintout(
          chunks: chunks,
          encrypted: encrypted,
          accounts: exportable.accounts.length,
          services: exportable.backupServices.length,
          exportedAt: now,
        );
        _codes = [for (final chunk in chunks) QrCode.fromData(data: chunk, errorCorrectLevel: QrErrorCorrectLevel.L)];
        _active = 0;
        _partial = partial;
        _password = '';
        _confirm = '';
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _show(int index) {
    if (index < 0 || index >= _codes.length || index == _active) return;
    setState(() => _active = index);
  }

  /// Prints every code through the system's print dialog, or, on a phone
  /// that can't print, hands the PDF to the share sheet.
  Future<void> _print() async {
    final made = _made;
    if (made == null || _printing) return;
    final printer = ref.read(printerProvider);
    final files = ref.read(fileServiceProvider);
    final holds = ref.read(autoLockHoldsProvider);
    setState(() => _printing = true);
    try {
      final fonts = await QrPdfFonts.load();
      Future<Uint8List> layout(PdfPageFormat format) => buildQrPdf(made, format, fonts);
      if (await printer.canPrint()) {
        // The print dialog hides the app; it mustn't lock behind it.
        await holds.withHeld(() => printer.printPdf(name: qrPrintTitle(made), layout: layout));
      } else {
        await files.shareFile('kemlock-qr-export.pdf', await layout(PdfPageFormat.a4), mimeType: 'application/pdf');
      }
    } catch (_) {
      // The dialog failed to open; the codes are still on screen to print again.
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final made = _made;
    return TransferSheet(
      icon: Icons.qr_code_2_rounded,
      title: context.t('qrExport.title'),
      actions: [
        SheetCloseButton(label: context.t('export.cancel')),
        if (made == null)
          FilledButton.icon(
            onPressed: _canGenerate ? _generate : null,
            icon: const Icon(Icons.qr_code_2_rounded, size: 20),
            label: Text(context.t('qrExport.generate')),
          )
        else
          FilledButton.icon(
            onPressed: _printing ? null : _print,
            icon: const Icon(Icons.print_outlined, size: 20),
            label: Text(context.t('qrExport.print')),
          ),
      ],
      children: made == null ? _passwordStep(context) : _codesStep(context, made),
    );
  }

  List<Widget> _passwordStep(BuildContext context) {
    final p = context.palette;
    final vault = ref.watch(vaultControllerProvider);
    final exportable = ExportableVault.of(vault, ref.watch(spaceExportRuleProvider), codesOnly: true);
    final accounts = exportable.accounts.length;
    final services = exportable.backupServices.length;
    return spaced([
      Text(
        context.t('qrExport.body', {'accountCount': accounts, 'serviceCount': services}),
        style: AppType.body2.copyWith(color: p.textSecondary),
      ),
      ExportModeControl(value: _mode, semanticLabel: context.t('qrExport.title'), onChanged: (mode) => setState(() => _mode = mode)),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (_encrypted) ...const [TransferTag('AES-256-GCM', tone: TagTone.accent), TransferTag('PBKDF2-SHA256', tone: TagTone.accent)],
          TransferTag(context.t('export.chip.accounts', {'count': accounts})),
          if (services > 0) TransferTag(context.t('export.chip.backupServices', {'count': services})),
        ],
      ),
      // What a space's rules keep out of the codes, by space, and the server spaces whose rules haven't been read
      for (final MapEntry(:key, :value) in exportable.blocked.entries)
        AppAlert(severity: AlertSeverity.info, child: Text(context.t('export.cxf.space', {'count': value, 'name': key}))),
      if (exportable.unknown > 0)
        AppAlert(
          severity: AlertSeverity.warning,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.t('export.space.unknown', {'count': exportable.unknown})),
              if (_encrypted) Padding(padding: const EdgeInsets.only(top: 4), child: Text(context.t('export.space.partial'))),
            ],
          ),
        ),
      // QR codes carry the codes alone; the rest needs a file export
      if (vault.keys.length +
              vault.notes.length +
              vault.passkeys.length +
              vault.contacts.length +
              vault.logins.length +
              vault.cards.length +
              vault.identities.length +
              vault.files.length >
          0)
        AppAlert(
          severity: AlertSeverity.info,
          child: Text(
            context.t('qrExport.leftOut', {
              'items': [
                if (vault.keys.isNotEmpty) context.t('export.chip.keys', {'count': vault.keys.length}),
                if (vault.notes.isNotEmpty) context.t('export.chip.notes', {'count': vault.notes.length}),
                if (vault.passkeys.isNotEmpty) context.t('export.chip.passkeys', {'count': vault.passkeys.length}),
                if (vault.contacts.isNotEmpty) context.t('export.chip.contacts', {'count': vault.contacts.length}),
                if (vault.logins.isNotEmpty) context.t('export.chip.logins', {'count': vault.logins.length}),
                if (vault.cards.isNotEmpty) context.t('export.chip.cards', {'count': vault.cards.length}),
                if (vault.identities.isNotEmpty) context.t('export.chip.identities', {'count': vault.identities.length}),
                if (vault.files.isNotEmpty) context.t('files.chip', {'count': vault.files.length}),
              ].join(', '),
            }),
          ),
        ),
      if (_encrypted) Divider(height: 1, color: p.divider),
      if (_error != null) AppAlert(severity: AlertSeverity.error, child: Text(_error!)),
      if (_encrypted) ...[
        PasswordField(
          label: context.t('export.field.password'),
          helperText: context.t('export.field.passwordHelper'),
          enabled: !_loading,
          autofocus: true,
          textInputAction: TextInputAction.next,
          onChanged: (value) => setState(() => _password = value),
        ),
        PasswordField(
          label: context.t('export.field.confirm'),
          errorText: _mismatch ? context.t('export.field.mismatch') : null,
          enabled: !_loading,
          revealable: false,
          onChanged: (value) => setState(() => _confirm = value),
          onSubmitted: (_) {
            if (!_loading && _password.isNotEmpty && !_mismatch) unawaited(_generate());
          },
        ),
      ],
      if (_loading) WorkingNote(caption: context.t('qrExport.generating')),
    ]);
  }

  List<Widget> _codesStep(BuildContext context, QrPrintout made) {
    final total = made.chunks.length;
    final chunk = made.chunks[_active];
    final label = context.t('qrExport.chunkLabel', {'index': _active + 1, 'total': total});
    return [
      AppAlert(severity: AlertSeverity.success, child: Text(context.t('qrExport.ready', {'total': total}))),
      if (_partial) ...[
        const SizedBox(height: 16),
        AppAlert(severity: AlertSeverity.warning, child: Text(context.t('export.space.partial'))),
      ],
      if (total > 1) ...[const SizedBox(height: 16), _ChunkSteps(total: total, active: _active, onSelect: _show)],
      const SizedBox(height: 16),
      GestureDetector(
        // Swiping across the code pages through them, as the arrows below do.
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity < -200) _show(_active + 1);
          if (velocity > 200) _show(_active - 1);
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            // Always black on white, whatever the scheme, so any camera reads it.
            color: Colors.white,
            borderRadius: BorderRadius.circular(appRadius),
            border: Border.all(color: context.bmc.line2),
          ),
          child: Column(
            children: [
              AnimatedSwitcher(
                duration: Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 200),
                child: Semantics(
                  key: ValueKey(_active),
                  image: true,
                  label: label,
                  child: QrImageView.withQr(
                    qr: _codes[_active],
                    size: qrCodeSize,
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
                    dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ExcludeSemantics(
                child: Text(
                  label,
                  style: AppType.caption.copyWith(color: AppPalette.light.textSecondary, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 2),
              ExcludeSemantics(
                child: Opacity(
                  opacity: 0.6,
                  child: Text(
                    '${chunk.substring(0, math.min(32, chunk.length))}…',
                    textAlign: TextAlign.center,
                    style: AppType.mono(fontSize: 10.5, color: AppPalette.light.textSecondary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      if (total > 1) ...[
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton.icon(
              style: smallButtonStyle,
              onPressed: _active == 0 ? null : () => _show(_active - 1),
              icon: const Icon(Icons.chevron_left_rounded, size: 20),
              label: Text(context.t('qrExport.prev')),
            ),
            Expanded(
              child: _Dots(total: total, active: _active),
            ),
            TextButton.icon(
              style: smallButtonStyle,
              iconAlignment: IconAlignment.end,
              onPressed: _active == total - 1 ? null : () => _show(_active + 1),
              icon: const Icon(Icons.chevron_right_rounded, size: 20),
              label: Text(context.t('qrExport.next')),
            ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      AppAlert(
        severity: AlertSeverity.info,
        child: Text(context.t('qrExport.hint', {'total': total}), style: AppType.caption),
      ),
    ];
  }
}

/// The codes as numbered steps, all done, with the one on screen marked:
/// MUI's Stepper with its labels below. Tapping a step shows its code.
class _ChunkSteps extends StatelessWidget {
  const _ChunkSteps({required this.total, required this.active, required this.onSelect});

  final int total;
  final int active;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    Widget line(bool show) => Expanded(child: Container(height: 1, color: show ? b.line2 : Colors.transparent));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < total; i++)
          Expanded(
            child: Semantics(
              button: true,
              selected: i == active,
              label: 'QR ${i + 1}',
              excludeSemantics: true,
              onTap: () => onSelect(i),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(i),
                child: Column(
                  children: [
                    Row(
                      children: [
                        line(i > 0),
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(color: i == active ? p.primary : b.accentSoft, shape: BoxShape.circle),
                          child: Icon(Icons.check_rounded, size: 16, color: i == active ? p.onPrimary : b.accentText),
                        ),
                        line(i < total - 1),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'QR ${i + 1}',
                      maxLines: 1,
                      style: AppType.caption.copyWith(
                        color: i == active ? p.text : p.textSecondary,
                        fontWeight: i == active ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A dot per code, the one on screen in Azure: MUI's MobileStepper.
class _Dots extends StatelessWidget {
  const _Dots({required this.total, required this.active});

  final int total;
  final int active;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < total; i++)
          AnimatedContainer(
            duration: Motion.reduced(context) ? Duration.zero : Motion.colour,
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: i == active ? context.palette.primary : context.bmc.line2, shape: BoxShape.circle),
          ),
      ],
    ),
  );
}
