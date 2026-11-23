import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where autofill stands on this phone.
class AutofillStatus {
  const AutofillStatus({
    required this.supported,
    required this.enabled,
    required this.biometrics,
    this.chromeNeedsSetting = false,
    this.savesPasswords = false,
  });

  /// The phone can fill codes from another app: iOS 18 or Android 11 and up,
  /// and passwords on Android 11 and up.
  final bool supported;

  /// The phone fills from Kemlock: its AutoFill extension is on (iOS), or
  /// it is the autofill service (Android).
  final bool enabled;

  /// Biometrics are set up, which the key the copy is encrypted to needs.
  final bool biometrics;

  /// Android: Chrome is installed and fills with its own passwords rather
  /// than another autofill service, so it won't ask Kemlock for codes.
  final bool chromeNeedsSetting;

  /// The phone can suggest strong passwords from Kemlock and save new ones
  /// to it: Android 8 and up, iOS 26.2 and up. Below, logins are only filled.
  final bool savesPasswords;

  /// A phone that can't fill codes, or a build without the native side.
  static const unsupported = AutofillStatus(supported: false, enabled: false, biometrics: false);

  factory AutofillStatus.fromMap(Map<Object?, Object?> map) => AutofillStatus(
    supported: map['supported'] == true,
    enabled: map['enabled'] == true,
    biometrics: map['biometrics'] == true,
    chromeNeedsSetting: map['chromeNeedsSetting'] == true,
    savesPasswords: map['savesPasswords'] == true,
  );

  @override
  bool operator ==(Object other) =>
      other is AutofillStatus &&
      other.supported == supported &&
      other.enabled == enabled &&
      other.biometrics == biometrics &&
      other.chromeNeedsSetting == chromeNeedsSetting &&
      other.savesPasswords == savesPasswords;

  @override
  int get hashCode => Object.hash(supported, enabled, biometrics, chromeNeedsSetting, savesPasswords);

  @override
  String toString() =>
      'AutofillStatus(supported: $supported, enabled: $enabled, biometrics: $biometrics, '
      'chromeNeedsSetting: $chromeNeedsSetting, savesPasswords: $savesPasswords)';
}

/// Where the passkey provider stands on this phone.
class PasskeyStatus {
  const PasskeyStatus({required this.supported, required this.enabled});

  /// The phone takes passkeys from another app: iOS 18 or Android 14 and up,
  /// with the native side built in.
  final bool supported;

  /// Kemlock is on as a place the phone saves passkeys to and signs in from.
  final bool enabled;

  static const unsupported = PasskeyStatus(supported: false, enabled: false);

  factory PasskeyStatus.fromMap(Map<Object?, Object?> map) =>
      PasskeyStatus(supported: map['supported'] == true, enabled: map['enabled'] == true);

  @override
  bool operator ==(Object other) => other is PasskeyStatus && other.supported == supported && other.enabled == enabled;

  @override
  int get hashCode => Object.hash(supported, enabled);

  @override
  String toString() => 'PasskeyStatus(supported: $supported, enabled: $enabled)';
}

/// A passkey the provider made while the vault was locked, as it waits:
/// the inbox file's [name] and its sealed [content] (`passkey_inbox.dart`).
typedef InboxFile = ({String name, String content});

/// What the phone may do with a vault besides filling its copy (openspec:
/// add-passwords, design decision 8): save new passkeys to it, save new and
/// changed logins to it, and suggest strong passwords for it. Saving needs
/// the vault's inbox key, which comes with the copy.
class VaultTakes {
  const VaultTakes({this.passkeys = false, this.logins = false, this.suggest = false});

  final bool passkeys;
  final bool logins;
  final bool suggest;

  Map<String, bool> toMap() => {'passkeys': passkeys, 'logins': logins, 'suggest': suggest};

  @override
  bool operator ==(Object other) => other is VaultTakes && other.passkeys == passkeys && other.logins == logins && other.suggest == suggest;

  @override
  int get hashCode => Object.hash(passkeys, logins, suggest);

  @override
  String toString() => 'VaultTakes(${toMap()})';
}

