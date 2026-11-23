import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/der.dart';
import 'package:kemlock/crypto/keys/openpgp/key_info.dart';
import 'package:kemlock/crypto/keys/openpgp/packets.dart';
import 'package:kemlock/crypto/keys/openpgp/rsa.dart' show hashOids;
import 'package:kemlock/crypto/keys/openpgp/signatures.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/apdu.dart';
import 'package:kemlock/security_key/connection.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';

import '../security_key/hex.dart';
import 'fake_openpgp_card.dart';
import 'fake_security_keys.dart';

const _nfc = {SecurityKeyLinkKind.nfc};

/// Sends raw commands to [card] held to a fake phone, the way the app's
/// code will, and gives each answer.
Future<T> _onCard<T>(FakeOpenPgpCard card, Future<T> Function(SmartCardSession session) action) {
  final phone = FakeSecurityKeys();
  phone.arrive(FakeKey(applets: [card]).device(kinds: _nfc));
  return runOnKey(phone, (connection) async => action(await connection.selectApplication(openPgpAid)), now: phone.now);
}

ApduCommand _verify(int reference, String pin) => ApduCommand(ins: 0x20, p2: reference, data: utf8.encode(pin));

ApduCommand _sign(List<int> input) => ApduCommand(ins: 0x2a, p1: 0x9e, p2: 0x9a, data: input, le: 256);

ApduCommand _read(CardPlace place) => ApduCommand(ins: 0x47, p1: 0x81, data: [place.crt, 0], le: 256);

/// The OpenPGP key packet of a card's Ed25519 key, made [created].
KeyPacket _ed25519Packet(Uint8List public, int created) {
  final body = [
    4,
    created >> 24 & 0xff,
    created >> 16 & 0xff,
    created >> 8 & 0xff,
    created & 0xff,
    22,
    9,
    ...unhex('2b06010401da470f01'),
    ...mpiOfBytes([0x40, ...public]),
  ];
  return parseKeyPacket(readPackets(writePacket(PgpTag.publicKey, body, oldFormat: true)).single);
}

KeyPacket _rsaPacket(Uint8List n, Uint8List e, int created) {
  final body = [4, created >> 24 & 0xff, created >> 16 & 0xff, created >> 8 & 0xff, created & 0xff, 1, ...mpiOfBytes(n), ...mpiOfBytes(e)];
  return parseKeyPacket(readPackets(writePacket(PgpTag.publicKey, body, oldFormat: true)).single);
}

