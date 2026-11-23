/// What a change to a PGP key in the vault goes through (openspec:
/// add-pgp-key-editing): biometrics as for the private half, then for a
/// key that keeps its own passphrase that passphrase, checked in a
/// background isolate; then the change itself, in the cancellable isolate
/// of `keygen.dart`, saved with `replaceKeyHalves` unless the vault locked
/// or changed meanwhile. Neither the passphrase nor the opened key is
/// stored: the passphrase is asked for again at the next change.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../crypto/keys/pgp.dart' show PgpException, PgpProblem;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../settings/auto_lock.dart';

/// Opens the primary key of [secretKey] with [passphrase], off the UI
/// isolate, to check the passphrase; throws [PgpException]. Tests replace
/// it with one that needs no isolate.
final pgpKeyOpenerProvider = Provider<Future<void> Function(Uint8List secretKey, String passphrase)>((ref) => _openInBackground);

Future<void> _openInBackground(Uint8List secretKey, String passphrase) => Isolate.run(() {
  crypto.PgpSigner.of(secretKey, passphrase: passphrase);
}, debugName: 'openPgpKey');

/// Starts a change to a PGP key in the background; tests replace it.
final pgpChangerProvider = Provider<crypto.KeyGeneration Function(crypto.KeyRequest request)>((ref) => crypto.generateKey);

/// The way through the gate: the key's passphrase, or null for a key that
/// keeps none.
typedef PgpEditPass = ({String? passphrase});

/// Biometrics when the vault has them, without the warning showing the
/// private half gives, then the passphrase dialog for a key that keeps its
/// own passphrase, unless the change [needsSecret] not (applying a
/// certificate). Null when the person refused or cancelled.
Future<PgpEditPass?> passPgpEditGate(BuildContext context, WidgetRef ref, VaultKey key, {bool needsSecret = true}) async {
  if (ref.read(vaultStoreProvider).hasBiometricUnlock()) {
    final reason = context.t('keys.change.biometric');
    final confirmed = await ref.read(autoLockHoldsProvider).withHeld(() => ref.read(biometricsProvider).authenticate(reason));
    if (!confirmed || !context.mounted) return null;
  }
  if (!needsSecret) return (passphrase: null);
  final secret = unb64(key.privateKey);
  bool needs;
  try {
    needs = crypto.primaryNeedsPassphrase(secret);
  } on crypto.KeyFormatException {
    needs = false;
  }
  if (!needs) return (passphrase: null);
  final passphrase = await showAppDialog<String>(
    context,
    builder: (_) => PgpPassphraseDialog(keyName: key.name, secretKey: secret),
  );
  return passphrase == null ? null : (passphrase: passphrase);
}

/// Asks for the passphrase of the key named [keyName] and checks it on
/// [secretKey] before it pops it: a wrong one stays in the dialog with the
/// error under the field. Pops null when cancelled.
class PgpPassphraseDialog extends ConsumerStatefulWidget {
  const PgpPassphraseDialog({super.key, required this.keyName, required this.secretKey});

  final String keyName;
  final Uint8List secretKey;

  @override
  ConsumerState<PgpPassphraseDialog> createState() => _PgpPassphraseDialogState();
}

