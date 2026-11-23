/// The account sheet's Vaultwarden part, in plain storage: the user's own
/// login an account's code is in (its name, username, password and
/// website, the password decrypted only when shown or copied, and a link to
/// it in the web vault), linking an account to such a login, and giving the
/// code its own login again.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../i18n/messages.dart';
import '../../../models/otp_account.dart';
import '../../../platform/links.dart';
import '../../../platform/network.dart';
import '../../../platform/secret_clipboard.dart';
import '../../../ui/ui.dart';
import '../../../vault/key_unlock.dart';
import '../../../vault/vault_controller.dart';
import '../../../vault/vault_providers.dart';
import '../../lock/key_pin_sheet.dart';
import '../../settings/offline_alert.dart';
import '../sync.dart';
import '../sync_store.dart';
import 'vw_api.dart';
import 'vw_backend.dart';
import 'vw_models.dart';

/// The user's own login that holds an account's code, from the last sync;
/// null outside plain Vaultwarden storage or when it's in no such login.
final vwLinkedLoginProvider = FutureProvider.autoDispose.family<VwLinkedLogin?, String>((ref, accountId) async {
  final target = ref.watch(syncProvider.select((sync) => sync.settings?.vaultwarden));
  // Read again after each sync
  ref.watch(syncProvider.select((sync) => sync.status[vaultwardenScope]?.lastSyncAt));
  final session = ref.watch(vaultControllerProvider.select((state) => state.session));
  if (target == null || target.mode != VaultwardenMode.plain || session == null) return null;
  final backend = VaultwardenBackend(vault: ref.read(vaultStoreProvider), session: session, clientFor: ref.read(vwClientFactoryProvider));
  return backend.linkedLogin(accountId);
});

/// The Vaultwarden section of an account's sheet, when the vault keeps its
/// codes plain in Vaultwarden.
class VaultwardenLoginPanel extends ConsumerStatefulWidget {
  const VaultwardenLoginPanel({super.key, required this.account});

  final OtpAccount account;

  @override
  ConsumerState<VaultwardenLoginPanel> createState() => _VaultwardenLoginPanelState();
}

class _VaultwardenLoginPanelState extends ConsumerState<VaultwardenLoginPanel> {
  String? _password;
  var _busy = false;
  String? _message;

  VaultwardenBackend _backend() => VaultwardenBackend(
    vault: ref.read(vaultStoreProvider),
    session: ref.read(vaultControllerProvider).session!,
    clientFor: ref.read(vwClientFactoryProvider),
    clock: ref.read(clockProvider),
  );

