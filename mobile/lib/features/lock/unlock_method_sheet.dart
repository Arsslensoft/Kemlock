import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../platform/secret_selection.dart';
import '../../platform/security_keys.dart';
import '../../ui/ui.dart';
import '../../vault/key_unlock.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_registry.dart';
import '../../vault/vault_store.dart';
import '../autofill/autofill_sheet.dart';
import '../breaches/leak_check.dart';
import '../recovery/recovery_kit_sheet.dart';
import '../security_keys/key_widgets.dart';
import '../security_keys/security_key_sheet.dart';
import '../settings/prefs.dart';
import '../spaces/space_policies_provider.dart';
import 'gate_widgets.dart';
import 'key_pin_sheet.dart';
import 'key_reader.dart';
import 'master_password.dart';
import 'password_checks.dart';
import 'replace_key_sheet.dart';

/// How the open vault opens and how many keys it has, read again whenever
/// its config is written (openspec: add-security-key-unlock).
final vaultUnlockProvider = Provider.autoDispose<({UnlockMode mode, int keys})>((ref) {
  final vaults = watchActiveVault(ref);
  watchKeys(ref, [vaults.vaultKey(keyConfig)]);
  final store = ref.watch(vaultStoreProvider);
  return (mode: store.unlockMode(), keys: store.enrolledKeys().length);
});

/// What the phone can reach a security key with, for the sheet to say
/// whether a vault can open with one here.
final keyReachProvider = FutureProvider.autoDispose<SecurityKeyCapabilities>((ref) => ref.watch(keyReaderProvider).capabilities());

/// The name of [mode], as the sheet's choices and the Settings row say it.
String unlockModeLabel(BuildContext context, UnlockMode mode) => context.t('unlockMethod.mode.${mode.name}');

/// The sheet "How this vault opens" (`UnlockMethod.dc.html`, openspec:
/// add-security-key-unlock): the three ways a vault can open, what it has
/// in case the key is lost, its keys, and the steps of a change.
Future<void> showUnlockMethodSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('unlockMethod.title'), builder: (_) => const UnlockMethodSheet());

class UnlockMethodSheet extends ConsumerStatefulWidget {
  const UnlockMethodSheet({super.key});

  @override
  ConsumerState<UnlockMethodSheet> createState() => _UnlockMethodSheetState();
}

class _UnlockMethodSheetState extends ConsumerState<UnlockMethodSheet> {
  late final VaultStore _store = ref.read(vaultStoreProvider);
  late final KeyReader _reader = ref.read(keyReaderProvider);
  late UnlockMode _chosen = _store.unlockMode();

  /// What opens the vault, once given: kept in memory until the sheet
  /// closes, so a second key or the commit takes no further read of the
  /// first key (decision 8).
  OwnerProof? _proof;

  /// The mode Continue stopped short of for want of a kit or second key.
  UnlockMode? _waitingFor;
  var _busy = false;
  String? _message;
  var _severity = AlertSeverity.error;

  /// Choosing "Security key" was refused for a key that is not tied to its
  /// PIN, and "Password and security key" is offered instead.
  var _offerBoth = false;

  /// The mode just turned on, and whether to offer a new key pair.
  UnlockMode? _done;
  var _offerReplacement = false;

  /// A key was removed and others stay, sharing the key secret it wrapped
  /// in copies made before (see [VaultStore.removeKey]): removing every
  /// key, so the keys at hand get a new one, is offered.
  var _offerRestart = false;

  /// Every key was removed that way: a new key pair is offered.
  var _offerPair = false;

  @override
  void dispose() {
    _proof?.wipe();
    super.dispose();
  }

  VaultSession? get _session => ref.read(vaultControllerProvider).session;

  /// Says the message [id] under the sheet's choices.
  void _say(String id, {Map<String, Object?> args = const {}, AlertSeverity severity = AlertSeverity.error}) {
    if (!mounted) return;
    setState(() {
      _message = context.t(id, args);
      _severity = severity;
    });
  }

  KeyUnlockAvailability _availability(SecurityKeyCapabilities? reach) =>
      reach == null ? KeyUnlockAvailability.available : keyUnlockAvailability(reach, iPhoneProven: ref.read(iPhoneKeyExchangeProvider));

  // ─── The pieces a change needs ─────────────────────────────────────────────

