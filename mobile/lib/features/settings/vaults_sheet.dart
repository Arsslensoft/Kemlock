import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../../vault/key_unlock.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_store.dart';
import '../lock/master_password.dart';
import '../lock/password_checks.dart';

/// Adds, renames, hides, switches and deletes vaults, `VaultsDialog.tsx`.
Future<void> showVaultsSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('vaults.title'), builder: (_) => const VaultsSheet());

enum _Mode { list, create }

/// The sheet [showVaultsSheet] opens. It lists this phone's vaults: the
/// open one's name and whether the lock screen shows it, the other listed
/// vaults to switch to, and a button to add one, which turns the sheet into
/// the new vault's form.
class VaultsSheet extends ConsumerStatefulWidget {
  const VaultsSheet({super.key});

  @override
  ConsumerState<VaultsSheet> createState() => _VaultsSheetState();
}

class _VaultsSheetState extends ConsumerState<VaultsSheet> {
  var _mode = _Mode.list;

  /// The open vault's name, saved when the field is left or the sheet closes.
  final _thisName = TextEditingController();
  final _thisNameFocus = FocusNode();

  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  var _hidden = false;
  var _busy = false;
  String? _errorId;
  var _hideRefused = false;

  @override
  void initState() {
    super.initState();
    _thisName.text = ref.read(vaultControllerProvider).vault.name ?? '';
    _thisNameFocus.addListener(() {
      if (!_thisNameFocus.hasFocus) _rename();
    });
  }

  @override
  void dispose() {
    _thisName.dispose();
    _thisNameFocus.dispose();
    _name.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String _label(String id) => ref.read(vaultRegistryProvider).vaultName(id) ?? context.t('vaults.defaultName');

  /// Saves the open vault's name when it changed; an empty one gives the first vault its default label back.
  void _rename() {
    if (!mounted) return;
    final current = ref.read(vaultControllerProvider).vault;
    if (_thisName.text.trim() == (current.name ?? '')) return;
    ref.read(vaultStoreProvider).renameVault(current.id, _thisName.text);
    ref.read(vaultControllerProvider.notifier).vaultChanged();
  }

  void _setListed(bool listed) {
    final current = ref.read(vaultControllerProvider).vault;
    // A vault that opens with a key alone is never hidden: a password is how a hidden vault is found
    // (openspec: add-security-key-unlock)
    _hideRefused = !listed && ref.read(vaultStoreProvider).unlockMode(current.id) == UnlockMode.key;
    if (_hideRefused) return setState(() {});
    // A hidden vault opens with its password only, and the lock screen never asks biometrics for it: entries
    // left behind would open it for whoever reads the phone's storage, and could never be turned off again
    if (!listed) unawaited(ref.read(vaultStoreProvider).removeBiometricUnlock().catchError((Object _) {}));
    ref.read(vaultRegistryProvider).setListed(current.id, listed);
    ref.read(vaultControllerProvider.notifier).vaultChanged();
    setState(() {});
  }

  void _reset() => setState(() {
    _mode = _Mode.list;
    _name.clear();
    _password.clear();
    _confirm.clear();
    _hidden = false;
    _errorId = null;
  });

  void _close() {
    if (_busy) return;
    Navigator.of(context).pop();
  }

  bool get _canCreate => !_busy && _name.text.trim().isNotEmpty && _password.text.isNotEmpty && _password.text == _confirm.text;

  Future<void> _create() async {
    final name = _name.text;
    final password = _password.text;
    if (name.trim().isEmpty || password != _confirm.text) return;
    if (!masterPasswordLongEnough(password)) {
      setState(() => _errorId = 'changePw.error.tooShort');
      return;
    }
    setState(() {
      _busy = true;
      _errorId = null;
    });
    try {
      // Whether the password opens a vault already is counted, as a try on the lock screen is
      final store = ref.read(vaultStoreProvider);
      final listed = !_hidden;
      await countedPasswordCheck(ref, () => store.createVault(name, password, listed: listed));
      if (!mounted) return;
      showToast(context, context.t(_hidden ? 'vaults.created.hidden' : 'vaults.created', {'name': name.trim()}));
      _reset();
    } on PasswordInUseError {
      if (mounted) setState(() => _errorId = 'vaults.error.passwordInUse');
    } catch (_) {
      if (mounted) setState(() => _errorId = 'setup.error.failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Closes the sheet and locks, with the lock screen set to [id].
  void _switchTo(String id) {
    if (_busy) return;
    final controller = ref.read(vaultControllerProvider.notifier);
    Navigator.of(context).pop();
    controller.switchVault(id);
  }

  Future<void> _delete() async {
    final current = ref.read(vaultControllerProvider).vault;
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('vaults.delete.title', {'name': _label(current.id)}),
      body: Text(context.t('vaults.delete.body')),
      cancelLabel: context.t('changePw.cancel'),
      confirmLabel: context.t('vaults.delete.confirm'),
    );
    if (!confirmed || !mounted) return;
    final controller = ref.read(vaultControllerProvider.notifier);
    Navigator.of(context).pop();
    controller.deleteVault();
  }

  @override
  Widget build(BuildContext context) {
    final creating = _mode == _Mode.create;
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _rename();
      },
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DialogHeading(icon: const Icon(Icons.inventory_2_outlined), title: context.t(creating ? 'vaults.new.title' : 'vaults.title')),
            if (creating) ..._createForm(context) else ..._list(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _list(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final current = ref.watch(vaultControllerProvider.select((state) => state.vault));
    final vaults = ref.watch(vaultRegistryProvider);
    final listed = vaults.isListed(current.id);
    final others = vaults.listedVaultIds().where((id) => id != current.id).toList();

    return [
      _Content(
        children: [
          Text(context.t('vaults.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
          TextField(
            controller: _thisName,
            focusNode: _thisNameFocus,
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => _thisNameFocus.unfocus(),
            onTapOutside: (_) => _thisNameFocus.unfocus(),
            decoration: InputDecoration(labelText: context.t('vaults.field.thisName'), hintText: context.t('vaults.defaultName')),
          ),
          _LabelledControl(
            label: context.t('vaults.showOnLock'),
            onTap: () => _setListed(!listed),
            control: AppSwitch(value: listed, onChanged: _setListed),
          ),
          if (_hideRefused) AppAlert(severity: AlertSeverity.error, child: Text(context.t('unlockMethod.hideKeyOnly'))),
          if (!listed)
            AppAlert(severity: AlertSeverity.info, child: Text(context.t(others.isEmpty ? 'vaults.hidden.alone' : 'vaults.hidden.hint'))),
          if (others.isNotEmpty)
            GroupCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, id) in others.indexed)
                    GroupRow(
                      first: i == 0,
                      icon: const Icon(Icons.inventory_2_outlined),
                      primary: _label(id),
                      secondary: context.t('vaults.switchHint'),
                      onTap: () => _switchTo(id),
                    ),
                ],
              ),
            ),
          PressScale(
            child: TextButton.icon(
              onPressed: () => setState(() => _mode = _Mode.create),
              style: TextButton.styleFrom(backgroundColor: b.accentSoft, foregroundColor: b.accentText),
              icon: const Icon(Icons.add_rounded),
              label: Text(context.t('vaults.new')),
            ),
          ),
        ],
      ),
      _Actions(
        alignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: TextButton.icon(
              onPressed: _busy ? null : () => unawaited(_delete()),
              style: TextButton.styleFrom(foregroundColor: p.error),
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(context.t('vaults.delete')),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _close,
            style: TextButton.styleFrom(foregroundColor: p.text),
            child: Text(context.t('export.close')),
          ),
        ],
      ),
    ];
  }

