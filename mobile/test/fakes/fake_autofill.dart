import 'dart:convert';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/platform/autofill.dart';

/// Stands in for the phone's autofill: keeps what the app wrote, in the
/// clear, and answers status as the test says.
///
/// ```dart
/// final autofill = FakeAutofill();
/// await app.pump(tester, overrides: [autofill.asOverride]);
/// expect(autofill.copies[vaultId]!['accounts'], hasLength(1));
/// ```
class FakeAutofill implements AutofillPlatform {
  FakeAutofill({this.current = const AutofillStatus(supported: true, enabled: false, biometrics: true), this.turnsOn = true});

  /// What [status] answers.
  AutofillStatus current;

  /// Whether the system's prompt turns it on when asked.
  bool turnsOn;

  /// Each vault's copy and index, decoded, as last written.
  final Map<String, Map<String, Object?>> copies = {};
  final Map<String, Map<String, Object?>?> indexes = {};

  /// Each vault's passkey inbox key, as last handed over; absent while passkeys are off.
  final Map<String, String> inboxKeys = {};

  /// What each vault takes besides filling, as last handed over.
  final Map<String, VaultTakes> takes = {};

  /// What [passkeyStatus] answers.
  PasskeyStatus passkeys = const PasskeyStatus(supported: true, enabled: false);

  /// The inbox files waiting for each vault, by name.
  final Map<String, Map<String, String>> inbox = {};

  /// Every call, in order: `write <vault>`, `remove <vault>`, `removeAll`,
  /// `turnOn`, `chrome`, `passkeySettings`, `readInbox <vault>`, `clearInbox <vault> <names>`.
  final List<String> calls = [];

  Override get asOverride => autofillPlatformProvider.overrideWithValue(this);

  @override
  Future<AutofillStatus> status() async => current;

  @override
  Future<bool> turnOn() async {
    calls.add('turnOn');
    if (turnsOn) {
      current = AutofillStatus(
        supported: current.supported,
        enabled: true,
        biometrics: current.biometrics,
        chromeNeedsSetting: current.chromeNeedsSetting,
        savesPasswords: current.savesPasswords,
      );
    }
    return turnsOn;
  }

  @override
  Future<bool> openChromeSettings() async {
    calls.add('chrome');
    return true;
  }

  @override
  Future<void> writeVault(String vaultId, String copy, String? index, {String? inboxKey, VaultTakes takes = const VaultTakes()}) async {
    calls.add('write $vaultId');
    this.takes[vaultId] = takes;
    copies[vaultId] = jsonDecode(copy) as Map<String, Object?>;
    indexes[vaultId] = index == null ? null : jsonDecode(index) as Map<String, Object?>;
    if (inboxKey == null) {
      inboxKeys.remove(vaultId);
    } else {
      inboxKeys[vaultId] = inboxKey;
    }
  }

  @override
  Future<PasskeyStatus> passkeyStatus() async => passkeys;

  @override
  Future<bool> openPasskeySettings() async {
    calls.add('passkeySettings');
    return true;
  }

  @override
  Future<List<InboxFile>> readInbox(String vaultId) async {
    calls.add('readInbox $vaultId');
    return [for (final MapEntry(key: name, value: content) in (inbox[vaultId] ?? const {}).entries) (name: name, content: content)];
  }

  @override
  Future<void> clearInbox(String vaultId, List<String> names) async {
    calls.add('clearInbox $vaultId ${names.join(',')}');
    inbox[vaultId]?.removeWhere((name, _) => names.contains(name));
  }

  @override
  Future<void> removeVault(String vaultId) async {
    calls.add('remove $vaultId');
    copies.remove(vaultId);
    indexes.remove(vaultId);
    inboxKeys.remove(vaultId);
    inbox.remove(vaultId);
  }

  @override
  Future<void> removeAll() async {
    calls.add('removeAll');
    copies.clear();
    indexes.clear();
    inboxKeys.clear();
    inbox.clear();
  }
}
