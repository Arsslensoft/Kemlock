/// What the person goes through before a secret leaves the open vault or
/// shows on screen: an export, the private half of a key, and an account's
/// secret or a saved password when Settings asks for it. Whoever holds the
/// phone while the vault is open can read its codes, but taking all of it
/// away, or a secret that makes the codes anywhere, asks first who they are.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../../vault/biometrics.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_store.dart';
import '../export/transfer_widgets.dart';
import '../lock/key_pin_sheet.dart';
import '../settings/auto_lock.dart';

/// Asks the person to show it is them; true when they did. [reason] is
/// what the biometric prompt and the password dialog say.
typedef OwnerCheck = Future<bool> Function(BuildContext context, WidgetRef ref, String reason);

/// The check [checkOwner] makes; tests put one in its place that answers
/// at once.
final ownerCheckProvider = Provider<OwnerCheck>((ref) => checkOwner);

/// The wrong master passwords in a row that lock the vault from the
/// password dialog. Whoever holds the open phone could otherwise guess the
/// master password there without end, where the lock screen counts each
/// try and may erase; locked, every further try goes through it.
const ownerCheckMissLimit = 3;

/// Wrong master passwords typed in a row in the password dialog, for the
/// vault open now: kept from one dialog to the next, back to none after a
/// right one, and whenever the vault locks or opens again.
final ownerCheckMissesProvider = NotifierProvider<OwnerCheckMisses, int>(OwnerCheckMisses.new);

class OwnerCheckMisses extends Notifier<int> {
  @override
  int build() {
    // A session of its own for each opening: a new one starts the count again
    ref.watch(vaultControllerProvider.select((state) => state.session));
    return 0;
  }

  /// Counts a wrong password, and returns how many there are in a row now.
  int miss() => ++state;

  /// A right password: the count starts again.
  void reset() => state = 0;
}

/// Biometrics when the open vault opens with them, as showing a private
/// key always asked. Otherwise, or when the prompt can't run (biometrics
/// gone from the phone, or locked out after failed tries), what opens the
/// vault: its master password, typed in a dialog that checks it, and for a
/// vault that needs a security key that key too, or the key alone.
/// Cancelling any of them is a no.
Future<bool> checkOwner(BuildContext context, WidgetRef ref, String reason) async {
  final store = ref.read(vaultStoreProvider);
  if (store.hasBiometricUnlock()) {
    try {
      return await ref.read(autoLockHoldsProvider).withHeld(() => ref.read(biometricsProvider).authenticate(reason));
    } on BiometricError {
      // The prompt can't run now: the password does instead
    }
    if (!context.mounted) return false;
  }
  if (!store.unlockMode().hasPassword) {
    try {
      final proof = await proveOwnerWithKey(context, ref);
      proof?.wipe();
      return proof != null;
    } on Object {
      return false;
    }
  }
  return await showAppDialog<bool>(context, builder: (_) => OwnerPasswordDialog(reason: reason)) ?? false;
}

/// Asks for the open vault's master password and checks it before it
/// pops true: a wrong one stays in the dialog with the error under the
/// field, and the [ownerCheckMissLimit]th in a row locks the vault and
/// pops false. For a vault that needs a security key, the key's sheet
/// follows the password. Pops false when cancelled.
class OwnerPasswordDialog extends ConsumerStatefulWidget {
  const OwnerPasswordDialog({super.key, required this.reason});

  final String reason;

  @override
  ConsumerState<OwnerPasswordDialog> createState() => _OwnerPasswordDialogState();
}

class _OwnerPasswordDialogState extends ConsumerState<OwnerPasswordDialog> {
  final _password = TextEditingController();
  var _checking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final password = _password.text;
    if (password.isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    final store = ref.read(vaultStoreProvider);
    try {
      final proof = store.unlockMode().needsKey
          ? await proveOwnerWithKey(context, ref, password: password)
          : await store.proveOwner(password: password);
      proof?.wipe();
      if (!mounted) return;
      // The key's sheet was closed: the password stays for another try
      if (proof == null) return setState(() => _checking = false);
      ref.read(ownerCheckMissesProvider.notifier).reset();
      Navigator.of(context).pop(true);
    } on IncorrectPasswordError {
      if (!mounted) return;
      if (ref.read(ownerCheckMissesProvider.notifier).miss() >= ownerCheckMissLimit) {
        // The lock screen takes the next try, and counts it with its own
        final controller = ref.read(vaultControllerProvider.notifier);
        Navigator.of(context).pop(false);
        controller.lock();
        return;
      }
      setState(() {
        _checking = false;
        _error = context.t('confirmOwner.wrong');
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = context.t('confirmOwner.failed');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // From the second wrong password in a row, in this dialog or an earlier one
    final lastTry = ref.watch(ownerCheckMissesProvider) >= ownerCheckMissLimit - 1;
    return AppDialog(
      semanticLabel: widget.reason,
      heading: DialogHeading(icon: const Icon(Icons.lock_outline_rounded), title: widget.reason),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.t('confirmOwner.body'), style: AppType.body2.copyWith(color: context.palette.textSecondary)),
          const SizedBox(height: 12),
          PasswordField(
            controller: _password,
            label: context.t('unlock.field.password'),
            autofocus: true,
            enabled: !_checking,
            errorText: _error,
            onSubmitted: (_) => unawaited(_check()),
          ),
          if (lastTry) ...[
            const SizedBox(height: 12),
            AppAlert(severity: AlertSeverity.warning, child: Text(context.t('confirmOwner.lastTry'))),
          ],
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: context.palette.text),
          onPressed: _checking ? null : () => Navigator.of(context).pop(false),
          child: Text(context.t('export.cancel')),
        ),
        FilledButton(
          onPressed: _checking || _password.text.isEmpty ? null : () => unawaited(_check()),
          child: _checking ? const Spinner(size: 18) : Text(context.t('confirmOwner.continue')),
        ),
      ],
    );
  }
}
