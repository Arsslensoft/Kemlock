import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/security_key/apdu.dart';
import 'package:kemlock/security_key/openpgp_card/card_commands.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';

import '../hex.dart';

/// The command as it goes over a link that takes extended APDUs: short
/// when it fits.
String _wire(ApduCommand command) => hex(command.fitsShort ? command.encodeShort() : command.encodeExtended());

Uint8List _ascii(String text) => Uint8List.fromList(ascii.encode(text));

void main() {
  // Every expected string below is written from the OpenPGP Smart Card
  // Application 3.4, section 7.2: CLA INS P1 P2, Lc and the data, Le.
  group('each command is the bytes the specification gives', () {
    test('selecting, reading and writing objects', () {
      expect(_wire(selectOpenPgp()), '00a4040006d2760001240100');
      expect(_wire(getData(0x6e)), '00ca006e00');
      expect(_wire(getData(0x5f52)), '00ca5f5200');
      expect(_wire(getData(0x00c4)), '00ca00c400');
      expect(_wire(getData(0x00fa)), '00ca00fa00');
      expect(_wire(putData(0x5b, _ascii('Doe<<Jo'))), '00da005b07446f653c3c4a6f');
      expect(_wire(putPinPolicy(everySignature: false)), '00da00c40101');
      expect(_wire(putPinPolicy(everySignature: true)), '00da00c40100');
      expect(_wire(putResetCode(_ascii('87654321'))), '00da00d3083837363534333231');
      expect(_wire(putResetCode(const [])), '00da00d3');
      expect(_wire(putTouch(CardPlace.signature, TouchPolicy.on)), '00da00d6020120');
      expect(_wire(putTouch(CardPlace.authentication, TouchPolicy.fixed)), '00da00d8020220');
      expect(
        _wire(putFingerprint(CardPlace.decryption, unhex('4ba83174fc8ce762a23bf0a4841a40e3b199ea67'))),
        '00da00c8144ba83174fc8ce762a23bf0a4841a40e3b199ea67',
      );
      expect(
        _wire(putKeyTime(CardPlace.authentication, DateTime.fromMillisecondsSinceEpoch(0x6afa23a7 * 1000, isUtc: true))),
        '00da00d0046afa23a7',
      );
      expect(
        _wire(putAttributes(CardPlace.signature, CardAlgorithm.parse(unhex('162b06010401da470f01')))),
        '00da00c10a162b06010401da470f01',
      );
      expect(_wire(putAttributes(CardPlace.decryption, RsaAttributes.ofBits(2048))), '00da00c206010800002000');
      expect(_wire(putKdf(unhex('810100'))), '00da00f903810100');
    });

    test('the PINs', () {
      expect(_wire(verifyPin(CardPin.pinToSign, _ascii('123456'))), '0020008106313233343536');
      expect(_wire(verifyPin(CardPin.pin, _ascii('123456'))), '0020008206313233343536');
      expect(_wire(verifyPin(CardPin.admin, _ascii('12345678'))), '00200083083132333435363738');
      expect(_wire(changePin(CardPin.pin, _ascii('123456'), _ascii('654321'))), '002400810c313233343536363534333231');
      expect(
        _wire(changePin(CardPin.admin, _ascii('12345678'), _ascii('87654321'))),
        '0024008310313233343536373838373635343332 31'.replaceAll(' ', ''),
      );
      expect(() => changePin(CardPin.resetCode, const [1], const [2]), throwsArgumentError);
      expect(_wire(resetPin(_ascii('654321'), resetCode: _ascii('87654321'))), '002c00810e3837363534333231363534333231');
      expect(_wire(resetPin(_ascii('654321'))), '002c028106363534333231');
    });

    test('the private operations', () {
      final digestInfo = unhex('3051300d060960864801650304020305000440${'ab' * 64}');
      expect(_wire(computeSignature(digestInfo)), '002a9e9a53${hex(digestInfo)}00');
      expect(_wire(computeSignature(unhex('cd' * 32))), '002a9e9a20${'cd' * 32}00');
      expect(_wire(decipherRsa(unhex('01' * 128))), '002a808681 00${'01' * 128}00'.replaceAll(' ', ''));
      // A 2048-bit cryptogram is 257 bytes with its padding indicator: an extended APDU
      expect(_wire(decipherRsa(unhex('02' * 256))), '002a8086000101 00${'02' * 256}0100'.replaceAll(' ', ''));
      expect(_wire(decipherEcdh(unhex('ee' * 32))), '002a808627a6257f49228620${'ee' * 32}00');
      expect(_wire(decipherEcdh(unhex('04${'aa' * 64}'))), '002a808648a6467f494386410 4${'aa' * 64}00'.replaceAll(' ', ''));
      expect(_wire(internalAuthenticate(unhex('11' * 32))), '0088000020${'11' * 32}00');
    });

    test('making and putting keys, and the factory reset', () {
      expect(_wire(generateKey(CardPlace.signature)), '0047800002b60000');
      expect(_wire(generateKey(CardPlace.decryption)), '0047800002b80000');
      expect(_wire(generateKey(CardPlace.authentication)), '0047800002a40000');
      expect(_wire(generateKey(CardPlace.signature, read: true)), '0047810002b60000');
      // Section 4.4.3.12's extended header list, for a 32-byte curve key
      expect(_wire(importKey(CardPlace.decryption, [(0x92, unhex('5a' * 32))])), '00db3fff2c4d2ab8007f480292205f4820${'5a' * 32}');
      // RSA in the standard form: e, p and q, each with its length in the template
      final rsa = _wire(importKey(CardPlace.signature, [(0x91, unhex('00010001')), (0x92, unhex('77' * 128)), (0x93, unhex('88' * 128))]));
      expect(rsa, '00db3fff00011a4d820116b6007f48089104928180938180 5f48820104 00010001${'77' * 128}${'88' * 128}'.replaceAll(' ', ''));
      expect(_wire(terminate()), '00e60000');
      expect(_wire(activate()), '00440000');
    });
  });

  group('status words', () {
    test('map to named errors', () {
      expect(
        cardError(0x63c2, pin: CardPin.admin),
        isA<CardWrongPin>().having((e) => e.triesLeft, 'tries', 2).having((e) => e.pin, 'pin', CardPin.admin),
      );
      expect(cardError(0x63c0), isA<CardWrongPin>().having((e) => e.triesLeft, 'tries', 0));
      expect(cardError(0x6983, pin: CardPin.resetCode), isA<CardPinBlocked>().having((e) => e.pin, 'pin', CardPin.resetCode));
      expect(cardError(0x6982), isA<CardSecurityNotSatisfied>());
      expect(cardError(0x6a88), isA<CardNotFound>());
      expect(cardError(0x6a82), isA<CardNotFound>());
      expect(cardError(0x6285), isA<CardTerminated>());
      expect(cardError(0x6d00), isA<CardNotSupported>());
      expect(cardError(0x6a80), isA<CardRefused>().having((e) => e.status, 'status', 0x6a80));
    });

    test('give the data of an answer that went well, and throw for one that did not', () {
      expect(cardAnswer(ApduResponse([1, 2], 0x9000)), [1, 2]);
      expect(() => cardAnswer(ApduResponse(const [], 0x63c1), pin: CardPin.pin), throwsA(isA<CardWrongPin>()));
      expect(() => cardAnswer(ApduResponse(const [], 0x6285)), throwsA(isA<CardTerminated>()));
    });
  });

  group('a public key from GENERATE', () {
    test('of a curve is its point', () {
      final key = CardPublicKey.parse(unhex('7f4922 8620${'ab' * 32}'.replaceAll(' ', '')));
      expect(key, isA<CardEcPublicKey>().having((k) => hex(k.point), 'point', 'ab' * 32));
    });

    test('of RSA is its modulus and exponent', () {
      final key = CardPublicKey.parse(unhex('7f49820109 81820100${'c3' * 256} 8203010001'.replaceAll(' ', '')));
      expect(key, isA<CardRsaPublicKey>().having((k) => k.modulus.length, 'modulus', 256).having((k) => hex(k.exponent), 'e', '010001'));
    });

    test('without either is the format error', () {
      expect(() => CardPublicKey.parse(unhex('7f4900')), throwsA(isA<CardFormatError>()));
      expect(() => CardPublicKey.parse(unhex('8620${'ab' * 32}')), throwsA(isA<CardFormatError>()));
    });
  });
}
