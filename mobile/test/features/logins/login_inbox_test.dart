import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/features/logins/login_inbox.dart';
import 'package:kemlock/features/passkeys/passkey_inbox.dart';

const _fixturePath = 'test/fixtures/passkeys/logins.json';

Map<String, Object?> _json(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

/// The records the fixture seals, and the nonce each is sealed with.
final _inputs = <({String name, Map<String, Object?> record, String nonce})>[
  (
    name: 'a login saved on a website, its password generated',
    record: {
      'kind': 'login',
      'id': '5f0c9a8e-3b7d-4c2a-9e1f-6a8b2c4d0e11',
      'name': 'larkspur.example',
      'username': 'ada@example.org',
      'password': 'Hw7e%Ns3Ry_bX5tK?pM8a',
      'site': 'larkspur.example',
      'generated': true,
      'at': 1795300000000,
    },
    nonce: '000102030405060708090a0b',
  ),
  (
    name: 'a login saved in an Android app',
    record: {
      'kind': 'login',
      'id': '0b7e6d5c-4a39-4281-b7f6-e5d4c3b2a190',
      'name': 'Larkspur Mail',
      'username': 'ada',
      'password': 'one-two-three',
      'app': {'package': 'example.larkspur.mail', 'cert': '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'},
      'generated': false,
      'at': 1795300060000,
    },
    nonce: '0c0d0e0f1011121314151617',
  ),
  (
    name: 'a generated password no save followed',
    record: {'kind': 'generated', 'password': 'kT9#vq2L-wPz8!mR4x', 'site': 'larkspur.example', 'at': 1795300120000},
    nonce: '18191a1b1c1d1e1f20212223',
  ),
];

Uint8List _hex(String hex) => Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);

void main() {
  // The inbox key and ephemeral key of the passkey fixture, so the two fixtures share them
  final passkeys = _json('test/fixtures/passkeys/passkeys.json')['inbox']! as Map<String, Object?>;
  Future<P256KeyPair> key(String part) async =>
      P256KeyPair.fromPkcs8(unb64((passkeys[part]! as Map<String, Object?>)['privateKey']! as String));

  test('writes the fixture once', () async {
    final inbox = await key('key');
    final ephemeral = await key('ephemeral');
    final cases = [
      for (final input in _inputs)
        {
          'name': input.name,
          'nonce': input.nonce,
          'record': input.record,
          'file': await sealLoginRecord(
            LoginInboxRecord.fromJson(input.record),
            inbox.point,
            ephemeral: ephemeral,
            nonce: _hex(input.nonce),
          ),
        },
    ];
    File(_fixturePath).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'about': 'Login inbox files, written once by login_inbox_test.dart with the inbox key and the ephemeral key of passkeys.json (openspec: add-passwords, design decision 9). Never regenerate: Dart, Kotlin and Swift must each seal every record here to its file, byte for byte, and open it.', 'cases': cases})}\n',
    );
  }, skip: Platform.environment['WRITE_LOGIN_INBOX_FIXTURE'] != '1');

  group('the fixture', () {
    final file = File(_fixturePath);
    final cases = file.existsSync()
        ? (_json(_fixturePath)['cases']! as List<Object?>).cast<Map<String, Object?>>()
        : const <Map<String, Object?>>[];

    test('has every case', () => expect(cases, hasLength(_inputs.length)));

    for (final c in cases) {
      test('seals and opens ${c['name']}', () async {
        final inbox = await key('key');
        final ephemeral = await key('ephemeral');
        final record = LoginInboxRecord.fromJson(c['record']! as Map<String, Object?>);

        expect(record.toJson(), c['record'], reason: 'the record is written in its fixed order');
        expect(await sealLoginRecord(record, inbox.point, ephemeral: ephemeral, nonce: _hex(c['nonce']! as String)), c['file']);
        expect((await openLoginRecord(c['file']! as String, inbox)).toJson(), c['record']);
        expect(isLoginFile(c['file']! as String), isTrue);
      });
    }

    test('a version before logins finds no passkey in a login file, and leaves it', () async {
      final inbox = await key('key');
      await expectLater(openInboxRecord(cases.first['file']! as String, inbox), throwsA(isA<InboxFileError>()));
    });
  });

  test('a passkey file is no login file', () {
    expect(isLoginFile(passkeys['file']! as String), isFalse);
    expect(isLoginFile('not json'), isFalse);
  });

  test('another key keeps a login file shut', () async {
    final file = await sealLoginRecord(const LoginInboxRecord.generated(password: 'p', at: 1), newP256KeyPair().point);
    await expectLater(openLoginRecord(file, newP256KeyPair()), throwsA(isA<InboxFileError>()));
  });

  test('a saved record becomes a login AutoFill saved', () {
    final login = LoginInboxRecord.fromJson(_inputs.first.record).toLogin();
    expect(login.id, '5f0c9a8e-3b7d-4c2a-9e1f-6a8b2c4d0e11');
    expect(login.websites, ['larkspur.example']);
    expect(login.source, 'autofill');
    expect((login.addedAt, login.passwordChangedAt), (1795300000000, 1795300000000));
  });

  test('refuses a record of no kind it knows', () {
    expect(() => LoginInboxRecord.fromJson({'kind': 'card', 'password': 'p'}), throwsFormatException);
    expect(() => LoginInboxRecord.fromJson({'kind': 'login', 'name': 'n'}), throwsFormatException);
  });
}