void main() {
  test('three wrong PINs block it, and then the right one is refused too', () async {
    final card = FakeOpenPgpCard();
    final statuses = await _onCard(card, (session) async {
      final out = <int>[];
      for (final pin in ['000000', '111111', '222222', FakeOpenPgpCard.factoryPin]) {
        out.add((await session.transmit(_verify(0x82, pin))).sw);
      }
      return out;
    });

    // A wrong PIN is "security status not satisfied", the last one too; "blocked" comes after
    expect(statuses, [0x6982, 0x6982, 0x6982, 0x6983]);
    expect(card.pinTries, 0);
    expect(card.adminPinTries, 3, reason: 'the admin PIN counts apart');
  });

  test('a card that counts in its status answers a wrong PIN with the tries left', () async {
    final card = FakeOpenPgpCard(wrongPinInStatus: true);
    final statuses = await _onCard(card, (session) async {
      final out = <int>[];
      for (final pin in ['000000', '111111', '222222', FakeOpenPgpCard.factoryPin]) {
        out.add((await session.transmit(_verify(0x82, pin))).sw);
      }
      return out;
    });

    expect(statuses, [0x63c2, 0x63c1, 0x6983, 0x6983]);
    expect(card.pinTries, 0);
  });

  test('an Ed25519 signature it makes verifies with verifySignature', () async {
    final card = FakeOpenPgpCard();
    card.load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature)));
    const created = 1794769831;
    final userId = utf8.encode('Card <card@example.org>');

    final (packet, body) = await _onCard(card, (session) async {
      final template = await session.transmit(_read(CardPlace.signature));
      final point = findTlv(parseTlvs(template.data), 0x86)!.value;
      final packet = _ed25519Packet(point, created);
      expect((await session.transmit(_verify(0x81, FakeOpenPgpCard.factoryPin))).ok, isTrue);
      final body = await makeSignature(
        type: 0x13,
        signer: packet,
        data: [...hashedKey(packet), ...hashedUserId(userId)],
        hashed: subpacket(2, [created >> 24 & 0xff, created >> 16 & 0xff, created >> 8 & 0xff, created & 0xff]),
        sign: (digest) async {
          final answer = await session.transmit(_sign(digest));
          expect(answer.ok, isTrue);
          return [...mpiOfBytes(answer.data.sublist(0, 32)), ...mpiOfBytes(answer.data.sublist(32))];
        },
      );
      return (packet, body);
    });

    expect(await verifySignature(parseSignature(body), packet, [...hashedKey(packet), ...hashedUserId(userId)]), isTrue);
    expect(card.signatures, 1);
    expect(card.log, containsAllInOrder(['select', 'read b6', 'verify 81', 'sign']));
  });

  test('an RSA signature it makes over a DigestInfo verifies with verifySignature', () async {
    final card = FakeOpenPgpCard();
    card.load(CardPlace.signature, await FakeCardKey.generate(RsaAttributes.ofBits(2048)));
    const created = 1794769831;
    final userId = utf8.encode('Card <card@example.org>');

    final (packet, body) = await _onCard(card, (session) async {
      final template = await session.transmit(_read(CardPlace.signature));
      final objects = parseTlvs(template.data);
      final packet = _rsaPacket(findTlv(objects, 0x81)!.value, findTlv(objects, 0x82)!.value, created);
      await session.transmit(_verify(0x81, FakeOpenPgpCard.factoryPin));
      final body = await makeSignature(
        type: 0x13,
        signer: packet,
        data: [...hashedKey(packet), ...hashedUserId(userId)],
        hashed: subpacket(2, [created >> 24 & 0xff, created >> 16 & 0xff, created >> 8 & 0xff, created & 0xff]),
        sign: (digest) async {
          final info = derSequence([
            derSequence([derOid(hashOids[10]!), derNull()]),
            derOctetString(digest),
          ]);
          return mpiOfBytes((await session.transmit(_sign(info))).data);
        },
      );
      return (packet, body);
    });

    expect(await verifySignature(parseSignature(body), packet, [...hashedKey(packet), ...hashedUserId(userId)]), isTrue);
  });

  test('a signature needs the PIN again when the card wants it for each one', () async {
    final card = FakeOpenPgpCard();
    card.load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature)));

    final statuses = await _onCard(card, (session) async {
      await session.transmit(_verify(0x81, FakeOpenPgpCard.factoryPin));
      return [(await session.transmit(_sign(Uint8List(64)))).sw, (await session.transmit(_sign(Uint8List(64)))).sw];
    });

    expect(statuses, [0x9000, 0x6982]);
  });

  test('a terminated card answers "terminated" to select, and activate brings it back empty', () async {
    final card = FakeOpenPgpCard();
    card.load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature)));
    card.pin = '654321';

    await _onCard(card, (session) async {
      for (var i = 0; i < 3; i++) {
        await session.transmit(_verify(0x83, '00000000'));
      }
      expect((await session.transmit(ApduCommand(ins: 0xe6))).ok, isTrue, reason: 'the admin PIN is blocked');
    });
    expect(card.terminated, isTrue);

    final phone = FakeSecurityKeys();
    phone.arrive(FakeKey(applets: [card]).device(kinds: _nfc));
    await runOnKey(phone, (connection) async {
      await expectLater(connection.selectApplication(openPgpAid), throwsA(isA<SecurityKeyFailed>()));
      final session = await connection.selectApplication(openPgpAid, alsoSelected: {0x6285});
      expect(session.selectStatus, 0x6285);
      expect((await session.transmit(ApduCommand(ins: 0x44))).ok, isTrue);
    }, now: phone.now);

    expect(card.terminated, isFalse);
    expect(card.keys, isEmpty);
    expect(card.pin, FakeOpenPgpCard.factoryPin);
    expect(card.adminPinTries, 3);
  });

  test('hashed PINs are taken hashed and refused plain', () async {
    final card = FakeOpenPgpCard()..hashPins(hashAlgorithm: 0x08);
    final settings = KdfSetting.parse(card.kdf);

    final statuses = await _onCard(card, (session) async {
      final plain = await session.transmit(_verify(0x82, FakeOpenPgpCard.factoryPin));
      final hashed = await session.transmit(
        ApduCommand(ins: 0x20, p2: 0x82, data: fakeCardKdf(FakeOpenPgpCard.factoryPin, 0x08, settings.count!, settings.saltPin!)),
      );
      return [plain.sw, hashed.sw];
    });

    expect(statuses, [0x6982, 0x9000]);
  });
}
