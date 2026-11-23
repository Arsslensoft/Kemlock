import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/public_suffixes.dart';
import '../core/toasts.dart';
import '../crypto/bytes.dart';
import '../crypto/p256.dart';
import '../features/autofill/autofill_copy.dart';
import '../features/backup/two_factor_directory.dart';
import '../features/logins/login_inbox.dart';
import '../features/logins/login_sites.dart';
import '../features/passkeys/passkey_inbox.dart';
import '../features/settings/prefs.dart';
import '../i18n/messages.dart';
import '../models/passkey.dart';
import '../platform/autofill.dart';
import '../vault/vault_controller.dart';

/// Keeps the open vault's autofill copy in step with its accounts and
/// passkeys, as [SyncHost] keeps its sync running (openspec: add-passwords, the code-autofill spec):
/// written on unlock, so an update or a new key catches up, and again
/// whenever they change, whether by the person, an import or what sync
/// merged. It watches the lists rather than the revision, which sync
/// doesn't bump. Codes go in while autofill is on, passkeys while passkeys
/// are, with the vault's inbox key. A vault with both off, or hidden from
/// the lock screen, has its copy removed instead.
class AutofillHost extends ConsumerStatefulWidget {
  const AutofillHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AutofillHost> createState() => _AutofillHostState();
}

class _AutofillHostState extends ConsumerState<AutofillHost> {
  /// What was last handed to the phone, so an unchanged copy isn't written again.
  String? _last;

  /// Writes run one after another, so the last state wins.
  Future<void> _queue = Future.value();

  /// The last write handed the phone an inbox key, so passkeys or saving were on.
  var _inboxHanded = false;

  /// A drain is going, whose own write mustn't start another.
  var _draining = false;

  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    ref.listenManual(vaultControllerProvider, (_, _) => _update(), fireImmediately: true);
    ref.listenManual(prefsProvider, (_, _) => _update());
    // What AutoFill saved while the vault was locked comes in once it is open, and whenever the app comes back
    ref.listenManual(vaultControllerProvider.select((state) => state.session), (_, session) {
      if (session != null) _drainLater();
    }, fireImmediately: true);
    _lifecycle = AppLifecycleListener(onResume: _drainLater);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _update() => _queue = _queue.then((_) => _write()).catchError((Object _) {});

  void _drainLater() => _queue = _queue.then((_) => _drain()).catchError((Object _) {});

  /// Takes what the phone saved for the open vault while it was locked:
  /// opens each inbox file with the vault's inbox key, adds the passkeys it
  /// doesn't hold, takes in the logins and generated passwords
  /// ([VaultController.takeLoginRecords]), writes the copy, and only then
  /// asks the phone to delete the files. A save that fails deletes nothing,
  /// so the files wait for the next try; doing it twice adds nothing twice.
  /// [evenIfOff] drains a vault whose passkeys or saving were just turned off.
  Future<void> _drain({bool evenIfOff = false}) async {
    if (!mounted || _draining) return;
    _draining = true;
    try {
      await _drainNow(evenIfOff: evenIfOff);
    } finally {
      _draining = false;
    }
  }

  Future<void> _drainNow({required bool evenIfOff}) async {
    final state = ref.read(vaultControllerProvider);
    final session = state.session;
    if (session == null || (!evenIfOff && (state.vault.hidden || !_takesInbox(ref.read(prefsProvider))))) return;
    final platform = ref.read(autofillPlatformProvider);
    final vaultId = state.vault.id;
    final files = await platform.readInbox(vaultId);
    if (!mounted) return;
    final controller = ref.read(vaultControllerProvider.notifier);
    // The key a replacement of the vault's key pair left behind, for passkeys made before it
    final previous = await controller.previousPasskeyInbox();
    if (files.isEmpty) {
      if (previous != null && mounted && ref.read(vaultControllerProvider).session == session) await controller.dropPreviousPasskeyInbox();
      return;
    }
    final inbox = await controller.passkeyInbox();
    if (inbox == null) return;
    final opened = <String>[];
    final passkeys = <Passkey>[];
    final logins = <LoginInboxRecord>[];
    var underPrevious = false;
    // A file says when it holds a login, which opens with the login info; any other is a passkey
    Future<void> open(String content, P256KeyPair key) async {
      if (isLoginFile(content)) {
        logins.add(await openLoginRecord(content, key));
      } else {
        passkeys.add((await openInboxRecord(content, key)).toPasskey(newUuid()));
      }
    }

    for (final file in files) {
      try {
        await open(file.content, inbox);
        opened.add(file.name);
      } on InboxFileError {
        if (previous == null) continue; // Not this vault's, or damaged: left where it is
        try {
          await open(file.content, previous);
          opened.add(file.name);
          underPrevious = true;
        } on InboxFileError {
          // Not this vault's under either key, or damaged: left where it is
        }
      }
    }
    if (!mounted || ref.read(vaultControllerProvider).session != session) return;
    // No file waits under the previous key any more: it has done its part
    if (previous != null && !underPrevious) await controller.dropPreviousPasskeyInbox();
    if (opened.isEmpty || !mounted) return;
    final added = passkeys.isEmpty ? 0 : await controller.addPasskeys(passkeys);
    if (added == null || !mounted) return;
    final suffixes = logins.isEmpty ? null : await ref.read(publicSuffixListProvider.future);
    final taken = logins.isEmpty ? (added: 0, updated: 0) : await controller.takeLoginRecords(logins, suffixes: suffixes);
    // A save that failed: the files wait for the next try, which adds nothing twice
    if (taken == null || !mounted) return;
    await _write();
    await platform.clearInbox(vaultId, opened);
    if (!mounted) return;
    final toasts = ref.read(toastsProvider.notifier);
    if (taken.added > 0) {
      toasts.show(context.t('logins.inbox.added', {'count': taken.added}));
    } else if (taken.updated > 0) {
      toasts.show(context.t('logins.inbox.updated', {'count': taken.updated}));
    } else if (added > 0) {
      toasts.show(context.t('passkeys.inbox.added', {'count': added}));
    }
  }

