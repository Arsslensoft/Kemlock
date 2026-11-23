import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/autofill.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../settings/auto_lock.dart';
import '../settings/prefs.dart';

/// Where autofill stands on this phone, asked again whenever it's read
/// afresh: the sheet invalidates it when the app comes back from the
/// phone's settings.
final autofillStatusProvider = FutureProvider.autoDispose<AutofillStatus>((ref) => ref.watch(autofillPlatformProvider).status());

/// Whether the phone takes passkeys from Kemlock, asked again as [autofillStatusProvider] is.
final passkeyStatusProvider = FutureProvider.autoDispose<PasskeyStatus>((ref) => ref.watch(autofillPlatformProvider).passkeyStatus());

bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;

/// Filling the open vault's codes into other apps and websites
/// (openspec: add-passwords, the code-autofill spec): whether this vault's codes are filled,
/// whether suggestions name the service, and whether the phone fills
/// from Kemlock at all, with the way to turn that on, and on Android
/// Chrome's own setting. A hidden vault can't use it, and a phone too
/// old for it says so.
Future<void> showAutofillSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('autofill.title'), builder: (_) => const _AutofillSheet());

class _AutofillSheet extends ConsumerStatefulWidget {
  const _AutofillSheet();

  @override
  ConsumerState<_AutofillSheet> createState() => _AutofillSheetState();
}

