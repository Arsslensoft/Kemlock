import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/prf_wrap.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_auth_api.dart';
import 'package:kemlock/features/sync/kemlock/km_device_key.dart';
import 'package:kemlock/features/sync/kemlock/km_dpop.dart';
import 'package:kemlock/features/sync/kemlock/km_passkey.dart';
import 'package:kemlock/features/sync/kemlock/km_signin.dart';
import 'package:kemlock/features/sync/kemlock_key_step.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_key_step.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_webauthn.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/hmac_secret.dart';

import '../../../fakes/fake_security_keys.dart';
import '../../../helpers/test_app.dart' show bundledSuffixes;
import '../../../security_key/soft_key.dart';
import 'fake_kemlock_accounts.dart';
import 'fake_kemlock_server.dart';

const _device = KmDeviceInfo(name: 'Kemlock on Pixel 9', kind: 'kemlock-android');
final _server = Uri.parse('https://kem.example.com');

Uint8List _bytes(int length, int start) => Uint8List.fromList(List.generate(length, (i) => (start + i) & 255));

Uint8List _hmac(List<int> key, List<int> message) => Uint8List.fromList(Hmac(sha256, key).convert(message).bytes);

late KmTestAccount _account;

/// A security key held to the phone with one credential for the server's name, and the step that asks it.
class _Kit {
  _Kit({String rpId = 'kem.example.com', bool hmacSecret = true, bool discoverable = false})
    : soft = SoftKey(pin: '123456', hmacSecret: hmacSecret) {
    soft.made.add(
      SoftCredential(
        id: credentialId,
        rpId: rpId,
        withUv: _bytes(32, 1),
        withoutUv: _bytes(32, 90),
        hmacSecret: true,
        discoverable: discoverable,
        userId: discoverable ? userHandle : null,
      ),
    );
    phone.arrive(FakeKey(productName: 'Example Key', ctap: soft).device(kinds: {SecurityKeyLinkKind.nfc}));
  }

  final SoftKey soft;
  final phone = FakeSecurityKeys(phone: FakeSecurityKeys.android);
  final credentialId = _bytes(16, 100);
  final userHandle = _bytes(8, 50);
  final pins = <String>[];

  late final step = KmKeyStep(
    keys: phone,
    now: phone.now,
    suffixes: bundledSuffixes,
    askPin: (wrong) async {
      pins.add('asked');
      return Uint8List.fromList(utf8.encode('123456'));
    },
  );

  KmPasskeyOptions options({String rpId = 'kem.example.com', bool discoverable = false}) => KmPasskeyOptions(
    sealedChallenge: 'sealed-challenge-1',
    challenge: _bytes(32, 200),
    rpId: rpId,
    credentialIds: discoverable ? const [] : [_bytes(16, 1), credentialId],
  );
}

