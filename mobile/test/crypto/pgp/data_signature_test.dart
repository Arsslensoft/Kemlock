// Signatures over data: GnuPG's detached and inline signatures checked,
// and Kemlock's own made and checked.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keccak.dart';
import 'package:kemlock/crypto/keys/openpgp/armor.dart';
import 'package:kemlock/crypto/keys/openpgp/data_signature.dart';
import 'package:kemlock/crypto/keys/openpgp/key_info.dart';
import 'package:kemlock/crypto/keys/openpgp/message.dart';
import 'package:kemlock/crypto/keys/openpgp/packets.dart';
import 'package:kemlock/crypto/keys/openpgp/s2k.dart';
import 'package:kemlock/crypto/keys/openpgp/secret_key.dart';
import 'package:kemlock/crypto/keys/openpgp/signatures.dart' hide hashSha512;
import 'package:kemlock/crypto/keys/openpgp/stream.dart';
import 'package:kemlock/crypto/keys/openpgp/usable_keys.dart';
import 'package:kemlock/crypto/keys/pgp.dart';

import 'decrypt_test.dart' show throwsProblem;
import 'fixtures.dart';
import 'usable_keys_test.dart' show withoutBackSignatures;

Future<SignatureResult> _check(String signature, {required List<Uint8List> keys, Uint8List? data, DateTime? now}) async {
  final verified = await verify(
    signed: PgpData.bytes(pgpFixture('gnupg/$signature')),
    data: PgpData.bytes(data ?? (signature.startsWith('report') ? pgpFixture('gnupg/report.txt') : messageTxt)),
    verifiers: keys,
    now: now ?? fixtureNow,
  );
  expect(verified.content, isNull);
  return verified.signatures.single;
}

Uint8List _expiry(String name, {bool secret = false}) => binaryKey('keys/gnupg/expiry/$name.${secret ? 'secret' : 'public'}.asc');