  Future<void> _write() async {
    if (!mounted) return;
    final state = ref.read(vaultControllerProvider);
    if (!state.isUnlocked) return;
    final vault = state.vault;
    // Turned off, or the vault hidden: what the phone made meanwhile comes in before it forgets the inbox key
    if ((!_takesInbox(ref.read(prefsProvider)) || vault.hidden) && _inboxHanded && !_draining) {
      await _drain(evenIfOff: true);
      if (!mounted) return;
    }
    final prefs = ref.read(prefsProvider);
    final platform = ref.read(autofillPlatformProvider);
    if ((!prefs.autofill && !prefs.passkeys && !prefs.passwords) || vault.hidden) {
      final removed = 'removed:${vault.id}';
      if (_last == removed) return;
      _last = removed;
      await platform.removeVault(vault.id);
      _inboxHanded = false;
      return;
    }
    TwoFactorDirectory? directory;
    try {
      directory = await ref.read(twoFactorDirectoryProvider.future);
    } catch (_) {
      // Without the directory, accounts match only by an issuer that is a domain.
    }
    // Without the list (null), a directory domain's parent is found by AutoFill's own rule
    final suffixes = await ref.read(publicSuffixListProvider.future);
    if (!mounted) return;
    // The vault may have changed while the directory loaded; the next update writes that.
    final now = ref.read(vaultControllerProvider);
    if (!now.isUnlocked || now.vault.id != vault.id) return;
    final current = ref.read(prefsProvider);
    // A login's domains count for the account linked to it, so its code is offered on the page after the password
    final linkedDomains = <String, List<String>>{};
    for (final login in now.logins) {
      if (login.accountId case final accountId?) {
        linkedDomains[accountId] = [...?linkedDomains[accountId], ...loginDomains(login, suffixes: suffixes)];
      }
    }
    final entries = current.autofill
        ? autofillEntries(now.accounts, directory: directory, suffixes: suffixes, linkedDomains: linkedDomains)
        : const <AutofillEntry>[];
    final passkeys = current.passkeys ? now.passkeys : const <Passkey>[];
    final logins = current.passwords
        ? [
            for (final login in now.logins)
              AutofillLogin(
                id: login.id,
                name: login.name,
                username: login.username,
                password: login.password,
                domains: loginDomains(login, suffixes: suffixes),
              ),
          ]
        : const <AutofillLogin>[];
    // The inbox key, made when passkeys or saving logins were turned on, lets the phone save new ones
    final inbox = _takesInbox(current) ? await ref.read(vaultControllerProvider.notifier).passkeyInbox() : null;
    if (!mounted) return;
    final copy = jsonEncode(autofillCopy(vault.id, entries, passkeys: passkeys, logins: logins));
    final names = current.autofill && current.autofillNames;
    final index = names || current.passkeys || current.passwords
        ? jsonEncode(autofillIndex(vault.id, names ? entries : const [], passkeys: passkeys, logins: logins))
        : null;
    final inboxKey = inbox == null ? null : b64(inbox.point);
    final takes = VaultTakes(
      passkeys: current.passkeys && inboxKey != null,
      logins: current.passwords && current.passwordSaving && inboxKey != null,
      suggest: current.passwords && current.passwordSuggesting,
    );
    final written = '${vault.id}\n$copy\n$index\n$inboxKey\n$takes';
    if (_last == written) return;
    _last = written;
    try {
      await platform.writeVault(vault.id, copy, index, inboxKey: inboxKey, takes: takes);
      _inboxHanded = inboxKey != null;
    } catch (_) {
      // Written again on the next change or unlock; Settings shows why it can't.
      _last = null;
    }
  }

  /// Whether the phone needs the vault's inbox key: to save passkeys, or logins.
  static bool _takesInbox(Prefs prefs) => prefs.passkeys || (prefs.passwords && prefs.passwordSaving);

  @override
  Widget build(BuildContext context) => widget.child;
}
