import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../platform/files.dart';
import '../../platform/secret_clipboard.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'key_bridge.dart';
import 'key_edit_gate.dart';

/// Revokes a PGP key, or makes a revocation certificate for it (openspec:
/// add-pgp-key-editing). Pops true once the key is revoked in the vault.
Future<bool> showKeyRevokeSheet(BuildContext context, VaultKey key) async =>
    await showAppBottomSheet<bool>(
      context,
      label: context.t('keys.change.revoke.title'),
      builder: (_) => KeyRevokeSheet(keyId: key.id),
    ) ??
    false;

/// Makes the armored revocation certificate of a secret key off the UI
/// isolate; tests replace it with one that needs no isolate.
final revocationMakerProvider =
    Provider<
      Future<String> Function(
        Uint8List secretKey, {
        String? passphrase,
        required crypto.PgpRevocationReason reason,
        required String note,
        required DateTime now,
      })
    >((ref) => _makeInBackground);

Future<String> _makeInBackground(
  Uint8List secretKey, {
  String? passphrase,
  required crypto.PgpRevocationReason reason,
  required String note,
  required DateTime now,
}) => Isolate.run(
  () => crypto.revocationCertificate(secretKey, passphrase: passphrase, reason: reason, note: note, now: now),
  debugName: 'revocationCertificate',
);

/// The message id of [reason].
String revocationReasonId(crypto.PgpRevocationReason reason) => 'keys.change.revoke.reason.${reason.name}';

/// The message id of why a certificate could not be applied.
String certificateProblemId(crypto.PgpEditProblem problem) => switch (problem) {
  crypto.PgpEditProblem.otherKey => 'keys.change.revoke.error.otherKey',
  crypto.PgpEditProblem.damaged => 'keys.change.revoke.error.damaged',
  crypto.PgpEditProblem.notARevocation => 'keys.change.revoke.error.notARevocation',
  crypto.PgpEditProblem.notACertificate => 'keys.change.revoke.error.notACertificate',
  crypto.PgpEditProblem.failedCheck => 'keys.change.failed',
};

/// The revocation sheet: a reason and an optional note, the warning that
/// anyone holding a certificate can revoke the key, and three actions:
/// make a certificate (then Save, Share or Copy it), apply one (pasted or
/// from a file), and revoke the key now, which asks first.
class KeyRevokeSheet extends ConsumerStatefulWidget {
  const KeyRevokeSheet({super.key, required this.keyId});

  final String keyId;

  @override
  ConsumerState<KeyRevokeSheet> createState() => _KeyRevokeSheetState();
}

class _KeyRevokeSheetState extends ConsumerState<KeyRevokeSheet> {
  var _reason = crypto.PgpRevocationReason.none;
  final _note = TextEditingController();
  final _paste = TextEditingController();
  String? _certificate;
  var _applying = false;
  String? _applyError;
  var _working = false;

  @override
  void initState() {
    super.initState();
    _paste.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _note.dispose();
    _paste.dispose();
    super.dispose();
  }

  void _toast(String id) => ref.read(toastsProvider.notifier).show(context.t(id));

