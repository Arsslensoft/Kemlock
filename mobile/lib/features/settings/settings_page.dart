import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/shell_page.dart';
import '../../app/theme_choice.dart';
import '../../core/project_links.dart';
import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../platform/links.dart';
import '../../platform/network.dart';
import '../../platform/unlock_keys.dart';
import '../../ui/ui.dart';
import '../../vault/key_unlock.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_registry.dart';
import '../../vault/vault_store.dart';
import '../autofill/autofill_sheet.dart';
import '../backup/backup_status.dart';
import '../breaches/breach_providers.dart';
import '../breaches/breaches_sheet.dart';
import '../duplicates/duplicates_provider.dart';
import '../duplicates/duplicates_sheet.dart';
import '../export/export_sheet.dart';
import '../export/qr_export_sheet.dart';
import '../import/import_sheet.dart';
import '../import/qr_import_sheet.dart';
import '../keys/key_reminders.dart';
import '../lock/change_password_sheet.dart';
import '../lock/enable_biometric_sheet.dart';
import '../lock/replace_key_sheet.dart';
import '../lock/unlock_attempts.dart';
import '../lock/unlock_method_sheet.dart';
import '../mail/mail_apps_group.dart';
import '../recovery/recovery_kit_sheet.dart';
import '../security_keys/security_key_sheet.dart';
import '../security_keys/spike_page.dart';
import '../spaces/account_security_sheet.dart';
import '../sync/spaces_sheet.dart';
import '../sync/sync_sheet.dart';
import '../sync/sync_store.dart';
import '../vault/owner_check.dart';
import 'app_version.dart';
import 'auto_lock.dart';
import 'prefs.dart';
import 'vault_health_card.dart';
import 'vaults_sheet.dart';

/// The open vault's Recovery Kit and whether biometric unlock is on, read
/// again whenever its config or either of its biometric entries is
/// written, as the Recovery Kit and biometric sheets do.
final vaultSafeguardsProvider = Provider.autoDispose<({RecoveryKitInfo? kit, bool biometric})>((ref) {
  final vaults = watchActiveVault(ref);
  watchKeys(ref, [vaults.vaultKey(keyConfig), vaults.vaultKey(keyNativeBio), vaults.vaultKey(keyHardwareBio)]);
  final store = ref.watch(vaultStoreProvider);
  return (kit: store.recoveryKitInfo(), biometric: store.hasBiometricUnlock());
});

/// Whether the phone has biometrics biometric unlock's hardware key can be
/// bound to: Class 3 on Android, Face ID or Touch ID with a passcode on iOS.
final biometricUnlockAvailableProvider = FutureProvider.autoDispose<bool>((ref) => ref.watch(unlockKeysProvider).status());

