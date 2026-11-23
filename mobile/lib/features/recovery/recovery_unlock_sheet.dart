import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_registry.dart';
import '../../vault/vault_store.dart';
import '../lock/master_password.dart';
import 'piece_collector.dart';
import 'recovery_sheet_layout.dart';

/// Opens a vault whose password is forgotten with its Recovery Kit's
/// pieces, from the lock screen, then has a new password set for it,
/// `RecoveryUnlockDialog.tsx`. Resolves to the vault's session once it has
/// the new password, or null when the sheet was closed first.
Future<VaultSession?> showRecoveryUnlockSheet(BuildContext context) =>
    showAppBottomSheet<VaultSession>(context, label: context.t('recovery.unlock.title'), builder: (_) => const RecoveryUnlockSheet());

/// The sheet's two steps: collecting pieces until they open a vault on this
/// device, then the vault's new password. The pieces are tried against
/// every vault here, and the one they open becomes the active vault, for
/// its new password to be written to. Closed before that password is
/// saved, the sheet makes the vault active before it so again: storage
/// then points at the vault the lock screen shows, not at the one the
/// pieces opened, which may be another vault, or a hidden one.
class RecoveryUnlockSheet extends ConsumerStatefulWidget {
  const RecoveryUnlockSheet({super.key});

  @override
  ConsumerState<RecoveryUnlockSheet> createState() => _RecoveryUnlockSheetState();
}

class _RecoveryUnlockSheetState extends ConsumerState<RecoveryUnlockSheet> {
  late final VaultRegistry _vaults = ref.read(vaultRegistryProvider);
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  /// The vault the pieces opened, which has no password key yet.
  VaultSession? _session;

  /// The active vault before the pieces opened [_session]'s, made active
  /// again when the sheet goes without the new password; null once it is
  /// saved.
  String? _activeBefore;

  /// It had security keys, which the new password takes away (openspec:
  /// add-security-key-unlock, decision 11).
  var _hadKeys = false;
  bool _busy = false;

  /// The message id of what went wrong, or null.
  String? _error;

  /// Starts the collector over after a key that opened nothing.
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    // Save turns on and off as the passwords are typed.
    _password.addListener(_changed);
    _confirm.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    if (_activeBefore case final before?) _vaults.active = before;
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _tryKey(String kitId, Uint8List key) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final before = _vaults.active;
    try {
      final store = ref.read(vaultStoreProvider);
      final session = await store.unlockWithRecoveryKey(kitId, key);
      // Closed while the pieces were tried: nothing is saved, so storage goes back to the vault on screen
      if (!mounted) {
        _vaults.active = before;
        return;
      }
      setState(() {
        _session = session;
        _activeBefore = before;
        _hadKeys = store.enrolledKeys().isNotEmpty;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'recovery.unlock.noVault';
          _attempt++;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _mismatch => _confirm.text.isNotEmpty && _password.text != _confirm.text;

  bool get _canSave => !_busy && _password.text.isNotEmpty && _password.text == _confirm.text;

  Future<void> _save() async {
    final session = _session;
    if (session == null || !_canSave) return;
    if (!masterPasswordLongEnough(_password.text)) {
      setState(() => _error = 'changePw.error.tooShort');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await ref.read(vaultStoreProvider).resetToPassword(session, _password.text);
      // Saved: the vault the pieces opened stays active, for the lock screen to open
      _activeBefore = null;
      if (mounted) Navigator.of(context).pop(next);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'setup.error.failed';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final body = AppType.body2.copyWith(color: p.textSecondary);
    final error = _error == null ? null : AppAlert(severity: AlertSeverity.error, child: Text(context.t(_error!)));
    final progress = _busy ? const LinearProgressIndicator() : null;
    final Widget layout;
    if (_session == null) {
      layout = RecoverySheetLayout(
        title: context.t('recovery.unlock.title'),
        content: GapColumn(
          children: [
            Text(context.t('recovery.unlock.body'), style: body),
            ?error,
            PieceCollector(key: ValueKey(_attempt), onKey: _tryKey, busy: _busy),
            ?progress,
          ],
        ),
        actions: [InkTextButton(label: context.t('changePw.cancel'), onPressed: _busy ? null : () => Navigator.of(context).pop())],
      );
    } else {
      layout = RecoverySheetLayout(
        title: context.t('recovery.unlock.newPassword'),
        // Closing the sheet drops what the phone's password manager holds of the fields instead of offering to
        // save it: they are a master password
        content: AutofillGroup(
          onDisposeAction: AutofillContextAction.cancel,
          child: GapColumn(
            children: [
              Text(context.t('recovery.unlock.opened'), style: body),
              if (_hadKeys) AppAlert(severity: AlertSeverity.warning, child: Text(context.t('unlockMethod.recovery.keys'))),
              ?error,
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                autofocus: true,
                // Null, not the empty default: the phone's password manager neither fills nor saves them
                autofillHints: null,
                enableIMEPersonalizedLearning: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: context.t('changePw.field.new')),
              ),
              TextField(
                controller: _confirm,
                enabled: !_busy,
                obscureText: true,
                autofillHints: null,
                enableIMEPersonalizedLearning: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                decoration: InputDecoration(
                  labelText: context.t('changePw.field.confirm'),
                  // A blank helper keeps the room the mismatch message takes, so nothing jumps.
                  helperText: ' ',
                  errorText: _mismatch ? context.t('changePw.field.mismatch') : null,
                ),
              ),
              ?progress,
            ],
          ),
        ),
        actions: [FilledButton(onPressed: _canSave ? _save : null, child: Text(context.t('recovery.unlock.save')))],
      );
    }
    // Neither the back gesture nor the scrim closes the sheet while a key or password is being worked on.
    return PopScope(canPop: !_busy, child: layout);
  }
}
