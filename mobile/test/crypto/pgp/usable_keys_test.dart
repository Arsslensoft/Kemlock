// Which key of a key may encrypt, sign, verify and decrypt, at a fixed
// time, with the expiry fixtures of add-key-expiry-warnings.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/openpgp/key_info.dart';
import 'package:kemlock/crypto/keys/openpgp/packets.dart';
import 'package:kemlock/crypto/keys/openpgp/pgp_error.dart';
import 'package:kemlock/crypto/keys/openpgp/secret_key.dart';
import 'package:kemlock/crypto/keys/openpgp/session_key.dart';
import 'package:kemlock/crypto/keys/openpgp/signatures.dart';
import 'package:kemlock/crypto/keys/openpgp/usable_keys.dart';
import 'package:kemlock/features/keys/key_standing.dart';

import 'fixtures.dart';
import 'modes_test.dart' show packetBody;

Matcher throwsUnusable(PgpKeyTrouble reason, {String? fingerprint}) => throwsA(
  isA<PgpException>()
      .having((e) => e.problem, 'problem', PgpProblem.keyUnusable)
      .having((e) => e.reason, 'reason', reason)
      .having((e) => e.fingerprint, 'fingerprint', fingerprint ?? isNotNull),
);

Matcher throwsUnsupported(String detail) =>
    throwsA(isA<PgpException>().having((e) => e.problem, 'problem', PgpProblem.unsupported).having((e) => e.detail, 'detail', detail));

Uint8List _expiry(String name, {bool secret = false}) => binaryKey('keys/gnupg/expiry/$name.${secret ? 'secret' : 'public'}.asc');

Future<PgpCertificate> _read(Uint8List key) => PgpCertificate.read(key);

/// [key] with the embedded signatures (subpacket 32) taken out of the
/// unhashed part of its signatures: a signing subkey loses its
/// back-signature, and every signature still verifies.
Uint8List withoutBackSignatures(Uint8List key) {
  final out = BytesBuilder();
  for (final packet in readPackets(key)) {
    if (packet.tag != PgpTag.signature) {
      out.add(packet.encoded);
      continue;
    }
    final body = packet.body;
    final hashedEnd = 6 + ((body[4] << 8) | body[5]);
    final unhashedLength = (body[hashedEnd] << 8) | body[hashedEnd + 1];
    final unhashed = body.sublist(hashedEnd + 2, hashedEnd + 2 + unhashedLength);
    final kept = <int>[];
    for (var at = 0; at < unhashed.length;) {
      // These subpackets are short or use the two-octet length
      final first = unhashed[at];
      final headLength = first < 192 ? 1 : 2;
      final length = first < 192 ? first : ((first - 192) << 8) + unhashed[at + 1] + 192;
      final whole = unhashed.sublist(at, at + headLength + length);
      if (whole[headLength] & 0x7f != 32) kept.addAll(whole);
      at += headLength + length;
    }
    out.add(
      writePacket(PgpTag.signature, [
        ...body.sublist(0, hashedEnd),
        kept.length >> 8,
        kept.length & 0xff,
        ...kept,
        ...body.sublist(hashedEnd + 2 + unhashedLength),
      ], oldFormat: packet.oldFormat),
    );
  }
  return out.toBytes();
}

/// [key], an unprotected Ed25519 secret key, with [subkey] bound to it as
/// one more encryption subkey, made at [created] and expiring [expiry]
/// seconds later (0 for never): a binding signature Kemlock makes here.
Future<Uint8List> withSubkey(Uint8List key, KeyPacket subkey, {required DateTime created, int expiry = 0}) async {
  final primary = parseKeyPacket(readPackets(key).first);
  final seed = (unlockSecretKey(primary) as Ed25519Secret).seed;
  final seconds = created.millisecondsSinceEpoch ~/ 1000;
  List<int> be32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
  // The subkey as made at that time: its creation time is in its body
  final body = Uint8List.fromList(subkey.publicBody)..setAll(1, be32(seconds));
  final moved = parseKeyPacket(readPackets(writePacket(PgpTag.publicSubkey, body, oldFormat: true)).single);
  final binding = await makeSignature(
    type: 0x18,
    signer: primary,
    data: [...hashedKey(primary), ...hashedKey(moved)],
    hashed: [
      ...subpacket(33, [4, ...primary.fingerprint]),
      ...subpacket(2, be32(seconds)),
      ...subpacket(27, [PgpKeyFlag.encryptCommunications | PgpKeyFlag.encryptStorage]),
      if (expiry != 0) ...subpacket(9, be32(expiry)),
    ],
    sign: (digest) => signEdDsa(seed, digest),
  );
  return Uint8List.fromList([...key, ...moved.packet.encoded, ...writePacket(PgpTag.signature, binding, oldFormat: true)]);
}