void main() {
  setUpAll(() async {
    _account = await KmTestAccount.create('00000000-0000-4000-8000-000000000001');
  });

  group('WebAuthn\'s PRF salt', () {
    test('is SHA-256 of "WebAuthn PRF", a zero byte and the input', () {
      // Computed outside the app: input 0, 1, ... 31
      expect(hex(webAuthnPrfSalt(_bytes(32, 0))), 'dc1f4f3b3d759586245d5de7e2e115d2a056a2df27109db7cef9b4b3a89bb106');
      // Kemlock's own input, SHA-256("kemlock/v1/prf-salt")
      expect(hex(prfEvalInput), '22f3a59b4a8c0212d1d1ecd26e0a4ad3676e5e862543c138bee7668602589417');
      expect(hex(webAuthnPrfSalt(prfEvalInput)), '838d430720bbe32f2003c794a1ae293d09aa8bd7b42ed6bff627d35ea86ee1f7');
    });
  });

  group('a security key over CTAP', () {
    test('signs the challenge for the server\'s origin and gives the PRF output of the mapped salt', () async {
      final kit = _Kit();
      final assertion = await kit.step.assertion(kit.options(), prfEvalInput, _server);

      expect(assertion.credentialId, kit.credentialId);
      final clientData = jsonDecode(utf8.decode(assertion.clientData)) as Map<String, Object?>;
      expect(clientData['type'], 'webauthn.get');
      expect(clientData['origin'], vwKeyOrigin(_server));
      expect(clientData['origin'], 'https://kem.example.com');
      expect(clientData['challenge'], b64urlEncode(kit.options().challenge));
      // The key was asked about the server's name, with the hash of that client data and the mapped salt
      // The soft key doesn't say how many credentials an allow list takes, so it is asked about one at a
      // time (maxCredentialsInList): the other credential first, then the one it holds
      expect(kit.soft.assertRequests, hasLength(2));
      final request = kit.soft.assertRequests.last;
      expect(request[1], 'kem.example.com');
      expect(request[2], vwKeyClientDataHash(assertion.clientData));
      expect(
        assertion.prfOutput,
        _hmac(_bytes(32, 1), webAuthnPrfSalt(prfEvalInput)),
        reason: 'the secret of the verified owner, for the mapped salt',
      );
      expect(kit.pins, ['asked'], reason: 'a key with a PIN set is asked for it before the secret');
    });

    test('a challenge for another name is refused before any key is looked for', () async {
      final kit = _Kit();
      await expectLater(
        kit.step.assertion(kit.options(rpId: 'evil.example.org'), prfEvalInput, _server),
        throwsA(isA<VwKeyStepError>().having((e) => e.problem, 'problem', VwKeyProblem.otherAddress)),
      );
      expect(kit.soft.assertRequests, isEmpty);
    });

    test('a key holding none of the account\'s credentials is "not registered"', () async {
      final kit = _Kit(rpId: 'another.example.org');
      await expectLater(
        kit.step.assertion(kit.options(), prfEvalInput, _server),
        throwsA(isA<VwKeyStepError>().having((e) => e.problem, 'problem', VwKeyProblem.notRegistered)),
      );
    });

    test('a discoverable credential is asked for with no allow list and answers with its user handle', () async {
      final kit = _Kit(discoverable: true);
      final assertion = await kit.step.assertion(kit.options(discoverable: true), prfEvalInput, _server);

      expect(kit.soft.assertRequests, hasLength(1));
      final request = kit.soft.assertRequests.single;
      expect(request[1], 'kem.example.com');
      expect(request.containsKey(3), isFalse, reason: 'an empty list is not sent: the key picks its own credential');
      expect(assertion.credentialId, kit.credentialId);
      expect(assertion.userHandle, kit.userHandle);
      expect(assertion.prfOutput, _hmac(_bytes(32, 1), webAuthnPrfSalt(prfEvalInput)));
    });

    test('a key with no discoverable credential for the name is "not registered"', () async {
      final kit = _Kit();
      await expectLater(
        kit.step.assertion(kit.options(discoverable: true), prfEvalInput, _server),
        throwsA(isA<VwKeyStepError>().having((e) => e.problem, 'problem', VwKeyProblem.notRegistered)),
      );
    });
  });

  group('the options and the credential', () {
    test('the options are read from the answer, flat or inside publicKey, with the sealed challenge kept apart', () {
      final options = {
        'challenge': b64urlEncode(_bytes(32, 5)),
        'rpId': 'kem.example.com',
        'allowCredentials': <Object?>[],
        'userVerification': 'required',
      };
      for (final wrapped in [
        options,
        {'publicKey': options},
      ]) {
        final read = KmPasskeyOptions.fromJson({'options': wrapped, 'challenge': 'sealed'});
        expect(read.sealedChallenge, 'sealed');
        expect(read.challenge, _bytes(32, 5));
        expect(read.rpId, 'kem.example.com');
        expect(read.credentialIds, isEmpty);
        expect(read.userVerification, 'required');
      }
    });

    test('options without a challenge, a name or the sealed challenge are refused', () {
      for (final bad in <Map<String, Object?>>[
        {
          'options': <String, Object?>{'rpId': 'kem.example.com'},
          'challenge': 's',
        },
        {
          'options': <String, Object?>{'challenge': 'AAAA'},
          'challenge': 's',
        },
        {
          'options': <String, Object?>{'challenge': 'AAAA', 'rpId': 'kem.example.com'},
        },
        {'options': 'text', 'challenge': 's'},
      ]) {
        expect(() => KmPasskeyOptions.fromJson(bad), throwsFormatException, reason: '$bad');
      }
    });

    test('the credential is a browser\'s toJSON: the id twice, the response, the user handle, and no extension results', () {
      final credential = kmPasskeyCredential(
        KmPasskeyAssertion(
          credentialId: _bytes(16, 100),
          authenticatorData: _bytes(37, 3),
          clientData: Uint8List.fromList(utf8.encode('{"type":"webauthn.get"}')),
          signature: _bytes(70, 9),
          userHandle: _bytes(8, 50),
          prfOutput: _bytes(32, 7),
        ),
      );

      expect(credential['id'], b64urlEncode(_bytes(16, 100)));
      expect(credential['rawId'], credential['id']);
      expect(credential['type'], 'public-key');
      final response = credential['response']! as Map<String, Object?>;
      expect(response.keys, unorderedEquals(['authenticatorData', 'clientDataJSON', 'signature', 'userHandle']));
      expect(response['userHandle'], b64urlEncode(_bytes(8, 50)));
      expect(credential['clientExtensionResults'], isEmpty, reason: 'the PRF output stays on the phone');
      expect(jsonEncode(credential), isNot(contains(b64urlEncode(_bytes(32, 7)))));
    });

    test('a credential with no user handle sends null', () {
      final credential = kmPasskeyCredential(
        KmPasskeyAssertion(
          credentialId: _bytes(4, 1),
          authenticatorData: _bytes(37, 3),
          clientData: _bytes(5, 1),
          signature: _bytes(70, 9),
        ),
      );
      expect((credential['response']! as Map<String, Object?>)['userHandle'], isNull);
    });
  });

  group('signing in with a passkey', () {
    Future<({KmSignIn signIn, FakeKemlockAccountServer server, Uint8List credential, Uint8List prf})> rig({
      bool wrapped = true,
      int keyVersion = 1,
    }) async {
      final server = FakeKemlockAccountServer(userId: _account.userId);
      final prf = _bytes(32, 7);
      final wrap = await wrapRootWithPrf(
        prfOutput: prf,
        credentialId: server.passkeyCredential,
        accountId: uuidBytes(_account.userId),
        keyVersion: keyVersion,
        rootKey: _account.root,
      );
      server.material = _account.material();
      server.passkeyWrap = wrapped ? {'wrappedKey': b64urlEncode(wrap), 'keyVersion': keyVersion} : null;
      final key = SoftwareDeviceKey.generate();
      final signIn = KmSignIn(
        api: KmApi(server.client, proofs: KmDpop(key)),
        server: FakeKemlockServer.url,
        device: _device,
        opaque: FakeKmOpaque(),
        argon2: cheapArgon2,
      );
      return (signIn: signIn, server: server, credential: server.passkeyCredential, prf: prf);
    }

    test('signs in, and the PRF output opens the account with the copy the sign-in answered with', () async {
      final (:signIn, :server, :credential, :prf) = await rig();
      final asserter = _Asserter(credential, prf);
      final step = await kmPasskeySignIn(signIn, asserter, 'me@example.com', prfEvalInput);
      final done = step as KmSignedIn;
      expect(done.account!.rootKey, _account.root);
      expect(asserter.inputs.single, prfEvalInput, reason: 'the PRF is asked for Kemlock\'s fixed input');
      expect(server.requests.map((r) => r.url.path), isNot(contains('/kem/v1/account/passkeys')), reason: 'no list of wraps is read');
    });

    test('asks for options with no email, and sends the sealed challenge back with the credential and the device', () async {
      final (:signIn, :server, :credential, :prf) = await rig();
      await kmPasskeySignIn(signIn, _Asserter(credential, prf), 'me@example.com', prfEvalInput);

      expect(server.passkeyOptionBodies.single, isEmpty);
      final sent = server.passkeyVerifies.single;
      expect(sent.keys, unorderedEquals(['challenge', 'credential', 'device']));
      expect(sent['challenge'], 'sealed-challenge-1');
      final sentCredential = sent['credential']! as Map<String, Object?>;
      expect(b64urlDecode(sentCredential['rawId']! as String), credential);
      expect((sentCredential['response']! as Map<String, Object?>)['userHandle'], b64urlEncode(_bytes(8, 50)));
      expect(jsonEncode(sent), isNot(contains(b64urlEncode(prf))), reason: 'the server never gets the PRF output');
    });

    test('the PRF output is wiped once the account is open', () async {
      final (:signIn, server: _, :credential, :prf) = await rig();
      final asserter = _Asserter(credential, prf);
      await kmPasskeySignIn(signIn, asserter, 'me@example.com', prfEvalInput);
      expect(asserter.given!.every((b) => b == 0), isTrue);
    });

    test('an authenticator without PRF signs in and leaves the account to be opened', () async {
      final (:signIn, server: _, :credential, prf: _) = await rig();
      final step = await kmPasskeySignIn(signIn, _Asserter(credential, null), 'me@example.com', prfEvalInput);
      expect((step as KmSignedIn).account, isNull);
    });

    test('a passkey with no copy of the root key signs in and leaves the account to be opened', () async {
      final (:signIn, server: _, :credential, :prf) = await rig(wrapped: false);
      final step = await kmPasskeySignIn(signIn, _Asserter(credential, prf), 'me@example.com', prfEvalInput);
      expect((step as KmSignedIn).account, isNull);
    });

    test('a copy for another key version than the account\'s now opens nothing', () async {
      final (:signIn, server: _, :credential, :prf) = await rig(keyVersion: 2);
      final step = await kmPasskeySignIn(signIn, _Asserter(credential, prf), 'me@example.com', prfEvalInput);
      expect((step as KmSignedIn).account, isNull);
    });

    test('a copy another output made does not open, and says so', () async {
      final (:signIn, server: _, :credential, prf: _) = await rig();
      await expectLater(
        kmPasskeySignIn(signIn, _Asserter(credential, _bytes(32, 99)), 'me@example.com', prfEvalInput),
        throwsA(isA<KmSignInError>().having((e) => e.issue, 'issue', KmSignInIssue.unreadable)),
      );
    });
  });

  group('the account\'s passkeys', () {
    Future<(KmAuthApi, FakeKemlockAccountServer)> authed() async {
      final server = FakeKemlockAccountServer(userId: _account.userId);
      server.checkTokens = false;
      final api = KmApi(server.client, proofs: KmDpop(SoftwareDeviceKey.generate()));
      return (KmAuthApi(api), server);
    }

    test('lists each with whether it holds a PRF copy and its key version', () async {
      final (auth, server) = await authed();
      final token = server.issueTokens('jkt')['accessToken']! as String;
      server.passkeyWrap = {'wrappedKey': b64urlEncode(Uint8List(92)), 'keyVersion': 1};
      final withCopy = (await auth.accountPasskeys(_server, token)).single;
      expect(withCopy.id, server.passkeyId);
      expect(withCopy.prf, isTrue);
      expect(withCopy.prfKeyVersion, 1);

      server.passkeyWrap = null;
      final without = (await auth.accountPasskeys(_server, token)).single;
      expect(without.prf, isFalse);
      expect(without.prfKeyVersion, isNull);
    });

    test('stores a PRF copy of 92 bytes for the current key version, and the server refuses another length or version', () async {
      final (auth, server) = await authed();
      final token = server.issueTokens('jkt')['accessToken']! as String;
      final wrap = _bytes(92, 4);

      await auth.setPasskeyPrf(_server, token, server.passkeyId, wrap, 1);

      expect(server.passkeyPrfPuts.single, {'wrappedKey': b64urlEncode(wrap), 'keyVersion': 1});
      await expectLater(auth.setPasskeyPrf(_server, token, server.passkeyId, _bytes(91, 4), 1), throwsA(isA<KmError>()));
      await expectLater(auth.setPasskeyPrf(_server, token, server.passkeyId, wrap, 2), throwsA(isA<KmError>()));
      expect(server.passkeyPrfPuts, hasLength(1));
    });
  });
}

String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// An authenticator that answers with a fixed credential and PRF output.
class _Asserter implements KmPasskeyAsserter {
  _Asserter(this.credential, Uint8List? prf) : given = prf == null ? null : Uint8List.fromList(prf);

  final Uint8List credential;

  /// The copy the sign-in is given and wipes.
  final Uint8List? given;
  final inputs = <Uint8List>[];

  @override
  Future<KmPasskeyAssertion> assertion(KmPasskeyOptions options, Uint8List prfInput, Uri server) async {
    inputs.add(prfInput);
    return KmPasskeyAssertion(
      credentialId: credential,
      authenticatorData: _bytes(37, 3),
      clientData: Uint8List.fromList(utf8.encode('{"type":"webauthn.get"}')),
      signature: _bytes(70, 9),
      userHandle: _bytes(8, 50),
      prfOutput: given,
    );
  }
}