  /// What opens the vault now, unless it was given already: its password
  /// when it has one, and an enrolled key when it needs one, or when
  /// [needSecret] asks for the key secret a further key or a key mode needs.
  Future<bool> _ensureProof({required bool needSecret}) async {
    final mode = _store.unlockMode();
    final keys = _store.enrolledKeys();
    final proof = _proof;
    if (proof != null && (!needSecret || keys.isEmpty || proof.keySecret != null)) return true;
    String? password;
    if (mode.hasPassword) {
      password = await _PasswordSheet.show(context);
      if (password == null || !mounted) return false;
    }
    KeyReading? key;
    if (mode.needsKey || (needSecret && keys.isNotEmpty)) {
      key = await _readEnrolledKey();
      if (key == null || !mounted) return false;
    }
    try {
      final next = await _store.proveOwner(password: password, key: key);
      _proof?.wipe();
      _proof = next;
      return true;
    } on IncorrectPasswordError {
      _say('changePw.error.incorrect');
    } on KeyNotEnrolledError {
      _say('lock.key.notThisVault');
    } finally {
      key?.output.fillRange(0, key.output.length, 0);
    }
    return false;
  }

  /// An enrolled key's PIN and the key, for the proof.
  Future<KeyReading?> _readEnrolledKey() async {
    final challenge = _store.keyChallenge();
    final prompts = keyPrompts(context);
    final output = await showKeyPinSheet<KeyOutput>(
      context,
      reader: _reader,
      title: context.t('unlockMethod.prove.key.title'),
      body: context.t('unlockMethod.prove.key.body'),
      read: (pin, lastTry) =>
          _reader.read(pin: pin, salt: challenge.salt, allow: challenge.credentials, prompts: prompts, lastTryConfirmed: lastTry),
    );
    return output == null ? null : (credential: output.credential, output: output.output);
  }

  /// A key presented now, made one of the vault's: its credential made,
  /// its secret read twice, and its wrap of the key secret written.
  Future<bool> _enrolKey() async {
    final session = _session;
    final proof = _proof;
    if (session == null || proof == null) return false;
    final challenge = _store.keyChallenge();
    final prompts = keyPrompts(context);
    final enrolment = await showKeyPinSheet<KeyEnrolment>(
      context,
      reader: _reader,
      title: context.t('unlockMethod.enrol.title'),
      body: context.t('unlockMethod.enrol.body'),
      enrolling: true,
      onSetPin: () => unawaited(showSecurityKeySheet(context)),
      read: (pin, lastTry) =>
          _reader.enrol(pin: pin, salt: challenge.salt, exclude: challenge.credentials, prompts: prompts, lastTryConfirmed: lastTry),
    );
    if (enrolment == null || !mounted) return false;
    try {
      final next = await _store.enrolKey(
        session,
        proof,
        salt: challenge.salt,
        credential: enrolment.credential,
        output: enrolment.output,
        name: _freeName(enrolment.productName ?? context.t('securityKeys.model.unknown')),
        pinBound: enrolment.pinBound,
      );
      proof.wipe();
      _proof = next;
      return true;
    } on KeyAlreadyEnrolledError {
      _say('unlockMethod.key.already');
    } finally {
      enrolment.wipe();
    }
    return false;
  }

  /// [name], or with a number after it when a key has that name already.
  String _freeName(String name) {
    final taken = {for (final key in _store.enrolledKeys()) key.name};
    if (!taken.contains(name)) return name;
    for (var n = 2; ; n++) {
      if (!taken.contains('$name $n')) return '$name $n';
    }
  }