void main() {
  final now = fixtureNow;

  group('to encrypt', () {
    test('a key in order gives its encryption subkey', () async {
      for (final (key, algorithm) in [
        (Keys.edPublic, 'cv25519'),
        (Keys.rsaPublic, 'rsa3072'),
        (Keys.kemlockEd, 'cv25519'),
        (Keys.kemlockRsa, 'rsa4096'),
        (Keys.signingSubkey, 'cv25519'),
        (_expiry('never'), 'cv25519'),
        (_expiry('future'), 'cv25519'),
      ]) {
        final certificate = await _read(key);
        expect(certificate.valid, isTrue);
        final chosen = certificate.encryptionKey(now);
        expect(chosen.name, algorithm);
        expect(chosen.fingerprint, certificate.subkeys.firstWhere((k) => k.info.canEncrypt).packet.fingerprint);
      }
    });

    test('the newest valid encryption subkey is chosen', () async {
      final spare = (await _read(_expiry('never'))).subkeys.single.packet;
      final older = (await _read(Keys.kemlockEd)).subkeys.single;
      // A subkey made a year after the key's own
      final later = older.info.created.add(const Duration(days: 365));
      final withNewer = await _read(await withSubkey(Keys.kemlockEd, spare, created: later));
      expect(withNewer.valid, isTrue);
      expect(withNewer.subkeys, hasLength(2));
      expect(withNewer.encryptionKey(now).fingerprint, withNewer.subkeys[1].packet.fingerprint);

      // One made before it is not preferred
      final withOlder = await _read(
        await withSubkey(Keys.kemlockEd, spare, created: older.info.created.subtract(const Duration(days: 30))),
      );
      expect(withOlder.encryptionKey(now).fingerprint, older.packet.fingerprint);

      // The newest has expired: the older one is used again
      final withExpired = await _read(await withSubkey(Keys.kemlockEd, spare, created: later, expiry: 60));
      expect(withExpired.subkeys[1].troubleAt(later.add(const Duration(hours: 1))), PgpKeyTrouble.expired);
      expect(withExpired.encryptionKey(later.add(const Duration(seconds: 30))).fingerprint, withExpired.subkeys[1].packet.fingerprint);
      expect(withExpired.encryptionKey(later.add(const Duration(hours: 1))).fingerprint, older.packet.fingerprint);
    });

    test('an expired or revoked key is refused, saying which, as its standing says', () async {
      for (final (name, reason) in [
        ('expired', PgpKeyTrouble.expired),
        ('revoked', PgpKeyTrouble.revoked),
        ('revoked-expired', PgpKeyTrouble.revoked),
        // The primary key is in order; its only encryption subkey expired
        ('subkey-expired', PgpKeyTrouble.expired),
      ]) {
        final certificate = await _read(_expiry(name));
        expect(() => certificate.encryptionKey(now), throwsUnusable(reason, fingerprint: certificate.fingerprintHex), reason: name);

        // What the key's row and sheet show comes to the same
        final standing = keyStanding(certificate.info, now);
        final shown = standing.standing.isOver ? standing.standing : standing.subkeyProblem;
        expect(shown, reason == PgpKeyTrouble.expired ? Standing.expired : Standing.revoked, reason: name);
      }
      for (final name in ['never', 'future']) {
        final standing = keyStanding((await _read(_expiry(name))).info, now);
        expect((standing.standing.isOver, standing.subkeyProblem), (false, null));
      }
    });

    test('the expired key was usable before it expired', () async {
      final certificate = await _read(_expiry('expired'));
      expect(certificate.encryptionKey(DateTime.utc(2020, 6, 1)).name, 'cv25519');
      // And GnuPG's fixture key with a subkey that expires in two years
      final ed = await _read(Keys.edPublic);
      expect(() => ed.encryptionKey(DateTime.utc(2030)), throwsUnusable(PgpKeyTrouble.expired));
    });

    test('a key with a broken binding signature is refused whole', () async {
      final packets = readPackets(Keys.edPublic);
      final binding = packets.last;
      expect(binding.tag, PgpTag.signature);
      final broken = Uint8List.fromList(Keys.edPublic);
      broken[broken.length - 3] ^= 1;
      final certificate = await _read(broken);
      expect(certificate.valid, isFalse);
      expect(() => certificate.encryptionKey(now), throwsUnusable(PgpKeyTrouble.invalid));
      expect(() => certificate.signingKey(now), throwsUnusable(PgpKeyTrouble.invalid));
      expect(await certificate.mayVerify(certificate.primary), isFalse);
    });

    test('RSA 1024 is too weak to write to', () async {
      final certificate = await _read(Keys.rsa1024);
      expect(() => certificate.encryptionKey(now), throwsUnusable(PgpKeyTrouble.weak));
      expect(() => certificate.signingKey(now), throwsUnusable(PgpKeyTrouble.weak));
      // It still verifies and decrypts
      expect(await certificate.mayVerify(certificate.primary), isTrue);
      expect(certificate.decryptionKeys(parsePkesk(packetBody('gnupg/to-rsa1024.gpg', 1))), hasLength(1));
    });

    // openspec: add-post-quantum-pgp, task 6.4: version 6 keys, once read
    // only, are written to and sign
    test('a version 6 key is written to and signs', () async {
      final certificate = await _read(Keys.v6);
      expect(certificate.valid, isTrue);
      expect(certificate.encryptionKey(now).algorithm, 25);
      expect(certificate.signingKey(now).algorithm, 27);
      expect(await certificate.mayVerify(certificate.primary), isTrue);
      expect(certificate.decryptionKeys(parsePkesk(packetBody('rfc9580/a8-x25519-ocb.asc', 1))), hasLength(1));
    });

    test('a curve Kemlock does not use is named', () async {
      final certificate = await _read(Keys.brainpool);
      expect(() => certificate.encryptionKey(now), throwsUnsupported('brainpoolP256r1'));
      expect(() => certificate.signingKey(now), throwsUnsupported('brainpoolP256r1'));
    });
  });

  group('to sign', () {
    test('the primary key when it may sign', () async {
      for (final key in [Keys.ed, Keys.rsa, Keys.kemlockEd, Keys.kemlockRsa, Keys.edProtected]) {
        final certificate = await _read(key);
        expect(certificate.signingKey(now).fingerprint, certificate.primary.packet.fingerprint);
      }
    });

    test('else its signing subkey', () async {
      final certificate = await _read(Keys.signingSubkey);
      expect(certificate.primary.info.canSign, isFalse);
      final chosen = certificate.signingKey(now);
      expect(chosen.fingerprint, certificate.subkeys.firstWhere((k) => k.info.canSign).packet.fingerprint);
      expect(chosen.name, 'ed25519');
    });

    test('expired and revoked keys do not sign', () async {
      expect(() async => (await _read(_expiry('expired', secret: true))).signingKey(now), throwsUnusable(PgpKeyTrouble.expired));
      expect(() async => (await _read(_expiry('revoked', secret: true))).signingKey(now), throwsUnusable(PgpKeyTrouble.revoked));
      // A subkey that expired does not stop the primary key signing
      expect((await _read(_expiry('subkey-expired', secret: true))).signingKey(now).name, 'ed25519');
    });

    test('a public key cannot sign, and a stub has no secret', () async {
      final public = await _read(Keys.edPublic);
      expect(() => public.signingKey(now), throwsA(isA<PgpException>().having((e) => e.problem, 'problem', PgpProblem.noSecretHere)));
      // The stub's primary packet is a secret key packet with no secret in it
      final stub = await _read(Keys.stub);
      expect(
        () => unlockSecretKey(stub.signingKey(now)),
        throwsA(isA<PgpException>().having((e) => e.problem, 'problem', PgpProblem.noSecretHere)),
      );
    });
  });

  group('to verify', () {
    test('a signing subkey needs its back-signature', () async {
      final whole = await _read(Keys.signingSubkey);
      final signing = whole.subkeys.firstWhere((k) => k.info.canSign);
      expect(await whole.mayVerify(signing), isTrue);

      final stripped = await _read(withoutBackSignatures(Keys.signingSubkey));
      // Its self-signatures still verify: only the back-signature is gone
      expect(stripped.valid, isTrue);
      expect(await stripped.mayVerify(stripped.subkeys.firstWhere((k) => k.info.canSign)), isFalse);
      expect(await stripped.mayVerify(stripped.primary), isTrue);
    });

    test('an encryption subkey is no signer', () async {
      final certificate = await _read(Keys.edPublic);
      expect(await certificate.mayVerify(certificate.subkeys.single), isFalse);
    });

    test('the issuer is found by fingerprint or key ID', () async {
      final certificate = await _read(Keys.signingSubkey);
      final signature = parseSignature(readPackets(pgpFixture('gnupg/message.txt.signing-subkey.sig')).single.body);
      final issuer = certificate.issuerOf(signature)!;
      expect(issuer.info.canSign, isTrue);
      expect(identical(issuer, certificate.primary), isFalse);
      expect((await _read(Keys.edPublic)).issuerOf(signature), isNull);
    });
  });

  group('to decrypt', () {
    test('the key a message names, whatever its standing', () async {
      final ed = await _read(Keys.ed);
      final named = ed.decryptionKeys(parsePkesk(packetBody('gnupg/to-ed25519.seipd.gpg', 1)));
      expect(named.single.fingerprint, ed.subkeys.single.packet.fingerprint);
      expect(ed.decryptionKeys(parsePkesk(packetBody('gnupg/to-rsa3072.seipd.gpg', 1))), isEmpty);
      // A public key decrypts nothing
      expect((await _read(Keys.edPublic)).decryptionKeys(parsePkesk(packetBody('gnupg/to-ed25519.seipd.gpg', 1))), isEmpty);
    });

    test('a hidden recipient: every secret key of the algorithm', () async {
      final hidden = parsePkesk(packetBody('gnupg/hidden.gpg', 1));
      expect((await _read(Keys.ed)).decryptionKeys(hidden).single.name, 'cv25519');
      expect((await _read(Keys.rsa)).decryptionKeys(hidden), isEmpty);
    });
  });

  // openspec: add-post-quantum-pgp, task 6.4
  group('post-quantum keys', () {
    final now = fixtureNow;
    Uint8List key(String path) => binaryKey('keys/$path');

    test('the standard key is written to with ML-KEM-768+X25519 and signs with ML-DSA-65+Ed25519', () async {
      final certificate = await _read(key('kemlock/pgp-pq-standard.unprotected.asc'));
      expect(certificate.encryptionKey(now).algorithm, 35);
      expect(certificate.signingKey(now).algorithm, 30);
      expect(certificate.readsSeipd2, isTrue);
    });

    test("GnuPG's Kyber keys are written to, the pqc shortcut's not, its primary key not checkable", () async {
      for (final name in ['ky768-cv25519', 'ky1024-bp384']) {
        final certificate = await _read(key('gnupg/pqc/$name.public.asc'));
        expect(certificate.encryptionKey(now).algorithm, 8, reason: name);
        expect(certificate.readsSeipd2, isFalse, reason: name);
      }
      expect(() async => (await _read(key('gnupg/pqc/pqc.public.asc'))).encryptionKey(now), throwsUnsupported('brainpoolP384r1'));
    });

    test('a key with a classical and a post-quantum subkey is written to with the post-quantum one, though it is older', () async {
      final certificate = await _read(key('gnupg/pqc/two-subkeys.public.asc'));
      final subkeys = certificate.subkeys.map((s) => s.info.algorithm).toList();
      expect(subkeys, ['ky768_cv25519', 'cv25519']);
      expect(certificate.subkeys.last.info.created.isAfter(certificate.subkeys.first.info.created), isTrue);
      expect(certificate.encryptionKey(now).name, 'ky768_cv25519');
    });

    test('keys of the algorithms not used are refused by name', () async {
      expect(() async => (await _read(key('rfc9980/a4-public.asc'))).encryptionKey(now), throwsUnsupported('mld87'));
      expect(() async => (await _read(key('rfc9980/a5-public.asc'))).signingKey(now), throwsUnsupported('SLH-DSA-SHAKE-128s'));
    });

    test('the version 2 form only when every recipient reads it', () async {
      final standard = await _read(key('kemlock/pgp-pq-standard.public.asc'));
      final a1 = await _read(key('rfc9980/a1-public.asc'));
      final kyber = await _read(key('gnupg/pqc/ky768-cv25519.public.asc'));
      final rsa = await _read(Keys.rsaPublic);
      expect(writesSeipd2([standard]), isTrue);
      expect(writesSeipd2([standard, a1]), a1.readsSeipd2);
      expect(writesSeipd2([kyber]), isFalse);
      expect(writesSeipd2([standard, kyber, rsa]), isFalse);
      expect(writesSeipd2([]), isFalse);
    });
  });
}