class _AutofillSheetState extends ConsumerState<_AutofillSheet> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Back from the phone's settings, where it may have been turned on or off.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        ref.invalidate(autofillStatusProvider);
        ref.invalidate(passkeyStatusProvider);
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Asks the phone to fill from Kemlock, holding auto-lock while its prompt or settings are up.
  Future<void> _turnOn() async {
    final platform = ref.read(autofillPlatformProvider);
    await ref.read(autoLockHoldsProvider).withHeld(platform.turnOn);
    if (mounted) ref.invalidate(autofillStatusProvider);
  }

  Future<void> _setVault(bool on, AutofillStatus status) async {
    ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(autofill: on));
    if (on && !status.enabled) await _turnOn();
  }

  /// Turns filling this vault's logins on or off. On, with saving on, makes
  /// the vault's inbox key first, which new logins wait sealed to, then asks
  /// the phone to fill from Kemlock.
  Future<void> _setPasswords(bool on, AutofillStatus status) async {
    final prefs = ref.read(prefsProvider);
    if (on && prefs.passwordSaving && await ref.read(vaultControllerProvider.notifier).passkeyInbox(create: true) == null) return;
    ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(passwords: on));
    if (on && !status.enabled) await _turnOn();
  }

  /// Turns offering to save new logins on or off; on makes the inbox key first.
  Future<void> _setPasswordSaving(bool on) async {
    if (on && await ref.read(vaultControllerProvider.notifier).passkeyInbox(create: true) == null) return;
    ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(passwordSaving: on));
  }

  /// The Passwords group (openspec: password-autofill; the approved mockup
  /// `AutofillSettings`): filling the vault's logins, and while it is on,
  /// offering to save new ones and suggesting strong passwords, then what
  /// is kept outside the vault, and on an iPhone below iOS 26.2, that it
  /// only fills.
  List<Widget> _passwords(BuildContext context, Prefs prefs, AutofillStatus status, String label) {
    final b = context.bmc;
    Widget toggle(String id, String detailId, IconData icon, bool value, ValueChanged<bool>? onChanged, {bool first = false}) => GroupRow(
      first: first,
      icon: Icon(icon),
      primary: context.t(id),
      secondary: context.t(detailId),
      control: Semantics(
        label: context.t(id),
        child: AppSwitch(value: value, onChanged: onChanged),
      ),
    );
    final saves = status.savesPasswords;
    return [
      SectionLabel(context.t('autofill.passwords.section'), padding: const EdgeInsets.fromLTRB(6, 8, 6, 0)),
      GroupCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            toggle(
              'autofill.passwords',
              'autofill.passwords.detail',
              Icons.password_rounded,
              prefs.passwords,
              (on) => unawaited(_setPasswords(on, status)),
              first: true,
            ),
            toggle(
              'autofill.passwordSaving',
              'autofill.passwordSaving.detail',
              Icons.save_alt_rounded,
              prefs.passwordSaving,
              prefs.passwords && saves ? (on) => unawaited(_setPasswordSaving(on)) : null,
            ),
            toggle(
              'autofill.passwordSuggesting',
              'autofill.passwordSuggesting.detail',
              Icons.casino_outlined,
              prefs.passwordSuggesting,
              prefs.passwords && saves
                  ? (on) => ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(passwordSuggesting: on))
                  : null,
            ),
          ],
        ),
      ),
      if (!saves) AppAlert(severity: AlertSeverity.info, child: Text(context.t('autofill.passwords.fillOnly'))),
      Text(context.t('autofill.passwords.kept', {'label': label}), style: AppType.caption.copyWith(color: b.faint)),
    ];
  }

  /// Turns passkeys on or off for the open vault. On makes the vault's
  /// inbox key first, then asks the phone to take passkeys from Kemlock.
  Future<void> _setPasskeys(bool on, PasskeyStatus status) async {
    if (on && await ref.read(vaultControllerProvider.notifier).passkeyInbox(create: true) == null) return;
    ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(passkeys: on));
    if (on && !status.enabled) await _openPasskeySettings();
  }

  Future<void> _openPasskeySettings() async {
    await ref.read(autoLockHoldsProvider).withHeld(ref.read(autofillPlatformProvider).openPasskeySettings);
    if (mounted) ref.invalidate(passkeyStatusProvider);
  }

  List<Widget> _passkeys(BuildContext context, Prefs prefs, AutofillStatus status, String label) {
    final b = context.bmc;
    final passkeys = ref.watch(passkeyStatusProvider).value;
    if (passkeys == null) return const [];
    return [
      SectionLabel(context.t('autofill.passkeys.section'), padding: const EdgeInsets.fromLTRB(6, 8, 6, 0)),
      if (!passkeys.supported)
        AppAlert(
          severity: AlertSeverity.info,
          child: Text(context.t(_ios ? 'autofill.passkeys.unsupported.ios' : 'autofill.passkeys.unsupported.android')),
        )
      else ...[
        GroupCard(
          child: GroupRow(
            first: true,
            icon: const Icon(Icons.fingerprint_rounded),
            primary: context.t('autofill.passkeys'),
            secondary: context.t('autofill.passkeys.detail'),
            control: Semantics(
              label: context.t('autofill.passkeys'),
              child: AppSwitch(value: prefs.passkeys, onChanged: (on) => unawaited(_setPasskeys(on, passkeys))),
            ),
          ),
        ),
        if (prefs.passkeys && !status.biometrics)
          AppAlert(severity: AlertSeverity.warning, child: Text(context.t('autofill.noBiometrics', {'label': label})))
        else if (prefs.passkeys && !passkeys.enabled)
          AppAlert(
            severity: AlertSeverity.warning,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Text(context.t(_ios ? 'autofill.passkeys.system.ios' : 'autofill.passkeys.system.android')),
                TextButton(onPressed: () => unawaited(_openPasskeySettings()), child: Text(context.t('autofill.passkeys.open'))),
              ],
            ),
          )
        else if (prefs.passkeys)
          AppAlert(severity: AlertSeverity.success, child: Text(context.t('autofill.passkeys.on'))),
        Text(context.t('autofill.passkeys.kept', {'label': label}), style: AppType.caption.copyWith(color: b.faint)),
        if (!_ios) Text(context.t('autofill.passkeys.assetLinks'), style: AppType.caption.copyWith(color: b.faint)),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final prefs = ref.watch(prefsProvider);
    final hidden = ref.watch(vaultControllerProvider.select((state) => state.vault.hidden));
    final status = ref.watch(autofillStatusProvider).value;
    final label = context.t(_ios ? 'enableBiometric.platform.ios.label' : 'enableBiometric.platform.android.label');

    final List<Widget> body;
    if (status == null) {
      body = [const Center(child: Spinner(size: 32))];
    } else if (!status.supported) {
      body = [
        AppAlert(severity: AlertSeverity.info, child: Text(context.t(_ios ? 'autofill.unsupported.ios' : 'autofill.unsupported.android'))),
      ];
    } else if (hidden) {
      body = [AppAlert(severity: AlertSeverity.info, child: Text(context.t('autofill.hidden')))];
    } else {
      // Filling codes or passwords both need Kemlock on in the phone's AutoFill
      final fills = prefs.autofill || prefs.passwords;
      body = [
        if (fills && !status.biometrics)
          AppAlert(severity: AlertSeverity.warning, child: Text(context.t('autofill.noBiometrics', {'label': label})))
        else if (fills && !status.enabled)
          AppAlert(
            severity: AlertSeverity.warning,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Text(context.t(_ios ? 'autofill.system.ios' : 'autofill.system.android')),
                TextButton(
                  onPressed: () => unawaited(_turnOn()),
                  child: Text(context.t(_ios ? 'autofill.turnOn.ios' : 'autofill.turnOn.android')),
                ),
              ],
            ),
          )
        else if (fills) ...[
          AppAlert(severity: AlertSeverity.success, child: Text(context.t('autofill.systemOn'))),
          if (status.chromeNeedsSetting)
            AppAlert(
              severity: AlertSeverity.info,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text(context.t('autofill.chrome')),
                  TextButton(
                    onPressed: () => unawaited(ref.read(autofillPlatformProvider).openChromeSettings()),
                    child: Text(context.t('autofill.chrome.open')),
                  ),
                ],
              ),
            ),
        ],
        ..._passwords(context, prefs, status, label),
        SectionLabel(context.t('autofill.codes.section'), padding: const EdgeInsets.fromLTRB(6, 8, 6, 0)),
        GroupCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GroupRow(
                first: true,
                icon: const Icon(Icons.password_rounded),
                primary: context.t('autofill.vault'),
                control: Semantics(
                  label: context.t('autofill.vault'),
                  child: AppSwitch(value: prefs.autofill, onChanged: (on) => unawaited(_setVault(on, status))),
                ),
              ),
              GroupRow(
                icon: const Icon(Icons.label_outline_rounded),
                primary: context.t('autofill.names'),
                secondary: context.t('autofill.names.detail'),
                control: Semantics(
                  label: context.t('autofill.names'),
                  child: AppSwitch(
                    value: prefs.autofillNames,
                    onChanged: prefs.autofill
                        ? (on) => ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(autofillNames: on))
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
        Text(context.t('autofill.privacy', {'label': label}), style: AppType.caption.copyWith(color: b.faint)),
        ..._passkeys(context, prefs, status, label),
      ];
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DialogHeading(icon: const Icon(Icons.keyboard_alt_outlined), title: context.t('autofill.title')),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                Text(context.t('autofill.body', {'label': label}), style: AppType.body2.copyWith(color: p.textSecondary)),
                ...body,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
