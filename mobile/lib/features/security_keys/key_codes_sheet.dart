/// "Codes" in the Security key sheet, and the "Codes on this key" sheet it
/// opens: the accounts of the key's code application with a delete each,
/// its password, erasing it, and forgetting the key in this vault
/// (openspec: add-security-key-codes, decision 12).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../models/key_account.dart';
import '../../security_key/connection.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'key_codes.dart';
import 'key_codes_flow.dart';
import 'key_widgets.dart';
import 'security_key_controller.dart';

/// Runs a codes action on the key the Security key sheet holds: on the one
/// connected, or on the one the person presents next, through the sheet's
/// own connection, so the sheet's read and this action never talk to the
/// key at the same time. The key's FIDO application is not opened first.
KeyRunner sheetKeyRunner(SecurityKeyController controller) =>
    <T>(Future<T> Function(SecurityKeyConnection connection) action) => controller.runOnConnection(action);

/// "Codes", in the Security key sheet's "Also on this key": with the count
/// of the accounts the vault remembers of the key's code application, once
/// the sheet has seen which one the key carries and the vault knows any;
/// and off for a key whose code application Kemlock cannot read.
class KeyCodesRow extends ConsumerWidget {
  const KeyCodesRow({super.key, required this.controller, this.first = true});

  final SecurityKeyController controller;
  final bool first;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plug = controller.key?.deviceId;
    final apps = ref.watch(keyCodesProvider.select((state) => state.apps));
    final keyAccounts = ref.watch(vaultControllerProvider.select((state) => state.keyAccounts));
    final title = context.t('keyCodes.row');
    final tried = plug != null && apps.containsKey(plug);
    final app = tried ? apps[plug] : null;
    if (tried && app == null) {
      return GroupRow(first: first, muted: true, primary: title, secondary: context.t('keyCodes.unsupported'));
    }
    // A key whose accounts the vault never listed shows no count, not "0 accounts".
    final count = app == null ? 0 : keyAccounts.where((account) => account.device == app.device).length;
    return GroupRow(
      first: first,
      primary: title,
      value: count == 0 ? null : Text(context.t('keyCodes.count', {'count': count})),
      onTap: controller.busy ? null : () => unawaited(openKeyCodes(context, ref, controller)),
    );
  }
}

/// Reads the codes of the key the Security key sheet holds, asking for its
/// password when it has one, and opens "Codes on this key".
Future<void> openKeyCodes(BuildContext context, WidgetRef ref, SecurityKeyController controller) async {
  final runner = sheetKeyRunner(controller);
  final codes = ref.read(keyCodesProvider.notifier);
  final result = await runKeyCodes(
    context,
    ref,
    onCancel: controller.cancel,
    (accessKey, remember) => codes.read(runner: runner, accessKey: accessKey, remember: remember),
  );
  // A read that listed the names and not the codes still shows the accounts.
  final device = result.device;
  if (!context.mounted || device == null || !(result.ok || result.partial)) return;
  await showAppBottomSheet<void>(
    context,
    label: context.t('keyCodes.manage.title'),
    builder: (_) => KeyCodesSheet(controller: controller, device: device),
  );
}

/// "Codes on this key": the accounts the vault remembers of the code
/// application [device], each with a delete; setting, changing and
/// removing its password; erasing it; and forgetting it in this vault.
class KeyCodesSheet extends ConsumerWidget {
  const KeyCodesSheet({super.key, required this.controller, required this.device});

  final SecurityKeyController controller;

  /// The code application's id, as [KeyAccount.device] keeps it.
  final String device;

  KeyRunner get _runner => sheetKeyRunner(controller);

  Future<void> _setPassword(BuildContext context, WidgetRef ref, {required bool change}) async {
    final password = await showAppDialog<String>(context, builder: (_) => KeyNewPasswordDialog(change: change));
    if (password == null || !context.mounted) return;
    final codes = ref.read(keyCodesProvider.notifier);
    final result = await runKeyCodes(
      context,
      ref,
      onCancel: controller.cancel,
      (accessKey, remember) => codes.setPassword(password, runner: _runner, accessKey: accessKey, device: device),
    );
    if (result.ok && context.mounted) showToast(context, context.t('keyCodes.password.wasSet'));
  }

