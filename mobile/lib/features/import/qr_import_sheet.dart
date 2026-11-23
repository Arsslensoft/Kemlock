import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../models/otp_account.dart';
import '../../platform/files.dart';
import '../../platform/scanner_source.dart';
import '../../ui/ui.dart';
import '../../vault/qr_transfer.dart';
import '../../vault/vault_controller.dart';
import '../export/transfer_widgets.dart';
import '../scan/qr_viewfinder.dart';
import 'import_merge.dart';
import 'import_widgets.dart';

/// Imports a vault shown as QR codes on another phone, `QRImportDialog.tsx`.
Future<void> showQrImportSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('qrImport.title'), builder: (_) => const QrImportSheet());

enum _Step { scan, decrypt, preview }

/// The same code read again within this long counts once, as the dialog's scan loop had it.
const _rescanAfter = Duration(seconds: 2);

/// The QR import sheet: the camera collects a transfer's codes in any order
/// (or they come from pictures of them), with a chip for each one in; an
/// encrypted transfer then asks for its export password; and the accounts
/// it holds are listed, those the vault has already marked, to merge in or
/// to replace the vault's lists with.
class QrImportSheet extends ConsumerStatefulWidget {
  const QrImportSheet({super.key});

  @override
  ConsumerState<QrImportSheet> createState() => _QrImportSheetState();
}

class _QrImportSheetState extends ConsumerState<QrImportSheet> {
  _Step _step = _Step.scan;
  bool _cameraOn = false;

  /// The text of each code in, by its number.
  final Map<int, String> _chunks = {};
  int? _total;

  /// Whether the codes are `BMC1` (encrypted) rather than `BMCP` (plain); null until one is in.
  bool? _encrypted;

  /// When each code's text was last taken.
  final Map<String, int> _lastSeen = {};

  final _password = TextEditingController();
  bool _decrypting = false;
  bool _reading = false;
  String? _error;
  QrTransfer? _preview;
  ImportMode _mode = ImportMode.merge;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  /// The transfer chunk [data] holds, encrypted or plain, or null.
  static QrChunk? _chunkOf(String data) {
    try {
      return isEncryptedQrChunk(data) ? parseQrChunk(data) : parseQrChunkPlaintext(data);
    } catch (_) {
      // Its payload isn't base64url.
      return null;
    }
  }

  /// Takes a code the camera or a picture read: a transfer's chunk is
  /// collected, anything else ignored, as the dialog's scan loop did.
  void _take(String data) {
    if (_step != _Step.scan) return;
    final now = ref.read(clockProvider)().millisecondsSinceEpoch;
    if (now - (_lastSeen[data] ?? 0) <= _rescanAfter.inMilliseconds) return;
    _lastSeen[data] = now;
    final chunk = _chunkOf(data);
    if (chunk == null) return;
    final encrypted = isEncryptedQrChunk(data);
    final total = chunk.total;
    setState(() {
      _encrypted = encrypted;
      _total = total;
      _chunks[chunk.index] = data;
    });
    if (_chunks.length >= total) unawaited(_allIn());
  }