/// The Settings tab, `routes/settings.tsx` as the phone app showed it: the
/// vault's health, then security, sync and sharing, data, the look
/// and the language, About and Terms, the lock button and the version.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(vaultControllerProvider);
    final prefs = ref.watch(prefsProvider);
    final safeguards = ref.watch(vaultSafeguardsProvider);
    final sync = ref.watch(syncProvider.select((sync) => sync.settings));
    final version = ref.watch(appVersionProvider).value;
    // Services with a breach listed since their entries were added (openspec: breach-alerts)
    final breached = ref.watch(breachFindingsProvider.select((findings) => findings.serviceCount));
    // The groups of items the vault holds twice, once a check has finished (the add-duplicate-cleaner plan)
    final duplicates = ref.watch(duplicatesProvider);
    // Offline mode pauses sync and the breach checks, and their rows say so (openspec: add-offline-mode)
    final offline = ref.watch(offlineProvider);

    final kit = safeguards.kit;
    final biometric = safeguards.biometric;
    // How the vault opens (openspec: add-security-key-unlock); biometric unlock is off while it needs a key
    final opens = ref.watch(vaultUnlockProvider).mode;
    // The lock screen offers quick unlock for listed vaults only
    final hidden = state.vault.hidden;
    // Not offered on a phone whose biometrics can't hold the key, but shown while on, to turn it off
    final offerBiometric = !hidden && (biometric || (ref.watch(biometricUnlockAvailableProvider).value ?? false));
    final vaultLabel = state.vault.name ?? context.t('vaults.defaultName');
    final syncOn = sync?.syncsOwnEntries ?? false;
    final spaceCount = sync?.spaces.length ?? 0;

    final lastBackupAt = prefs.lastBackupAt;
    final unbacked = entriesSince(state.accounts, state.backupServices, lastBackupAt);
    final lastBackup = lastBackupAt == null
        ? ''
        : DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(DateTime.fromMillisecondsSinceEpoch(lastBackupAt));

    // The encrypted-backup line of the health card, which the erase's confirmation repeats
    final backupDetail = lastBackupAt == null
        ? context.t('settings.health.backupNever')
        : unbacked > 0
        ? context.t('settings.health.backupStale', {'date': lastBackup, 'count': unbacked})
        : context.t('settings.health.backupOn', {'date': lastBackup});

    final setUp = context.t('settings.health.setUp');
    final health = [
      HealthItem(id: 'pq', ok: true, title: context.t('settings.health.pq'), detail: 'ML-KEM-1024 · AES-256-GCM'),
      // Until the key pair is replaced (openspec: replace-vault-key-pair, decision 8)
      if (state.keyExposed)
        HealthItem(
          id: 'key',
          ok: false,
          title: context.t('settings.health.key'),
          detail: context.t('settings.health.keyExposed'),
          action: (label: context.t('settings.health.replaceKey'), onPressed: () => unawaited(showReplaceKeySheet(context, exposed: true))),
        ),
      HealthItem(
        id: 'recovery',
        ok: kit != null,
        title: context.t('recovery.kit.title'),
        detail: kit == null
            ? context.t('settings.health.kitNone')
            : context.t(kit.shares == 1 ? 'settings.health.kitMe' : 'settings.health.kitPeople', {
                'needed': kit.threshold,
                'total': kit.shares,
              }),
        action: (label: setUp, onPressed: () => unawaited(showRecoveryKitSheet(context))),
      ),
      if (offerBiometric)
        HealthItem(
          id: 'quick',
          ok: biometric,
          title: context.t('settings.health.biometric'),
          detail: context.t(
            opens.needsKey
                ? 'unlockMethod.health.biometricOff'
                : biometric
                ? 'settings.health.biometricOn'
                : 'settings.health.quickOff',
          ),
          action: opens.needsKey ? null : (label: setUp, onPressed: () => unawaited(showEnableBiometricSheet(context))),
        ),
      HealthItem(
        id: 'lock',
        ok: true,
        title: context.t('settings.autoLock'),
        detail: context.t(prefs.lockOnHide ? 'settings.autoLock.detailHidden' : 'settings.autoLock.detail', {
          'minutes': prefs.autoLockMinutes,
        }),
      ),
      HealthItem(
        id: 'backup',
        ok: lastBackupAt != null && unbacked == 0,
        title: context.t('settings.health.backup'),
        detail: backupDetail,
        action: (label: context.t('settings.health.backUp'), onPressed: () => unawaited(showExportSheet(context))),
      ),
      HealthItem(
        id: 'breaches',
        ok: breached == 0,
        title: context.t('settings.health.breaches'),
        detail: breached == 0 ? context.t('settings.health.breachesNone') : context.t('settings.health.breachesSome', {'count': breached}),
        action: (label: context.t('settings.health.review'), onPressed: () => unawaited(showBreachesSheet(context))),
      ),
      // Only while there is something to review or to undo, as the key's row shows only while it is exposed
      if (duplicates.groups.isNotEmpty || duplicates.merges > 0)
        HealthItem(
          id: 'duplicates',
          ok: duplicates.groups.isEmpty,
          title: context.t('settings.health.duplicates'),
          detail: duplicates.groups.isEmpty
              ? context.t('settings.health.duplicatesUndo', {'count': duplicates.merges})
              : context.t('settings.health.duplicatesSome', {'count': duplicates.groups.length}),
          // With only merges to undo the row is in order, and its button still opens the screen
          action: (label: context.t('settings.health.review'), onPressed: () => unawaited(showDuplicatesSheet(context))),
          actionWhenOk: true,
        ),
    ];

    final prefsNotifier = ref.read(prefsProvider.notifier);
    Text onOff(bool on) => Text(context.t(on ? 'settings.value.on' : 'settings.value.off'));

    return ShellPage(
      children: [
        const SizedBox(height: 40),
        PageTitle(title: context.t('app.settings.title')),
        VaultHealthCard(items: health),
        const _SupportCard(),
        const _NetworkGroup(),
        Group(
          label: context.t('app.settings.section.security'),
          children: [
            // A vault that opens with a key alone has no password to change
            if (opens != UnlockMode.key)
              GroupRow(
                first: true,
                icon: const Icon(Icons.key_rounded),
                primary: context.t('app.menu.changePassword'),
                onTap: () => unawaited(showChangePasswordSheet(context)),
              ),
            GroupRow(
              first: opens == UnlockMode.key,
              icon: const Icon(Icons.vpn_key_outlined),
              primary: context.t('unlockMethod.title'),
              // "Password and security key" wraps rather than pushing the row off the screen
              value: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(unlockModeLabel(context, opens), textAlign: TextAlign.end),
              ),
              onTap: () => unawaited(showUnlockMethodSheet(context)),
            ),
            GroupRow(
              icon: const Icon(Icons.health_and_safety_outlined),
              primary: context.t('recovery.kit.title'),
              secondary: context.t('settings.recovery.hint'),
              value: onOff(kit != null),
              onTap: () => unawaited(showRecoveryKitSheet(context)),
            ),
            GroupRow(
              icon: const Icon(Icons.autorenew_rounded),
              primary: context.t('settings.replaceKey'),
              secondary: context.t('settings.replaceKey.hint'),
              onTap: () => unawaited(showReplaceKeySheet(context)),
            ),
            // The fingerprint of the account's public keys, for someone confirming it in a space
            if (sync?.kemlock != null)
              GroupRow(
                icon: const Icon(Icons.fingerprint_rounded),
                primary: context.t('accountSecurity.title'),
                secondary: context.t('accountSecurity.row.hint'),
                onTap: () => unawaited(showAccountSecurity(context)),
              ),
            if (offerBiometric && !opens.needsKey)
              GroupRow(
                icon: const Icon(Icons.face_rounded),
                primary: context.t('settings.health.biometric'),
                control: _LabelledSwitch(
                  label: context.t('settings.health.biometric'),
                  value: biometric,
                  onChanged: (_) {
                    if (biometric) {
                      unawaited(ref.read(vaultStoreProvider).removeBiometricUnlock().catchError((Object _) {}));
                    } else {
                      unawaited(showEnableBiometricSheet(context));
                    }
                  },
                ),
              ),
            GroupRow(
              icon: const Icon(Icons.keyboard_alt_outlined),
              primary: context.t('settings.autofill'),
              secondary: context.t('settings.autofill.hint'),
              value: onOff(prefs.autofill && !hidden),
              onTap: () => unawaited(showAutofillSheet(context)),
            ),
            _AutoLockRow(minutes: prefs.autoLockMinutes),
            GroupRow(
              icon: const Icon(Icons.visibility_off_outlined),
              primary: context.t('settings.lockOnHide'),
              secondary: context.t('settings.lockOnHide.detail'),
              control: _LabelledSwitch(
                label: context.t('settings.lockOnHide'),
                value: prefs.lockOnHide,
                onChanged: (on) => prefsNotifier.update((prefs) => prefs.copyWith(lockOnHide: on)),
              ),
            ),
            GroupRow(
              icon: const Icon(Icons.password_rounded),
              primary: context.t('settings.askBeforeSecret'),
              secondary: context.t('settings.askBeforeSecret.detail'),
              control: _LabelledSwitch(
                label: context.t('settings.askBeforeSecret'),
                value: prefs.askBeforeSecret,
                onChanged: (on) async {
                  // Whoever could turn it off without asking would get round it: off asks first, as a reveal does
                  final reason = context.t('settings.askBeforeSecret.off');
                  if (!on && !await ref.read(ownerCheckProvider)(context, ref, reason)) return;
                  prefsNotifier.update((prefs) => prefs.copyWith(askBeforeSecret: on));
                },
              ),
            ),
            GroupRow(
              icon: const Icon(Icons.gpp_maybe_outlined),
              primary: context.t('settings.leakCheck'),
              secondary: context.t('settings.leakCheck.detail'),
              tag: offline ? const _PausedTag() : null,
              control: _LabelledSwitch(
                label: context.t('settings.leakCheck'),
                value: prefs.leakCheck,
                onChanged: (on) => prefsNotifier.update((prefs) => prefs.copyWith(leakCheck: on)),
              ),
            ),
            GroupRow(
              icon: const Icon(Icons.cloud_sync_outlined),
              primary: context.t('settings.breachRefresh'),
              secondary: context.t('settings.breachRefresh.detail'),
              tag: offline ? const _PausedTag() : null,
              control: _LabelledSwitch(
                label: context.t('settings.breachRefresh'),
                value: prefs.breachRefresh,
                onChanged: (on) => prefsNotifier.update((prefs) => prefs.copyWith(breachRefresh: on)),
              ),
            ),
            _ClipboardRow(seconds: prefs.clearClipboard ? prefs.clipboardClearSeconds : null),
            _UnlockEraseRow(backupDetail: backupDetail),
          ],
        ),
        // Android only; between the Security and the Keys groups (openspec: add-pgp-mail-provider)
        const MailAppsGroup(),
        Group(
          label: context.t('settings.section.keys'),
          children: [
            // A hidden vault gets no reminders: one on the lock screen would show that it exists
            if (!hidden) _KeyRemindersRow(on: prefs.keyReminders),
            GroupRow(
              first: hidden,
              primary: context.t('securityKeys.settings.row'),
              secondary: context.t('securityKeys.settings.detail'),
              onTap: () => unawaited(showSecurityKeySheet(context)),
            ),
            if (keySpikeEnabled) GroupRow(primary: 'Key spike', onTap: () => unawaited(context.push(keySpikePath))),
          ],
        ),
        Group(
          label: context.t('settings.section.sync'),
          children: [
            GroupRow(
              first: true,
              icon: const Icon(Icons.inventory_2_outlined),
              primary: context.t('vaults.title'),
              value: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(vaultLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              onTap: () => unawaited(showVaultsSheet(context)),
            ),
            GroupRow(
              icon: const Icon(Icons.cloud_sync_outlined),
              primary: context.t('sync.title'),
              secondary: context.t('settings.sync.hint'),
              value: offline ? null : onOff(syncOn),
              tag: offline ? const _PausedTag() : null,
              onTap: () => unawaited(showSyncSheet(context)),
            ),
            GroupRow(
              icon: const Icon(Icons.groups_outlined),
              primary: context.t('spaces.title'),
              secondary: context.t('settings.spaces.hint'),
              value: Text('$spaceCount'),
              onTap: () => unawaited(showSpacesSheet(context)),
            ),
          ],
        ),
        Group(
          label: context.t('app.settings.section.data'),
          children: [
            GroupRow(
              first: true,
              icon: const Icon(Icons.file_download_outlined),
              primary: context.t('app.menu.export'),
              onTap: () => unawaited(showExportSheet(context)),
            ),
            GroupRow(
              icon: const Icon(Icons.file_upload_outlined),
              primary: context.t('app.menu.import'),
              onTap: () => unawaited(showImportSheet(context)),
            ),
            GroupRow(
              icon: const Icon(Icons.qr_code_2_rounded),
              primary: context.t('app.menu.qrExport'),
              onTap: () => unawaited(showQrExportSheet(context)),
            ),
            GroupRow(
              icon: const Icon(Icons.qr_code_scanner_rounded),
              primary: context.t('app.menu.qrImport'),
              onTap: () => unawaited(showQrImportSheet(context)),
            ),
          ],
        ),
        Group(
          label: context.t('settings.section.appearance'),
          children: [
            GroupRow(
              first: true,
              icon: const Icon(Icons.dark_mode_outlined),
              primary: context.t('settings.theme'),
              control: SizedBox(
                width: 196,
                child: SegmentedControl<ThemeChoice>(
                  size: SegmentSize.small,
                  semanticLabel: context.t('settings.theme'),
                  value: ref.watch(themeChoiceProvider),
                  onChanged: ref.read(themeChoiceProvider.notifier).choose,
                  options: [
                    for (final choice in ThemeChoice.values)
                      SegmentOption(value: choice, label: context.t('settings.theme.${choice.name}')),
                  ],
                ),
              ),
            ),
            GroupRow(
              icon: const Icon(Icons.translate_rounded),
              primary: context.t('app.settings.language'),
              control: SizedBox(
                width: 196,
                child: SegmentedControl<AppLocale>(
                  size: SegmentSize.small,
                  semanticLabel: context.t('app.settings.language'),
                  value: ref.watch(localeProvider),
                  onChanged: ref.read(localeProvider.notifier).setLocale,
                  options: [for (final locale in AppLocale.values) SegmentOption(value: locale, label: locale.label)],
                ),
              ),
            ),
          ],
        ),
        Group(
          label: context.t('app.settings.section.about'),
          children: [
            GroupRow(
              first: true,
              icon: const Icon(Icons.info_outline_rounded),
              primary: context.t('settings.about'),
              onTap: () => context.go('/about'),
            ),
            GroupRow(
              icon: const Icon(Icons.description_outlined),
              primary: context.t('app.terms.title'),
              onTap: () => context.go('/terms'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _LockButton(onPressed: ref.read(vaultControllerProvider.notifier).lock),
        if (version != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              context.t('settings.version', {'version': version}),
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: fontSans, fontSize: 11.5, height: 1.5, color: context.bmc.faint),
            ),
          ),
      ],
    );
  }
}

