// What Kemlock relies on from Vaultwarden, checked against a real server
// (see server_kit.dart): signing in, by code and by security key, the
// revision date, items round-tripping through an update, the out-of-date
// check, the trash.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/accounts/otp.dart';
import 'package:kemlock/features/passkeys/passkey_bytes.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_key_step.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_webauthn.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/security_keys.dart';

import '../fakes/fake_fido_key.dart';
import '../fakes/fake_security_keys.dart';
import 'server_kit.dart';

void main() {
  late http.Client client;
  late VwApi api;

  setUp(() {
    client = serverClient();
    api = VwApi(client);
  });
  tearDown(() => client.close());

  Future<(TestAccount, VwSignedIn)> signedIn({BwKdf kdf = cheapPbkdf2}) async {
    final account = await registerAccount(client, kdf: kdf);
    final masterKey = await bwMasterKey(account.password, account.email, await api.prelogin(serverUrl!, account.email));
    final login = await api.signIn(
      serverUrl!,
      email: account.email,
      passwordHash: await bwMasterPasswordHash(masterKey, account.password),
      device: testDevice(),
    );
    return (account, login as VwSignedIn);
  }

  test('answers as a Bitwarden-compatible server', () async {
    final config = await api.config(serverUrl!);
    expect(jsonKey(jsonKey(config, 'server')! as Map<String, Object?>, 'name'), 'Vaultwarden');
  }, skip: skipServer);

  test('signs in with PBKDF2 and with Argon2id, and the user key opens', () async {
    for (final kdf in [cheapPbkdf2, cheapArgon2id]) {
      final (account, login) = await signedIn(kdf: kdf);
      expect(await api.prelogin(serverUrl!, account.email), kdf);
      final masterKey = await bwMasterKey(account.password, account.email, kdf);
      final userKey = await bwOpenUserKey(login.key!, masterKey);
      expect(userKey.bytes, account.userKey.bytes);
      expect(login.userId, isNotEmpty);
    }
  }, skip: skipServer);

  test('refuses a wrong password', () async {
    final account = await registerAccount(client);
    final masterKey = await bwMasterKey('wrong', account.email, cheapPbkdf2);
    await expectLater(
      api.signIn(serverUrl!, email: account.email, passwordHash: await bwMasterPasswordHash(masterKey, 'wrong'), device: testDevice()),
      throwsA(isA<VwError>().having((e) => e.problem, 'problem', VwProblem.auth)),
    );
  }, skip: skipServer);

  test('signs in with a second step, a remembered device, and a personal API key', () async {
    final account = await registerAccount(client);
    final masterKey = await bwMasterKey(account.password, account.email, account.kdf);
    final hash = await bwMasterPasswordHash(masterKey, account.password);
    final first = await api.signIn(serverUrl!, email: account.email, passwordHash: hash, device: testDevice()) as VwSignedIn;
    Future<Map<String, Object?>> post(String path, Map<String, Object?> body) async {
      final res = await client.post(
        serverUrl!.replace(path: '${serverUrl!.path}/api$path'),
        headers: {'Authorization': 'Bearer ${first.tokens.access}', 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      expect(res.statusCode, 200, reason: '$path: ${res.body}');
      return jsonDecode(res.body) as Map<String, Object?>;
    }

    // A personal API key skips the second step; the user key is the same
    final apiKey = (await post('/accounts/api-key', {'masterPasswordHash': hash}))['apiKey']! as String;
    final viaKey = await api.signInWithApiKey(serverUrl!, clientId: 'user.${first.userId}', clientSecret: apiKey, device: testDevice());
    expect(viaKey.key, first.key);
    // Its session has no refresh token: when it ends, the key signs in again
    final setup = VwAccountSetup(api);
    await setup.connect(serverUrl.toString(), account.email);
    final done = await setup.signInWithApiKey('user.${first.userId}', apiKey, account.password, deviceId: testDevice().id);
    VwCredentials? renewed;
    final connection = VwConnection(
      api: api,
      server: serverUrl!,
      credentials: done.credentials.withTokens(accessToken: 'expired', refreshToken: '', expiresAt: 0),
      onCredentials: (next) async => renewed = next,
    );
    expect(await connection.call((token) => api.revisionDate(serverUrl!, token)), isPositive);
    expect(renewed?.clientSecret, apiKey);

    // Turn an authenticator on, as the web vault does
    final generated = await post('/two-factor/get-authenticator', {'masterPasswordHash': hash});
    final secret = (generated['authenticator']! as Map<String, Object?>)['key']! as String;
    final totp = OtpAccount(id: 't', issuer: 'Vaultwarden', label: '', secret: secret, addedAt: 0);
    int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await post('/two-factor/authenticator', {
      'key': secret,
      'token': codeAt(totp, nowSec()),
      'userVerificationToken': generated['userVerificationToken'],
    });

    final device = testDevice();
    final needs = await api.signIn(serverUrl!, email: account.email, passwordHash: hash, device: device);
    expect(needs, isA<VwSecondStepNeeded>().having((n) => n.providers, 'providers', contains(VwTwoFactor.authenticator)));
    await expectLater(
      api.signIn(
        serverUrl!,
        email: account.email,
        passwordHash: hash,
        device: device,
        step: const VwSecondStep(provider: VwTwoFactor.authenticator, code: '000000'),
      ),
      throwsA(isA<VwError>().having((e) => e.problem, 'problem', VwProblem.code)),
    );
    // The code just used to turn it on can't be used again: take the next one, within the allowed drift
    final signedIn = await api.signIn(
      serverUrl!,
      email: account.email,
      passwordHash: hash,
      device: device,
      step: VwSecondStep(provider: VwTwoFactor.authenticator, code: codeAt(totp, nowSec() + 30), remember: true),
    );
    expect(signedIn, isA<VwSignedIn>().having((s) => s.rememberToken, 'rememberToken', isNotNull));

    // The remembered device skips the step next time
    final again = await api.signIn(
      serverUrl!,
      email: account.email,
      passwordHash: hash,
      device: device,
      rememberToken: (signedIn as VwSignedIn).rememberToken,
    );
    expect(again, isA<VwSignedIn>());
  }, skip: skipServer);

  group('with a security key as the second step', () {
    // The key is FakeFidoKey, a FIDO2 authenticator in Dart, held to a fake
    // phone: a software P-256 credential, registered through the routes the
    // web vault uses. The server's DOMAIN must be VAULTWARDEN_URL itself.
    late TestAccount account;
    late String hash;
    late FakeSecurityKeys phone;
    late FakeFidoKey fido;

    setUp(() async {
      if (serverUrl == null) return;
      final (registered, login) = await signedIn();
      account = registered;
      hash = await bwMasterPasswordHash(await bwMasterKey(account.password, account.email, account.kdf), account.password);
      fido = FakeFidoKey();
      phone = FakeSecurityKeys()..arrive(FakeKey(productName: 'Example Key', ctap: fido).device(kinds: {SecurityKeyLinkKind.nfc}));
      await _registerKey(client, login.tokens.access, hash, fido.addSignInCredential(serverUrl!.host));
    });

    Future<VwLogin> signIn(VwDevice device, {VwSecondStep? step, String? rememberToken}) =>
        api.signIn(serverUrl!, email: account.email, passwordHash: hash, device: device, step: step, rememberToken: rememberToken);

    /// The key's answer to the challenge in [needs], as the token of the second step.
    Future<String> answer(VwLogin needs, {Uri? server}) async {
      expect(needs, isA<VwSecondStepNeeded>().having((n) => n.providers, 'providers', [VwTwoFactor.webauthn]));
      final challenge = VwKeyChallenge.parse((needs as VwSecondStepNeeded).details['${VwTwoFactor.webauthn}'], receivedAt: DateTime.now())!;
      expect(challenge.rpId, serverUrl!.host);
      return VwKeyStep(keys: phone, askPin: (_) async => null, now: phone.now).answer(challenge, server ?? serverUrl!);
    }

    for (final remember in [true, false]) {
      test('signs in with the key, ${remember ? 'and the remembered device skips it next time' : 'and asks for it again'}', () async {
        final device = testDevice();
        final token = await answer(await signIn(device));
        final signedIn = await signIn(
          device,
          step: VwSecondStep(provider: VwTwoFactor.webauthn, code: token, remember: remember),
        );

        expect(signedIn, isA<VwSignedIn>());
        final rememberToken = (signedIn as VwSignedIn).rememberToken;
        expect(rememberToken, remember ? isNotNull : isNull);
        final masterKey = await bwMasterKey(account.password, account.email, account.kdf);
        expect((await bwOpenUserKey(signedIn.key!, masterKey)).bytes, account.userKey.bytes);

        final again = await signIn(device, rememberToken: rememberToken);
        expect(again, remember ? isA<VwSignedIn>() : isA<VwSecondStepNeeded>());
      }, skip: skipServer);
    }

    test('takes the answer only from its own origin, and uses the challenge up either way', () async {
      final device = testDevice();
      // The same name on another port is another origin
      final elsewhere = await answer(await signIn(device), server: serverUrl!.replace(port: serverUrl!.port + 1));
      await expectLater(
        signIn(
          device,
          step: VwSecondStep(provider: VwTwoFactor.webauthn, code: elsewhere),
        ),
        throwsA(isA<VwError>().having((e) => e.problem, 'problem', VwProblem.code)),
      );

      // A new challenge, answered right, with the member spelled as browsers do
      final token = (await answer(await signIn(device))).replaceFirst('"clientDataJson"', '"clientDataJSON"');
      expect(
        await signIn(
          device,
          step: VwSecondStep(provider: VwTwoFactor.webauthn, code: token),
        ),
        isA<VwSignedIn>(),
      );
      // An answer counts once
      await expectLater(
        signIn(
          device,
          step: VwSecondStep(provider: VwTwoFactor.webauthn, code: token),
        ),
        throwsA(isA<VwError>().having((e) => e.problem, 'problem', VwProblem.code)),
      );
    }, skip: skipServer);
  });

  test('refreshes the token', () async {
    final (_, login) = await signedIn();
    final tokens = await api.refresh(serverUrl!, login.tokens.refresh);
    expect(await api.revisionDate(serverUrl!, tokens.access), isPositive);
    await expectLater(
      api.refresh(serverUrl!, 'not a refresh token'),
      throwsA(isA<VwError>().having((e) => e.problem, 'problem', VwProblem.signedOut)),
    );
  }, skip: skipServer);

  test('keeps every value of an item through an update, and checks the revision', () async {
    final (account, login) = await signedIn();
    final token = login.tokens.access;
    final key = account.userKey;
    final folder = await api.createFolder(serverUrl!, token, await bwEncryptString('Kemlock', key));
    final before = await api.revisionDate(serverUrl!, token);

    final created = await api.createCipher(serverUrl!, token, {
      'type': 1,
      'folderId': folder['id'],
      'organizationId': null,
      'name': await bwEncryptString('GitHub', key),
      'notes': await bwEncryptString('a note', key),
      'favorite': true,
      'reprompt': 0,
      'encryptedFor': login.userId,
      'fields': [
        {'type': 1, 'name': await bwEncryptString('Kemlock', key), 'value': await bwEncryptString('{"v":1}', key), 'linkedId': null},
        {'type': 0, 'name': await bwEncryptString('Other app', key), 'value': await bwEncryptString('keep me', key), 'linkedId': null},
      ],
      'login': {
        'username': await bwEncryptString('me@example.com', key),
        'password': await bwEncryptString('hunter2', key),
        'totp': await bwEncryptString('otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP', key),
        'uris': [
          {'uri': await bwEncryptString('https://github.com', key), 'match': null},
        ],
      },
      'passwordHistory': null,
    });
    expect(await api.revisionDate(serverUrl!, token), greaterThan(before));

    final synced = await api.sync(serverUrl!, token);
    final ciphers = (synced['ciphers']! as List<Object?>).cast<Map<String, Object?>>();
    final item = ciphers.singleWhere((c) => c['id'] == created['id']);
    expect(item['folderId'], folder['id']);
    expect(item['deletedDate'], isNull);

    // Send it back as the server gave it, with one value changed. The check
    // allows a second, so the update comes more than one after the copy.
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    final changed = jsonDecode(jsonEncode(item)) as Map<String, Object?>;
    (changed['login']! as Map<String, Object?>)['totp'] = await bwEncryptString('otpauth://totp/GitHub:me?secret=KRSXG5A', key);
    final updated = await api.updateCipher(serverUrl!, token, item['id']! as String, {
      ...changed,
      'encryptedFor': login.userId,
      'lastKnownRevisionDate': item['revisionDate'],
    });
    for (final name in ['name', 'notes', 'favorite', 'folderId', 'fields', 'reprompt', 'key']) {
      expect(updated[name], item[name], reason: name);
    }
    final loginAfter = updated['login']! as Map<String, Object?>;
    final loginBefore = item['login']! as Map<String, Object?>;
    expect(loginAfter['password'], loginBefore['password']);
    expect(loginAfter['uris'], loginBefore['uris']);
    expect(await bwDecryptString(loginAfter['totp']! as String, key), 'otpauth://totp/GitHub:me?secret=KRSXG5A');

    // A second write from the copy read before the first is refused
    await expectLater(
      api.updateCipher(serverUrl!, token, item['id']! as String, {
        ...changed,
        'encryptedFor': login.userId,
        'lastKnownRevisionDate': item['revisionDate'],
      }),
      throwsA(isA<VwError>().having((e) => e.problem, 'problem', VwProblem.outOfDate)),
    );
  }, skip: skipServer);

  test('moves items to the trash and back', () async {
    final (account, login) = await signedIn();
    final token = login.tokens.access;
    final created = await api.createCipher(serverUrl!, token, {
      'type': 2,
      'name': await bwEncryptString('note', account.userKey),
      'secureNote': {'type': 0},
      'encryptedFor': login.userId,
    });
    final id = created['id']! as String;
    await api.trashCipher(serverUrl!, token, id);
    Map<String, Object?> find(Map<String, Object?> synced) =>
        (synced['ciphers']! as List<Object?>).cast<Map<String, Object?>>().singleWhere((c) => c['id'] == id);
    expect(find(await api.sync(serverUrl!, token))['deletedDate'], isNotNull);
    final restored = await api.restoreCipher(serverUrl!, token, id);
    expect(restored['deletedDate'], isNull);
    expect(find(await api.sync(serverUrl!, token))['deletedDate'], isNull);
  }, skip: skipServer);
}

/// Registers [credential] as a security key of the account signed in with
/// [access], as the web vault does: a user verification token for the
/// master password's [hash], the creation options, and the key's
/// attestation (`none`) for them, from the server's own origin.
Future<void> _registerKey(http.Client client, String access, String hash, FakeSignInCredential credential) async {
  final server = serverUrl!;
  Future<Map<String, Object?>> send(String method, String path, Map<String, Object?> body) async {
    final request = http.Request(method, server.replace(path: '${server.path}/api/two-factor/$path'))
      ..headers.addAll({'Authorization': 'Bearer $access', 'Content-Type': 'application/json'})
      ..body = jsonEncode(body);
    final res = await http.Response.fromStream(await client.send(request));
    expect(res.statusCode, 200, reason: '$path: ${res.body}');
    return jsonDecode(res.body) as Map<String, Object?>;
  }

  final verification = jsonKey(await send('POST', 'get-webauthn', {'masterPasswordHash': hash}), 'userVerificationToken');
  final created = await send('POST', 'get-webauthn-challenge', {'masterPasswordHash': hash, 'userVerificationToken': verification});
  final options = (jsonKey(created, 'options') ?? created) as Map<String, Object?>;
  final clientData = utf8.encode(
    jsonEncode({
      'type': 'webauthn.create',
      'challenge': jsonKey(options, 'challenge'),
      'origin': vwKeyOrigin(server),
      'crossOrigin': false,
    }),
  );
  // User present and attested credential data, no AAGUID, a counter of 0
  final authData = Uint8List.fromList([
    ...rpIdHash(credential.rpId),
    0x41,
    ...Uint8List(4),
    ...Uint8List(16),
    credential.id.length >> 8,
    credential.id.length & 0xff,
    ...credential.id,
    ...coseEs256Key(credential.keyPair.point),
  ]);
  await send('PUT', 'webauthn', {
    'id': 1,
    'name': 'Kemlock test key',
    'masterPasswordHash': hash,
    'userVerificationToken': verification,
    'deviceResponse': {
      'id': b64url(credential.id),
      'rawId': b64url(credential.id),
      'type': 'public-key',
      'extensions': <String, Object?>{},
      'response': {'AttestationObject': b64url(attestationObject(authData)), 'clientDataJson': b64url(clientData)},
    },
  });
}