  Future<void> _removePassword(BuildContext context, WidgetRef ref) async {
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.lock_open_rounded),
      title: context.t('keyCodes.password.remove.title'),
      body: Text(context.t('keyCodes.password.remove.body')),
      cancelLabel: context.t('export.cancel'),
      confirmLabel: context.t('keyCodes.password.remove'),
    );
    if (!confirmed || !context.mounted) return;
    final codes = ref.read(keyCodesProvider.notifier);
    final result = await runKeyCodes(
      context,
      ref,
      onCancel: controller.cancel,
      (accessKey, remember) => codes.setPassword(null, runner: _runner, accessKey: accessKey, device: device),
    );
    if (result.ok && context.mounted) showToast(context, context.t('keyCodes.password.wasRemoved'));
  }

  Future<void> _erase(BuildContext context, WidgetRef ref) async {
    final confirmed = await showAppDialog<bool>(context, builder: (_) => const KeyEraseDialog());
    if (confirmed != true || !context.mounted) return;
    final navigator = Navigator.of(context);
    final codes = ref.read(keyCodesProvider.notifier);
    final result = await runKeyCodes(
      context,
      ref,
      onCancel: controller.cancel,
      (_, _) => codes.erase(runner: _runner, device: device),
    );
    if (!result.ok || !context.mounted) return;
    showToast(context, context.t('keyCodes.erased'));
    // The application has a new id now, with nothing on it: this sheet was about the old one.
    navigator.pop();
  }

  Future<void> _forget(BuildContext context, WidgetRef ref) async {
    final navigator = Navigator.of(context);
    if (await forgetKeyCodes(context, ref, device) && navigator.mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final accounts = [
      for (final account in ref.watch(vaultControllerProvider.select((state) => state.keyAccounts)))
        if (account.device == device) account,
    ]..sort((a, b) => keyAccountTitle(context, a).toLowerCase().compareTo(keyAccountTitle(context, b).toLowerCase()));
    final plug = controller.key?.deviceId;
    final app = ref.watch(keyCodesProvider.select((state) => plug == null ? null : state.apps[plug]));
    final busy = ref.watch(keyCodesProvider.select((state) => state.activity != KeyCodesActivity.idle));
    final password = app != null && app.device == device && app.password;
    VoidCallback? tap(Future<void> Function() action) => busy ? null : () => unawaited(action());

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('keyCodes.manage.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (accounts.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                      context.t('keyCodes.manage.empty'),
                      textAlign: TextAlign.center,
                      style: AppType.body2.copyWith(color: p.textSecondary),
                    ),
                  )
                else
                  Group(
                    label: context.t('keyCodes.manage.accounts'),
                    children: [
                      for (final (index, account) in accounts.indexed)
                        Rise(
                          delay: Duration(milliseconds: 40 * (index < 6 ? index : 6)),
                          child: GroupRow(
                            first: index == 0,
                            icon: Text(tileLetters(keyAccountTitle(context, account))),
                            primary: keyAccountTitle(context, account),
                            secondary: account.issuer.isNotEmpty && account.label.isNotEmpty ? account.label : null,
                            control: IconButton(
                              tooltip: context.t('keyCodes.delete.named', {'name': keyAccountTitle(context, account)}),
                              color: p.error,
                              onPressed: tap(() => deleteKeyAccount(context, ref, account, runner: _runner, onCancel: controller.cancel)),
                              icon: const Icon(Icons.delete_outline_rounded, size: 20),
                            ),
                          ),
                        ),
                    ],
                  ),
                Group(
                  label: context.t('keyCodes.manage.password'),
                  children: [
                    if (!password)
                      GroupRow(
                        first: true,
                        primary: context.t('keyCodes.password.set'),
                        value: Text(context.t('keyCodes.manage.password.off')),
                        onTap: tap(() => _setPassword(context, ref, change: false)),
                      )
                    else ...[
                      GroupRow(
                        first: true,
                        primary: context.t('keyCodes.password.change'),
                        value: Text(context.t('keyCodes.manage.password.on')),
                        onTap: tap(() => _setPassword(context, ref, change: true)),
                      ),
                      GroupRow(primary: context.t('keyCodes.password.remove'), onTap: tap(() => _removePassword(context, ref))),
                    ],
                  ],
                ),
                const SizedBox(height: 22),
                FilledButton(
                  style: largeButtonStyle.merge(filledButtonColors(background: p.error, foreground: p.onError)),
                  onPressed: tap(() => _erase(context, ref)),
                  child: Text(context.t('keyCodes.erase')),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: tap(() => _forget(context, ref)),
                  style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  child: Text(context.t('keyCodes.forget')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Asks for a new password for a key's code application, typed twice.
/// Pops with it once both copies match.
class KeyNewPasswordDialog extends StatefulWidget {
  const KeyNewPasswordDialog({super.key, this.change = false});

  /// The key has a password already, which this one replaces.
  final bool change;

  @override
  State<KeyNewPasswordDialog> createState() => _KeyNewPasswordDialogState();
}

class _KeyNewPasswordDialogState extends State<KeyNewPasswordDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  bool get _matches => _first.text.isNotEmpty && _first.text == _second.text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final title = context.t(widget.change ? 'keyCodes.password.change' : 'keyCodes.password.set');
    final mismatch = _second.text.isNotEmpty && _first.text != _second.text;
    return AppDialog(
      semanticLabel: title,
      heading: DialogHeading(icon: const Icon(Icons.password_rounded), title: title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.t('keyCodes.password.set.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
          const SizedBox(height: 14),
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: _first,
            autofocus: true,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: context.t('keyCodes.password.new')),
          ),
          const SizedBox(height: 10),
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: _second,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_matches) Navigator.of(context).pop(_first.text);
            },
            decoration: InputDecoration(
              labelText: context.t('keyCodes.password.repeat'),
              errorText: mismatch ? context.t('keyCodes.password.mismatch') : null,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: p.text),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('export.cancel')),
        ),
        FilledButton(
          onPressed: _matches ? () => Navigator.of(context).pop(_first.text) : null,
          child: Text(context.t('keyCodes.password.save')),
        ),
      ],
    );
  }
}

/// Asks before erasing a key's code application: what goes and what
/// stays, and a word to type before the button turns on. Pops with true.
class KeyEraseDialog extends StatefulWidget {
  const KeyEraseDialog({super.key});

  @override
  State<KeyEraseDialog> createState() => _KeyEraseDialogState();
}

class _KeyEraseDialogState extends State<KeyEraseDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final word = context.t('keyCodes.erase.word');
    final title = context.t('keyCodes.erase.title');
    final matches = _typed.text.trim() == word;
    return AppDialog(
      semanticLabel: title,
      heading: DialogHeading(icon: const Icon(Icons.delete_forever_outlined), title: title, tone: DialogTone.danger),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.t('keyCodes.erase.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
          const SizedBox(height: 14),
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: _typed,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: context.t('keyCodes.erase.type', {'word': word})),
          ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: p.text),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.t('export.cancel')),
        ),
        FilledButton(
          style: filledButtonColors(background: p.error, foreground: p.onError),
          onPressed: matches ? () => Navigator.of(context).pop(true) : null,
          child: Text(context.t('keyCodes.erase.confirm')),
        ),
      ],
    );
  }
}