/// The one way the app asks for support: a row that says Kemlock is free and
/// complete and opens the support page in the browser, and nothing else, ever.
class _SupportCard extends ConsumerWidget {
  const _SupportCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: GroupCard(
      child: GroupRow(
        first: true,
        icon: const Icon(Icons.favorite_outline_rounded),
        primary: context.t('settings.support.title'),
        secondary: context.t('settings.support.body'),
        onTap: () => unawaited(ref.read(linkOpenerProvider).open(context, supportPage)),
      ),
    ),
  );
}

/// Turns the notifications before a PGP key expires on and off for the open
/// vault (openspec: add-key-expiry-warnings). Turning them on asks the phone
/// for permission to notify; when that is refused the switch stays off and
/// a message says where to allow it.
class _KeyRemindersRow extends ConsumerWidget {
  const _KeyRemindersRow({required this.on});

  final bool on;

  Future<void> _set(BuildContext context, WidgetRef ref, bool value) async {
    if (!value) return turnKeyRemindersOff(ref);
    final denied = context.t('settings.keyReminders.denied');
    final toasts = ref.read(toastsProvider.notifier);
    if (!await turnKeyRemindersOn(ref)) toasts.show(denied, severity: ToastSeverity.error);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => GroupRow(
    first: true,
    primary: context.t('settings.keyReminders'),
    secondary: context.t('settings.keyReminders.detail'),
    control: _LabelledSwitch(
      label: context.t('settings.keyReminders'),
      value: on,
      onChanged: (value) => unawaited(_set(context, ref, value)),
    ),
  );
}

/// The Network group, first on the page: the offline mode switch and,
/// while it is on, what it pauses, each tagged "Paused" (openspec:
/// add-offline-mode, decision 9). The switch is the phone's, so every vault
/// shows the same.
class _NetworkGroup extends ConsumerWidget {
  const _NetworkGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(offlineProvider);
    final paused = [
      'settings.offline.sync',
      'settings.offline.breaches',
      'settings.offline.keyLookup',
      // Only Android fetches a site's list of apps itself; on iOS the system checks the app
      if (defaultTargetPlatform == TargetPlatform.android) 'settings.offline.passkeyApps',
    ];
    return Rise(
      child: Group(
        label: context.t('settings.section.network'),
        children: [
          GroupRow(
            first: true,
            accent: true,
            icon: const Icon(Icons.wifi_off_rounded),
            primary: context.t('settings.offline'),
            secondary: context.t('settings.offline.detail'),
            control: _LabelledSwitch(
              label: context.t('settings.offline'),
              value: offline,
              onChanged: ref.read(offlineProvider.notifier).set,
            ),
          ),
          if (offline)
            for (final (index, id) in paused.indexed)
              GroupRow(
                primary: context.t(id),
                tag: PopIn(
                  delay: Duration(milliseconds: 60 * (index + 1)),
                  child: const _PausedTag(),
                ),
              ),
        ],
      ),
    );
  }
}

