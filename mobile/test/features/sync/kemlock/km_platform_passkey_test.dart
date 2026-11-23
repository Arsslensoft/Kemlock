// Platform passkeys (add-kemlock-server-sync, task 7.2): the WebAuthn request
// and answer as JSON, the assetlinks check that decides whether the way in is
// offered, the channel's mapping of the platform's answers, and that iOS never
// offers one.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/prf_wrap.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_auth_api.dart';
import 'package:kemlock/features/sync/kemlock/km_platform_passkey.dart';
import 'package:kemlock/features/sync/kemlock/km_sso.dart' show KmBrowserAuth;
import 'package:kemlock/features/sync/kemlock/km_trust.dart';
import 'package:kemlock/features/sync/kemlock_flow.dart';
import 'package:kemlock/platform/device_keys.dart';
import 'package:kemlock/platform/platform_passkeys.dart';
import 'package:kemlock/platform/security_keys.dart' show SecurityKeyCancelled;

import '../../../fakes/fake_device_keys.dart';
import 'fake_kemlock_accounts.dart';
import 'km_phone_kit.dart';

const _package = 'com.kemlock.app';
const _channel = MethodChannel('com.kemlock.app/platform_passkeys');

final _options = KmPasskeyOptions(
  sealedChallenge: 'sealed-1',
  challenge: Uint8List.fromList(List.generate(32, (i) => i)),
  rpId: 'kem.example.com',
  credentialIds: [
    Uint8List.fromList([1, 2, 3]),
    Uint8List.fromList([4, 5, 6]),
  ],
);

String _response({Object? prf, String? rawId}) => jsonEncode({
  'id': 'ignored',
  'rawId': rawId ?? b64urlEncode(Uint8List.fromList([1, 2, 3])),
  'type': 'public-key',
  'response': {
    'clientDataJSON': b64urlEncode(utf8.encode('{"type":"webauthn.get"}')),
    'authenticatorData': b64urlEncode(Uint8List.fromList(List.filled(37, 7))),
    'signature': b64urlEncode(Uint8List.fromList(List.filled(70, 9))),
    'userHandle': b64urlEncode(Uint8List.fromList([7, 8])),
  },
  'clientExtensionResults': {
    if (prf != null)
      'prf': {
        'results': {'first': prf},
      },
  },
});

class _FakePasskeys implements KmPlatformPasskeys {
  _FakePasskeys({this.supported = true, this.answer});

  final bool supported;
  final String? answer;
  final requests = <String>[];

  @override
  Future<KmPlatformPasskeyInfo> info() async => KmPlatformPasskeyInfo(supported: supported, package: _package);