  /// Every code is in: the camera stops, and a plain transfer is read at
  /// once while an encrypted one asks for its password.
  Future<void> _allIn() async {
    if (_encrypted ?? true) {
      setState(() {
        _cameraOn = false;
        _step = _Step.decrypt;
      });
      return;
    }
    setState(() => _cameraOn = false);
    try {
      final result = await importVaultQrPlaintext(_chunks.values.toList(), now: ref.read(clockProvider)());
      if (!mounted) return;
      setState(() {
        _preview = result;
        _step = _Step.preview;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error is QrTransferError ? error.message : '$error');
    }
  }

  /// Reads the code in a picture the person picks, such as a screenshot of the other phone.
  Future<void> _fromPicture() async {
    if (_reading) return;
    final files = ref.read(fileServiceProvider);
    final reader = ref.read(qrImageReaderProvider);
    setState(() => _reading = true);
    try {
      // The reader takes a path, so the picker's copy stays until the code is read
      final picked = await files.pickImage(keepFile: true);
      if (picked == null) return;
      final String? data;
      try {
        final path = picked.path;
        if (path == null || !mounted) return;
        data = await reader.decode(path);
      } finally {
        // A picture of a transfer's code holds the vault's accounts: no copy of it stays in the cache
        await files.forget(picked);
      }
      if (!mounted) return;
      // A picture without a transfer's code in it gets an answer; the camera just keeps looking.
      if (data == null || _chunkOf(data) == null) {
        setState(() => _error = context.t('qrScanner.error.notFound'));
        return;
      }
      setState(() => _error = null);
      _take(data);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _decrypt() async {
    if (_password.text.isEmpty || _decrypting) return;
    setState(() {
      _error = null;
      _decrypting = true;
    });
    try {
      final result = await importVaultQr(_chunks.values.toList(), _password.text, now: ref.read(clockProvider)());
      if (!mounted) return;
      setState(() {
        _preview = result;
        _step = _Step.preview;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error is QrTransferError ? error.message : '$error');
    } finally {
      if (mounted) setState(() => _decrypting = false);
    }
  }

  Future<void> _import() async {
    final preview = _preview;
    if (preview == null) return;
    final vault = ref.read(vaultControllerProvider);
    final merged = mergeImport(
      ImportPreview(accounts: preview.accounts, backupServices: preview.backupServices),
      accounts: vault.accounts,
      services: vault.backupServices,
      mode: _mode,
    );
    final controller = ref.read(vaultControllerProvider.notifier);
    Navigator.of(context).pop();
    await controller.imported(merged.accounts, merged.backupServices);
  }

  @override
  Widget build(BuildContext context) {
    final vault = ref.watch(vaultControllerProvider);
    final preview = _preview;
    final counts = preview == null
        ? null
        : countImport(
            ImportPreview(accounts: preview.accounts, backupServices: preview.backupServices),
            accounts: vault.accounts,
            services: vault.backupServices,
            mode: _mode,
          );
    final merge = _mode == ImportMode.merge;
    final importCount = merge ? counts?.newAccounts ?? 0 : preview?.accounts.length ?? 0;

    return TransferSheet(
      icon: Icons.qr_code_2_rounded,
      title: context.t('qrImport.title'),
      actions: [
        SheetCloseButton(label: context.t('export.cancel')),
        if (_step == _Step.preview)
          FilledButton(
            onPressed: merge && importCount == 0 ? null : _import,
            child: Text(context.t('import.confirm', {'count': importCount})),
          ),
      ],
      children: switch (_step) {
        _Step.scan => _scanStep(context),
        _Step.decrypt => _decryptStep(context),
        _Step.preview => _previewStep(context, preview!, vault.accounts, counts!.newAccounts, counts.duplicates),
      },
    );
  }

  List<Widget> _scanStep(BuildContext context) {
    final p = context.palette;
    final total = _total;
    final scanned = _chunks.length;
    return [
      Text(context.t('qrImport.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
      const SizedBox(height: 16),
      if (_error != null) ...[AppAlert(severity: AlertSeverity.error, child: Text(_error!)), const SizedBox(height: 16)],
      if (total != null) ...[
        Semantics(
          liveRegion: true,
          child: Text(
            context.t('qrImport.progress', {'scanned': scanned, 'total': total}),
            style: AppType.caption.copyWith(fontWeight: FontWeight.w600, color: p.text),
          ),
        ),
        const SizedBox(height: 5),
        LinearProgressIndicator(value: scanned / total),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 1; i <= total; i++) TransferTag('QR $i', tone: _chunks.containsKey(i) ? TagTone.filled : TagTone.neutral),
          ],
        ),
        const SizedBox(height: 16),
      ],
      if (_cameraOn) QrViewfinder(onScan: _take) else _CameraOff(onStart: () => setState(() => _cameraOn = true)),
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          style: smallButtonStyle,
          onPressed: _reading ? null : _fromPicture,
          icon: const Icon(Icons.image_outlined, size: 18),
          label: Text(context.t('qrScanner.chooseImage')),
        ),
      ),
      if (total == null) ...[
        const SizedBox(height: 4),
        Text(context.t('qrImport.hint'), style: AppType.caption.copyWith(color: p.textSecondary)),
      ],
    ];
  }

  List<Widget> _decryptStep(BuildContext context) => [
    AppAlert(severity: AlertSeverity.success, child: Text(context.t('qrImport.allScanned', {'total': _total}))),
    const SizedBox(height: 16),
    Text(context.t('qrImport.enterPassword'), style: AppType.body2.copyWith(color: context.palette.textSecondary)),
    const SizedBox(height: 16),
    if (_error != null) ...[AppAlert(severity: AlertSeverity.error, child: Text(_error!)), const SizedBox(height: 16)],
    Row(
      children: [
        Expanded(
          child: PasswordField(
            controller: _password,
            label: context.t('import.field.password'),
            autofocus: true,
            enabled: !_decrypting,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => unawaited(_decrypt()),
          ),
        ),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 80),
          child: FilledButton(
            onPressed: _password.text.isEmpty || _decrypting ? null : _decrypt,
            child: Text(_decrypting ? '\u{2026}' : context.t('qrImport.decrypt')),
          ),
        ),
      ],
    ),
    if (_decrypting) ...[const SizedBox(height: 10), const WorkingBar()],
  ];

  List<Widget> _previewStep(BuildContext context, QrTransfer preview, List<OtpAccount> current, int newCount, int duplicates) => [
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        TransferTag(context.t('export.chip.accounts', {'count': preview.accounts.length}), tone: TagTone.filled),
        if (preview.backupServices.isNotEmpty)
          TransferTag(context.t('export.chip.backupServices', {'count': preview.backupServices.length}), tone: TagTone.accent),
        if (newCount > 0) TransferTag(context.t('import.preview.new', {'count': newCount}), tone: TagTone.accent),
        if (duplicates > 0) TransferTag(context.t('import.preview.duplicate', {'count': duplicates})),
      ],
    ),
    const SizedBox(height: 16),
    ImportModeControl(value: _mode, onChanged: (mode) => setState(() => _mode = mode)),
    const SizedBox(height: 16),
    Divider(height: 1, color: context.palette.divider),
    const SizedBox(height: 8),
    _ScannedAccounts(accounts: preview.accounts, current: current),
  ];
}

