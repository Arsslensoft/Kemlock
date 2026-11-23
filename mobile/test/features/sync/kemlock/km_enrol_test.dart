// Enrolling the keys of an account that single sign-on made with none (add-kemlock-server-sync, task 6.3) against the
// fake server: the first phone makes the keys and its trusted-device copy of the root key and opens the account, a
// phone that finds an account with none enrols it too, and a 409 leaves the other device's keys alone.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/bundle.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/keys.dart';
import 'package:kemlock/crypto/account/private_keys.dart';
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_auth_api.dart';
import 'package:kemlock/features/sync/kemlock/km_device_key.dart';
import 'package:kemlock/features/sync/kemlock/km_dpop.dart';
import 'package:kemlock/features/sync/kemlock/km_signin.dart';
import 'package:kemlock/features/sync/kemlock/km_trust.dart';
import 'package:kemlock/platform/device_keys.dart';

import '../../../fakes/fake_device_keys.dart';
import 'fake_kemlock_accounts.dart';
import 'fake_kemlock_server.dart';

const _userId = '00000000-0000-4000-8000-000000000001';
const _device = KmDeviceInfo(name: 'Kemlock on Pixel 9', kind: 'kemlock-android');
const _tag = 'trust.main.$_userId';

/// An answer the server never gives: key version 0 with no keys in it (an account with none yet is a 404).
const _keyVersionZero = {'keyVersion': 0, 'wrappedRootKey': '', 'publicBundle': '', 'bundleSignature': '', 'sealedPrivateKeys': ''};

class _Phone {
  _Phone(this.server, {FakeDeviceKeys? keys, bool newAccount = true}) : keys = keys ?? FakeDeviceKeys() {
    trust = KmTrust(wrapper: DeviceKeysWrapper(this.keys, protection: 'secure-enclave'));
    final key = SoftwareDeviceKey.generate();
    signIn = KmSignIn(
      api: KmApi(server.client, proofs: KmDpop(key)),
      server: FakeKemlockServer.url,
      device: _device,
      opaque: FakeKmOpaque(),
      deviceKey: const {'protection': 'software'},
      argon2: cheapArgon2,
    );
    answer = KmSignInAnswer.fromJson({
      'status': 'signed_in',
      'tokens': server.issueTokens(FakeKemlockServer.thumbprint(key.publicJwk)),
      'newAccount': newAccount,
    }, DateTime.now().millisecondsSinceEpoch);
  }

  final FakeKemlockAccountServer server;
  final FakeDeviceKeys keys;
  late final KmTrust trust;
  late final KmSignIn signIn;
  late final KmSignInAnswer answer;

  /// The sign-in as SSO leaves it: signed in, the account not open. The ways in are asked first, as the sheet does,
  /// which also gives the proofs the server's nonce, and the requests of the sign-in itself are forgotten.
  Future<KmSignedIn> signedIn() async {
    await signIn.ways('me@example.com');
    final signed = await signIn.continueWith(answer) as KmSignedIn;
    server.requests.clear();
    return signed;
  }
}

/// The paths the server was sent requests for, in order.
List<String> _paths(FakeKemlockServer server) => [for (final request in server.requests) request.url.path.replaceFirst('/kem/v1', '')];

FakeKemlockAccountServer _keylessServer({Map<String, Object?>? answer}) => FakeKemlockAccountServer(userId: _userId)
  ..noKeys = true
  ..noKeysAnswer = answer;