  // ─── The actions ───────────────────────────────────────────────────────────

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _offerBoth = false;
      _offerRestart = false;
      _offerPair = false;
    });
    try {
      await action();
    } catch (_) {
      _say('setup.error.failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Continue: what opens the vault now, a first key when the new way
  /// needs one and the vault has none, and the change.
  Future<void> _continue() => _run(() async {
    final target = _chosen;
    if (target == _store.unlockMode()) return;
    if (!await _ensureProof(needSecret: target.needsKey)) return;
    if (target.needsKey && _store.enrolledKeys().isEmpty && !await _enrolKey()) return;
    await _commit(target);
  });

  /// "Add" beside the second key: a further key, and the change Continue
  /// stopped short of, if any.
  Future<void> _addKey() => _run(() async {
    if (!await _ensureProof(needSecret: true)) return;
    if (!await _enrolKey()) return;
    if (_waitingFor case final target?) {
      await _commit(target);
    } else {
      _say('unlockMethod.added', severity: AlertSeverity.success);
    }
  });

  Future<void> _commit(UnlockMode target) async {
    final session = _session;
    final current = _store.unlockMode();
    if (session == null || _proof == null) return;
    switch (_store.unlockModeRefusal(target)) {
      case SafetyNetError():
        _waitingFor = target;
        return _say('unlockMethod.missing', severity: AlertSeverity.warning);
      case KeyNotPinBoundError():
        _say('unlockMethod.notPinBound', severity: AlertSeverity.warning);
        if (mounted) setState(() => _offerBoth = true);
        return;
      case HiddenVaultKeyOnlyError():
        return _say('unlockMethod.hiddenKeyOnly');
      case final Exception refusal:
        throw refusal;
      case null:
        break;
    }
    String? newPassword;
    if (target.hasPassword && !current.hasPassword) {
      newPassword = await _NewPasswordSheet.show(context);
      if (newPassword == null || !mounted) return;
    }
    try {
      final proof = _proof!;
      Future<OwnerProof> change() => _store.setUnlockMode(session, proof, target, newPassword: newPassword);
      // A new password is checked against every vault's first: that check is counted, as a try on the lock screen is
      final next = await (newPassword == null ? change() : countedPasswordCheck(ref, change));
      _proof?.wipe();
      _proof = next;
    } on PasswordInUseError {
      return _say('vaults.error.passwordInUse');
    }
    _waitingFor = null;
    if (!mounted) return;
    setState(() {
      _done = target;
      _offerReplacement = target.needsKey && !current.needsKey;
    });
  }

  Future<void> _check(EnrolledKey key) => _run(() async {
    final challenge = _store.keyChallenge();
    final prompts = keyPrompts(context);
    final output = await showKeyPinSheet<KeyOutput>(
      context,
      reader: _reader,
      title: context.t('unlockMethod.check.title'),
      body: context.t('unlockMethod.check.body', {'name': key.name}),
      read: (pin, lastTry) =>
          _reader.read(pin: pin, salt: challenge.salt, allow: [key.credential], prompts: prompts, lastTryConfirmed: lastTry),
    );
    if (output == null || !mounted) return;
    try {
      final opens = await _store.checkKey((credential: output.credential, output: output.output));
      if (!mounted) return;
      if (opens) {
        _say('unlockMethod.check.opens', args: {'name': key.name}, severity: AlertSeverity.success);
      } else {
        _say('lock.key.notThisVault');
      }
    } finally {
      output.wipe();
    }
  });

  Future<void> _rename(EnrolledKey key) => _run(() async {
    final name = await _NameDialog.show(context, key.name);
    if (name == null || name.trim().isEmpty || !mounted) return;
    if (!await _ensureProof(needSecret: false)) return;
    final session = _session;
    if (session == null) return;
    await _store.renameKey(session, _proof!, key.id, name);
  });

  Future<void> _remove(EnrolledKey key) => _run(() async {
    // The rule is said before anything is asked
    switch (_store.removeKeyRefusal(key.id)) {
      case LastKeyError():
        return _say('unlockMethod.refusal.lastKey');
      case SafetyNetError():
        return _say('unlockMethod.refusal.safetyNet');
      case final Exception refusal:
        throw refusal;
      case null:
        break;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('unlockMethod.remove.title'),
      body: Text(context.t('unlockMethod.remove.body', {'name': key.name})),
      cancelLabel: context.t('export.cancel'),
      confirmLabel: context.t('unlockMethod.remove.confirm'),
    );
    if (!confirmed || !mounted) return;
    if (!await _ensureProof(needSecret: false)) return;
    final session = _session;
    if (session == null) return;
    await _store.removeKey(session, _proof!, key.id);
    if (_store.enrolledKeys().isEmpty) {
      // The key secret went with the last key: a key added later gets a new one
      _say('unlockMethod.removed', args: {'name': key.name}, severity: AlertSeverity.success);
      return;
    }
    _say('unlockMethod.removed.shared', args: {'name': key.name}, severity: AlertSeverity.warning);
    if (mounted) setState(() => _offerRestart = true);
  });

  /// Removes every key, the sure way after a lost one: the keys still at
  /// hand are then added again and share a new key secret. A vault that
  /// needs a key opens with its password first, since its last key can't
  /// go otherwise, and that way stays chosen for Continue to turn on again.
  Future<void> _removeEveryKey() => _run(() async {
    final before = _store.unlockMode();
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.warning_amber_rounded),
      title: context.t('unlockMethod.restart.title'),
      body: Text(context.t(before.needsKey && !before.hasPassword ? 'unlockMethod.restart.body.key' : 'unlockMethod.restart.body')),
      cancelLabel: context.t('export.cancel'),
      confirmLabel: context.t('unlockMethod.restart.confirm'),
      danger: true,
    );
    if (!confirmed || !mounted) return;
    if (!await _ensureProof(needSecret: false) || !mounted) return;
    final session = _session;
    if (session == null) return;
    if (before.needsKey) {
      String? newPassword;
      if (!before.hasPassword) {
        newPassword = await _NewPasswordSheet.show(context);
        if (newPassword == null || !mounted) return;
      }
      try {
        final next = await _store.setUnlockMode(session, _proof!, UnlockMode.password, newPassword: newPassword);
        _proof?.wipe();
        _proof = next;
      } on PasswordInUseError {
        return _say('vaults.error.passwordInUse');
      }
    }
    for (final key in _store.enrolledKeys()) {
      await _store.removeKey(session, _proof!, key.id);
    }
    if (!mounted) return;
    _say(before.needsKey ? 'unlockMethod.restart.done.mode' : 'unlockMethod.restart.done', severity: AlertSeverity.success);
    setState(() {
      _chosen = before;
      _offerPair = true;
    });
  });

  // ─── The sheet ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    // Read again whenever the config is written: keys added, renamed or removed, the mode changed
    ref.watch(vaultUnlockProvider);
    final hidden = ref.watch(vaultControllerProvider.select((state) => state.vault.hidden));
    final reach = ref.watch(keyReachProvider).value;
    final availability = _availability(reach);
    final current = _store.unlockMode();
    final keys = _store.enrolledKeys();
    final kit = _store.recoveryKitInfo();
    final prefs = ref.watch(prefsProvider);
    final locale = Localizations.localeOf(context).toLanguageTag();
    String date(DateTime at) => DateFormat.MMMd(locale).format(at.toLocal());

    if (_done case final done?) return _doneView(context, done);

    final keyModesOpen = availability == KeyUnlockAvailability.available;
    final unavailable = switch (availability) {
      KeyUnlockAvailability.available => null,
      KeyUnlockAvailability.notOnIPhoneYet => context.t('unlockMethod.unavailable.iphone'),
      KeyUnlockAvailability.noKeyReachable =>
        reach?.readsOnRequest ?? false ? context.t('unlockMethod.unavailable.ipad') : context.t('securityKeys.wait.none'),
    };
    bool selectable(UnlockMode mode) =>
        !_busy && (mode == current || !mode.needsKey || keyModesOpen) && !(mode == UnlockMode.key && hidden && current != mode);
    final kitMade = kit == null ? null : DateTime.tryParse(kit.createdAt);

    Widget choice(UnlockMode mode, {required bool first}) => GroupRow(
      first: first,
      primary: unlockModeLabel(context, mode),
      secondary: context.t('unlockMethod.mode.${mode.name}.detail'),
      muted: !selectable(mode),
      onTap: selectable(mode) ? () => setState(() => _chosen = mode) : null,
      tag: _Radio(selected: _chosen == mode, enabled: selectable(mode)),
    );

    return PopScope(
      canPop: !_busy,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KeySheetHeader(title: context.t('unlockMethod.title')),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    container: true,
                    explicitChildNodes: true,
                    child: GroupCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [for (final (index, mode) in UnlockMode.values.indexed) choice(mode, first: index == 0)],
                      ),
                    ),
                  ),
                  if (unavailable != null) ...[
                    const SizedBox(height: 12),
                    AppAlert(severity: AlertSeverity.info, child: Text(unavailable)),
                  ],
                  if (hidden && current != UnlockMode.key) ...[
                    const SizedBox(height: 12),
                    Text(context.t('unlockMethod.hiddenKeyOnly'), style: AppType.caption.copyWith(color: p.textSecondary)),
                  ],
                  SectionLabel(context.t('unlockMethod.lose')),
                  GroupCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        GroupRow(
                          first: true,
                          accent: kit != null,
                          icon: Icon(kit != null ? Icons.check_rounded : Icons.add_rounded),
                          primary: context.t('recovery.kit.title'),
                          secondary: kitMade == null
                              ? context.t('unlockMethod.kit.none')
                              : context.t('unlockMethod.kit.made', {'date': date(kitMade)}),
                          onTap: _busy ? null : () => unawaited(showRecoveryKitSheet(context)),
                        ),
                        GroupRow(
                          accent: keys.length >= 2,
                          icon: Icon(keys.length >= 2 ? Icons.check_rounded : Icons.add_rounded),
                          primary: context.t('unlockMethod.second'),
                          secondary: keys.length >= 2 ? keys[1].name : context.t('unlockMethod.second.none'),
                          control: TextButton(
                            onPressed: _busy || !keyModesOpen ? null : _addKey,
                            style: TextButton.styleFrom(foregroundColor: b.accentText),
                            child: Text(context.t('unlockMethod.add')),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
                    child: Text(context.t('unlockMethod.note'), style: AppType.caption.copyWith(color: p.textSecondary)),
                  ),
                  if (keys.isNotEmpty) ...[
                    SectionLabel(context.t('unlockMethod.keys')),
                    GroupCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (index, key) in keys.indexed)
                            GroupRow(
                              first: index == 0,
                              icon: const Icon(Icons.key_rounded),
                              primary: key.name,
                              secondary: context.t('unlockMethod.keys.added', {
                                'date': date(DateTime.fromMillisecondsSinceEpoch(key.addedAt)),
                              }),
                              control: _KeyActions(
                                name: key.name,
                                enabled: !_busy,
                                canCheck: keyModesOpen,
                                onCheck: () => _check(key),
                                onRename: () => _rename(key),
                                onRemove: () => _remove(key),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (_chosen.needsKey && !current.needsKey && _store.hasBiometricUnlock()) ...[
                    const SizedBox(height: 14),
                    AppAlert(severity: AlertSeverity.info, child: Text(context.t('unlockMethod.biometric'))),
                  ],
                  if (_chosen.needsKey && prefs.autofill && !hidden) ...[
                    const SizedBox(height: 14),
                    AppAlert(
                      severity: AlertSeverity.info,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(context.t('unlockMethod.autofill')),
                          TextButton(onPressed: () => unawaited(showAutofillSheet(context)), child: Text(context.t('settings.autofill'))),
                        ],
                      ),
                    ),
                  ],
                  if (reach != null && reach.readsOnRequest && reach.nfc) ...[
                    const SizedBox(height: 14),
                    AppAlert(severity: AlertSeverity.info, child: Text(context.t('unlockMethod.iphone'))),
                  ],
                  if (_message case final message?) ...[
                    const SizedBox(height: 14),
                    AppAlert(
                      severity: _severity,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(message),
                          if (_offerBoth)
                            TextButton(
                              onPressed: () => setState(() {
                                _chosen = UnlockMode.both;
                                _offerBoth = false;
                                _message = null;
                              }),
                              child: Text(context.t('unlockMethod.useBoth')),
                            ),
                          if (_offerRestart)
                            TextButton(onPressed: _busy ? null : _removeEveryKey, child: Text(context.t('unlockMethod.restart'))),
                          if (_offerPair)
                            TextButton(
                              onPressed: _busy ? null : () => unawaited(showReplaceKeySheet(context)),
                              child: Text(context.t('unlockMethod.replace.button')),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    style: largeButtonStyle,
                    onPressed: _busy || _chosen == current ? null : _continue,
                    child: Text(context.t('unlockMethod.continue.key')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// After a change: what the vault opens with now, and, for a way that
  /// needs the key, the offer of a new key pair (design, Risks).
  Widget _doneView(BuildContext context, UnlockMode done) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('unlockMethod.title')),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 14,
            children: [
              AppAlert(severity: AlertSeverity.success, child: Text(context.t('unlockMethod.done.${done.name}'))),
              if (_offerReplacement)
                Text(context.t('unlockMethod.replace.body'), style: AppType.body2.copyWith(color: context.palette.textSecondary)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 14,
            runSpacing: 8,
            children: [
              if (_offerReplacement) ...[
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: context.palette.text),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.t('replaceKey.notNow')),
                ),
                FilledButton(
                  onPressed: () async {
                    await showReplaceKeySheet(context);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: Text(context.t('unlockMethod.replace.button')),
                ),
              ] else
                FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('enableBiometric.done'))),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The radio of a choice row, whose row is the button; it says to a screen
/// reader which choice is marked, as the vault picker's chips do.
class _Radio extends StatelessWidget {
  const _Radio({required this.selected, required this.enabled});

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      child: AnimatedContainer(
        duration: Motion.reduced(context) ? Duration.zero : Motion.colour,
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: selected ? p.primary : b.line2, width: selected ? 6.5 : 1.5),
        ),
      ),
    );
  }
}