/// The "Paused" tag of a feature offline mode stops.
class _PausedTag extends StatelessWidget {
  const _PausedTag();

  @override
  Widget build(BuildContext context) => StatusTag(label: context.t('settings.offline.paused'), tone: StatusTone.warning);
}

/// A switch at the end of a row, named for screen readers.
class _LabelledSwitch extends StatelessWidget {
  const _LabelledSwitch({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: AppSwitch(value: value, onChanged: onChanged),
  );
}

/// The auto-lock row, which opens a menu of timeouts under its right end,
/// the chosen one ticked.
class _AutoLockRow extends ConsumerWidget {
  const _AutoLockRow({required this.minutes});

  final int minutes;

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final row = context.findRenderObject()! as RenderBox;
    // Over the whole app, the tab bar included, as the web app's menus were
    final overlay = Navigator.of(context, rootNavigator: true).overlay!.context.findRenderObject()! as RenderBox;
    final corner = row.localToGlobal(row.size.bottomRight(Offset.zero), ancestor: overlay);
    final p = context.palette;
    final chosen = await showMenu<int>(
      context: context,
      useRootNavigator: true,
      // Level with the row's foot and growing left from its right end, as anchorOrigin bottom-right had it
      position: RelativeRect.fromLTRB(corner.dx, corner.dy, overlay.size.width - corner.dx, overlay.size.height - corner.dy),
      constraints: const BoxConstraints(minWidth: 160),
      items: [
        for (final option in autoLockMinuteOptions)
          PopupMenuItem(
            value: option,
            child: Semantics(
              inMutuallyExclusiveGroup: true,
              checked: option == minutes,
              child: Row(
                children: [
                  Opacity(
                    opacity: option == minutes ? 1 : 0,
                    child: Icon(Icons.check_rounded, size: 20, color: p.text),
                  ),
                  const SizedBox(width: 12),
                  Text(context.t('settings.autoLock.option', {'minutes': option}), style: AppType.body1.copyWith(color: p.text)),
                ],
              ),
            ),
          ),
      ],
    );
    if (chosen != null) ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(autoLockMinutes: chosen));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => GroupRow(
    icon: const Icon(Icons.timer_outlined),
    primary: context.t('settings.autoLock'),
    secondary: context.t('settings.autoLock.hint'),
    value: Text(context.t('settings.autoLock.value', {'minutes': minutes})),
    onTap: () => unawaited(_choose(context, ref)),
  );
}