/// The phone's side of autofill (openspec: code-autofill, password-autofill): the iOS AutoFill
/// extension and the Android autofill service, and the files they read.
/// The copy is handed over in the clear and encrypted on the phone's side,
/// to a key only its secure hardware holds, which needs only the public key
/// and so never asks for biometrics here.
abstract interface class AutofillPlatform {
  Future<AutofillStatus> status();

  /// Asks the phone to fill from Kemlock: iOS's prompt, or Android's
  /// autofill service screen. True when it is on afterwards, or, on Android,
  /// when the screen opened.
  Future<bool> turnOn();

  /// Opens Chrome's setting for filling with another service (Android).
  Future<bool> openChromeSettings();

  /// Writes the autofill copy of the vault [vaultId] (the JSON of
  /// `autofillCopy`) and its index (of `autofillIndex`), or removes the
  /// index when [index] is null. Makes the key first when there's none.
  /// [inboxKey] is the public point of the vault's passkey inbox key,
  /// base64 (65 bytes, uncompressed), while passkeys are on; without it the
  /// phone forgets the vault's inbox key and offers none of its passkeys.
  /// [takes] says what else the phone may do with the vault.
  Future<void> writeVault(String vaultId, String copy, String? index, {String? inboxKey, VaultTakes takes = const VaultTakes()});

  /// Whether the phone can take passkeys from Kemlock, and does.
  Future<PasskeyStatus> passkeyStatus();

  /// Opens the phone's settings for where passkeys are saved: iOS's
  /// AutoFill & Passwords, Android's credential providers. True when they opened.
  Future<bool> openPasskeySettings();

  /// The passkeys the provider made for [vaultId] while it was locked.
  Future<List<InboxFile>> readInbox(String vaultId);

  /// Deletes the inbox files [names] of [vaultId], once their passkeys are in the vault.
  Future<void> clearInbox(String vaultId, List<String> names);

  /// Removes the vault's copy, index and remembered picks.
  Future<void> removeVault(String vaultId);

  /// Removes every vault's files, the key, and what the phone shows above the keyboard.
  Future<void> removeAll();
}

/// [AutofillPlatform] over the app's method channel. A build without the
/// native side, such as the tests', can't fill and writes nothing.
class ChannelAutofillPlatform implements AutofillPlatform {
  const ChannelAutofillPlatform();

  static const _channel = MethodChannel('com.kemlock.app/autofill');

  @override
  Future<AutofillStatus> status() async {
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('status');
      return map == null ? AutofillStatus.unsupported : AutofillStatus.fromMap(map);
    } on MissingPluginException {
      return AutofillStatus.unsupported;
    }
  }

  @override
  Future<bool> turnOn() => _bool('turnOn');

  @override
  Future<bool> openChromeSettings() => _bool('openChromeSettings');

  @override
  Future<void> writeVault(String vaultId, String copy, String? index, {String? inboxKey, VaultTakes takes = const VaultTakes()}) =>
      _call('writeVault', {'vault': vaultId, 'copy': copy, 'index': index, 'inboxKey': inboxKey, 'takes': takes.toMap()});

  @override
  Future<PasskeyStatus> passkeyStatus() async {
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('passkeyStatus');
      return map == null ? PasskeyStatus.unsupported : PasskeyStatus.fromMap(map);
    } on MissingPluginException {
      return PasskeyStatus.unsupported;
    } on PlatformException {
      return PasskeyStatus.unsupported;
    }
  }

  @override
  Future<bool> openPasskeySettings() => _bool('openPasskeySettings');

  @override
  Future<List<InboxFile>> readInbox(String vaultId) async {
    try {
      final files = await _channel.invokeListMethod<Object?>('readInbox', {'vault': vaultId}) ?? const [];
      return [
        for (final file in files.whereType<Map<Object?, Object?>>())
          if (file['name'] case final String name)
            if (file['content'] case final String content) (name: name, content: content),
      ];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<void> clearInbox(String vaultId, List<String> names) => _call('clearInbox', {'vault': vaultId, 'names': names});

  @override
  Future<void> removeVault(String vaultId) => _call('removeVault', {'vault': vaultId});

  @override
  Future<void> removeAll() => _call('removeAll');

  Future<bool> _bool(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _call(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No native side: nothing to write or remove.
    }
  }
}

/// The phone's autofill; tests put a fake in its place.
final autofillPlatformProvider = Provider<AutofillPlatform>((ref) => const ChannelAutofillPlatform());