/// Check, Rename and Remove for one enrolled key.
class _KeyActions extends StatelessWidget {
  const _KeyActions({
    required this.name,
    required this.enabled,
    required this.canCheck,
    required this.onCheck,
    required this.onRename,
    required this.onRemove,
  });

  final String name;
  final bool enabled;
  final bool canCheck;
  final VoidCallback onCheck;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => PopupMenuButton<VoidCallback>(
    enabled: enabled,
    tooltip: context.t('unlockMethod.keys.actions', {'name': name}),
    icon: const Icon(Icons.more_horiz_rounded),
    onSelected: (action) => action(),
    itemBuilder: (context) => [
      PopupMenuItem(value: onCheck, enabled: canCheck, child: Text(context.t('unlockMethod.keys.check'))),
      PopupMenuItem(value: onRename, child: Text(context.t('unlockMethod.keys.rename'))),
      PopupMenuItem(value: onRemove, child: Text(context.t('unlockMethod.keys.remove'))),
    ],
  );
}

/// The vault's master password, for the proof of a vault that has one.
class _PasswordSheet extends StatefulWidget {
  const _PasswordSheet();

  static Future<String?> show(BuildContext context) =>
      showAppBottomSheet<String>(context, label: context.t('unlockMethod.prove.password.title'), builder: (_) => const _PasswordSheet());