/// The name of a clipboard delay in Settings: [seconds], or never when null.
String _clipboardOption(BuildContext context, int? seconds) =>
    context.t(seconds == null ? 'settings.clipboard.never' : 'settings.clipboard.after$seconds');

/// The clipboard row, which opens a menu of delays and never under its
/// right end, the chosen one ticked. On iOS it says copies stay on the phone,
/// off Universal Clipboard; on Android that they are marked sensitive.
class _ClipboardRow extends ConsumerWidget {
  const _ClipboardRow({required this.seconds});

  /// The delay, or null for never.
  final int? seconds;

  /// What the menu answers for never, as it takes no null.
  static const _never = 0;

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final row = context.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(context, rootNavigator: true).overlay!.context.findRenderObject()! as RenderBox;
    final corner = row.localToGlobal(row.size.bottomRight(Offset.zero), ancestor: overlay);
    final p = context.palette;
    final current = seconds ?? _never;
    final chosen = await showMenu<int>(
      context: context,
      useRootNavigator: true,
      position: RelativeRect.fromLTRB(corner.dx, corner.dy, overlay.size.width - corner.dx, overlay.size.height - corner.dy),
      constraints: const BoxConstraints(minWidth: 160),
      items: [
        for (final option in [...clipboardClearOptions, _never])
          PopupMenuItem(
            value: option,
            child: Semantics(
              inMutuallyExclusiveGroup: true,
              checked: option == current,
              child: Row(
                children: [
                  Opacity(
                    opacity: option == current ? 1 : 0,
                    child: Icon(Icons.check_rounded, size: 20, color: p.text),
                  ),
                  const SizedBox(width: 12),
                  Text(_clipboardOption(context, option == _never ? null : option), style: AppType.body1.copyWith(color: p.text)),
                ],
              ),
            ),
          ),
      ],
    );
    if (chosen == null) return;
    ref
        .read(prefsProvider.notifier)
        .update(
          (prefs) => chosen == _never
              ? prefs.copyWith(clearClipboard: false)
              : prefs.copyWith(clearClipboard: true, clipboardClearSeconds: chosen),
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    final delay = seconds;
    final String detail;
    if (delay == null) {
      detail = context.t(ios ? 'settings.clipboard.detailNeverIos' : 'settings.clipboard.detailNever');
    } else {
      final after = _clipboardOption(context, delay).toLowerCase();
      detail = context.t(ios ? 'settings.clipboard.detailIos' : 'settings.clipboard.detail', {'delay': after});
    }
    return GroupRow(
      icon: const Icon(Icons.content_paste_off_rounded),
      primary: context.t('settings.clipboard'),
      secondary: detail,
      value: Text(_clipboardOption(context, delay)),
      onTap: () => unawaited(_choose(context, ref)),
    );
  }
}

