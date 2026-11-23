import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/lock/key_reader.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_security_keys.dart';
import '../../security_key/soft_key.dart';
import '../../vault/rotation_helpers.dart' show newKit;
import 'lock_phone.dart';

export '../../security_key/soft_key.dart' show SoftKey;

const KeyPrompts testKeyPrompts = (nfcMessage: 'Hold your key', nfcFailure: 'No key');

Uint8List pinBytes(String pin) => Uint8List.fromList(utf8.encode(pin));

/// A phone for the screens of security key unlock (openspec:
/// add-security-key-unlock): a [LockPhone] whose key reader is the app's
/// own, over a fake phone that reaches keys as [reach] says, and software
/// keys to hold to it.
///
/// ```dart
/// final rig = KeyPhone();
/// final blue = SoftKey(pin: '123456');
/// final session = await rig.phone.createVault(tester, 'secret');
/// await rig.keyUp(tester, session, password: 'secret', keys: [blue], mode: UnlockMode.both);
/// rig.hold(blue);                          // held to the phone, every other key taken away
/// ```
class KeyPhone {
  KeyPhone({
    SecurityKeyCapabilities reach = FakeSecurityKeys.android,
    bool? iPhoneProven,
    PromptBiometrics? biometrics,
    List<Override> extra = const [],
  }) : keys = FakeSecurityKeys(phone: reach) {
    reader = CtapKeyReader(keys, now: keys.now);
    phone = LockPhone(
      biometrics: biometrics,
      extra: [
        keyReaderProvider.overrideWithValue(reader),
        securityKeysProvider.overrideWithValue(keys),
        if (iPhoneProven != null) iPhoneKeyExchangeProvider.overrideWithValue(iPhoneProven),
        ...extra,
      ],
    );
  }

  final FakeSecurityKeys keys;
  late final CtapKeyReader reader;
  late final LockPhone phone;
  final Map<SoftKey, FakeDevice> _held = {};

  /// [soft] is held to the phone, and every other key taken away.
  void hold(SoftKey soft) {
    takeAway();
    final device = FakeKey(productName: 'Example Key', ctap: soft).device(kinds: {SecurityKeyLinkKind.nfc});
    keys.arrive(device);
    _held[soft] = device;
  }

  /// Every key is taken away.
  void takeAway() {
    for (final device in _held.values) {
      keys.remove(device);
    }
    _held.clear();
  }

  /// The active vault, open in [session] with [password] (null for one
  /// that opens with a key alone), gets a Recovery Kit unless [kit] is
  /// false and each of [keys] enrolled, through the reader and the store,
  /// and is set to open in [mode].
  Future<void> keyUp(
    WidgetTester tester,
    VaultSession session, {
    required String? password,
    required List<SoftKey> keys,
    UnlockMode mode = UnlockMode.password,
    bool kit = true,
  }) async {
    await tester.runAsync(() async {
      final store = phone.vaultStore;
      if (kit) await store.setRecoveryKey(session, newKit());
      var proof = await store.proveOwner(password: password);
      for (final soft in keys) {
        hold(soft);
        final challenge = store.keyChallenge();
        final enrolment = await reader.enrol(
          pin: pinBytes(soft.pin ?? ''),
          salt: challenge.salt,
          exclude: challenge.credentials,
          prompts: testKeyPrompts,
        );
        proof = await store.enrolKey(
          session,
          proof,
          salt: challenge.salt,
          credential: enrolment.credential,
          output: enrolment.output,
          name: 'Key ${keys.indexOf(soft) + 1}',
          pinBound: enrolment.pinBound,
        );
      }
      if (mode != UnlockMode.password) await store.setUnlockMode(session, proof, mode);
      takeAway();
    });
  }
}
