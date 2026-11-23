import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;

import '../contacts_kit.dart';
import 'lookup_kit.dart';

/// The answers of `test/fixtures/keys/lookup` (openspec: add-key-lookup, task 1.2), read as a lookup reads
/// them: every key in the bytes, trimmed and checked.
void main() {
  Future<List<List<Object>>> read(String path) async => [
    for (final key in await crypto.readPublicKeys(lookupAnswer(path))) [key.info.primary.fingerprintHex, key.info.userIds],
  ];

  test('a directory answer of one binary key', () async {
    expect(await read(wkdGrace), [
      [
        graceFingerprint,
        ['Grace Hopper <grace@example.org>'],
      ],
    ]);
  });

  test('two keys for one address, the first revoked', () async {
    final keys = await crypto.readPublicKeys(lookupAnswer(wkdRevokedThenOther));

    expect(
      [
        for (final key in keys) [key.info.primary.fingerprintHex, key.info.userIds, key.info.primary.revoked],
      ],
      [
        [
          graceFingerprint,
          ['Grace Hopper <grace@example.org>'],
          true,
        ],
        [
          graceOtherFingerprint,
          ['Grace Hopper <grace@example.org>'],
          false,
        ],
      ],
    );
  });

  test('a key that names another address', () async {
    expect(await read(wkdAlan), [
      [
        alanFingerprint,
        ['Alan Turing <alan@example.org>'],
      ],
    ]);
  });

  test('a key that names the searched address and a bare address at another domain', () async {
    expect(await read(wkdTwoAddresses), [
      [
        graceFingerprint,
        ['Grace Hopper <grace@example.org>', 'hopper@lab.example.org'],
      ],
    ]);
  });

  test('a key-server answer, armored, with a single user ID', () async {
    expect(String.fromCharCodes(lookupAnswer(vksAlan).take(36)), '-----BEGIN PGP PUBLIC KEY BLOCK-----');
    expect(await read(vksAlan), [
      [
        alanFingerprint,
        ['Alan Turing <alan@example.org>'],
      ],
    ]);
  });
}