void main() {
  group('detached signatures GnuPG made', () {
    for (final (file, key, fingerprint) in [
      ('message.txt.ed25519.sig', () => Keys.edPublic, Keys.edFingerprint),
      ('message.txt.ed25519.asc', () => Keys.edPublic, Keys.edFingerprint),
      ('message.txt.rsa3072.sig', () => Keys.rsaPublic, Keys.rsaFingerprint),
      ('message.txt.rsa3072.asc', () => Keys.rsaPublic, Keys.rsaFingerprint),
      ('message.txt.ed25519-protected.sig', () => Keys.edProtectedPublic, Keys.edProtectedFingerprint),
      ('message.txt.ed25519-protected.asc', () => Keys.edProtectedPublic, Keys.edProtectedFingerprint),
      ('message.txt.rsa3072-protected.sig', () => Keys.rsaProtectedPublic, Keys.rsaProtectedFingerprint),
      ('message.txt.rsa3072-protected.asc', () => Keys.rsaProtectedPublic, Keys.rsaProtectedFingerprint),
      ('report.txt.sig', () => Keys.edPublic, Keys.edFingerprint),
      // Text mode: the file's LF line endings are hashed as CR LF
      ('message.txt.text.sig', () => Keys.edPublic, Keys.edFingerprint),
    ]) {
      test('$file is good, made when GnuPG says', () async {
        final result = await _check(file, keys: [Keys.kemlockEd, key()]);
        expect(result.verdict, SignatureVerdict.good);
        expect(result.signerFingerprint, fingerprint);
        expect((result.keyExpired, result.keyRevoked), (false, false));
        final recorded = gnupgSignatures(file);
        if (recorded.isNotEmpty) {
          expect(result.made, recorded.single.made);
          expect(result.issuer, recorded.single.signer);
        }
      });
    }

    test('message.txt.rsa1024.sig matches, and is weak: an RSA key under 2048 bits can be factored', () async {
      final result = await _check('message.txt.rsa1024.sig', keys: [Keys.rsa1024]);
      expect((result.verdict, result.detail), (SignatureVerdict.weakKey, 'RSA 1024'));
      expect(result.signerFingerprint, 'E95EE09FEF5558A822254BE1072C81B8334FE703');
      expect(result.made, gnupgSignatures('message.txt.rsa1024.sig').single.made);
      // One that does not match is bad, whatever the key
      final changed = Uint8List.fromList(messageTxt)..[10] ^= 0x20;
      expect((await _check('message.txt.rsa1024.sig', keys: [Keys.rsa1024], data: changed)).verdict, SignatureVerdict.bad);
    });

    test('one changed byte of the file is bad', () async {
      for (final file in ['message.txt.ed25519.sig', 'message.txt.rsa3072.sig', 'message.txt.text.sig']) {
        final changed = Uint8List.fromList(messageTxt)..[10] ^= 0x20;
        final key = file.contains('rsa') ? Keys.rsaPublic : Keys.edPublic;
        final result = await _check(file, keys: [key], data: changed);
        expect(result.verdict, SignatureVerdict.bad, reason: file);
        expect(result.signerFingerprint, isNotNull);
      }
      // And one changed byte of the signature
      final signature = Uint8List.fromList(pgpFixture('gnupg/message.txt.ed25519.sig'));
      signature[signature.length - 5] ^= 1;
      final verified = await verify(
        signed: PgpData.bytes(signature),
        data: PgpData.bytes(messageTxt),
        verifiers: [Keys.edPublic],
        now: fixtureNow,
      );
      expect(verified.signatures.single.verdict, SignatureVerdict.bad);
    });

    test('text mode takes either line ending; binary mode does not', () async {
      final crlf = Uint8List.fromList(utf8.encode(utf8.decode(messageTxt).replaceAll('\n', '\r\n')));
      expect((await _check('message.txt.text.sig', keys: [Keys.edPublic], data: crlf)).verdict, SignatureVerdict.good);
      expect((await _check('message.txt.ed25519.sig', keys: [Keys.edPublic], data: crlf)).verdict, SignatureVerdict.bad);
    });

    test('the signer\'s key absent: unknown, with its fingerprint', () async {
      final result = await _check('message.txt.rsa3072.sig', keys: [Keys.edPublic]);
      expect(result.verdict, SignatureVerdict.unknownSigner);
      expect(result.issuer, Keys.rsaFingerprint);
      expect(result.signerFingerprint, isNull);
      expect(result.made, gnupgSignatures('message.txt.rsa3072.sig').single.made);
      expect((await _check('message.txt.rsa3072.sig', keys: const [])).verdict, SignatureVerdict.unknownSigner);
    });

    test('SHA-1 is not trusted, whoever made it', () async {
      final known = await _check('message.txt.sha1.sig', keys: [Keys.rsaPublic]);
      expect((known.verdict, known.detail, known.signerFingerprint), (SignatureVerdict.weakHash, 'SHA-1', Keys.rsaFingerprint));
      expect((await _check('message.txt.sha1.sig', keys: const [])).verdict, SignatureVerdict.weakHash);
    });

    test('a signing subkey: good with its back-signature, bad without', () async {
      final result = await _check('message.txt.signing-subkey.sig', keys: [Keys.signingSubkey]);
      expect(result.verdict, SignatureVerdict.good);
      // The primary key's fingerprint names the signer; the subkey made it
      final recorded = gnupgSignatures('message.txt.signing-subkey.sig').single;
      expect((result.signerFingerprint, result.issuer), (recorded.primary, recorded.signer));
      expect(recorded.primary, isNot(recorded.signer));

      final stripped = await _check('message.txt.signing-subkey.sig', keys: [withoutBackSignatures(Keys.signingSubkey)]);
      expect(stripped.verdict, SignatureVerdict.bad);
    });

    test('a signature that has expired is bad', () async {
      // Made with --default-sig-expire 10y
      final made = gnupgSignatures('message.txt.signing-subkey.sig').single.made;
      final before = await _check('message.txt.signing-subkey.sig', keys: [Keys.signingSubkey], now: made.add(const Duration(days: 3649)));
      expect(before.verdict, SignatureVerdict.good);
      final after = await _check('message.txt.signing-subkey.sig', keys: [Keys.signingSubkey], now: made.add(const Duration(days: 3651)));
      expect(after.verdict, SignatureVerdict.bad);
    });

    test('a key on brainpoolP256r1 is named, and one on NIST P-256 checked', () async {
      final result = await _check('message.txt.brainpoolP256r1.sig', keys: [Keys.brainpool]);
      expect((result.verdict, result.detail), (SignatureVerdict.unsupported, 'brainpoolP256r1'));
      expect((await _check('message.txt.brainpoolP256r1.sig', keys: const [])).verdict, SignatureVerdict.unknownSigner);
      expect((await _check('message.txt.nistp256.sig', keys: [Keys.nistp256])).verdict, SignatureVerdict.good);
    });

    test('a key whose self-signatures fail verifies nothing', () async {
      final broken = Uint8List.fromList(Keys.edPublic);
      broken[broken.length - 3] ^= 1;
      expect((await _check('message.txt.ed25519.sig', keys: [broken])).verdict, SignatureVerdict.bad);
    });

    test('what is no signature', () async {
      Future<PgpVerified> run(Uint8List signed, {Uint8List? data}) => verify(
        signed: PgpData.bytes(signed),
        data: data == null ? null : PgpData.bytes(data),
        verifiers: [Keys.edPublic],
        now: fixtureNow,
      );
      await expectLater(run(messageTxt, data: messageTxt), throwsProblem(PgpProblem.notAMessage));
      await expectLater(run(pgpFixture('gnupg/armored.asc'), data: messageTxt), throwsProblem(PgpProblem.notAMessage));
      await expectLater(run(pgpFixture('gnupg/to-ed25519.seipd.gpg'), data: messageTxt), throwsProblem(PgpProblem.notAMessage));
      // A lone signature with no file to check it against
      await expectLater(run(pgpFixture('gnupg/message.txt.ed25519.sig')), throwsProblem(PgpProblem.notAMessage, detail: 'detached'));
      await expectLater(run(pgpFixture('gnupg/message.txt.ed25519.asc')), throwsProblem(PgpProblem.notAMessage, detail: 'detached'));
      // An encrypted message is for Decrypt
      await expectLater(run(pgpFixture('gnupg/to-ed25519.seipd.gpg')), throwsProblem(PgpProblem.notAMessage, detail: 'encrypted'));
      await expectLater(run(pgpFixture('gnupg/sym-default.gpg')), throwsProblem(PgpProblem.notAMessage, detail: 'encrypted'));
    });
  });

  group('signed messages', () {
    test('GnuPG\'s inline-signed message gives its text and the result', () async {
      for (final file in ['inline-signed.gpg', 'inline-signed.asc']) {
        final verified = await verify(signed: PgpData.bytes(pgpFixture('gnupg/$file')), verifiers: [Keys.edPublic], now: fixtureNow);
        expect(verified.content, messageTxt);
        expect(verified.signatures.single.verdict, SignatureVerdict.good);
        expect(verified.signatures.single.made, gnupgSignatures(file).single.made);
      }
    });

    test('two signers are listed, each with their result', () async {
      final verified = await verify(
        signed: PgpData.bytes(pgpFixture('gnupg/two-signers.gpg')),
        verifiers: [Keys.rsaPublic],
        now: fixtureNow,
      );
      expect(verified.signatures, hasLength(2));
      final byIssuer = {for (final s in verified.signatures) s.issuer: s.verdict};
      expect(byIssuer, {Keys.rsaFingerprint: SignatureVerdict.good, Keys.edFingerprint: SignatureVerdict.unknownSigner});
    });

    test('A.7 of RFC 9580 verifies with the RFC\'s version 6 key', () async {
      final verified = await verify(
        signed: PgpData.bytes(pgpFixture('rfc9580/a7-inline-signed.asc')),
        verifiers: [Keys.v6Public],
        now: fixtureNow,
      );
      final result = verified.signatures.single;
      expect(result.verdict, SignatureVerdict.good);
      expect(result.signerFingerprint, 'CB186C4F0609A697E4D52DFA6C722B0C1F1E27C18A56708F6525EC27BAD9ACC9');
      expect(verified.isText, isTrue);
    });
  });

  group('the hash', () {
    test('text mode turns every line ending into CR LF, across pieces', () {
      Uint8List digest(List<String> pieces, {required bool text}) {
        final hasher = SignatureHasher.of(hashSha256, text: text)!;
        for (final piece in pieces) {
          hasher.add(Uint8List.fromList(utf8.encode(piece)));
        }
        return hasher.finish(Uint8List(0));
      }

      final canonical = digest(['one\r\ntwo\r\n\r\nthree'], text: false);
      expect(digest(['one\ntwo\n\nthree'], text: true), canonical);
      expect(digest(['one\r\ntwo\r\n\r\nthree'], text: true), canonical);
      expect(digest(['one\r', '\ntwo', '\n', '\nthr', 'ee'], text: true), canonical);
      expect(digest(['o', 'n', 'e', '\n', 't', 'w', 'o', '\n', '\n', 't', 'h', 'r', 'e', 'e'], text: true), canonical);
      expect(digest(['one\ntwo\n\nthree'], text: false), isNot(canonical));
    });

    test('SHA-3 hashes in pieces as it does at once', () {
      final data = Uint8List.fromList(List.generate(1000, (i) => i & 0xff));
      for (final (id, whole) in [(hashSha3_256, sha3_256(data)), (hashSha3_512, sha3_512(data))]) {
        final hasher = SignatureHasher.of(id, text: false)!
          ..add(Uint8List.sublistView(data, 0, 333))
          ..add(Uint8List.sublistView(data, 333));
        expect(hasher.finish(Uint8List(0)), whole);
      }
      expect(SignatureHasher.of(hashRipemd160, text: false), isNull);
      expect(SignatureHasher.of(99, text: false), isNull);
    });

    test('a version 6 salt is hashed first', () {
      final salted = SignatureHasher.of(hashSha512, text: false, salt: [1, 2, 3])!..add(Uint8List.fromList([4]));
      final plain = SignatureHasher.of(hashSha512, text: false)!..add(Uint8List.fromList([1, 2, 3, 4]));
      expect(salted.finish(Uint8List(0)), plain.finish(Uint8List(0)));
    });
  });

  group('signatures Kemlock makes', () {
    final time = DateTime.utc(2026, 11, 20, 9, 30);
    final data = Uint8List.fromList(utf8.encode('signed by Kemlock\nsecond line\n'));

    Future<SignatureResult> made(PgpSecretKey signer, Uint8List public, {PgpSignatureForm form = PgpSignatureForm.detached}) async {
      final signature = await sign(data: PgpData.bytes(data), signer: signer, form: form, now: time);
      final verified = await verify(signed: PgpData.bytes(signature), data: PgpData.bytes(data), verifiers: [public], now: time);
      return verified.signatures.single;
    }

    test('with the Ed25519 and the RSA 3072 fixture: its own checker says good', () async {
      for (final (secret, public, fingerprint) in [
        (Keys.ed, Keys.edPublic, Keys.edFingerprint),
        (Keys.rsa, Keys.rsaPublic, Keys.rsaFingerprint),
        (Keys.kemlockEd, Keys.kemlockEd, null),
        (Keys.kemlockRsa, Keys.kemlockRsa, null),
      ]) {
        for (final form in [PgpSignatureForm.detached, PgpSignatureForm.detachedArmored]) {
          final result = await made(PgpSecretKey(secret), public, form: form);
          expect(result.verdict, SignatureVerdict.good);
          expect(result.made, time);
          if (fingerprint != null) expect((result.signerFingerprint, result.issuer), (fingerprint, fingerprint));
        }
      }
    });

    test('it is version 4, SHA-512, with the issuer and the time hashed', () async {
      final signature = await sign(data: PgpData.bytes(data), signer: PgpSecretKey(Keys.ed), form: PgpSignatureForm.detached, now: time);
      final packet = readPackets(signature).single;
      expect((packet.tag, packet.oldFormat), (PgpTag.signature, false));
      final parsed = parseSignature(packet.body);
      expect((parsed.version, parsed.type, parsed.publicKeyAlgorithm, parsed.hashAlgorithm), (4, 0x00, 22, 10));
      expect(hexOf(parsed.issuerFingerprint!).toUpperCase(), Keys.edFingerprint);
      expect(parsed.created, time.millisecondsSinceEpoch ~/ 1000);
      // Ed25519 signatures are deterministic: the same bytes again
      expect(await sign(data: PgpData.bytes(data), signer: PgpSecretKey(Keys.ed), form: PgpSignatureForm.detached, now: time), signature);
      // Armored, it is a PGP SIGNATURE block of the same packet
      final armored = await sign(
        data: PgpData.bytes(data),
        signer: PgpSecretKey(Keys.ed),
        form: PgpSignatureForm.detachedArmored,
        now: time,
      );
      expect(utf8.decode(armored), startsWith('-----BEGIN PGP SIGNATURE-----\n'));
    });

    test('a signing subkey signs, and its signature verifies', () async {
      final result = await made(PgpSecretKey(Keys.signingSubkey), Keys.signingSubkey);
      expect(result.verdict, SignatureVerdict.good);
      expect(result.issuer, isNot(result.signerFingerprint));
    });

    test('a protected key asks for its passphrase', () async {
      Future<Uint8List> run(String? passphrase) => sign(
        data: PgpData.bytes(data),
        signer: PgpSecretKey(Keys.edProtected, passphrase: passphrase),
        form: PgpSignatureForm.detached,
        now: time,
      );
      await expectLater(run(null), throwsProblem(PgpProblem.passphraseNeeded, fingerprint: Keys.edProtectedFingerprint));
      await expectLater(run('wrong'), throwsProblem(PgpProblem.wrongPassphrase, fingerprint: Keys.edProtectedFingerprint));
      final before = Uint8List.fromList(Keys.edProtected);
      expect(
        (await made(PgpSecretKey(Keys.edProtected, passphrase: fixturePassphrase), Keys.edProtectedPublic)).verdict,
        SignatureVerdict.good,
      );
      expect(Keys.edProtected, before);
    });

    test('keys that may not sign are refused, saying why', () async {
      Future<Uint8List> run(Uint8List key) =>
          sign(data: PgpData.bytes(data), signer: PgpSecretKey(key), form: PgpSignatureForm.detached, now: time);
      await expectLater(
        run(_expiry('expired', secret: true)),
        throwsA(isA<PgpException>().having((e) => e.reason, 'reason', PgpKeyTrouble.expired)),
      );
      await expectLater(
        run(_expiry('revoked', secret: true)),
        throwsA(isA<PgpException>().having((e) => e.reason, 'reason', PgpKeyTrouble.revoked)),
      );
      await expectLater(run(Keys.rsa1024), throwsA(isA<PgpException>().having((e) => e.reason, 'reason', PgpKeyTrouble.weak)));
      // A version 6 key signs since add-post-quantum-pgp; one Kemlock cannot sign with is named
      await expectLater(run(binaryKey('keys/rfc9980/a5-secret.asc')), throwsProblem(PgpProblem.unsupported, detail: 'SLH-DSA-SHAKE-128s'));
      await expectLater(run(Keys.nistp256), throwsProblem(PgpProblem.unsupported, detail: 'nistp256'));
      await expectLater(run(Keys.edPublic), throwsProblem(PgpProblem.noSecretHere));
      await expectLater(run(Keys.stub), throwsProblem(PgpProblem.noSecretHere));
    });

    // The writer refuses such keys, so these signatures are made a layer down
    Future<Uint8List> signedBy(Uint8List key, DateTime when) async {
      final certificate = await PgpCertificate.read(key);
      final packet = certificate.primary.packet;
      return writeDetachedSignature(data: BytesSource(data), signer: MessageSigner(packet, unlockSecretKey(packet)), time: when);
    }

    test('a signature dated after its key\'s expiry is good, with the mark', () async {
      final expired = _expiry('expired', secret: true);
      final public = _expiry('expired');
      // The key was made on 2020-01-01 and expired a year later
      final late = await signedBy(expired, DateTime.utc(2021, 6, 1));
      final after = (await verify(
        signed: PgpData.bytes(late),
        data: PgpData.bytes(data),
        verifiers: [public],
        now: fixtureNow,
      )).signatures.single;
      expect((after.verdict, after.keyExpired, after.keyRevoked), (SignatureVerdict.good, true, false));
      expect(after.keyExpiredSince, isFalse);

      final early = await signedBy(expired, DateTime.utc(2020, 6, 1));
      final before = (await verify(
        signed: PgpData.bytes(early),
        data: PgpData.bytes(data),
        verifiers: [public],
        now: fixtureNow,
      )).signatures.single;
      expect((before.verdict, before.keyExpired), (SignatureVerdict.good, false));
    });

    test('a signature dated before its key expired, by a key expired now, is good with the other mark', () async {
      final early = await signedBy(_expiry('expired', secret: true), DateTime.utc(2020, 6, 1));
      Future<SignatureResult> at(DateTime now) async => (await verify(
        signed: PgpData.bytes(early),
        data: PgpData.bytes(data),
        verifiers: [_expiry('expired')],
        now: now,
      )).signatures.single;

      // Anyone who holds the key after it expired can date a signature so
      final since = await at(fixtureNow);
      expect((since.verdict, since.keyExpired, since.keyExpiredSince), (SignatureVerdict.good, false, true));
      final then = await at(DateTime.utc(2020, 7, 1));
      expect((then.verdict, then.keyExpired, then.keyExpiredSince), (SignatureVerdict.good, false, false));
    });

    test('a signature by a revoked key is good, with the mark', () async {
      final signature = await signedBy(_expiry('revoked', secret: true), time);
      final result = (await verify(
        signed: PgpData.bytes(signature),
        data: PgpData.bytes(data),
        verifiers: [_expiry('revoked')],
        now: time,
      )).signatures.single;
      expect((result.verdict, result.keyExpired, result.keyRevoked), (SignatureVerdict.good, false, true));
    });

    test('a critical subpacket nobody knows makes it bad', () async {
      final primary = (await PgpCertificate.read(Keys.ed)).primary.packet;
      final seed = (unlockSecretKey(primary) as Ed25519Secret).seed;
      Future<SignatureVerdict> verdictWith(int type) async {
        final hashedPart = signatureHashedPart(
          type: 0x00,
          signer: primary,
          hashed: [
            ...subpacket(33, [4, ...primary.fingerprint]),
            ...subpacket(2, [0x65, 0, 0, 0]),
            ...subpacket(type, [1, 2, 3]),
          ],
        );
        final hasher = SignatureHasher.of(hashSha512, text: false)!..add(data);
        final body = await finishSignature(
          hashedPart: hashedPart,
          signer: primary,
          digest: hasher.finish(signatureTrailerOf(hashedPart)),
          sign: (digest) => signEdDsa(seed, digest),
        );
        final verified = await verify(
          signed: PgpData.bytes(writePacket(PgpTag.signature, body)),
          data: PgpData.bytes(data),
          verifiers: [Keys.edPublic],
          now: fixtureNow,
        );
        return verified.signatures.single.verdict;
      }

      expect(await verdictWith(0x80 | 99), SignatureVerdict.bad);
      // Not marked critical, it is passed over
      expect(await verdictWith(99), SignatureVerdict.good);
    });
  });

  // openspec: add-post-quantum-pgp, task 6.3
  group('post-quantum signatures', () {
    final testing = Uint8List.fromList(utf8.encode('Testing\n'));
    final sequoiaText = File('test/fixtures/keys/sequoia/pqc/message.txt').readAsBytesSync();
    // Sequoia's files are armored whatever their names say
    Uint8List key(String path) {
      final bytes = File('test/fixtures/keys/$path').readAsBytesSync();
      return bytes[0] == 0x2d ? readArmorBlock(bytes) : bytes;
    }

    Future<SignatureResult> detached(Uint8List signature, Uint8List data, Uint8List signer) async =>
        (await verify(signed: PgpData.bytes(signature), data: PgpData.bytes(data), verifiers: [signer], now: fixtureNow)).signatures.single;

    /// [signature] with one byte changed in its Ed25519 part, or its ML-DSA one.
    Uint8List changed(Uint8List signature, {required bool mlDsa}) {
      final packet = readPackets(signature).single;
      final body = Uint8List.fromList(packet.body);
      final start = body.length - parseSignature(packet.body).material.length;
      body[start + (mlDsa ? 64 + 2000 : 20)] ^= 1;
      return writePacket(PgpTag.signature, body);
    }

    test("RFC 9980's A.3 detached signature is good, and bad with a byte changed in either part or in the data", () async {
      final signature = key('rfc9980/a3-signature.asc');
      final signer = key('rfc9980/a3-public.asc');
      final good = await detached(signature, testing, signer);
      expect(good.verdict, SignatureVerdict.good);
      expect(good.signerFingerprint, 'A3E2E14B6A493FF930FB27321F125E9A6880338BE9FB7DA3AE065EA65793242F');
      expect((await detached(changed(signature, mlDsa: true), testing, signer)).verdict, SignatureVerdict.bad);
      expect((await detached(changed(signature, mlDsa: false), testing, signer)).verdict, SignatureVerdict.bad);
      expect((await detached(signature, Uint8List.fromList(utf8.encode('Testing!')), signer)).verdict, SignatureVerdict.bad);
    });

    test("Sequoia's detached and inline signatures are good, by its signing subkey", () async {
      final signer = key('sequoia/pqc/standard.public.asc');
      final signature = key('sequoia/pqc/message.txt.sig');
      final good = await detached(signature, sequoiaText, signer);
      expect(good.verdict, SignatureVerdict.good);
      expect(good.signerFingerprint, 'CDB400EA83727C3BA3F4675018A8075B5A075B9F8C9D7AAAB9CA48BD4CCC609C');
      expect((await detached(changed(signature, mlDsa: true), sequoiaText, signer)).verdict, SignatureVerdict.bad);
      expect((await detached(changed(signature, mlDsa: false), sequoiaText, signer)).verdict, SignatureVerdict.bad);
      expect((await detached(signature, Uint8List.fromList([...sequoiaText, 0x20]), signer)).verdict, SignatureVerdict.bad);
      final inline = await verify(signed: PgpData.bytes(key('sequoia/pqc/message.signed.pgp')), verifiers: [signer], now: fixtureNow);
      expect(inline.content, sequoiaText);
      expect(inline.signatures.single.verdict, SignatureVerdict.good);
    });

    test('a signature by ML-DSA-87 or SLH-DSA cannot be checked, and is not called good or bad', () async {
      for (final (section, name) in [
        ('a4', 'mld87'),
        ('a5', 'SLH-DSA-SHAKE-128s'),
        ('a6', 'SLH-DSA-SHAKE-128f'),
        ('a7', 'SLH-DSA-SHAKE-256s'),
      ]) {
        final result = await detached(key('rfc9980/$section-signature.asc'), testing, key('rfc9980/$section-public.asc'));
        expect((result.verdict, result.detail), (SignatureVerdict.unsupported, name), reason: section);
      }
    });

    test('Kemlock signs with a standard key: detached, inline and in the clear, version 6 and good', () async {
      final secret = key('kemlock/pgp-pq-standard.unprotected.asc');
      final public = key('kemlock/pgp-pq-standard.public.asc');
      final data = Uint8List.fromList(utf8.encode('Signed post-quantum.\n'));
      final signature = await sign(
        data: PgpData.bytes(data),
        signer: PgpSecretKey(secret),
        form: PgpSignatureForm.detached,
        now: fixtureNow,
      );
      final parsed = parseSignature(readPackets(signature).single.body);
      expect((parsed.version, parsed.publicKeyAlgorithm, parsed.hashAlgorithm, parsed.salt?.length), (6, 30, 10, 32));
      expect((await detached(signature, data, public)).verdict, SignatureVerdict.good);
      expect((await detached(changed(signature, mlDsa: true), data, public)).verdict, SignatureVerdict.bad);

      final certificate = await PgpCertificate.read(secret);
      final packet = certificate.signingKey(fixtureNow);
      final out = BytesSink();
      await writeSignedData(
        data: BytesSource(data),
        out: out,
        signer: MessageSigner(packet, unlockSecretKey(packet)),
        format: 0x62,
        definite: true,
        time: fixtureNow,
      );
      final inline = out.takeBytes();
      expect(readPackets(inline).first.body.first, 6, reason: 'a version 6 one-pass packet');
      final read = await verify(signed: PgpData.bytes(inline), verifiers: [public], now: fixtureNow);
      expect(read.content, data);
      expect(read.signatures.single.verdict, SignatureVerdict.good);
    });

    test('signing with the GnuPG-format key gives the version 4 Ed25519 signature it gave before', () async {
      final secret = key('kemlock/pgp-pq-gnupg.unprotected.asc');
      final data = Uint8List.fromList(utf8.encode('Signed with Ed25519.\n'));
      final signature = await sign(
        data: PgpData.bytes(data),
        signer: PgpSecretKey(secret),
        form: PgpSignatureForm.detached,
        now: fixtureNow,
      );
      final parsed = parseSignature(readPackets(signature).single.body);
      expect((parsed.version, parsed.publicKeyAlgorithm, parsed.hashAlgorithm), (4, 22, 10));
      expect((await detached(signature, data, key('kemlock/pgp-pq-gnupg.public.asc'))).verdict, SignatureVerdict.good);
    });
  });
}
