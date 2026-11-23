import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../models/otp_account.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../import/importers.dart';
import '../scan/qr_viewfinder.dart';
import '../security_keys/key_account_transfer.dart';
import 'add_account/keep_it.dart';
import 'add_account/manual_entry.dart';
import 'add_account/manual_form.dart';
import 'add_account/photo_picker.dart';
import 'add_account/scan_result.dart';
import 'key_transfer_actions.dart';
import 'otpauth.dart';

/// Adds an account by scanning its QR code, reading one from a picture or
/// typing its details: `AddAccountDialog.tsx`. A Google Authenticator
/// transfer QR code adds every account it holds at once. With [link], an
/// `otpauth://` link another app handed over, the sheet opens on what it
/// holds, as if a picture of its QR code had been read, for the person to add.
Future<void> showAddAccountSheet(BuildContext context, {String? link}) => showAppBottomSheet<void>(
  context,
  label: context.t('addAccount.title'),
  builder: (context) => AddAccountSheet(link: link),
);

/// The ways to add an account, one tab each.
enum AddMethod { scan, photo, manual }

final _migrationLink = RegExp('^[Oo][Tt][Pp][Aa][Uu][Tt][Hh]-[Mm][Ii][Gg][Rr][Aa][Tt][Ii][Oo][Nn]:');

/// The sheet [showAddAccountSheet] opens: a close button and the title, the
/// tabs, the tab's panel, and the button that adds what was found or typed.
/// It fills the sheet, as the dialog filled a phone's screen.
class AddAccountSheet extends ConsumerStatefulWidget {
  const AddAccountSheet({super.key, this.link});

  /// A set-up link to open on, without the camera.
  final String? link;

  @override
  ConsumerState<AddAccountSheet> createState() => _AddAccountSheetState();
}

class _AddAccountSheetState extends ConsumerState<AddAccountSheet> {
  final _form = ManualForm();
  final _resultKey = GlobalKey();
  AddMethod _mode = AddMethod.scan;
  OtpAccount? _scanned;
  ForeignImport? _migration;
  String? _scanError;
  String? _manualError;
  bool _advanced = false;

  /// "Keep it: On your key" is chosen.
  bool _onKey = false;