  @override
  Future<String> get(String requestJson) async {
    requests.add(requestJson);
    return answer!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the request', () {
    test('is the WebAuthn options as JSON, with the passkey\'s own ids and the PRF input', () {
      final json = jsonDecode(platformPasskeyRequest(_options, prfEvalInput)) as Map<String, Object?>;

      expect(json['rpId'], 'kem.example.com');
      expect(json['challenge'], b64urlEncode(_options.challenge));
      expect(json['userVerification'], 'required', reason: 'as the server asks it');
      expect(json['allowCredentials'], [
        {
          'type': 'public-key',
          'id': b64urlEncode(Uint8List.fromList([1, 2, 3])),
        },
        {
          'type': 'public-key',
          'id': b64urlEncode(Uint8List.fromList([4, 5, 6])),
        },
      ]);
      expect(((json['extensions']! as Map<String, Object?>)['prf']! as Map<String, Object?>)['eval'], {
        'first': b64urlEncode(prfEvalInput),
      });
    });

    test('has an empty allow list for the server\'s discoverable credentials, so the provider offers its own', () {
      final discoverable = KmPasskeyOptions(sealedChallenge: 'sealed-1', challenge: Uint8List(32), rpId: 'kem.example.com');
      final json = jsonDecode(platformPasskeyRequest(discoverable, prfEvalInput)) as Map<String, Object?>;

      expect(json['allowCredentials'], isEmpty);
      expect(json['userVerification'], 'required');
    });
  });

  group('the answer', () {
    test('gives the assertion the server verifies, and the PRF output', () {
      final prf = Uint8List.fromList(List.generate(32, (i) => 100 + i));
      final assertion = readPlatformPasskeyResponse(_response(prf: b64urlEncode(prf)));

      expect(assertion.credentialId, [1, 2, 3]);
      expect(utf8.decode(assertion.clientData), '{"type":"webauthn.get"}');
      expect(assertion.authenticatorData, hasLength(37));
      expect(assertion.signature, hasLength(70));
      expect(assertion.userHandle, [7, 8]);
      expect(assertion.prfOutput, prf);
    });

    test('has no PRF output when the provider gave none, or one of the wrong size', () {
      expect(readPlatformPasskeyResponse(_response()).prfOutput, isNull);
      expect(readPlatformPasskeyResponse(_response(prf: b64urlEncode(Uint8List(31)))).prfOutput, isNull);
    });

    test('an answer that is not a credential is a failure', () {
      for (final bad in [
        'not json',
        '[]',
        '{"response":{}}',
        jsonEncode({'rawId': 'AQID', 'response': {}}),
      ]) {
        expect(
          () => readPlatformPasskeyResponse(bad),
          throwsA(isA<KmPlatformPasskeyError>().having((e) => e.code, 'code', 'failed')),
          reason: bad,
        );
      }
    });

    test('the asserter sends the request and reads the answer', () async {
      final passkeys = _FakePasskeys(answer: _response());

      final assertion = await KmPlatformAsserter(passkeys).assertion(_options, prfEvalInput, Uri.parse('https://kem.example.com'));

      expect(passkeys.requests, hasLength(1));
      expect(assertion.credentialId, [1, 2, 3]);
    });
  });

  group('assetlinks.json', () {
    Object statement({
      String relation = 'delegate_permission/common.get_login_creds',
      String namespace = 'android_app',
      String package = _package,
    }) => {
      'relation': [relation],
      'target': {
        'namespace': namespace,
        'package_name': package,
        'sha256_cert_fingerprints': ['AA:BB'],
      },
    };

    test('names the app when a statement gives it the passkey relation', () {
      expect(assetLinksNameApp([statement()], _package), isTrue);
      expect(assetLinksNameApp([statement(package: 'com.other.app'), statement()], _package), isTrue);
    });

    test('does not when it names another app, another relation, a web target or is no list', () {
      expect(assetLinksNameApp([statement(package: 'com.other.app')], _package), isFalse);
      expect(assetLinksNameApp([statement(relation: 'delegate_permission/common.handle_all_urls')], _package), isFalse);
      expect(assetLinksNameApp([statement(namespace: 'web')], _package), isFalse);
      expect(assetLinksNameApp({'relation': []}, _package), isFalse);
      expect(assetLinksNameApp(null, _package), isFalse);
    });

    test('is read from the well-known path of the host, with no credentials', () async {
      http.Request? seen;
      final api = KmApi(
        MockClient((request) async {
          seen = request;
          return http.Response(jsonEncode([statement()]), 200, headers: {'content-type': 'application/json'});
        }),
      );

      final links = await api.assetLinks(Uri.parse('https://kem.example.com:8443/base'), host: 'login.example.com');

      expect(seen!.url.toString(), 'https://login.example.com/.well-known/assetlinks.json');
      expect(seen!.headers.keys.map((key) => key.toLowerCase()), isNot(contains('authorization')));
      expect(seen!.headers.keys.map((key) => key.toLowerCase()), isNot(contains('dpop')));
      expect(assetLinksNameApp(links, _package), isTrue);
    });

    test('a missing file is null', () async {
      final api = KmApi(MockClient((request) async => http.Response('', 404)));
      expect(await api.assetLinks(Uri.parse('https://kem.example.com')), isNull);
    });
  });

  group('whether the way in is offered', () {
    late KmTestAccount account;

    setUpAll(() async => account = await KmTestAccount.create('00000000-0000-4000-8000-000000000001'));

    Future<bool> offered(List<Object?>? links, {bool supported = true}) async {
      final server = FakeKemlockAccountServer(userId: account.userId)
        ..methods = {
          'methods': ['password'],
        };
      server.respond = (request) async => request.url.path == '/.well-known/assetlinks.json'
          ? (links == null ? http.Response('', 404) : http.Response(jsonEncode(links), 200, headers: {'content-type': 'application/json'}))
          : server.handle(request);
      final flow = KmSetupFlow(
        vaultId: 'main',
        values: KmMemoryValues(),
        clientFor: (pin) => server.client,
        deviceKeys: FakeDeviceKeys(hasHardware: false),
        trust: KmTrust(wrapper: DeviceKeysWrapper(FakeDeviceKeys(), protection: 'keystore')),
        parts: KmSetupParts(opaque: FakeKmOpaque(), deviceName: 'Kemlock on Pixel 9', deviceKind: 'kemlock-android', argon2: cheapArgon2),
        browser: _NoBrowser(),
      );
      final methods = await flow.connect('https://kem.example.com', 'me@example.com');
      return flow.platformPasskeyOffered(methods, _FakePasskeys(supported: supported));
    }

    final named = [
      {
        'relation': ['delegate_permission/common.get_login_creds'],
        'target': {'namespace': 'android_app', 'package_name': _package},
      },
    ];

    test('when the phone can ask for a passkey and the server names the app, whatever the account lists', () async {
      expect(await offered(named), isTrue);
    });

    test('not when the server\'s assetlinks.json is missing or names another app', () async {
      expect(await offered(null), isFalse);
      expect(
        await offered([
          {
            'relation': ['delegate_permission/common.get_login_creds'],
            'target': {'namespace': 'android_app', 'package_name': 'com.other.app'},
          },
        ]),
        isFalse,
      );
    });

    test('not when the phone cannot ask for one', () async {
      expect(await offered(named, supported: false), isFalse);
    });
  });

  group('the channel', () {
    void answer(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, handler);
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));
    }

    test('reports what the phone says: supported, and the app\'s package', () async {
      answer((call) async => {'supported': true, 'package': _package});

      final info = await ChannelPlatformPasskeys(ios: false).info();

      expect(info.supported, isTrue);
      expect(info.package, _package);
    });

    test('iOS never offers a platform passkey, whatever the channel says, and does not ask', () async {
      var asked = false;
      answer((call) async {
        asked = true;
        return {'supported': true, 'package': _package};
      });

      final info = await ChannelPlatformPasskeys(ios: true).info();

      expect(info.supported, isFalse);
      expect(asked, isFalse);
    });

    test('a build without the native side offers nothing', () async {
      expect((await ChannelPlatformPasskeys(ios: false).info()).supported, isFalse);
    });

    test('a closed picker is a cancel, no passkey is said so, and anything else is a failure', () async {
      answer((call) async => throw PlatformException(code: 'cancelled'));
      await expectLater(ChannelPlatformPasskeys(ios: false).get('{}'), throwsA(isA<SecurityKeyCancelled>()));

      answer((call) async => throw PlatformException(code: 'noCredential', message: 'none'));
      await expectLater(
        ChannelPlatformPasskeys(ios: false).get('{}'),
        throwsA(isA<KmPlatformPasskeyError>().having((e) => e.code, 'code', 'noCredential')),
      );

      answer((call) async => throw PlatformException(code: 'failed', message: 'boom'));
      await expectLater(
        ChannelPlatformPasskeys(ios: false).get('{}'),
        throwsA(isA<KmPlatformPasskeyError>().having((e) => e.message, 'message', 'boom')),
      );
    });

    test('hands the request over as JSON and returns the answer', () async {
      Object? sent;
      answer((call) async {
        sent = call.arguments;
        return '{"ok":true}';
      });

      expect(await ChannelPlatformPasskeys(ios: false).get('{"a":1}'), '{"ok":true}');
      expect(sent, {'requestJson': '{"a":1}'});
    });
  });
}

/// A browser sheet that is never opened.
class _NoBrowser implements KmBrowserAuth {
  @override
  Future<Uri?> authenticate(Uri url, {required String state}) async => null;

  @override
  Future<void> cancel() async {}
}