  /// Asks for the vault's password when the login has Bitwarden's re-prompt
  /// on, and for its security key too, or its key alone, when the vault
  /// needs one (openspec: add-security-key-unlock, decision 9).
  Future<bool> _confirmed(VwLinkedLogin login) async {
    if (!login.reprompt) return true;
    final keyOnly = ref.read(vaultStoreProvider).unlockMode() == UnlockMode.key;
    final password = keyOnly ? null : await showAppDialog<String>(context, builder: (context) => const _RepromptDialog());
    if ((password == null && !keyOnly) || !mounted) return false;
    try {
      final proof = await proveOwnerWithKey(context, ref, password: password);
      proof?.wipe();
      return proof != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _togglePassword(VwLinkedLogin login) async {
    if (_password != null) {
      setState(() => _password = null);
      return;
    }
    if (!await _confirmed(login)) return;
    final password = await login.password();
    if (mounted) setState(() => _password = password);
  }

  Future<void> _copy(String text) async {
    if (await ref.read(secretClipboardProvider).copy(text) && mounted) {
      setState(() => _message = context.t('vaultwarden.login.copied'));
    }
  }

  Future<void> _copyPassword(VwLinkedLogin login) async {
    if (!await _confirmed(login)) return;
    final password = await login.password();
    if (password != null) await _copy(password);
  }

  Future<void> _run(Future<void> Function(VaultwardenBackend backend, VaultwardenTarget target) action, String done) async {
    final target = ref.read(syncProvider).settings?.vaultwarden;
    if (target == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final backend = _backend();
    try {
      await action(backend, target);
      ref.read(syncProvider.notifier).requestSync();
      if (mounted) setState(() => _message = done);
    } catch (_) {
      if (mounted) setState(() => _message = context.t('vaultwarden.link.failed'));
    } finally {
      backend.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _link() async {
    final target = ref.read(syncProvider).settings?.vaultwarden;
    if (target == null) return;
    final chosen = await showAppBottomSheet<VwLoginChoice>(
      context,
      label: context.t('vaultwarden.link'),
      builder: (context) => _LinkSheet(target: target),
    );
    if (chosen == null || !mounted) return;
    await _run(
      (backend, target) => backend.link(target, widget.account, chosen.cipherId),
      context.t('vaultwarden.link.done', {'name': chosen.name}),
    );
  }

  Future<void> _unlink() => _run((backend, target) => backend.unlink(target, widget.account), context.t('vaultwarden.unlink'));

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final target = ref.watch(syncProvider.select((sync) => sync.settings?.vaultwarden));
    if (target == null || target.mode != VaultwardenMode.plain || widget.account.spaceId != null) return const SizedBox.shrink();
    final login = ref.watch(vwLinkedLoginProvider(widget.account.id)).value;
    // Linking and unlinking write to the server, so both wait while offline mode is on
    final offline = ref.watch(offlineProvider);
    final children = <Widget>[];
    if (login == null) {
      if (widget.account.kind != OtpType.hotp) {
        children.add(
          TextButton.icon(
            onPressed: _busy || offline ? null : _link,
            icon: const Icon(Icons.link_rounded, size: 20),
            label: Text(context.t('vaultwarden.link')),
          ),
        );
      }
    } else {
      final mono = AppType.mono(fontSize: 13.5, color: p.text);
      children.addAll([
        Text(context.t('vaultwarden.login.title'), style: AppType.subtitle2.copyWith(color: p.textSecondary)),
        Text(login.name, style: AppType.subtitle1.copyWith(color: p.text)),
        if (login.username case final username? when username.isNotEmpty)
          _Row(
            label: context.t('vaultwarden.login.username'),
            value: Text(username, style: AppType.body2.copyWith(color: p.text)),
            actions: [
              _IconAction(icon: Icons.content_copy_rounded, label: context.t('vaultwarden.login.copy'), onTap: () => _copy(username)),
            ],
          ),
        if (login.hasPassword)
          _Row(
            label: context.t('vaultwarden.login.password'),
            value: Text(_password ?? '••••••••', style: mono),
            actions: [
              _IconAction(
                icon: _password == null ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                label: context.t(_password == null ? 'vaultwarden.login.show' : 'vaultwarden.login.hide'),
                onTap: () => _togglePassword(login),
              ),
              _IconAction(icon: Icons.content_copy_rounded, label: context.t('vaultwarden.login.copy'), onTap: () => _copyPassword(login)),
            ],
          ),
        if (login.website case final website? when website.isNotEmpty)
          _Row(
            label: context.t('vaultwarden.login.website'),
            value: Text(
              website,
              style: AppType.body2.copyWith(color: p.text),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              onPressed: () => unawaited(ref.read(linkOpenerProvider).open(context, vwWebVaultItem(target.server, login.cipherId))),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text(context.t('vaultwarden.login.open')),
            ),
            TextButton(onPressed: _busy || offline ? null : _unlink, child: Text(context.t('vaultwarden.unlink'))),
          ],
        ),
      ]);
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(color: b.raised, borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 6,
            children: [
              ...children,
              if (offline) Text(context.t('sync.offline'), style: AppType.caption.copyWith(color: p.textSecondary)),
              if (_busy) const LinearProgressIndicator(),
              if (_message case final message?)
                Semantics(
                  liveRegion: true,
                  child: Text(message, style: AppType.caption.copyWith(color: p.textSecondary)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks for the vault's password before a re-prompting login's password
/// shows; pops what was typed, or null.
class _RepromptDialog extends StatefulWidget {
  const _RepromptDialog();

  @override
  State<_RepromptDialog> createState() => _RepromptDialogState();
}

class _RepromptDialogState extends State<_RepromptDialog> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AppDialog(
      semanticLabel: context.t('vaultwarden.login.password'),
      heading: DialogHeading(title: context.t('vaultwarden.login.password')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text(context.t('vaultwarden.login.reprompt'), style: AppType.body2.copyWith(color: p.textSecondary)),
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: _password,
            obscureText: true,
            autofocus: true,
            onSubmitted: (text) => Navigator.of(context).pop(text),
            decoration: InputDecoration(labelText: context.t('unlock.field.password')),
          ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: p.text),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('changePw.cancel')),
        ),
        FilledButton(onPressed: () => Navigator.of(context).pop(_password.text), child: Text(context.t('vaultwarden.continue'))),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.actions = const []});

  final String label;
  final Widget value;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(label, style: AppType.body2.copyWith(color: context.palette.textSecondary)),
        ),
        Expanded(child: value),
        ...actions,
      ],
    ),
  );
}

class _IconAction extends StatelessWidget {
  const _IconAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(tooltip: label, onPressed: onTap, icon: Icon(icon, size: 20));
}

/// Picks one of the user's logins to put an account's code in; pops it.
class _LinkSheet extends ConsumerStatefulWidget {
  const _LinkSheet({required this.target});

  final VaultwardenTarget target;

  @override
  ConsumerState<_LinkSheet> createState() => _LinkSheetState();
}

class _LinkSheetState extends ConsumerState<_LinkSheet> {
  final _search = TextEditingController();
  List<VwLoginChoice>? _logins;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null || ref.read(offlineProvider)) return;
    final backend = VaultwardenBackend(vault: ref.read(vaultStoreProvider), session: session, clientFor: ref.read(vwClientFactoryProvider));
    try {
      final logins = await backend.loginsToLink(widget.target);
      if (mounted) setState(() => _logins = logins);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      backend.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final query = _search.text.trim().toLowerCase();
    final logins = [
      for (final login in _logins ?? const <VwLoginChoice>[])
        if (query.isEmpty || '${login.name} ${login.username ?? ''} ${login.website ?? ''}'.toLowerCase().contains(query)) login,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.link_rounded), title: context.t('vaultwarden.link')),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: TextField(
            enableIMEPersonalizedLearning: false,
            controller: _search,
            decoration: InputDecoration(labelText: context.t('vaultwarden.link.search'), prefixIcon: const Icon(Icons.search_rounded)),
          ),
        ),
        if (ref.watch(offlineProvider))
          Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), child: OfflineAlert(context.t('sync.offline')))
        else if (_failed)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: AppAlert(severity: AlertSeverity.error, child: Text(context.t('vaultwarden.problem.network'))),
          )
        else if (_logins == null)
          const Padding(padding: EdgeInsets.fromLTRB(24, 8, 24, 24), child: LinearProgressIndicator())
        else if (logins.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Text(context.t('vaultwarden.link.none'), style: AppType.body2.copyWith(color: p.textSecondary)),
          )
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              children: [
                for (final login in logins)
                  ListTile(
                    leading: const Icon(Icons.vpn_key_outlined),
                    title: Text(login.name, style: AppType.body1.copyWith(color: p.text)),
                    subtitle: Text(
                      [?login.username, ?login.website].where((part) => part.isNotEmpty).join(' · '),
                      style: AppType.caption.copyWith(color: p.textSecondary),
                    ),
                    onTap: () => Navigator.of(context).pop(login),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