void main() {
  late KmTestAccount account;

  setUpAll(() async {
    account = await KmTestAccount.create(_userId);
  });

  group('a new account', () {
    test('enrols its keys and its device copy in one request, and opens with no further step', () async {
      final server = _keylessServer();
      final phone = _Phone(server);
      final signed = await phone.signedIn();
      expect(signed.account, isNull);
      expect(signed.newAccount, isTrue);

      final opened = await phone.signIn.enrolKeys(signed.session, phone.trust, _tag, newAccount: signed.newAccount);

      expect(opened, isNotNull);
      expect(opened!.accountId, _userId);
      expect(opened.keyVersion, 1);
      expect(opened.rootKey, hasLength(rootKeyLength));
      expect(_paths(server), ['/account/keys/enrol', '/account/keys'], reason: 'the flag saves asking first');
      expect(server.enrolRefusals, 0);
    });

    test('sends the body the server takes: a signed bundle at version 1, sealed keys and the copy', () async {
      final server = _keylessServer();
      final phone = _Phone(server);
      final signed = await phone.signedIn();
      final opened = (await phone.signIn.enrolKeys(signed.session, phone.trust, _tag, newAccount: true))!;

      final body = server.keyEnrolments.single;
      expect(body.keys.toSet(), {'publicBundle', 'bundleSignature', 'sealedPrivateKeys', 'deviceCopy'});
      expect((body['deviceCopy']! as Map).keys.toSet(), {'wrappedKey', 'protection'});
      expect((body['deviceCopy']! as Map)['protection'], 'secure-enclave');

      final bundle = KeyBundle.parse(b64urlDecode(body['publicBundle']! as String));
      expect(uuidText(bundle.accountId), _userId);
      expect(bundle.keyVersion, 1);
      expect(await verifyBundle(bundle, b64urlDecode(body['bundleSignature']! as String)), isTrue);

      // The sealed private keys open under the root key the account holds, and are the bundle's own
      final keys = AccountKeys.fromRoot(opened.rootKey);
      final privateKeys = await openPrivateKeys(
        privateKeysKey: keys.privateKeysKey,
        accountId: uuidBytes(_userId),
        keyVersion: 1,
        sealed: b64urlDecode(body['sealedPrivateKeys']! as String),
      );
      keys.dispose();
      expect(privateKeys.kx1PrivateKey, opened.kx1PrivateKey);
      expect(privateKeys.sig1PrivateKey, opened.sig1PrivateKey);
      expect(opened.kx1PublicKey, bundle.kx1PublicKey);
      expect(opened.sig1PublicKey, bundle.sig1PublicKey);
    });

    test("the device copy it wrote opens with this phone's hardware key, for this device and account only", () async {
      final server = _keylessServer();
      final phone = _Phone(server);
      final signed = await phone.signedIn();
      final opened = (await phone.signIn.enrolKeys(signed.session, phone.trust, _tag, newAccount: true))!;

      final copy = server.keyCopy!;
      expect(copy['protection'], 'secure-enclave');
      final blob = b64urlDecode(copy['wrappedKey']!);
      expect(blob[0], 1, reason: 'the format version');
      expect(blob[1], 0x01, reason: 'the Secure Enclave platform byte');
      final deviceId = uuidBytes(signed.session.deviceId);

      final root = await phone.trust.open(tag: _tag, blob: blob, accountId: uuidBytes(_userId), deviceId: deviceId, keyVersion: 1);
      expect(root, opened.rootKey);

      Future<Uint8List> open({List<int>? accountId, List<int>? device, int keyVersion = 1}) => phone.trust.open(
        tag: _tag,
        blob: blob,
        accountId: accountId ?? uuidBytes(_userId),
        deviceId: device ?? deviceId,
        keyVersion: keyVersion,
      );
      final otherAccount = uuidBytes('00000000-0000-4000-8000-0000000000ff');
      final otherDevice = uuidBytes('00000000-0000-4000-8000-0000000000fe');
      await expectLater(open(accountId: otherAccount), throwsA(isA<KmTrustUnreadable>()));
      await expectLater(open(device: otherDevice), throwsA(isA<KmTrustUnreadable>()));
      await expectLater(open(keyVersion: 2), throwsA(isA<KmTrustUnreadable>()));
      // The next sign-in on this phone opens the account with the copy and no approval
      final again = await phone.signIn.openWithTrust(signed.session, phone.trust, _tag);
      expect(again!.rootKey, opened.rootKey);
    });

    test('the account the server then holds has no password wrap, and the root key is nowhere in a request', () async {
      final server = _keylessServer();
      final phone = _Phone(server);
      final signed = await phone.signedIn();
      final opened = (await phone.signIn.enrolKeys(signed.session, phone.trust, _tag, newAccount: true))!;

      expect(server.material['wrappedRootKey'], '');
      expect(server.material['keyVersion'], 1);
      final root = b64urlEncode(opened.rootKey);
      for (final request in server.requests) {
        expect(request.body, isNot(contains(root)));
      }
    });
  });

  group('an account that has no keys when it is found at sign-in', () {
    test('a 404 is enrolled, after one read to find out', () async {
      final server = _keylessServer();
      final phone = _Phone(server, newAccount: false);
      final signed = await phone.signedIn();
      expect(signed.newAccount, isFalse);

      final opened = await phone.signIn.enrolKeys(signed.session, phone.trust, _tag);

      expect(opened, isNotNull);
      expect(opened!.keyVersion, 1);
      expect(_paths(server), ['/account/keys', '/account/keys/enrol', '/account/keys']);
      expect(server.keyEnrolments, hasLength(1));
      final blob = b64urlDecode(server.keyCopy!['wrappedKey']!);
      final root = await phone.trust.open(
        tag: _tag,
        blob: blob,
        accountId: uuidBytes(_userId),
        deviceId: uuidBytes(signed.session.deviceId),
        keyVersion: 1,
      );
      expect(root, opened.rootKey);
    });

    test('key version 0 with no keys in it is refused, and no keys are made over it', () async {
      final server = _keylessServer(answer: _keyVersionZero);
      final phone = _Phone(server, newAccount: false);
      final signed = await phone.signedIn();

      await expectLater(
        phone.signIn.enrolKeys(signed.session, phone.trust, _tag),
        throwsA(isA<KmSignInError>().having((e) => e.issue, 'issue', KmSignInIssue.unreadable)),
      );
      expect(server.keyEnrolments, isEmpty);
      expect(phone.keys.calls, isEmpty);
    });

    test('an account that has keys is left alone: no request but the read, and no hardware key made', () async {
      final server = FakeKemlockAccountServer(userId: _userId)..material = account.material();
      final phone = _Phone(server, newAccount: false);
      final signed = await phone.signedIn();

      expect(await phone.signIn.enrolKeys(signed.session, phone.trust, _tag), isNull);

      expect(_paths(server), ['/account/keys']);
      expect(phone.keys.calls, isEmpty);
    });
  });

  group('another device enrolled first', () {
    test("a 409 overwrites nothing, deletes this phone's new hardware key and falls back to the usual ways", () async {
      final server = _keylessServer()
        ..enrolConflict = true
        ..material = account.material()
        ..keyCopy = {'wrappedKey': 'AAAA', 'protection': 'software'};
      final phone = _Phone(server);
      final signed = await phone.signedIn();

      final opened = await phone.signIn.enrolKeys(signed.session, phone.trust, _tag, newAccount: true);

      expect(opened, isNull);
      expect(server.keyEnrolments, isEmpty);
      expect(server.keyCopy, {'wrappedKey': 'AAAA', 'protection': 'software'});
      expect(server.material, account.material(), reason: 'the other device\'s keys stand');
      expect(phone.keys.wrapping, isEmpty, reason: 'no copy of this phone\'s was stored, so no key for one stays');
      // The next steps are the ones for an account with keys: no copy of this phone's, so an approval
      expect(await phone.signIn.openWithTrust(signed.session, phone.trust, _tag), isNull);
      // and an approval's root key opens it
      final byApproval = await phone.signIn.openWithRoot(signed.session, account.root);
      expect(byApproval.accountId, _userId);
    });

    test('a 409 found by the read first is the same: the account has keys, nothing is sent', () async {
      final server = FakeKemlockAccountServer(userId: _userId)..material = account.material();
      final phone = _Phone(server, newAccount: false);
      final signed = await phone.signedIn();

      expect(await phone.signIn.enrolKeys(signed.session, phone.trust, _tag), isNull);
      expect(server.keyEnrolments, isEmpty);
    });
  });

  group('what stops an enrolment', () {
    test('a phone with no hardware key can not hold the copy: nothing is sent', () async {
      final server = _keylessServer();
      final phone = _Phone(server, keys: FakeDeviceKeys(hasHardware: false));
      final signed = await phone.signedIn();

      await expectLater(
        phone.signIn.enrolKeys(signed.session, phone.trust, _tag, newAccount: true),
        throwsA(isA<KmSignInError>().having((e) => e.issue, 'issue', KmSignInIssue.noDeviceKey)),
      );
      expect(_paths(server), isEmpty);
    });

    test('a server that refuses the enrolment leaves no hardware key behind, and the error is the usual one', () async {
      final server = _keylessServer();
      server.respond = (request) async => request.url.path.endsWith('/account/keys/enrol')
          ? server.problem(429, 'rate-limited', extra: {'retryAfter': 30})
          : server.handle(request);
      final phone = _Phone(server);
      final signed = await phone.signedIn();

      await expectLater(
        phone.signIn.enrolKeys(signed.session, phone.trust, _tag, newAccount: true),
        throwsA(isA<KmError>().having((e) => e.problem, 'problem', KmProblem.rateLimited)),
      );
      expect(phone.keys.wrapping, isEmpty);
      expect(server.keyCopy, isNull);
    });

    test('an answer lost after the server stored the keys keeps the hardware key, and the next sign-in opens', () async {
      final server = _keylessServer();
      server.respond = (request) async {
        final answer = await server.handle(request);
        if (request.url.path.endsWith('/account/keys/enrol') && answer.statusCode == 200) {
          throw Exception('the connection dropped before the answer');
        }
        return answer;
      };
      final phone = _Phone(server);
      final signed = await phone.signedIn();

      await expectLater(
        phone.signIn.enrolKeys(signed.session, phone.trust, _tag, newAccount: true),
        throwsA(isA<KmError>().having((e) => e.problem, 'problem', KmProblem.network)),
      );
      expect(server.keyCopy, isNotNull, reason: 'the server stored the keys and the copy');
      expect(phone.keys.wrapping, isNotEmpty, reason: 'the copy is the only way into this account, so its key stays');

      server.respond = server.handle;
      final again = await phone.signIn.openWithTrust(signed.session, phone.trust, _tag);
      expect(again, isNotNull);
    });

    test('a server without account-keys can not open what it enrolled, so nothing is made', () async {
      final server = _keylessServer()..features = ['opaque', 'dpop'];
      final phone = _Phone(server);
      final signed = await phone.signedIn();
      await phone.signIn.ways('me@example.com');

      await expectLater(
        phone.signIn.enrolKeys(signed.session, phone.trust, _tag, newAccount: true),
        throwsA(isA<KmSignInError>().having((e) => e.issue, 'issue', KmSignInIssue.unsupported)),
      );
      expect(server.keyEnrolments, isEmpty);
      expect(phone.keys.calls, isEmpty);
    });
  });

  group('the account material of an SSO account', () {
    test('empty fields are no keys, and opening them says so', () async {
      final material = KmAccountMaterial.fromJson(_keyVersionZero);
      expect(material.hasKeys, isFalse);
      expect(openKmAccount(accountId: _userId, rootKey: newRootKey(), material: material), throwsA(isA<KmAccountUnreadable>()));
      expect(KmAccountMaterial.fromJson(account.material()).hasKeys, isTrue);
    });
  });
}