/// Erasing every vault after wrong passwords: a menu of off, 10, 15 and 20
/// under the row's right end. Turning it on, or to another number, asks
/// first, saying that every vault on this phone goes, without counting
/// them, that exports and sync are the way back, how the open vault is
/// backed up, and what the erase doesn't stop. It is the phone's, so every
/// vault shows the same, hidden ones too. It doesn't ask for the master
/// password: whoever has the vault open can already reset every vault from
/// the lock screen.
class _UnlockEraseRow extends ConsumerWidget {
  const _UnlockEraseRow({required this.backupDetail});

  /// The open vault's encrypted-backup line from the health card.
  final String backupDetail;

  /// What the menu answers for off, as it takes no null.
  static const _off = 0;

  Future<void> _choose(BuildContext context, WidgetRef ref, int? current) async {
    final row = context.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(context, rootNavigator: true).overlay!.context.findRenderObject()! as RenderBox;
    final corner = row.localToGlobal(row.size.bottomRight(Offset.zero), ancestor: overlay);
    final p = context.palette;
    final ticked = current ?? _off;
    final chosen = await showMenu<int>(
      context: context,
      useRootNavigator: true,
      position: RelativeRect.fromLTRB(corner.dx, corner.dy, overlay.size.width - corner.dx, overlay.size.height - corner.dy),
      constraints: const BoxConstraints(minWidth: 160),
      items: [
        for (final option in [_off, ...unlockEraseChoices])
          PopupMenuItem(
            value: option,
            child: Semantics(
              inMutuallyExclusiveGroup: true,
              checked: option == ticked,
              child: Row(
                children: [
                  Opacity(
                    opacity: option == ticked ? 1 : 0,
                    child: Icon(Icons.check_rounded, size: 20, color: p.text),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    option == _off ? context.t('settings.value.off') : context.t('settings.unlockErase.option', {'count': option}),
                    style: AppType.body1.copyWith(color: p.text),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
    if (chosen == null || chosen == ticked || !context.mounted) return;
    final store = ref.read(keyValueStoreProvider);
    if (chosen == _off) return writeUnlockErase(store, null);
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_forever_rounded),
      title: context.t('settings.unlockErase.confirm.title', {'count': chosen}),
      body: _UnlockEraseConfirmation(after: chosen, backupDetail: backupDetail),
      cancelLabel: context.t('settings.unlockErase.confirm.cancel'),
      confirmLabel: context.t('settings.unlockErase.confirm.ok'),
    );
    if (!confirmed) return;
    // Old wrong passwords don't count towards the number just chosen: see [UnlockAttempts.resetAll]
    ref.read(unlockAttemptsProvider).resetAll();
    writeUnlockErase(store, chosen);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final after = ref.watch(unlockEraseProvider);
    return GroupRow(
      icon: const Icon(Icons.delete_sweep_outlined),
      primary: context.t('settings.unlockErase'),
      secondary: context.t('settings.unlockErase.detail'),
      value: Text(after == null ? context.t('settings.value.off') : context.t('settings.unlockErase.value', {'count': after})),
      onTap: () => unawaited(_choose(context, ref, after)),
    );
  }
}

/// What turning the erase on means: every vault on this phone goes after
/// [after] wrong passwords in a row, exports and sync are the way back, the
/// open vault's backup, and what the erase doesn't stop.
class _UnlockEraseConfirmation extends StatelessWidget {
  const _UnlockEraseConfirmation({required this.after, required this.backupDetail});

  final int after;
  final String backupDetail;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 12,
    children: [
      Text(context.t('settings.unlockErase.confirm.body', {'count': after})),
      Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: context.t('settings.health.backup'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const TextSpan(text: '\n'),
            TextSpan(text: backupDetail),
          ],
        ),
      ),
      Text(context.t('settings.unlockErase.detail')),
    ],
  );
}

/// "Lock vault now": a wide soft red button under the groups.
class _LockButton extends StatelessWidget {
  const _LockButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return PressScale(
      child: TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          backgroundColor: context.bmc.dangerSoft,
          foregroundColor: p.error,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
        ),
        icon: const Icon(Icons.lock_rounded),
        label: Text(context.t('app.menu.lockVault')),
      ),
    );
  }
}
