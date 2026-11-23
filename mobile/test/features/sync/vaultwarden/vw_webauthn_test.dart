// The request and the answer of a security key sign-in, against what a
// real Vaultwarden sent and accepted (test/fixtures/vaultwarden/webauthn).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_webauthn.dart';

import '../../../helpers/test_app.dart' show bundledSuffixes;

String _fixture(String name) => File('test/fixtures/vaultwarden/webauthn/$name').readAsStringSync().trim();

final _received = DateTime.utc(2026, 11, 16, 9);

VwKeyChallenge? _parse(Map<String, Object?> json) => VwKeyChallenge.parse(json, receivedAt: _received);

Map<String, Object?> _options() => jsonDecode(_fixture('providers2-7.json')) as Map<String, Object?>;

void main() {
  group('the challenge', () {
    test('parses what the server sent', () {
      final challenge = _parse(_options())!;

      expect(challenge.challenge, 'x8G1k0ZH-D-N9AZUasBulEHWFpbehFLDT5O2O-L0Qmk');
      expect(challenge.rpId, 'localhost');
      expect(challenge.allowCredentials.map(b64url), ['K5batEojFBBKNyXM6Dn0zDxutfKnWjWVaMjT_5ODxJs']);
      expect(challenge.timeout, const Duration(minutes: 1));
      expect(challenge.appId, 'https://localhost:18443/app-id.json');
      expect(challenge.receivedAt, _received);
    });

    test('is no challenge without an rpId, a challenge or a credential', () {
      expect(_parse(_options()..remove('rpId')), isNull);
      expect(_parse(_options()..['rpId'] = ' '), isNull);
      expect(_parse(_options()..remove('challenge')), isNull);
      expect(_parse(_options()..['challenge'] = 'not base64url!'), isNull);
      expect(_parse(_options()..['allowCredentials'] = <Object?>[]), isNull);
      expect(_parse(_options()..remove('allowCredentials')), isNull);
      expect(
        _parse(
          _options()
            ..['allowCredentials'] = [
              {'type': 'public-key', 'id': '***'},
            ],
        ),
        isNull,
      );
      expect(VwKeyChallenge.parse(null, receivedAt: _received), isNull);
      expect(VwKeyChallenge.parse('7', receivedAt: _received), isNull);
    });

    test('takes a minute when the server names no time, and has no appid without the extension', () {
      final challenge = _parse(
        _options()
          ..remove('timeout')
          ..remove('extensions'),
      )!;

      expect(challenge.timeout, const Duration(minutes: 1));
      expect(challenge.appId, isNull);
    });

    test('is fresh until ten seconds before the server drops it', () {
      final challenge = _parse(_options())!;

      expect(challenge.isFresh(_received), isTrue);
      expect(challenge.isFresh(_received.add(const Duration(seconds: 49))), isTrue);
      expect(challenge.isFresh(_received.add(const Duration(seconds: 50))), isFalse);
      expect(challenge.isFresh(_received.add(const Duration(minutes: 2))), isFalse);
    });
  });

  group('the origin', () {
    String origin(String address) => vwKeyOrigin(Uri.parse(address));

    test('is the scheme and host, with the port when it is not 443', () {
      expect(origin('https://vault.example.org'), 'https://vault.example.org');
      expect(origin('https://vault.example.org:443'), 'https://vault.example.org');
      expect(origin('https://vault.example.org:8443'), 'https://vault.example.org:8443');
    });

    test('leaves a path out and writes the host in lower case', () {
      expect(origin('https://example.org/vault/'), 'https://example.org');
      expect(origin('https://example.org:8443/vault'), 'https://example.org:8443');
      expect(origin('https://Vault.Example.ORG'), 'https://vault.example.org');
    });

    test('keeps an IPv6 host in its brackets', () {
      expect(origin('https://[2001:db8::1]:8443'), 'https://[2001:db8::1]:8443');
    });
  });

  group('the rpId rule', () {
    bool allowed(String rpId, String address) => vwKeyRpIdAllowed(rpId, Uri.parse(address), suffixes: bundledSuffixes);

    test('takes the host itself, in any case', () {
      expect(allowed('vault.example.org', 'https://vault.example.org'), isTrue);
      expect(allowed('vault.example.org', 'https://vault.example.org:8443/vault'), isTrue);
      expect(allowed('Vault.Example.org', 'https://VAULT.example.org'), isTrue);
      expect(allowed('localhost', 'https://localhost:18443'), isTrue);
    });

    test('takes a parent domain', () {
      expect(allowed('example.org', 'https://vault.example.org'), isTrue);
      expect(allowed('example.org', 'https://a.b.example.org'), isTrue);
    });

    test('refuses a bare top-level name', () {
      expect(allowed('org', 'https://vault.example.org'), isFalse);
      expect(allowed('', 'https://vault.example.org'), isFalse);
    });

    test('refuses a public suffix, under which anyone can register a name', () {
      expect(allowed('co.uk', 'https://vault.example.co.uk'), isFalse);
      expect(allowed('example.co.uk', 'https://vault.example.co.uk'), isTrue);
      expect(allowed('herokuapp.com', 'https://vault-alice.herokuapp.com'), isFalse);
      expect(allowed('github.io', 'https://vault.alice.github.io'), isFalse);
      expect(allowed('alice.github.io', 'https://vault.alice.github.io'), isTrue);
    });

    test('without the Public Suffix List, takes the host only', () {
      bool bare(String rpId, String address) => vwKeyRpIdAllowed(rpId, Uri.parse(address));

      expect(bare('vault.example.org', 'https://vault.example.org:8443'), isTrue);
      expect(bare('example.org', 'https://vault.example.org'), isFalse);
      expect(bare('co.uk', 'https://vault.example.co.uk'), isFalse);
    });

    test('refuses an unrelated host, and one that only ends the same', () {
      expect(allowed('accounts.example.com', 'https://vault.example.org'), isFalse);
      expect(allowed('ample.org', 'https://vault.example.org'), isFalse);
      expect(allowed('vault.example.org', 'https://example.org'), isFalse);
      expect(allowed('.example.org', 'https://vault.example.org'), isFalse);
    });

    test('gives an IP address no parent domain', () {
      expect(allowed('192.168.1.20', 'https://192.168.1.20'), isTrue);
      expect(allowed('1.20', 'https://192.168.1.20'), isFalse);
      expect(allowed('168.1.20', 'https://192.168.1.20:8443'), isFalse);
      expect(allowed('vault.example.org', 'https://192.168.1.20'), isFalse);
      expect(allowed('2001:db8::1', 'https://[2001:db8::1]'), isTrue);
    });
  });

  group('the answer', () {
    final token = jsonDecode(_fixture('token.json')) as Map<String, Object?>;
    final response = token['response']! as Map<String, Object?>;
    final accepted = unb64url(response['clientDataJson']! as String);

    test('writes the client data a browser writes, byte for byte', () {
      final challenge = _parse(_options())!;
      final clientData = vwKeyClientData(challenge: challenge.challenge, origin: vwKeyOrigin(Uri.parse('https://localhost:18443')));

      expect(clientData, accepted);
      expect(
        utf8.decode(clientData),
        '{"type":"webauthn.get","challenge":"x8G1k0ZH-D-N9AZUasBulEHWFpbehFLDT5O2O-L0Qmk","origin":"https://localhost:18443","crossOrigin":false}',
      );
    });

    test('hashes the client data with SHA-256', () {
      // The SHA-256 of the three bytes "abc" (FIPS 180-2, appendix B.1)
      expect(
        vwKeyClientDataHash(utf8.encode('abc')).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('writes the token the server accepted, for the same inputs', () {
      final written = vwKeyToken(
        credentialId: unb64url(token['id']! as String),
        authenticatorData: unb64url(response['authenticatorData']! as String),
        clientData: accepted,
        signature: unb64url(response['signature']! as String),
      );

      expect(written, _fixture('token.json'));
    });
  });
}
