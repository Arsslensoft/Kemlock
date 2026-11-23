import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/json.dart';
import '../../vault/vault_providers.dart';

/// Non-secret settings, stored as JSON in the clear, as `prefs.ts` keeps
/// them. Nothing here touches the vault's contents, but each vault keeps its
/// own: its last backup date is about that vault's data.
const prefsKey = 'backmycodes_prefs';

/// The delays Settings offers before a copied code or secret is cleared, in
/// seconds; "never" is `clearClipboard: false`.
const clipboardClearOptions = [10, 30, 60, 120];

/// The delay a vault starts with, the one every version before the choice cleared after.
const defaultClipboardClearSeconds = 30;

/// The order of the account list. The names are what the JSON stores.
enum AccountSort {
  name,
  custom;

  static AccountSort? fromName(Object? name) => switch (name) {
    'name' => AccountSort.name,
    'custom' => AccountSort.custom,
    _ => null,
  };
}

/// One vault's preferences.
class Prefs {
  const Prefs({
    this.clearClipboard = true,
    this.lastBackupAt,
    this.autoLockMinutes = 5,
    this.lockOnHide = false,
    this.accountSort = AccountSort.name,
    this.backupNudgeDismissedAt,
    this.autofill = false,
    this.autofillNames = true,
    this.leakCheck = false,
    this.breachRefresh = false,
    this.passkeys = false,
    this.passwords = false,
    this.passwordSaving = true,
    this.passwordSuggesting = true,
    this.clipboardClearSeconds = defaultClipboardClearSeconds,
    this.keyReminders = false,
    this.keyRemindersOffered = false,
    this.askBeforeSecret = false,
    this.extra = const {},
  });

  /// What a vault starts with.
  static const defaults = Prefs();

  /// The defaults, overridden by whatever [json] holds. A value of the
  /// wrong type keeps the default.
  factory Prefs.fromJson(Map<String, Object?> json) => Prefs(
    clearClipboard: asBool(json['clearClipboard']) ?? defaults.clearClipboard,
    lastBackupAt: asInt(json['lastBackupAt']),
    autoLockMinutes: asInt(json['autoLockMinutes']) ?? defaults.autoLockMinutes,
    lockOnHide: asBool(json['lockOnHide']) ?? defaults.lockOnHide,
    accountSort: AccountSort.fromName(json['accountSort']) ?? defaults.accountSort,
    backupNudgeDismissedAt: asInt(json['backupNudgeDismissedAt']),
    autofill: asBool(json['autofill']) ?? defaults.autofill,
    autofillNames: asBool(json['autofillNames']) ?? defaults.autofillNames,
    leakCheck: asBool(json['leakCheck']) ?? defaults.leakCheck,
    breachRefresh: asBool(json['breachRefresh']) ?? defaults.breachRefresh,
    passkeys: asBool(json['passkeys']) ?? defaults.passkeys,
    passwords: asBool(json['passwords']) ?? defaults.passwords,
    passwordSaving: asBool(json['passwordSaving']) ?? defaults.passwordSaving,
    passwordSuggesting: asBool(json['passwordSuggesting']) ?? defaults.passwordSuggesting,
    clipboardClearSeconds: _clipboardSeconds(json['clipboardClearSeconds']),
    keyReminders: asBool(json['keyReminders']) ?? defaults.keyReminders,
    keyRemindersOffered: asBool(json['keyRemindersOffered']) ?? defaults.keyRemindersOffered,
    askBeforeSecret: asBool(json['askBeforeSecret']) ?? defaults.askBeforeSecret,
    extra: extraKeys(json, _known),
  );

  /// One of [clipboardClearOptions]; anything else reads as the default.
  static int _clipboardSeconds(Object? value) {
    final seconds = asInt(value);
    return clipboardClearOptions.contains(seconds) ? seconds! : defaultClipboardClearSeconds;
  }