  @override
  void initState() {
    super.initState();
    final link = widget.link;
    if (link != null) {
      // The picture tab, which shows what was read without starting the camera.
      _mode = AddMethod.photo;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onCode(link);
      });
    }
  }

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  void _setMode(AddMethod mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _scanned = null;
      _migration = null;
      _scanError = null;
      _manualError = null;
    });
  }

  /// A QR code from the camera or a picture: one account, or a Google Authenticator transfer batch.
  void _onCode(String data) {
    if (_migrationLink.hasMatch(data)) {
      final result = parseGoogleMigration(data);
      setState(() {
        if (result != null && (result.accounts.isNotEmpty || result.skipped > 0)) {
          _scanError = null;
          _migration = result;
        } else {
          _scanError = context.t('addAccount.migration.error');
        }
      });
    } else {
      final parsed = parseOtpUri(data);
      setState(() {
        if (parsed != null) {
          _scanError = null;
          _scanned = parsed;
        } else {
          _scanError = context.t('addAccount.scan.error', {'raw': data});
        }
      });
    }
    if (_scanned != null || _migration != null) _revealResult();
  }

  /// Scrolls the result into view below the frozen viewfinder, once it is laid out.
  void _revealResult() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _resultKey.currentContext;
      if (target == null || !target.mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          duration: Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 450),
          curve: Ease.sheet,
        ),
      );
    });
  }

  void _rescan() => setState(() {
    _scanned = null;
    _migration = null;
    _scanError = null;
  });

  void _submit() {
    final vault = ref.read(vaultControllerProvider.notifier);
    final migration = _migration;
    if (_mode != AddMethod.manual && migration != null) {
      if (migration.accounts.isNotEmpty) unawaited(vault.addAccounts(migration.accounts));
      Navigator.of(context).pop();
      return;
    }
    final OtpAccount? data;
    if (_mode == AddMethod.manual) {
      final error = _form.error;
      setState(() => _manualError = error == null ? null : context.t(error));
      data = error == null ? _form.toAccount() : null;
    } else {
      data = _scanned;
    }
    if (data == null) return;
    if (_onKey && _keepsOnKey) return unawaited(_toKey(data));
    unawaited(vault.addAccount(data));
    Navigator.of(context).pop();
  }

  /// Whether "Keep it" is offered: to a vault that knows a key.
  bool get _keepsOnKey => ref.read(vaultControllerProvider).keyAccounts.isNotEmpty;

  /// Writes [data] to the key and never to the vault; the sheet stays, filled in, when it fails.
  Future<void> _toKey(OtpAccount data) async {
    final navigator = Navigator.of(context);
    if (await transferToKey(context, ref, data, KeyTransfer.add) && navigator.mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final migration = _migration;
    final scanned = _scanned;
    final manual = _mode == AddMethod.manual;
    final showAdd = manual || scanned != null || migration != null;
    final keepsOnKey = ref.watch(vaultControllerProvider.select((state) => state.keyAccounts.isNotEmpty));

    return SizedBox(
      // As tall as the sheet allows: the dialog filled a phone's screen.
      height: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(onClose: () => Navigator.of(context).pop()),
                const SizedBox(height: 18),
                SegmentedControl<AddMethod>(
                  semantics: SegmentSemantics.tabs,
                  semanticLabel: context.t('addAccount.method'),
                  value: _mode,
                  onChanged: _setMode,
                  options: [
                    SegmentOption(
                      value: AddMethod.scan,
                      label: context.t('addAccount.tab.scan'),
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                    ),
                    SegmentOption(value: AddMethod.photo, label: context.t('addAccount.tab.photo'), icon: const Icon(Icons.image_rounded)),
                    SegmentOption(
                      value: AddMethod.manual,
                      label: context.t('addAccount.tab.manual'),
                      icon: const Icon(Icons.keyboard_rounded),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              // Scrolled content slips under a gap below the tabs, not right against them.
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Semantics(
                role: SemanticsRole.tabPanel,
                container: true,
                explicitChildNodes: true,
                child: Rise(
                  key: ValueKey(_mode),
                  duration: const Duration(milliseconds: 400),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_mode == AddMethod.scan) ...[
                        QrViewfinder(onScan: _onCode, found: scanned != null || migration != null),
                        if (_scanError != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: AppAlert(severity: AlertSeverity.error, child: Text(_scanError!)),
                          ),
                        if (scanned == null && migration == null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 320),
                                child: Text(
                                  context.t('addAccount.scan.hint'),
                                  textAlign: TextAlign.center,
                                  style: AppType.body2.copyWith(color: p.textSecondary),
                                ),
                              ),
                            ),
                          ),
                      ],
                      if (_mode == AddMethod.photo && scanned == null && migration == null)
                        PhotoPicker(
                          onDecoded: _onCode,
                          onFailed: () => setState(() => _scanError = context.t('qrScanner.error.notFound')),
                          error: _scanError,
                        ),
                      if (!manual && migration != null)
                        Padding(
                          key: _resultKey,
                          padding: const EdgeInsets.only(top: 16),
                          child: MigrationResult(result: migration, onRescan: _rescan),
                        ),
                      if (!manual && scanned != null)
                        Padding(
                          key: _resultKey,
                          padding: const EdgeInsets.only(top: 16),
                          child: ScanResult(account: scanned, onRescan: _rescan),
                        ),
                      if (manual)
                        ManualEntry(
                          form: _form,
                          error: _manualError,
                          advanced: _advanced,
                          onToggleAdvanced: () => setState(() => _advanced = !_advanced),
                          onSubmit: _submit,
                        ),
                      if (keepsOnKey && (manual || scanned != null))
                        Padding(
                          padding: const EdgeInsets.only(top: 18),
                          child: KeepItChoice(onKey: _onKey, onChanged: (onKey) => setState(() => _onKey = onKey)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (showAdd)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: FilledButton(
                onPressed: _submit,
                style: largeButtonStyle,
                child: Text(
                  !manual && migration != null
                      ? context.t('addAccount.migration.add', {'count': migration.accounts.length})
                      : context.t('addAccount.add'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The close button and the sheet's title.
class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          SizedBox.square(
            dimension: 40,
            child: PressScale(
              scale: .94,
              child: IconButton(
                onPressed: onClose,
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  backgroundColor: context.bmc.raised,
                  foregroundColor: p.textSecondary,
                  fixedSize: const Size.square(40),
                  minimumSize: const Size.square(40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: CircleBorder(side: BorderSide(color: p.divider)),
                ),
                icon: Icon(Icons.close_rounded, size: 18, semanticLabel: context.t('addAccount.cancel')),
              ),
            ),
          ),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                context.t('addAccount.title'),
                textAlign: TextAlign.center,
                style: AppType.h5.copyWith(color: p.text),
              ),
            ),
          ),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}
