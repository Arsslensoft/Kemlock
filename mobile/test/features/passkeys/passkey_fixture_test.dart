import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/features/passkeys/passkey_bytes.dart';
import 'package:kemlock/features/passkeys/passkey_inbox.dart';

/// The passkey fixtures, which are never regenerated (see the README beside
/// them): the iOS and Android providers build these same bytes.
final _fixture = jsonDecode(File('test/fixtures/passkeys/passkeys.json').readAsStringSync()) as Map<String, Object?>;

Map<String, Object?> _part(String name) => _fixture[name]! as Map<String, Object?>;
Uint8List _bytes(Map<String, Object?> part, String key) => unb64(part[key]! as String);

void main() {
  final credential = _part('credential');
  final point = _bytes(credential, 'point');

  test('the AAGUID is Kemlock’s', () {
    expect(_fixture['aaguid'], kemlockAaguid);
    expect(kemlockAaguidBytes, hasLength(16));
  });

  test('reads the credential key from its PKCS#8, and writes it back the same', () async {
    final key = await P256KeyPair.fromPkcs8(_bytes(credential, 'privateKey'));

    expect(key.d, _bytes(credential, 'd'));
    expect(key.point, point);
    expect(key.toPkcs8(), _bytes(credential, 'privateKey'));
  });

  test('builds the registration bytes', () {
    final registration = _part('registration');
    final credentialId = unb64url(credential['credentialId']! as String);

    expect(coseEs256Key(point), _bytes(registration, 'coseKey'));
    final authData = registrationAuthData(rpId: credential['rpId']! as String, credentialId: credentialId, point: point);
    expect(authData, _bytes(registration, 'authData'));
    expect(attestationObject(authData), _bytes(registration, 'attestationObject'));
  });

  test('builds the assertion bytes, and its signature verifies', () async {
    final assertion = _part('assertion');
    final hash = Uint8List.fromList(sha256.convert(utf8.encode(assertion['clientDataJSON']! as String)).bytes);

    expect(hash, _bytes(assertion, 'clientDataHash'));
    final authData = assertionAuthData(credential['rpId']! as String);
    expect(authData, _bytes(assertion, 'authData'));
    final signed = assertionSignedBytes(authData, hash);
    expect(signed, _bytes(assertion, 'signedBytes'));
    expect(es256Verify(point, signed, _bytes(assertion, 'signature')), isTrue);
    // A signature made now verifies too, and one over other bytes doesn't
    final key = await P256KeyPair.fromPkcs8(_bytes(credential, 'privateKey'));
    expect(es256Verify(point, signed, es256Sign(key, signed)), isTrue);
    expect(es256Verify(point, Uint8List.fromList([...signed, 0]), _bytes(assertion, 'signature')), isFalse);
  });

  test('seals the inbox record to the same file, and opens it', () async {
    final inbox = _part('inbox');
    final key = await P256KeyPair.fromPkcs8(_bytes(inbox['key']! as Map<String, Object?>, 'privateKey'));
    final ephemeral = await P256KeyPair.fromPkcs8(_bytes(inbox['ephemeral']! as Map<String, Object?>, 'privateKey'));
    final record = InboxRecord.fromJson(inbox['record']! as Map<String, Object?>);

    expect(p256SharedSecret(ephemeral.d, key.point), _bytes(inbox, 'sharedSecret'));
    expect(p256SharedSecret(key.d, ephemeral.point), _bytes(inbox, 'sharedSecret'));
    final file = await sealInboxRecord(record, key.point, ephemeral: ephemeral, nonce: _bytes(inbox, 'nonce'));
    expect(file, inbox['file']);
    final opened = await openInboxRecord(inbox['file']! as String, key);
    expect(opened.toJson(), inbox['record']);
  });

  test('refuses an inbox file that another key or a change keeps shut', () async {
    final inbox = _part('inbox');
    final file = jsonDecode(inbox['file']! as String) as Map<String, Object?>;
    final key = await P256KeyPair.fromPkcs8(_bytes(inbox['key']! as Map<String, Object?>, 'privateKey'));
    final ct = unb64(file['ct']! as String)..[0] ^= 1;

    await expectLater(openInboxRecord(inbox['file']! as String, newP256KeyPair()), throwsA(isA<InboxFileError>()));
    await expectLater(openInboxRecord(jsonEncode({...file, 'ct': b64(ct)}), key), throwsA(isA<InboxFileError>()));
    await expectLater(openInboxRecord(jsonEncode({...file, 'v': 2}), key), throwsA(isA<InboxFileError>()));
    await expectLater(openInboxRecord('not json', key), throwsA(isA<InboxFileError>()));
  });

  test('a fresh seal opens, with a key of its own each time', () async {
    final inbox = newP256KeyPair();
    final record = InboxRecord.fromJson(_part('inbox')['record']! as Map<String, Object?>);

    final first = await sealInboxRecord(record, inbox.point);
    final second = await sealInboxRecord(record, inbox.point);

    expect(first, isNot(second));
    expect((await openInboxRecord(first, inbox)).credentialId, record.credentialId);
    expect(record.toPasskey('p1').privateKey, record.privateKey);
  });
}