  /// The stored text, or the defaults when there's none or it isn't a JSON object.
  factory Prefs.parse(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, Object?> ? Prefs.fromJson(json) : defaults;
    } on FormatException {
      return defaults;
    }
  }

  static const _known = {
    'clearClipboard',
    'lastBackupAt',
    'autoLockMinutes',
    'lockOnHide',
    'accountSort',
    'backupNudgeDismissedAt',
    'autofill',
    'autofillNames',
    'leakCheck',
    'breachRefresh',
    'passkeys',
    'passwords',
    'passwordSaving',
    'passwordSuggesting',
    'clipboardClearSeconds',
    'keyReminders',
    'keyRemindersOffered',
    'askBeforeSecret',
  };

  /// Clear the clipboard [clipboardClearSeconds] after a code is copied;
  /// false is "never".
  final bool clearClipboard;

  /// How long a copied code or secret stays on the clipboard while
  /// [clearClipboard] is on: one of [clipboardClearOptions] (openspec:
  /// harden-unlock-and-clipboard). Versions before the choice read only
  /// [clearClipboard], and clear after 30 seconds whatever this says.
  final int clipboardClearSeconds;

  /// How long a copy stays on the clipboard, or null to leave it there.
  Duration? get clipboardDelay => clearClipboard ? Duration(seconds: clipboardClearSeconds) : null;

  /// Epoch ms of the last completed export, null if never.
  final int? lastBackupAt;

  /// Lock the vault after this many minutes without interaction.
  final int autoLockMinutes;

  /// Lock the vault as soon as the app is hidden.
  final bool lockOnHide;

  /// Order of the account list.
  final AccountSort accountSort;

  /// Epoch ms the Codes tab's backup reminder was last dismissed, null if never.
  final int? backupNudgeDismissedAt;

  /// Other apps and websites can fill this vault's codes (openspec: code-autofill).
  final bool autofill;

  /// Autofill suggestions name the service before biometrics, which keeps
  /// the issuers and domains outside the vault, on the phone.
  final bool autofillNames;

  /// A new master password is checked against the passwords known from data breaches,
  /// which sends five characters of its SHA-1 hash to Have I Been Pwned (openspec:
  /// password-leak-check). Off until the person turns it on.
  final bool leakCheck;

  /// While this vault is open the app asks Have I Been Pwned, at most once a day, for
  /// breaches newer than the list it has (openspec: breach-alerts). Off until the person
  /// turns it on.
  final bool breachRefresh;

  /// The phone may save new passkeys to this vault and sign in with its
  /// passkeys, which keeps them in the autofill copy outside the vault
  /// (openspec: add-vault-items). Off until the person turns it on.
  final bool passkeys;

  /// Other apps and websites can fill this vault's logins, which keeps them
  /// in the autofill copy, and their websites, names and usernames readable,
  /// outside the vault (openspec: password-autofill). Off until the person
  /// turns it on.
  final bool passwords;

  /// While [passwords] is on, AutoFill offers to save new and changed logins
  /// into this vault. On by default.
  final bool passwordSaving;

  /// While [passwords] is on, AutoFill suggests a strong password on sign-up
  /// and change-password forms. On by default.
  final bool passwordSuggesting;

  /// The phone notifies 30, 7 and 1 days before a PGP key of this vault
  /// expires, and on the day (openspec: add-key-expiry-warnings). Off until
  /// the person turns it on, which asks the phone for permission to notify.
  final bool keyReminders;

  /// The Vault tab has offered [keyReminders] once, whatever the answer, and
  /// does not offer it again.
  final bool keyRemindersOffered;

  /// Showing an account's secret, as text or as its QR code, or a saved
  /// login's password, asks first who it is, as an export does
  /// (`features/vault/owner_check.dart`). Copying a password does not. Off
  /// until the person turns it on; turning it off asks too.
  final bool askBeforeSecret;

  /// Keys this version doesn't know, kept as they were.
  final Map<String, Object?> extra;

  /// Every setting, the unset dates as null, as `setPref` writes them, and
  /// the autofill ones when they aren't the defaults.
  Map<String, Object?> toJson() => {
    'clearClipboard': clearClipboard,
    'lastBackupAt': lastBackupAt,
    'autoLockMinutes': autoLockMinutes,
    'lockOnHide': lockOnHide,
    'accountSort': accountSort.name,
    'backupNudgeDismissedAt': backupNudgeDismissedAt,
    // Added after the TypeScript app, so written only once changed: settings it wrote stay as it wrote them.
    if (autofill) 'autofill': true,
    if (!autofillNames) 'autofillNames': false,
    if (leakCheck) 'leakCheck': true,
    if (breachRefresh) 'breachRefresh': true,
    if (passkeys) 'passkeys': true,
    if (passwords) 'passwords': true,
    if (!passwordSaving) 'passwordSaving': false,
    if (!passwordSuggesting) 'passwordSuggesting': false,
    if (clipboardClearSeconds != defaultClipboardClearSeconds) 'clipboardClearSeconds': clipboardClearSeconds,
    if (keyReminders) 'keyReminders': true,
    if (keyRemindersOffered) 'keyRemindersOffered': true,
    if (askBeforeSecret) 'askBeforeSecret': true,
    ...extra,
  };

  /// A copy with the given settings changed. Pass [unset] to clear a date.
  Prefs copyWith({
    bool? clearClipboard,
    Object? lastBackupAt = keep,
    int? autoLockMinutes,
    bool? lockOnHide,
    AccountSort? accountSort,
    Object? backupNudgeDismissedAt = keep,
    bool? autofill,
    bool? autofillNames,
    bool? leakCheck,
    bool? breachRefresh,
    bool? passkeys,
    bool? passwords,
    bool? passwordSaving,
    bool? passwordSuggesting,
    int? clipboardClearSeconds,
    bool? keyReminders,
    bool? keyRemindersOffered,
    bool? askBeforeSecret,
  }) => Prefs(
    clearClipboard: clearClipboard ?? this.clearClipboard,
    lastBackupAt: pick(lastBackupAt, this.lastBackupAt),
    autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
    lockOnHide: lockOnHide ?? this.lockOnHide,
    accountSort: accountSort ?? this.accountSort,
    backupNudgeDismissedAt: pick(backupNudgeDismissedAt, this.backupNudgeDismissedAt),
    autofill: autofill ?? this.autofill,
    autofillNames: autofillNames ?? this.autofillNames,
    leakCheck: leakCheck ?? this.leakCheck,
    breachRefresh: breachRefresh ?? this.breachRefresh,
    passkeys: passkeys ?? this.passkeys,
    passwords: passwords ?? this.passwords,
    passwordSaving: passwordSaving ?? this.passwordSaving,
    passwordSuggesting: passwordSuggesting ?? this.passwordSuggesting,
    clipboardClearSeconds: clipboardClearSeconds ?? this.clipboardClearSeconds,
    keyReminders: keyReminders ?? this.keyReminders,
    keyRemindersOffered: keyRemindersOffered ?? this.keyRemindersOffered,
    askBeforeSecret: askBeforeSecret ?? this.askBeforeSecret,
    extra: extra,
  );

  @override
  bool operator ==(Object other) => other is Prefs && jsonEquals(toJson(), other.toJson());

  @override
  int get hashCode => Object.hash(
    clearClipboard,
    lastBackupAt,
    autoLockMinutes,
    lockOnHide,
    accountSort,
    backupNudgeDismissedAt,
    autofill,
    autofillNames,
    leakCheck,
    breachRefresh,
    passkeys,
    passwords,
    passwordSaving,
    passwordSuggesting,
    clipboardClearSeconds,
    keyReminders,
    keyRemindersOffered,
    askBeforeSecret,
  );

  @override
  String toString() => 'Prefs(${toJson()})';
}