  List<Widget> _createForm(BuildContext context) {
    final p = context.palette;
    final mismatch = _confirm.text.isNotEmpty && _password.text != _confirm.text;
    final errorId = _errorId;
    return [
      _Content(
        children: [
          Text(context.t('vaults.new.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
          if (errorId != null) AppAlert(severity: AlertSeverity.error, child: Text(context.t(errorId))),
          TextField(
            controller: _name,
            autofocus: true,
            enabled: !_busy,
            textInputAction: TextInputAction.next,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: context.t('vaults.field.name'), hintText: context.t('vaults.field.namePlaceholder')),
          ),
          TextField(
            controller: _password,
            enabled: !_busy,
            obscureText: true,
            // Null, not the empty default: the phone's password manager neither fills nor saves them
            autofillHints: null,
            enableIMEPersonalizedLearning: false,
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: context.t('setup.field.password')),
          ),
          TextField(
            controller: _confirm,
            enabled: !_busy,
            obscureText: true,
            autofillHints: null,
            enableIMEPersonalizedLearning: false,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_canCreate) unawaited(_create());
            },
            decoration: InputDecoration(
              labelText: context.t('setup.field.confirm'),
              errorText: mismatch ? context.t('setup.field.mismatch') : null,
              helperText: ' ',
            ),
          ),
          _LabelledControl(
            label: context.t('vaults.new.hide'),
            onTap: _busy ? null : () => setState(() => _hidden = !_hidden),
            control: Checkbox(value: _hidden, onChanged: _busy ? null : (value) => setState(() => _hidden = value ?? false)),
          ),
          if (_hidden) AppAlert(severity: AlertSeverity.info, child: Text(context.t('vaults.new.hideHint'))),
          if (_busy) const LinearProgressIndicator(),
        ],
      ),
      _Actions(
        children: [
          TextButton(
            onPressed: _busy ? null : _reset,
            style: TextButton.styleFrom(foregroundColor: p.text),
            child: Text(context.t('changePw.cancel')),
          ),
          const SizedBox(width: 14),
          PressScale(
            enabled: _canCreate,
            child: FilledButton(onPressed: _canCreate ? () => unawaited(_create()) : null, child: Text(context.t('vaults.new.create'))),
          ),
        ],
      ),
    ];
  }
}

/// The sheet's body: 24 from the sides, 16 between its parts.
class _Content extends StatelessWidget {
  const _Content({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 16, children: children),
  );
}

/// The buttons along the foot of the sheet.
class _Actions extends StatelessWidget {
  const _Actions({required this.children, this.alignment = MainAxisAlignment.end});

  final List<Widget> children;

  /// At the right by default, as MUI's DialogActions put them.
  final MainAxisAlignment alignment;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
    child: Row(mainAxisAlignment: alignment, children: children),
  );
}

/// A switch or checkbox with its label after it, one control to screen
/// readers; tapping the label works it too.
class _LabelledControl extends StatelessWidget {
  const _LabelledControl({required this.label, required this.control, required this.onTap});

  final String label;
  final Widget control;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        children: [
          control,
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: AppType.body1.copyWith(color: context.palette.text)),
          ),
        ],
      ),
    ),
  );
}
