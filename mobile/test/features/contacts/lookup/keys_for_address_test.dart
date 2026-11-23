import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/contacts/lookup/keys_for_address.dart';

import '../contacts_kit.dart';
import 'lookup_kit.dart';

/// Only the keys of an answer that name the searched address, with only the user IDs that name it (openspec:
/// add-key-lookup, decision 7), against the answers of `test/fixtures/keys/lookup`.
void main() {
  Future<List<crypto.PgpPublicKey>> found(String answer, String address) async =>
      keysForAddress(await crypto.readPublicKeys(lookupAnswer(answer)), address, contactsNow);

  test('drops a key for another address', () async {
    expect(await found(wkdAlan, 'grace@example.org'), isEmpty);
  });

  test('keeps only the user ID of the searched address, on the same key, which still passes its checks', () async {
    final key = (await found(wkdTwoAddresses, 'grace@example.org')).single;

    expect(key.info.userIds, ['Grace Hopper <grace@example.org>']);
    expect(key.info.primary.fingerprintHex, graceFingerprint);
    expect(key.info.subkeys, hasLength(1));
    final again = (await crypto.readPublicKeys(key.bytes)).single;
    expect(again.bytes, key.bytes);
    expect(again.info.userIds, ['Grace Hopper <grace@example.org>']);
  });

  test('matches the address whatever its case, in a name and brackets or bare', () async {
    expect((await found(wkdGrace, 'GRACE@Example.org')).single.info.userIds, ['Grace Hopper <grace@example.org>']);
    expect((await found(wkdTwoAddresses, 'Hopper@LAB.example.ORG')).single.info.userIds, [graceLabAddress]);
  });

  test('puts the valid key before the revoked one', () async {
    final keys = await found(wkdRevokedThenOther, 'grace@example.org');

    expect(
      [for (final key in keys) (key.info.primary.fingerprintHex, key.info.primary.revoked)],
      [(graceOtherFingerprint, false), (graceFingerprint, true)],
    );
  });

  test('a user ID names an address only as a whole, inside its brackets or bare', () {
    expect(userIdNames('Grace Hopper <grace@example.org>', 'grace@example.org'), isTrue);
    expect(userIdNames('grace@example.org', 'GRACE@EXAMPLE.ORG'), isTrue);
    expect(userIdNames('Grace Hopper <grace@example.org.evil.example>', 'grace@example.org'), isFalse);
    expect(userIdNames('Grace Hopper (grace@example.org)', 'grace@example.org'), isFalse);
    expect(userIdNames('Zoë <ZOË@example.org>', 'zoë@example.org'), isFalse);
  });
}
