import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/crashing_store.dart';
import 'rotation_helpers.dart';

/// A replacement of the vault's key pair killed at each single write in
/// turn never loses the vault (openspec: replace-vault-key-pair, task 2.4).
void main() {
  test('killed at any write, the vault opens with every item, and the next unlock settles it', () async {
    var killed = 0;
    var beforeCommit = 0;
    for (var n = 1; ; n++) {
      final store = CrashingStore();
      final phone = Phone(store);
      final old = await phone.vault.setupVault('pw');
      await fillVault(phone.vault, phone.store, keyFuture, old);
      final oldKit = newKit();
      await phone.vault.setRecoveryKey(old, oldKit);
      final kit = newKit(threshold: 2, shares: 3);
      store.diesAt = store.writes + n;
      try {
        await phone.vault.replaceKeyPair(old, 'pw', kit: kit);
        // The replacement made fewer than n writes: every write has had its turn
        expect(store.dead, isFalse);
        break;
      } on StoreDied {
        killed++;
      }
      final survived = store.reopen();
      final committed = (jsonDecode(survived.getItem(keyConfig)!) as Map<String, Object?>)['publicKey'] != b64(old.publicKey);
      final reason = 'killed at write $n of the replacement';

      if (!committed) {
        beforeCommit++;
        // As it was: the password and the old kit open the old key pair
        final byPassword = Phone(store.reopen());
        final session = await byPassword.vault.unlockAnyVault('pw', mainVault);
        expect(session.secretKey, old.secretKey, reason: reason);
        expect(byPassword.store.getItem(keyKeyRotation), isNull, reason: reason);
        await expectEveryItem(byPassword.vault, session);
        final byKit = Phone(store.reopen());
        expect((await byKit.vault.unlockWithRecoveryKey(oldKit.kitId, oldKit.key)).secretKey, old.secretKey, reason: reason);
        expect(byKit.store.getItem(keyKeyRotation), isNull, reason: reason);
        continue;
      }

      // Committed: the next unlock, by password or by the new kit, finishes it
      final byPassword = Phone(store.reopen());
      final session = await byPassword.vault.unlockAnyVault('pw', mainVault);
      expect(session.secretKey, isNot(old.secretKey), reason: reason);
      expect(byPassword.store.getItem(keyKeyRotation), isNull, reason: reason);
      await expectEveryItem(byPassword.vault, session);
      final byKit = Phone(store.reopen());
      final kitSession = await byKit.vault.unlockWithRecoveryKey(kit.kitId, kit.key);
      expect(kitSession.secretKey, session.secretKey, reason: reason);
      expect(byKit.store.getItem(keyKeyRotation), isNull, reason: reason);
      await expectEveryItem(byKit.vault, kitSession);
      await expectLater(Phone(store.reopen()).vault.unlockWithRecoveryKey(oldKit.kitId, oldKit.key), throwsA(isA<KitNotFoundError>()));
    }
    // The replacement's value, and the config, which is the commit
    expect(beforeCommit, 2);
    expect(killed, greaterThan(beforeCommit + 9));
  });
}