class _PgpPassphraseDialogState extends ConsumerState<PgpPassphraseDialog> {
  final _field = TextEditingController();
  var _checking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _field.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final passphrase = _field.text;
    if (passphrase.isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      await ref.read(pgpKeyOpenerProvider)(widget.secretKey, passphrase);
      if (mounted) Navigator.of(context).pop(passphrase);
    } on PgpException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e.problem == PgpProblem.unsupported
            ? context.t('keys.change.passphrase.unsupported', {'name': e.detail ?? ''})
            : e.problem == PgpProblem.wrongPassphrase
            ? context.t('keys.change.passphrase.wrong')
            : context.t('keys.change.failed'),
      );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    semanticLabel: context.t('keys.change.passphrase.title', {'name': widget.keyName}),
    heading: DialogHeading(
      icon: const Icon(Icons.lock_outline_rounded),
      title: context.t('keys.change.passphrase.title', {'name': widget.keyName}),
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(context.t('keys.change.passphrase.body')),
        const SizedBox(height: 12),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: _field,
          obscureText: true,
          autofocus: true,
          enabled: !_checking,
          decoration: InputDecoration(labelText: context.t('keys.change.passphrase.field'), errorText: _error, errorMaxLines: 3),
          onSubmitted: (_) => unawaited(_check()),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('export.cancel'))),
      FilledButton(
        onPressed: _checking || _field.text.isEmpty ? null : () => unawaited(_check()),
        child: _checking ? const Spinner(size: 18) : Text(context.t('keys.change.passphrase.continue')),
      ),
    ],
  );
}

/// How a change to a key ended.
enum PgpChangeOutcome {
  /// Made and saved.
  saved,

  /// Refused at the gate, cancelled, or the vault locked meanwhile:
  /// nothing changed.
  stopped,

  /// The change or its save failed; the person was told.
  failed,
}

/// Runs a change to a PGP key, as each change's sheet asks for it: [key]
/// as the vault holds it, [change] what to make; [running] is told of the
/// generation while it runs, for a Cancel button. Goes through the gate
/// first; [needsSecret] false skips its passphrase, as applying a
/// certificate needs no secret. The changed key is saved only when the
/// vault is the same one, unlocked, as when it started. Says what failed
/// in a toast, or that it worked with [doneId]. [onError] takes a
/// [crypto.PgpEditException] the change threw, for a sheet that says it in
/// place; when it returns true, nothing more is said.
Future<PgpChangeOutcome> runPgpChange(
  BuildContext context,
  WidgetRef ref, {
  required VaultKey key,
  required crypto.PgpChange change,
  required String doneId,
  void Function(crypto.KeyGeneration? generation)? running,
  bool Function(crypto.PgpEditException error)? onError,
  bool needsSecret = true,
}) async {
  final pass = await passPgpEditGate(context, ref, key, needsSecret: needsSecret);
  if (pass == null || !context.mounted) return PgpChangeOutcome.stopped;
  // The sheet may close while the change is made: what follows outlives it
  final container = ProviderScope.containerOf(context, listen: false);
  final controller = container.read(vaultControllerProvider.notifier);
  final session = container.read(vaultControllerProvider).session;
  final messages = container.read(messagesProvider);
  void toast(String id, [ToastSeverity severity = ToastSeverity.success]) =>
      container.read(toastsProvider.notifier).show(messages.t(id), severity: severity);
  final generation = container.read(pgpChangerProvider)(
    crypto.PgpChangeRequest(unb64(key.privateKey), change, passphrase: pass.passphrase, now: container.read(clockProvider)().toUtc()),
  );
  running?.call(generation);
  // A vault that locks meanwhile gets nothing of the change
  final sub = container.listen(vaultControllerProvider.select((state) => state.session), (_, now) {
    if (now != session) generation.cancel();
  });
  crypto.KeyGenerationResult result;
  try {
    result = await generation.result;
  } on crypto.PgpEditException catch (e) {
    if (!(onError?.call(e) ?? false)) toast('keys.change.failed', ToastSeverity.error);
    return PgpChangeOutcome.failed;
  } catch (_) {
    toast('keys.change.failed', ToastSeverity.error);
    return PgpChangeOutcome.failed;
  } finally {
    sub.close();
    running?.call(null);
  }
  final stillOpen = session != null && container.read(vaultControllerProvider).session == session;
  if (result is! crypto.KeyGenerated || !stillOpen) return PgpChangeOutcome.stopped;
  final changed = result.key;
  if (!await controller.replaceKeyHalves(key, changed.private, changed.public!)) return PgpChangeOutcome.failed;
  toast(doneId);
  return PgpChangeOutcome.saved;
}
