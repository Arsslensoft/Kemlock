import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../platform/security_keys.dart';
import '../../security_key/fido/client_pin.dart';
import '../../security_key/fido/credential_management.dart';
import '../../ui/ui.dart';
import 'key_widgets.dart';
import 'pin_forms.dart';
import 'security_key_controller.dart';

/// How many passkeys the list shows before "Show N more".
const keyPasskeysShown = 5;

typedef _Loaded = ({PasskeyStorage storage, List<KeyPasskey> passkeys});

/// Reads how full the key is and every passkey on it, after the PIN.
/// With [deleting], that passkey is deleted first, in the same connection.
Future<_Loaded?> _load(BuildContext context, SecurityKeyController controller, {KeyPasskey? deleting}) => runWithKeyPin(
  context,
  controller,
  permission: PinPermission.credentialManagement,
  action: (session, token) async {
    final management = CredentialManagement(session.fido, session.info.credentialManagementCommand!, token);
    if (deleting != null) await management.delete(deleting);
    final storage = await management.metadata();
    final passkeys = await management.list();
    controller.storage = storage;
    return (storage: storage, passkeys: passkeys);
  },
);

/// Asks for the key's PIN, reads its passkeys and opens the list. Nothing
/// opens when the read fails: a list is whole or not shown.
Future<void> openKeyPasskeys(BuildContext context, SecurityKeyController controller) async {
  final loaded = await guardKey(context, () => _load(context, controller));
  if (loaded == null || !context.mounted) return;
  await showAppBottomSheet<void>(
    context,
    label: context.t('securityKeys.passkeys.row'),
    builder: (_) => KeyPasskeysSheet(controller: controller, storage: loaded.storage, passkeys: loaded.passkeys),
  );
}

/// "Passkeys on this key": how many places are used, each passkey with
/// its site and user name, and deleting one. The same sheet serves keys
/// with the standard and with the preview version of the command.
class KeyPasskeysSheet extends StatefulWidget {
  const KeyPasskeysSheet({super.key, required this.controller, required this.storage, required this.passkeys});

  final SecurityKeyController controller;
  final PasskeyStorage storage;
  final List<KeyPasskey> passkeys;

  @override
  State<KeyPasskeysSheet> createState() => _KeyPasskeysSheetState();
}

class _KeyPasskeysSheetState extends State<KeyPasskeysSheet> {
  late PasskeyStorage _storage = widget.storage;
  late List<KeyPasskey> _passkeys = widget.passkeys;
  bool _showAll = false;

  /// A change was sent and the key left before answering: what the list
  /// shows may no longer be what the key holds.
  bool _unconfirmed = false;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onKey);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onKey);
    super.dispose();
  }

  /// The key is back after an unconfirmed change: it is read again.
  void _onKey() {
    if (_unconfirmed && !_reading && widget.controller.connected && !widget.controller.busy) unawaited(_read());
  }

  Future<void> _read({KeyPasskey? deleting}) async {
    if (_reading) return;
    setState(() => _reading = true);
    try {
      final loaded = await _load(context, widget.controller, deleting: deleting);
      if (loaded == null || !mounted) return;
      setState(() {
        _storage = loaded.storage;
        _passkeys = loaded.passkeys;
        _unconfirmed = false;
      });
      if (deleting != null) showToast(context, context.t('securityKeys.passkeys.deleted'));
    } on SecurityKeyRemoved {
      // The app cannot say the change happened, nor that it did not.
      if (mounted) setState(() => _unconfirmed = _unconfirmed || deleting != null);
      if (mounted && deleting == null) showKeyError(context, const SecurityKeyRemoved());
    } on SecurityKeyCancelled {
      // Nothing to say.
    } catch (error) {
      if (mounted) showKeyError(context, error);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _delete(KeyPasskey passkey) async {
    final user = passkey.userName ?? passkey.userDisplayName ?? context.t('securityKeys.passkeys.noUser');
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('securityKeys.passkeys.delete.title'),
      body: Text(context.t('securityKeys.passkeys.delete.body', {'site': passkey.rpId, 'user': user})),
      confirmLabel: context.t('securityKeys.passkeys.delete'),
      cancelLabel: context.t('export.cancel'),
    );
    if (!confirmed || !mounted) return;
    await _read(deleting: passkey);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final key = widget.controller.key;
    final used = {'used': _storage.used, 'total': _storage.total};
    final shown = _showAll ? _passkeys : _passkeys.take(keyPasskeysShown).toList();
    final hidden = _passkeys.length - shown.length;
    final fraction = _storage.total == 0 ? 0.0 : (_storage.used / _storage.total).clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('securityKeys.passkeys.row')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyActivity(controller: widget.controller),
                if (_unconfirmed) ...[
                  AppAlert(severity: AlertSeverity.warning, child: Text(context.t('securityKeys.error.unconfirmed'))),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: _reading ? null : () => unawaited(_read()),
                      child: Text(context.t('securityKeys.passkeys.readAgain')),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              key?.productName ?? context.t('securityKeys.model.unknown'),
                              style: AppType.caption.copyWith(color: p.textSecondary),
                            ),
                          ),
                          ExcludeSemantics(
                            child: Text(
                              context.t('securityKeys.passkeys.used', used),
                              style: AppType.mono(fontSize: 12.5, fontWeight: FontWeight.w500, color: p.text),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Semantics(
                        image: true,
                        label: context.t('securityKeys.passkeys.used.label', used),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: SizedBox(
                            height: 6,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ColoredBox(color: b.raised),
                                FractionallySizedBox(
                                  alignment: AlignmentDirectional.centerStart,
                                  widthFactor: fraction,
                                  child: ColoredBox(color: b.accentText),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_passkeys.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                      context.t('securityKeys.passkeys.empty'),
                      textAlign: TextAlign.center,
                      style: AppType.body2.copyWith(color: p.textSecondary),
                    ),
                  )
                else
                  GroupCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (index, passkey) in shown.indexed)
                          Rise(
                            delay: Duration(milliseconds: 40 * (index < 6 ? index : 6)),
                            child: GroupRow(
                              first: index == 0,
                              icon: Text(tileLetters(passkey.rpId)),
                              primary: passkey.rpId,
                              secondary: passkey.userName ?? passkey.userDisplayName ?? context.t('securityKeys.passkeys.noUser'),
                              control: TextButton(
                                style: TextButton.styleFrom(
                                  foregroundColor: p.error,
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                                ),
                                onPressed: _reading || widget.controller.busy ? null : () => unawaited(_delete(passkey)),
                                child: Text(context.t('securityKeys.passkeys.delete')),
                              ),
                            ),
                          ),
                        if (hidden > 0)
                          TextButton(
                            onPressed: () => setState(() => _showAll = true),
                            child: Text(context.t('securityKeys.passkeys.showMore', {'count': hidden})),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                AppAlert(severity: AlertSeverity.warning, child: Text(context.t('securityKeys.passkeys.warning'))),
                const SizedBox(height: 14),
                Text(
                  context.t('securityKeys.passkeys.caption'),
                  textAlign: TextAlign.center,
                  style: AppType.caption.copyWith(color: p.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
