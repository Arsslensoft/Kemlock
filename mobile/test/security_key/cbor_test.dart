import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/features/passkeys/passkey_bytes.dart';
import 'package:kemlock/security_key/cbor.dart';

Uint8List _hex(String hex) {
  final clean = hex.replaceAll(' ', '');
  return Uint8List.fromList([for (var i = 0; i < clean.length; i += 2) int.parse(clean.substring(i, i + 2), radix: 16)]);
}

String _toHex(List<int> bytes) => [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join();

void main() {
  test('writes and reads the examples of RFC 8949 appendix A that CTAP2 uses', () {
    final examples = <(Object?, String)>[
      (0, '00'),
      (1, '01'),
      (10, '0a'),
      (23, '17'),
      (24, '1818'),
      (25, '1819'),
      (100, '1864'),
      (1000, '1903e8'),
      (1000000, '1a000f4240'),
      (1000000000000, '1b000000e8d4a51000'),
      (-1, '20'),
      (-10, '29'),
      (-100, '3863'),
      (-1000, '3903e7'),
      (false, 'f4'),
      (true, 'f5'),
      (Uint8List(0), '40'),
      (_hex('01020304'), '4401020304'),
      ('', '60'),
      ('a', '6161'),
      ('IETF', '6449455446'),
      ('"\\', '62225c'),
      ('ü', '62c3bc'),
      ('水', '63e6b0b4'),
      (<Object?>[], '80'),
      (<Object?>[1, 2, 3], '83010203'),
      (
        <Object?>[
          1,
          <Object?>[2, 3],
          <Object?>[4, 5],
        ],
        '8301820203820405',
      ),
      (<Object?>[for (var i = 1; i <= 25; i++) i], '98190102030405060708090a0b0c0d0e0f101112131415161718181819'),
      (<Object, Object?>{}, 'a0'),
      (<Object, Object?>{1: 2, 3: 4}, 'a201020304'),
      (
        <Object, Object?>{
          'a': 1,
          'b': <Object?>[2, 3],
        },
        'a26161016162820203',
      ),
      (
        <Object?>[
          'a',
          <Object, Object?>{'b': 'c'},
        ],
        '826161a161626163',
      ),
      (<Object, Object?>{'a': 'A', 'b': 'B', 'c': 'C', 'd': 'D', 'e': 'E'}, 'a56161614161626142616361436164614461656145'),
    ];
    for (final (value, hex) in examples) {
      expect(_toHex(cborEncode(value)), hex, reason: 'writing $value');
      expect(cborDecode(_hex(hex)), value, reason: 'reading $hex');
    }
  });

  test('writes map keys in CTAP2 canonical order, whatever order they were given in', () {
    // Numbers before text, shorter before longer, then byte order: 1, 3, 24, -1, -2, "b", "aa".
    final map = <Object, Object?>{'aa': 0, 'b': 0, -2: 0, 24: 0, -1: 0, 3: 0, 1: 0};

    expect(
      _toHex(cborEncode(map)),
      'a7'
      '0100'
      '0300'
      '181800'
      '2000'
      '2100'
      '616200'
      '62616100',
    );
    expect(cborEncode(Map.fromEntries(map.entries.toList().reversed)), cborEncode(map));
    expect((cborDecode(cborEncode(map))! as Map).keys, [1, 3, 24, -1, -2, 'b', 'aa']);
  });

  test('reads a map whose keys are out of order, as a platform must', () {
    expect(cborDecode(_hex('a2 03 04 01 02')), {3: 4, 1: 2});
  });

  test('refuses what CTAP2 forbids and what is not whole', () {
    final refused = {
      'an indefinite byte string': '5f4101ff',
      'an indefinite text string': '7f6161ff',
      'an indefinite array': '9f01ff',
      'an indefinite map': 'bf0102ff',
      'a lone break': 'ff',
      'a duplicate number key': 'a201020103',
      'a duplicate text key': 'a2616101616102',
      'trailing bytes': '0000',
      'a truncated number': '19 03',
      'a truncated byte string': '44010203',
      'a truncated array': '8301 02',
      'a truncated map': 'a2 0102 03',
      'an array longer than the input': '9a ffffffff',
      'nothing': '',
      'a tag': 'c074323031332d30332d32315432303a30343a30305a',
      'a number past 63 bits': '1b ffffffffffffffff',
      'a byte string as a map key': 'a1 4101 02',
      'text that is not UTF-8': '62 c328',
      'a reserved length': '1c',
    };
    for (final MapEntry(key: what, value: hex) in refused.entries) {
      expect(() => cborDecode(_hex(hex)), throwsA(isA<CborError>()), reason: what);
    }
    expect(() => cborEncode(<Object, Object?>{1: 0, 1.5: 0}), throwsA(isA<CborError>()));
    expect(() => cborEncode(1.5), throwsA(isA<CborError>()));
    expect(() => cborEncode(null), throwsA(isA<CborError>()));
  });

  test('reads null and floating-point numbers, which a key may put under a member the app does not use', () {
    expect(cborDecode(_hex('a3 01 f6 02 f93c00 03 fb3ff199999999999a')), {1: null, 2: 1.0, 3: 1.1});
    expect(cborDecode(_hex('fa47c35000')), 100000.0);
    expect(cborDecode(_hex('f9c400')), -4.0);
  });

  test('keeps only the keys of the kind asked for', () {
    final mixed = cborDecode(_hex('a2 01 02 6161 03'));
    expect(cborIntMap(mixed), {1: 2});
    expect(cborTextMap(mixed), {'a': 3});
    expect(cborIntMap(7), isEmpty);
    expect(cborTextMap(null), isEmpty);
  });

  test('reads the COSE key and the attestation object passkey_bytes.dart writes', () {
    final pair = P256KeyPair.fromScalar(Uint8List.fromList(List.generate(32, (i) => i + 1)));

    final cose = coseEs256Key(pair.point);
    expect(cborDecode(cose), {1: 2, 3: -7, -1: 1, -2: pair.x, -3: pair.y});
    expect(cborEncode({-3: pair.y, -2: pair.x, -1: 1, 3: -7, 1: 2}), cose, reason: 'the two writers agree on the canonical form');

    final authData = registrationAuthData(rpId: 'example.org', credentialId: Uint8List.fromList(List.filled(16, 7)), point: pair.point);
    final attestation = attestationObject(authData);
    expect(cborDecode(attestation), {'fmt': 'none', 'attStmt': <Object, Object?>{}, 'authData': authData});
    expect(cborEncode({'authData': authData, 'fmt': 'none', 'attStmt': <Object, Object?>{}}), attestation);
  });
}