  @override
  State<_PasswordSheet> createState() => _PasswordSheetState();
}

class _PasswordSheetState extends State<_PasswordSheet> {
  final _password = TextEditingController();
  var _show = false;

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

  void _submit() {
    if (_password.text.isNotEmpty) Navigator.of(context).pop(_password.text);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeySheetHeader(title: context.t('unlockMethod.prove.password.title')),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 14,
              children: [
                Text(context.t('unlockMethod.prove.password.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                // Shown and copied, the password goes through the secret clipboard
                SecretSelection(
                  child: TextField(
                    controller: _password,
                    autofocus: true,
                    obscureText: !_show,
                    autocorrect: false,
                    enableSuggestions: false,
                    // Null, not the empty default: the phone's password manager neither fills nor saves it
                    autofillHints: null,
                    enableIMEPersonalizedLearning: false,
                    contextMenuBuilder: secretTextMenu,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: context.t('unlock.field.password'),
                      suffixIcon: RevealPasswordButton(shown: _show, onPressed: () => setState(() => _show = !_show)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 14,
              children: [
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: p.text),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.t('export.cancel')),
                ),
                FilledButton(onPressed: _password.text.isEmpty ? null : _submit, child: Text(context.t('unlockMethod.continue'))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A new master password for a vault that opened with its key alone, with
/// the change-password sheet's rules: 12 characters or more, typed twice,
/// and the leak check when it is on.
class _NewPasswordSheet extends ConsumerStatefulWidget {
  const _NewPasswordSheet();

  static Future<String?> show(BuildContext context) =>
      showAppBottomSheet<String>(context, label: context.t('unlockMethod.newPassword.title'), builder: (_) => const _NewPasswordSheet());

  @override
  ConsumerState<_NewPasswordSheet> createState() => _NewPasswordSheetState();
}

class _NewPasswordSheetState extends ConsumerState<_NewPasswordSheet> with LeakChecking {
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final field in [_next, _confirm]) {
      field.addListener(() => setState(() => leakPasswordEdited(_next.text)));
    }
    leakCheckOn = ref.read(prefsProvider).leakCheck;
  }

  @override
  void dispose() {
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _mismatch => _confirm.text.isNotEmpty && _next.text != _confirm.text;

  Future<void> _submit({bool unchecked = false}) async {
    final next = _next.text;
    if (next.isEmpty || leakChecking) return;
    if (next != _confirm.text) return setState(() => _error = context.t('changePw.error.mismatch'));
    if (!masterPasswordLongEnough(next)) return setState(() => _error = context.t('changePw.error.tooShort'));
    // A space the member belongs to may ask for a longer one than the vault's own minimum
    final short = ref.read(spacePoliciesProvider).shortfallsOf(next);
    if (short.isNotEmpty) {
      return setState(() => _error = context.t('changePw.error.space', {'space': short.first.label, 'length': short.first.minimum}));
    }
    setState(() => _error = null);
    if (!await passesLeakCheck(next, skip: unchecked)) return;
    if (mounted && next == _next.text) Navigator.of(context).pop(next);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeySheetHeader(title: context.t('unlockMethod.newPassword.title')),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 14,
              children: [
                Text(context.t('unlockMethod.newPassword.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                if (_error case final error?) AppAlert(severity: AlertSeverity.error, child: Text(error)),
                TextField(
                  controller: _next,
                  autofocus: true,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  // Null, not the empty default: the phone's password manager neither fills nor saves them
                  autofillHints: null,
                  enableIMEPersonalizedLearning: false,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(labelText: context.t('changePw.field.new')),
                ),
                TextField(
                  controller: _confirm,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: null,
                  enableIMEPersonalizedLearning: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: context.t('changePw.field.confirm'),
                    helperText: ' ',
                    errorText: _mismatch ? context.t('changePw.field.mismatch') : null,
                  ),
                ),
                LeakCheckOption(
                  value: leakCheckOn,
                  onChanged: leakChecking
                      ? null
                      : (on) {
                          ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(leakCheck: on));
                          setState(() {
                            leakCheckOn = on;
                            if (!on) leakFinding = null;
                          });
                        },
                ),
                if (leakNotice case final finding?)
                  LeakFindingNotice(finding: finding, onUseAnyway: () => _submit(unchecked: true), onRetry: _submit),
                if (leakChecking) const LinearProgressIndicator(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 14,
              children: [
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: p.text),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.t('export.cancel')),
                ),
                FilledButton(
                  onPressed: _next.text.isEmpty || _confirm.text.isEmpty || _mismatch || leakChecking ? null : _submit,
                  child: Text(context.t('unlockMethod.continue')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A new name for an enrolled key.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.name});

  final String name;

  static Future<String?> show(BuildContext context, String name) => showAppDialog<String>(context, builder: (_) => _NameDialog(name: name));

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.t('unlockMethod.rename.title')),
    content: TextField(
      controller: _name,
      autofocus: true,
      maxLength: 40,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => Navigator.of(context).pop(_name.text),
      decoration: InputDecoration(labelText: context.t('unlockMethod.rename.field')),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('export.cancel'))),
      FilledButton(onPressed: () => Navigator.of(context).pop(_name.text), child: Text(context.t('unlockMethod.rename.save'))),
    ],
  );
}

/// The Security key sheet's row "Open the vault with this key", in a group
/// of its own (`SecurityKey.dc.html`): whether the open vault has keys,
/// and the way into "How this vault opens". It says nothing of whether the
/// key connected is one of them, which only an exchange with its PIN could.
class VaultKeysGroup extends ConsumerWidget {
  const VaultKeysGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(vaultControllerProvider.select((state) => !state.isUnlocked))) return const SizedBox.shrink();
    final keys = ref.watch(vaultUnlockProvider).keys;
    return Group(
      label: context.t('unlockMethod.securityKey.section'),
      children: [
        GroupRow(
          first: true,
          primary: context.t('unlockMethod.securityKey.row'),
          secondary: keys == 0
              ? context.t('unlockMethod.securityKey.notSetUp')
              : context.t('unlockMethod.securityKey.count', {'count': keys}),
          value: keys == 0 ? Text(context.t('unlockMethod.securityKey.setUp')) : null,
          onTap: () => unawaited(showUnlockMethodSheet(context)),
        ),
      ],
    );
  }
}

/// The line the Security key sheet's reset warning gains while the open
/// vault has keys: a key that is one of them stops opening it.
class VaultKeysResetLine extends ConsumerWidget {
  const VaultKeysResetLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(vaultControllerProvider.select((state) => !state.isUnlocked)) || ref.watch(vaultUnlockProvider).keys == 0) {
      return const SizedBox.shrink();
    }
    return Padding(padding: const EdgeInsets.only(top: 8), child: Text(context.t('unlockMethod.securityKey.reset')));
  }
}