/// The active vault's preferences. Rebuilds when they are written and when
/// another vault becomes the active one.
class PrefsNotifier extends Notifier<Prefs> {
  @override
  Prefs build() {
    final key = watchActiveVault(ref).vaultKey(prefsKey);
    watchKeys(ref, [key]);
    return Prefs.parse(ref.watch(keyValueStoreProvider).getItem(key));
  }

  /// Changes some settings of the active vault and stores them all, with
  /// any key this version doesn't know, as `setPref` does.
  ///
  /// ```dart
  /// ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(lockOnHide: true));
  /// ```
  void update(Prefs Function(Prefs prefs) change) {
    // Read from storage rather than [state], which still holds the last
    // vault's settings until the switch to another vault has rebuilt it.
    final store = ref.read(keyValueStoreProvider);
    final key = ref.read(vaultRegistryProvider).vaultKey(prefsKey);
    store.setItem(key, jsonEncode(change(Prefs.parse(store.getItem(key))).toJson()));
  }

  /// Records that the vault was just exported (feeds the Vault health card).
  void recordBackup() {
    final now = ref.read(clockProvider)().millisecondsSinceEpoch;
    update((prefs) => prefs.copyWith(lastBackupAt: now));
  }
}

final prefsProvider = NotifierProvider<PrefsNotifier, Prefs>(PrefsNotifier.new);