/// Where the camera goes until it is started: dark, with the button that
/// starts it, so the permission prompt comes when the person asks.
class _CameraOff extends StatelessWidget {
  const _CameraOff({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    // The viewfinder's size: 1.08 times as tall as it is wide, and no taller than 420.
    builder: (context, constraints) => SizedBox(height: math.min(constraints.maxWidth * 1.08, 420), child: _box(context)),
  );

  Widget _box(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(30),
    child: DecoratedBox(
      decoration: const BoxDecoration(
        // The viewfinder's ground, so the camera comes up where the button was.
        gradient: RadialGradient(center: Alignment(0, -.24), radius: 1.1, colors: [Color(0xFF1A1C21), Color(0xFF050506)], stops: [0, .72]),
      ),
      child: Center(
        child: FilledButton.icon(
          onPressed: onStart,
          icon: const Icon(Icons.qr_code_2_rounded, size: 20),
          label: Text(context.t('qrImport.startCamera')),
        ),
      ),
    ),
  );
}

/// The accounts a transfer brought: a check by each new one, and an empty
/// ring and "Already in vault" by those the vault has.
class _ScannedAccounts extends StatelessWidget {
  const _ScannedAccounts({required this.accounts, required this.current});

  final List<OtpAccount> accounts;
  final List<OtpAccount> current;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: accounts.length,
        itemBuilder: (context, i) {
          final account = accounts[i];
          final duplicate = isDuplicateAccount(account, current);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  duplicate ? Icons.radio_button_unchecked_rounded : Icons.check_circle_rounded,
                  size: 20,
                  color: duplicate ? p.disabled : p.success,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.issuer.isNotEmpty ? account.issuer : account.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.body2.copyWith(fontWeight: FontWeight.w500, color: p.text),
                      ),
                      if (duplicate) Text(context.t('import.preview.existsTag'), style: AppType.caption.copyWith(color: p.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