  Future<void> _make(VaultKey key) async {
    final pass = await passPgpEditGate(context, ref, key);
    if (pass == null || !mounted) return;
    setState(() => _working = true);
    try {
      final text = await ref.read(revocationMakerProvider)(
        unb64(key.privateKey),
        passphrase: pass.passphrase,
        reason: _reason,
        note: _note.text,
        now: ref.read(clockProvider)().toUtc(),
      );
      if (mounted) setState(() => _certificate = text);
    } catch (_) {
      if (mounted) ref.read(toastsProvider.notifier).show(context.t('keys.change.failed'), severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _fileName(VaultKey key) => '${exportedKeyFileName(key).replaceAll(RegExp(r'\.asc$'), '')}.rev.asc';

  Future<void> _save(VaultKey key, String text) async {
    final result = await ref
        .read(fileServiceProvider)
        .saveFile(_fileName(key), Uint8List.fromList(utf8.encode(text)), mimeType: 'application/octet-stream');
    if (result is Saved && mounted) ref.read(toastsProvider.notifier).show(context.t('notes.copy.saved', {'location': result.location}));
  }

  Future<void> _share(VaultKey key, String text) =>
      ref.read(fileServiceProvider).shareFile(_fileName(key), Uint8List.fromList(utf8.encode(text)), mimeType: 'text/plain');

  Future<void> _copy(String text) async {
    if (await ref.read(secretClipboardProvider).copy(text) && mounted) _toast('keys.change.revoke.copied');
  }

  Future<void> _pick(VaultKey key) async {
    final picked = await ref.read(fileServiceProvider).pickFile();
    if (picked == null || !mounted) return;
    await _apply(key, picked.bytes);
  }

  Future<void> _apply(VaultKey key, Uint8List certificate) async {
    setState(() {
      _working = true;
      _applyError = null;
    });
    final outcome = await runPgpChange(
      context,
      ref,
      key: key,
      change: crypto.ApplyPgpRevocation(certificate),
      doneId: 'keys.change.done.revoked',
      needsSecret: false,
      onError: (error) {
        if (mounted) setState(() => _applyError = context.t(certificateProblemId(error.problem)));
        return true;
      },
    );
    if (!mounted) return;
    setState(() => _working = false);
    if (outcome == PgpChangeOutcome.saved) Navigator.of(context).pop(true);
  }

  Future<void> _revokeNow(VaultKey key) async {
    final sure = await showConfirmDialog(
      context,
      icon: const Icon(Icons.gpp_bad_outlined),
      title: context.t('keys.change.revoke.confirm.title', {'name': key.name}),
      body: Text(context.t('keys.change.revoke.confirm.body')),
      confirmLabel: context.t('keys.change.revoke.confirm.button'),
      cancelLabel: context.t('export.cancel'),
    );
    if (!sure || !mounted) return;
    setState(() => _working = true);
    final outcome = await runPgpChange(
      context,
      ref,
      key: key,
      change: crypto.RevokePgpKey(reason: _reason, note: _note.text),
      doneId: 'keys.change.done.revoked',
    );
    if (!mounted) return;
    setState(() => _working = false);
    if (outcome == PgpChangeOutcome.saved) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final key = ref.watch(vaultControllerProvider.select((state) => state.keys.firstWhereOrNull((key) => key.id == widget.keyId)));
    final certificate = _certificate;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.gpp_maybe_outlined), title: context.t('keys.change.revoke.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Rise(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<crypto.PgpRevocationReason>(
                    isExpanded: true,
                    initialValue: _reason,
                    decoration: InputDecoration(labelText: context.t('keys.change.revoke.reason')),
                    items: [
                      for (final reason in crypto.PgpRevocationReason.values)
                        DropdownMenuItem(value: reason, child: Text(context.t(revocationReasonId(reason)))),
                    ],
                    onChanged: _working ? null : (reason) => setState(() => _reason = reason ?? _reason),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    enableIMEPersonalizedLearning: false,
                    controller: _note,
                    enabled: !_working,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(labelText: context.t('keys.change.revoke.note')),
                  ),
                  const SizedBox(height: 14),
                  AppAlert(severity: AlertSeverity.warning, child: Text(context.t('keys.change.revoke.warning'))),
                  const SizedBox(height: 14),
                  Group(
                    children: [
                      GroupRow(
                        first: true,
                        icon: const Icon(Icons.description_outlined),
                        primary: context.t('keys.change.revoke.make'),
                        onTap: key == null || _working ? null : () => unawaited(_make(key)),
                      ),
                      GroupRow(
                        icon: const Icon(Icons.file_open_outlined),
                        primary: context.t('keys.change.revoke.apply'),
                        onTap: _working ? null : () => setState(() => _applying = !_applying),
                      ),
                      GroupRow(
                        icon: const Icon(Icons.gpp_bad_outlined),
                        primary: context.t('keys.change.revoke.now'),
                        danger: true,
                        onTap: key == null || _working ? null : () => unawaited(_revokeNow(key)),
                      ),
                    ],
                  ),
                  if (_working) ...[const SizedBox(height: 12), const Center(child: Spinner())],
                  if (certificate != null && key != null) ...[
                    const SizedBox(height: 16),
                    Text(context.t('keys.change.revoke.certificate'), style: AppType.caption.copyWith(color: p.textSecondary)),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: context.bmc.raised, borderRadius: BorderRadius.circular(12)),
                      child: Text(
                        certificate,
                        key: const ValueKey('revocation-certificate'),
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.mono(fontSize: 11, color: p.text),
                      ),
                    ),
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: () => unawaited(_save(key, certificate)),
                          icon: const Icon(Icons.file_download_outlined, size: 18),
                          label: Text(context.t('notes.copy.save')),
                        ),
                        TextButton.icon(
                          onPressed: () => unawaited(_share(key, certificate)),
                          icon: const Icon(Icons.ios_share_rounded, size: 18),
                          label: Text(context.t('notes.copy.share')),
                        ),
                        TextButton.icon(
                          onPressed: () => unawaited(_copy(certificate)),
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          label: Text(context.t('keys.public.copy')),
                        ),
                      ],
                    ),
                  ],
                  if (_applying && key != null) ...[
                    const SizedBox(height: 16),
                    TextField(
                      enableIMEPersonalizedLearning: false,
                      controller: _paste,
                      enabled: !_working,
                      minLines: 3,
                      maxLines: 8,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: AppType.mono(fontSize: 12, color: p.text),
                      decoration: InputDecoration(
                        labelText: context.t('keys.change.revoke.paste'),
                        hintText: '-----BEGIN PGP PUBLIC KEY BLOCK-----',
                        alignLabelWithHint: true,
                      ),
                    ),
                    if (_applyError != null) ...[
                      const SizedBox(height: 8),
                      AppAlert(key: const ValueKey('apply-error'), severity: AlertSeverity.error, child: Text(_applyError!)),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: _working ? null : () => unawaited(_pick(key)),
                          icon: const Icon(Icons.folder_open_rounded, size: 18),
                          label: Text(context.t('keys.change.revoke.file')),
                        ),
                        FilledButton(
                          onPressed: _working || _paste.text.trim().isEmpty
                              ? null
                              : () => unawaited(_apply(key, Uint8List.fromList(utf8.encode(_paste.text)))),
                          child: Text(context.t('keys.change.revoke.applyButton')),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
