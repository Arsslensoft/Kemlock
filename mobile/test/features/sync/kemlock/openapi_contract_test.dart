// The contract test of design decision 15 and task 13.2 of docs/plans/add-kemlock-server-sync.md: the hand-written client
// and the fake servers held to the server's OpenAPI document, test/fixtures/server/openapi.json (copied from the server's
// commit in SOURCE.json, never edited).
//
// - The checker itself (openapi_checker.dart): what it reports on made-up exchanges.
// - The client's flows through the fakes with the checker on: sign-in, a second step, the Bitwarden enrolment, SSO, passkeys,
//   approvals, devices, the account's keys, sync with files and the manifest, the trusted-device copy, the duplicate cleaner,
//   Sends, and the space routes. Every request the app sends and every answer a fake gives is checked, and no violation is
//   left but the known gaps of the spec below (told to the server session).
// - 13.2's check: the same flow against a test-local copy of the spec with a field renamed, which the checker reports.
// - The routes the client code names, listed with where each comes from, each of them in the spec with its method.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/kem1.dart';
import 'package:kemlock/crypto/account/kx1.dart';
import 'package:kemlock/crypto/account/send.dart';
import 'package:kemlock/crypto/account/sig1.dart';
import 'package:kemlock/crypto/attachment_format.dart';
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/spaces/km_server_spaces.dart';
import 'package:kemlock/features/spaces/space_invites.dart';
import 'package:kemlock/features/spaces/space_members.dart';
import 'package:kemlock/features/spaces/space_pending.dart';
import 'package:kemlock/features/spaces/space_types.dart';
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_auth_api.dart';
import 'package:kemlock/features/sync/kemlock/km_dedup_api.dart';
import 'package:kemlock/features/sync/kemlock/km_device_key.dart';
import 'package:kemlock/features/sync/kemlock/km_dpop.dart';
import 'package:kemlock/features/sync/kemlock/km_sends_api.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/features/sync/kemlock/km_signin.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/secure_note.dart';

import '../../../helpers/core_sources.dart';
import '../../spaces/chain_kit.dart';
import '../../spaces/fake_space_server.dart';
import '../../spaces/server_spaces_test.dart' show KmSpacePhone;
import 'fake_dedup_server.dart';
import 'fake_kemlock_accounts.dart';
import 'fake_kemlock_server.dart';
import 'km_sync_kit.dart';
import 'openapi_checker.dart';

/// What the spec lacks or gets wrong, which the server's code does (read-only, `kemlock-server` at `build/vertical-slice`).
/// Each is a message for the server session; when the spec says it, the entry goes.
const _gaps = <ContractGap>[];

const _password = 'correct horse battery staple';
const _email = 'me@example.com';
const _device = KmDeviceInfo(name: 'Kemlock on Pixel 9', kind: 'kemlock-android');
const _userId = '00000000-0000-4000-8000-000000000001';
const _itemA = '3f2c9a71-e4b0-4856-8a00-0000000000a1';
const _itemB = '3f2c9a71-e4b0-4856-8a00-0000000000b2';
final _server = FakeKemlockServer.url;

/// Bitwarden's master key without its cost, as the sign-in's `bitwardenKey` takes.
Future<Uint8List> _cheapBitwardenKey(String password, String email, BwKdf kdf) async =>
    Uint8List.fromList(sha256.convert(utf8.encode('$password|$email|${kdf.iterations}')).bytes);

/// A checker over the spec as copied, made the one the fakes report to until the test ends.
OpenApiChecker _checkerOn(Json? spec) {
  final checker = OpenApiChecker(spec == null ? OpenApiSpec.fixture() : OpenApiSpec(spec));
  OpenApiChecker.active = checker;
  return checker;
}

/// No violation is left but the known gaps, and the flow reached [routes] (`METHOD /kem/v1/template`).
void _expectClean(OpenApiChecker checker, List<String> routes) {
  expect([for (final violation in checker.unexpected(_gaps)) '$violation'], isEmpty, reason: 'the spec and the code disagree');
  expect(checker.operations, containsAll(routes), reason: 'the flow went through each of these routes');
}

({KmSignIn signIn, KmApi api}) _signIn(FakeKemlockAccountServer server) {
  final key = SoftwareDeviceKey.generate();
  final api = KmApi(server.client, proofs: KmDpop(key));
  final signIn = KmSignIn(
    api: api,
    server: _server,
    device: _device,
    opaque: FakeKmOpaque(),
    deviceKey: const {'protection': 'software'},
    argon2: cheapArgon2,
    // The real derivation is never reached without the Bitwarden route, so the cheap one stands in for both
    bitwardenKey: _cheapBitwardenKey,
  );
  return (signIn: signIn, api: api);
}

/// A path on the server, for the made-up exchanges of the checker's own tests.
Uri _at(String path) => Uri.parse('https://kem.example.com/kem/v1$path');

/// What the checker finds in one made-up exchange: [method] and [path], with [body] as JSON, answered with [status] and
/// [answer] as JSON of [answerType] (a problem by default for 4xx and 5xx).
List<String> _found(
  String method,
  String path, {
  Map<String, String> headers = const {},
  Object? body,
  int status = 200,
  Object? answer,
  String? answerType,
  Json? spec,
}) {
  final checker = OpenApiChecker(spec == null ? OpenApiSpec.fixture() : OpenApiSpec(spec));
  final request = http.Request(method, _at(path))..headers.addAll(headers);
  if (body != null) {
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode(body);
  }
  final type = answerType ?? (status >= 400 ? 'application/problem+json' : 'application/json');
  final response = http.Response(answer == null ? '' : jsonEncode(answer), status, headers: {if (answer != null) 'content-type': type});
  checker.exchange(request, response);
  return [for (final violation in checker.violations) '$violation'];
}

const _secured = {'Authorization': 'DPoP token', 'DPoP': 'proof'};

/// A copy of the spec's JSON with [schema]'s property [from] called [to], as the server would have renamed it.
Json _renamed(String schema, String from, String to) {
  final json = OpenApiSpec.copyOf(OpenApiSpec.fixture().json);
  final node = ((json['components']! as Json)['schemas']! as Json)[schema]! as Json;
  final properties = node['properties']! as Json;
  properties[to] = properties.remove(from);
  final required = node['required'];
  if (required is List<Object?>) {
    for (var i = 0; i < required.length; i++) {
      if (required[i] == from) {
        required[i] = to;
      }
    }
  }
  return json;
}

/// An attached file of [size] bytes: its sealed KMA1 bytes, and the attachment that names it.
({Uint8List sealed, NoteAttachment file}) _attachment(String id, int size) {
  final key = randomBytes(32);
  final plain = randomBytes(size);
  return (sealed: kma1EncryptSync(plain, key), file: NoteAttachment(id: id, name: '$id.jpg', size: size, key: b64(key), addedAt: 1));
}

/// One phone that syncs a note with a file to a fresh fake server, as `km_files_test` does.
Future<({FakeKemlockServer server, KmPhone phone})> _syncWithFile() async {
  final server = FakeKemlockServer()..checkTokens = false;
  final photo = _attachment('photo-1', 70000);
  final note = SecureNote(id: '3f2c9a71-e4b0-4856-8a00-0000000000d1', title: 'Photos', addedAt: 1, attachments: [photo.file]);
  final phone = KmPhone(
    server,
    clock: KmClock(),
    fileStore: FakeFileStore()..files['photo-1'] = photo.sealed,
    lists: Lists(notes: [note]),
  );
  await phone.run();
  return (server: server, phone: phone);
}

void main() {
  tearDown(() => OpenApiChecker.active = null);

  group('the checker', () {
    test('lets through a request and an answer that the spec describes', () {
      expect(
        _found(
          'POST',
          '/auth/methods',
          body: {'email': 'a@b.c'},
          answer: {
            'methods': ['password'],
            'sso': null,
          },
        ),
        isEmpty,
      );
    });

    test('reports a field the spec lacks, a required field that is missing, and a field of another type', () {
      final lacks = _found('POST', '/auth/methods', body: {'mail': 'a@b.c'}, answer: {'methods': <String>[]});
      expect(lacks, contains(contains(r'$.email is missing')));
      expect(lacks, contains(contains(r'$.mail is not in the spec')));
      expect(
        _found('POST', '/auth/methods', body: {'email': 5}, answer: {'methods': <String>[]}),
        contains(contains('is an integer, and the spec says string')),
      );
      expect(
        _found('POST', '/auth/methods', body: {'email': 'a@b.c'}, answer: {'methods': 'password'}),
        contains(contains(r'$.methods is a string, and the spec says array')),
      );
    });

    test('reports an id that is not a UUID where the spec says uuid, and a number below the minimum', () {
      final body = {'deviceId': 'not-a-uuid'};
      expect(_found('POST', '/devices/sign-out', headers: _secured, body: body, status: 204), contains(contains('is not a UUID')));
      expect(
        _found('GET', '/sync?limit=-1', headers: _secured, status: 304),
        contains(contains('is below the minimum 0')),
        reason: 'limit is an int32 of 0 or more',
      );
    });

    test('reports a route, a method, a query parameter and a header that the spec lacks', () {
      expect(_found('GET', '/nope', status: 404), contains(contains('the spec has no such path')));
      expect(_found('PATCH', '/sync', headers: _secured, status: 304), contains(contains('the spec has no PATCH')));
      expect(_found('GET', '/sync?since=a&foo=1', headers: _secured, status: 304), contains(contains('no query parameter foo')));
      expect(_found('GET', '/sync', headers: {..._secured, 'X-Mine': '1'}, status: 304), contains(contains('no header x-mine')));
    });

    test('reports a header the spec requires, and a secured route sent without its token', () {
      final tags = {'tags': <String>[], 'tagVersion': 1};
      expect(
        _found('PUT', '/items/$_itemA/tags', headers: _secured, body: tags, answer: {'matches': <String>[]}),
        contains(contains('If-Match')),
      );
      expect(_found('GET', '/devices/key-copy', status: 404), contains(contains('header Authorization')));
    });

    test('reports a status the spec does not list, and lets a 401 or a 429 through', () {
      expect(
        _found('GET', '/devices/key-copy', headers: _secured, status: 418),
        contains(contains('the spec lists 200, 401, 404, 429, 500')),
      );
      final problem = {'type': 'urn:kemlock:problem:unauthorized', 'title': 'unauthorized', 'status': 401};
      expect(_found('GET', '/devices', headers: _secured, status: 401, answer: problem), isEmpty);
      expect(
        _found('GET', '/devices', headers: _secured, status: 401, answer: {'title': 'x'}),
        contains(contains('is missing')),
        reason: 'but the body is still a problem',
      );
    });

    test('reports a body on a 204 and the wrong content type', () {
      expect(
        _found('DELETE', '/devices/key-copy', headers: _secured, status: 204, answer: <String, Object?>{}),
        contains(contains('has a body')),
      );
      expect(
        _found('GET', '/devices/key-copy', headers: _secured, answer: <String, Object?>{}, answerType: 'text/plain'),
        contains(contains('content type')),
      );
    });

    test('follows a reference, and a list of types for null, and checks each alternative of a oneOf', () {
      final send = {
        'accessCount': 0,
        'accessId': 'a',
        'createdAt': 1,
        'deletionAt': 2,
        'disabled': false,
        'hasPassword': false,
        'hideEmail': false,
        'id': '3f2c9a71-e4b0-4a56-8a00-000000000001',
        'kind': 'text',
        'maxAccess': null,
        'meta': 'm',
        'payload': 'p',
        'revisedAt': 3,
        'sealedKey': 's',
        'file': null,
      };
      expect(_found('GET', '/sends/${send['id']}', headers: _secured, answer: send), isEmpty);
      expect(
        _found('GET', '/sends/${send['id']}', headers: _secured, answer: {...send, 'file': 5}),
        contains(contains(r'$.file fits 0 of the 2')),
      );
    });
  });

  group('the sign-in routes against the spec', () {
    late KmTestAccount account;

    setUpAll(() async {
      account = await KmTestAccount.create(_userId);
    });

    test('config, the ways in, OPAQUE, a second step and the account keys', () async {
      final checker = _checkerOn(null);
      final server = FakeKemlockAccountServer(userId: _userId)..secondStep = ['totp'];
      await server.registerOpaque(_password, account);
      final (:signIn, api: _) = _signIn(server);

      await signIn.ways(_email);
      expect(await signIn.password(_email, _password), isA<KmSecondStep>());
      expect(await signIn.secondStep('totp', '123456'), isA<KmSignedIn>());

      _expectClean(checker, [
        'GET /kem/v1/config',
        'POST /kem/v1/auth/methods',
        'POST /kem/v1/auth/prelogin',
        'POST /kem/v1/auth/opaque/start',
        'POST /kem/v1/auth/opaque/finish',
        'POST /kem/v1/auth/two-factor',
        'GET /kem/v1/account/keys',
      ]);
    });

    test('the first sign-in of a Compatible account enrols OPAQUE through the Bitwarden routes', () async {
      final checker = _checkerOn(null);
      final server = FakeKemlockAccountServer(userId: _userId);
      const kdf = BwKdf(type: BwKdfType.pbkdf2, iterations: 600000);
      final master = await _cheapBitwardenKey(_password, _email, kdf);
      server
        ..bitwarden = kdf.toJson()
        ..bitwardenHashExpected = await bwMasterPasswordHash(master, _password)
        ..bitwardenUserKey = (await bwEncrypt(account.root, bwStretch(master))).toString()
        ..material = {'keyVersion': 1};
      final (:signIn, api: _) = _signIn(server);

      expect(await signIn.password(_email, _password), isA<KmSignedIn>());

      _expectClean(checker, ['POST /kem/v1/auth/bitwarden/start', 'POST /kem/v1/auth/bitwarden/finish', 'GET /kem/v1/account/keys']);
    });

    test('config with the vaults asked for, as repeated ?vault= the spec lists', () async {
      final checker = _checkerOn(null);
      final server = FakeKemlockAccountServer(userId: _userId);
      final vault = 'user:$_userId';
      server.vaults = [
        {
          'vault': vault,
          'epoch': 1,
          'servers': [
            {
              'serverId': '00000000-0000-4000-8000-0000000000a1',
              'address': 'https://kem.example.com',
              'identityKey': b64urlEncode(Uint8List(1984)),
              'role': 'home',
            },
          ],
          'promotion': null,
        },
      ];

      final config = await KmApi(server.client).config(_server, vaults: [vault]);

      expect(config.vaults, hasLength(1));
      _expectClean(checker, ['GET /kem/v1/config']);
      expect(checker.violations, isEmpty);
    });

    test('single sign-on, a passkey, a new device that is approved, and a replica signing a device in', () async {
      final checker = _checkerOn(null);
      final server = FakeKemlockAccountServer(userId: _userId)
        ..checkTokens = false
        ..phraseOverride = 'alpha bravo charlie delta echo'
        ..material = account.material();
      final api = KmApi(server.client, proofs: KmDpop(SoftwareDeviceKey.generate()));
      final auth = KmAuthApi(api);
      final token = server.issueTokens('jkt')['accessToken']! as String;

      final verifier = b64urlEncode(List.generate(32, (i) => i + 1));
      await auth.ssoStart(_server, b64urlEncode(sha256.convert(utf8.encode(verifier)).bytes), 'state-0123456789abcdef');
      await auth.ssoFinish(_server, server.ssoCode, verifier, _device);

      final options = await auth.passkeyOptions(_server);
      await auth.passkeyVerify(_server, options.sealedChallenge, {'id': 'AAAA', 'rawId': 'AAAA', 'type': 'public-key'}, _device);
      await auth.setPasskeyPrf(_server, token, server.passkeyId, Uint8List(92), 1);
      expect(await auth.accountPasskeys(_server, token), hasLength(1));

      final ticket = await auth.approvalRequest(_server, _email, Uint8List.fromList(List.filled(1600, 7)), _device);
      await auth.approvalPoll(_server, ticket.id);
      expect(await auth.approvals(_server, token), hasLength(1));
      await auth.answerApproval(_server, token, ticket.id, sealedKey: Uint8List(80));
      final polled = await auth.approvalPoll(_server, ticket.id);
      expect(polled.status, 'approved');
      await auth.deviceVerify(_server, await auth.deviceChallenge(_server, ticket.id));

      server.knownDevices.add(FakeKemlockServer.deviceId);
      await auth.replicaVerify(_server, await auth.replicaChallenge(_server, FakeKemlockServer.deviceId));

      _expectClean(checker, [
        'POST /kem/v1/auth/sso/start',
        'POST /kem/v1/auth/sso/finish',
        'POST /kem/v1/auth/passkey/options',
        'POST /kem/v1/auth/passkey/verify',
        'PUT /kem/v1/account/passkeys/{id}/prf',
        'GET /kem/v1/account/passkeys',
        'POST /kem/v1/auth/device/request',
        'GET /kem/v1/auth/device/request/{id}',
        'GET /kem/v1/devices/approvals',
        'POST /kem/v1/devices/approvals/{id}',
        'POST /kem/v1/auth/device/challenge',
        'POST /kem/v1/auth/device/verify',
        'POST /kem/v1/auth/device-key/challenge',
        'POST /kem/v1/auth/device-key/verify',
      ]);
    });

    test('the devices list, the push token, a device signed out, and the first keys of an account that has none', () async {
      final checker = _checkerOn(null);
      final server = FakeKemlockAccountServer(userId: _userId)
        ..checkTokens = false
        ..noKeys = true
        ..deviceList = [
          {
            'id': FakeKemlockServer.deviceId,
            'name': 'Kemlock on Pixel 9',
            'kind': 'kemlock-android',
            'createdAt': '2026-11-20T10:00:00Z',
            'lastSeenAt': '2026-11-22T10:00:00Z',
            'lastKemlockUseAt': '2026-11-22T10:00:00Z',
            'lastBitwardenUseAt': null,
            'current': true,
            'trusted': true,
          },
        ];
      final api = KmApi(server.client, proofs: KmDpop(SoftwareDeviceKey.generate()));
      final auth = KmAuthApi(api);
      final token = server.issueTokens('jkt')['accessToken']! as String;

      expect(await auth.devices(_server, token), hasLength(1));
      await auth.registerPushToken(_server, token, (kind: 'fcm', token: 'push-token-1'));
      await auth.unregisterPushToken(_server, token);
      await auth.signOutDevice(_server, token, FakeKemlockServer.deviceId);
      final keys = {...account.material()}..remove('keyVersion');
      expect(await auth.enrolKeys(_server, token, keys, Uint8List(80), 'software'), 1);
      expect((await auth.accountKeys(_server, token)).hasKeys, isTrue);

      _expectClean(checker, [
        'GET /kem/v1/devices',
        'POST /kem/v1/devices/push-token',
        'DELETE /kem/v1/devices/push-token',
        'POST /kem/v1/devices/sign-out',
        'POST /kem/v1/account/keys/enrol',
        'GET /kem/v1/account/keys',
      ]);
    });
  });

  group('the sync routes against the spec', () {
    test('a note with a file goes up and comes down, with the manifest and the delta', () async {
      final checker = _checkerOn(null)..requireProof = false;

      final (:server, :phone) = await _syncWithFile();
      await phone.another(fileStore: FakeFileStore()).run();

      expect(server.files, hasLength(1));
      _expectClean(checker, [
        'GET /kem/v1/sync',
        'POST /kem/v1/items:batch',
        'PUT /kem/v1/manifests/{owner}',
        'GET /kem/v1/manifests/{owner}',
        'POST /kem/v1/items/{id}/files',
        'PUT /kem/v1/items/{id}/files/{file}',
        'GET /kem/v1/items/{id}/files/{file}',
      ]);
    });

    test('the delta with a cursor, the siblings of an item and this device\'s key copy', () async {
      final checker = _checkerOn(null)..requireProof = false;
      final server = FakeKemlockServer()..checkTokens = false;
      final api = KmApi(server.client);
      final token = server.issueTokens('jkt')['accessToken']! as String;
      server.write(id: _itemA, kind: 'login', revision: 1, ciphertext: Uint8List(40), itemKey: Uint8List(kem1WrappedKeyLength));

      final page = await api.sync(_server, token);
      expect(await api.sync(_server, token, since: page!.cursor), isNull, reason: 'a 304');
      expect(await api.resolveSiblings(_server, token, _itemA), 0);
      await api.putKeyCopy(_server, token, Uint8List(40), 'software');
      expect(await api.keyCopy(_server, token), isNotNull);
      await api.deleteKeyCopy(_server, token);
      expect(await api.keyCopy(_server, token), isNull);

      _expectClean(checker, [
        'GET /kem/v1/sync',
        'POST /kem/v1/items/{id}/siblings/resolve',
        'PUT /kem/v1/devices/key-copy',
        'GET /kem/v1/devices/key-copy',
        'DELETE /kem/v1/devices/key-copy',
      ]);
    });

    test('a 409 of a stale write is a problem the spec lists', () async {
      final checker = _checkerOn(null)..requireProof = false;
      final server = FakeKemlockServer()..checkTokens = false;
      final api = KmApi(server.client);
      final token = server.issueTokens('jkt')['accessToken']! as String;
      server.write(id: _itemA, kind: 'login', revision: 1, ciphertext: Uint8List(40), itemKey: Uint8List(kem1WrappedKeyLength));
      final item = Kem1Item(
        id: _itemA,
        owner: Owner.user(_userId),
        kind: 'login',
        revision: 2,
        keyVersion: 1,
        ciphertext: Uint8List(40),
        itemKey: Uint8List(kem1WrappedKeyLength),
      );

      await expectLater(api.batch(_server, token, [(expected: 5, item: item)]), throwsA(isA<KmError>()));

      _expectClean(checker, ['POST /kem/v1/items:batch']);
      expect(checker.answers, contains('POST /kem/v1/items:batch 409'));
    });
  });

  group('the duplicate cleaner against the spec', () {
    test('the switch, the tags of an item, the groups, a dismissal, and the tags deleted', () async {
      final checker = _checkerOn(null)..requireProof = false;
      final server = FakeDedupServer()..checkTokens = false;
      final api = KmApi(server.client);
      final dedup = KmDedupApi(api);
      final token = server.issueTokens('jkt')['accessToken']! as String;
      final owner = server.owner;
      for (final id in [_itemA, _itemB]) {
        server.write(id: id, kind: 'login', revision: 1, ciphertext: Uint8List(40), itemKey: Uint8List(kem1WrappedKeyLength));
      }

      await dedup.settings(_server, token, owner);
      await dedup.turnOn(_server, token, owner);
      for (final id in [_itemA, _itemB]) {
        expect(await dedup.putTags(_server, token, id, 1, (version: 1, tags: [Uint8List(32)])), KmTagsResult.stored);
      }
      expect((await dedup.hints(_server, token, owner)).enabled, isTrue);
      final dismissal = await dedup.dismiss(_server, token, owner, [_itemA, _itemB]);
      await dedup.undismiss(_server, token, dismissal);
      await dedup.deleteTags(_server, token, owner);

      _expectClean(checker, [
        'GET /kem/v1/duplicates/settings',
        'PUT /kem/v1/duplicates/settings',
        'PUT /kem/v1/items/{id}/tags',
        'GET /kem/v1/duplicates',
        'POST /kem/v1/duplicates/dismissals',
        'DELETE /kem/v1/duplicates/dismissals/{id}',
        'DELETE /kem/v1/duplicates/tags',
      ]);
    });

    test('a batch that carries tags, which the spec\'s ItemDto has no room for', () async {
      final checker = _checkerOn(null)..requireProof = false;
      final server = FakeDedupServer()
        ..checkTokens = false
        ..turnOn();
      final api = KmApi(server.client);
      final token = server.issueTokens('jkt')['accessToken']! as String;
      final item = Kem1Item(
        id: _itemA,
        owner: Owner.user(_userId),
        kind: 'login',
        revision: 1,
        keyVersion: 1,
        ciphertext: Uint8List(40),
        itemKey: Uint8List(kem1WrappedKeyLength),
      );

      final tags = <String, KmTagSet>{
        _itemA: (version: 1, tags: [Uint8List(32)]),
      };
      final stored = await api.batchTagged(_server, token, [(expected: null, item: item)], tags: tags);

      expect(stored.tagged, {_itemA});
      _expectClean(checker, ['POST /kem/v1/items:batch']);
      expect(checker.violations, isEmpty, reason: 'the spec holds the tags of a write and of its answer');
    });
  });

  group('the Send routes against the spec', () {
    test('a text Send is made, read, changed, opened and deleted, and a file Send is uploaded and downloaded', () async {
      final checker = _checkerOn(null)..requireProof = false;
      final now = DateTime.utc(2030, 1, 1);
      final server = FakeKemlockServer()..checkTokens = false;
      server.sends.clock = () => now;
      final token = server.issueTokens('jkt')['accessToken']! as String;
      final sends = KmSendsApi(KmApi(server.client));
      const textId = '3f2c9a71-e4b0-4a56-8a00-000000000001';
      const fileId = '3f2c9a71-e4b0-4a56-8a00-000000000002';
      final deletion = now.add(const Duration(days: 7));
      final proof = Uint8List.fromList(List.generate(32, (i) => i));

      await sends.create(
        _server,
        token,
        KmNewSend(
          id: textId,
          kind: sendKindText,
          meta: Uint8List(40),
          sealedKey: Uint8List(sendSealedKeyLength),
          payload: Uint8List(50),
          maxAccess: 5,
          expiresAt: now.add(const Duration(days: 3)),
          deletionAt: deletion,
          password: proof,
        ),
      );
      expect(await sends.list(_server, token), hasLength(1));
      await sends.get(_server, token, textId);
      final access = sendAccessId(uuidBytes(textId));
      await sends.access(_server, access, password: proof);
      final change = KmSendUpdate(meta: Uint8List(40), deletionAt: deletion, payload: Uint8List(50), removePassword: true);
      await sends.update(_server, token, textId, change);
      await sends.access(_server, access);

      final file = kma1EncryptSync(Uint8List.fromList(List.generate(70000, (i) => i)), Uint8List(32));
      final made = await sends.create(
        _server,
        token,
        KmNewSend(
          id: fileId,
          kind: sendKindFile,
          meta: Uint8List(40),
          sealedKey: Uint8List(sendSealedKeyLength),
          payload: Uint8List(50),
          fileSize: file.length,
          deletionAt: deletion,
        ),
      );
      await sends.upload(_server, token, fileId, made.uploadUrl!, file);
      expect(await sends.download(_server, sendAccessId(uuidBytes(fileId)), fileSize: file.length), file);
      await sends.delete(_server, token, textId);

      _expectClean(checker, [
        'POST /kem/v1/sends',
        'GET /kem/v1/sends',
        'GET /kem/v1/sends/{id}',
        'PUT /kem/v1/sends/{id}',
        'DELETE /kem/v1/sends/{id}',
        'PUT /kem/v1/sends/{id}/file',
        'POST /kem/v1/send-access/{access_id}',
        'POST /kem/v1/send-access/{access_id}/file',
      ]);
    });
  });

  group('the space routes against the spec', () {
    final space = uuid(0x5a);
    final everyone = uuid(0xe0);
    final privateKeys = <String, Uint8List>{};
    late Person alice;
    late Person bob;
    late SealRegistry seals;

    Uint8List seq(int n, int start) => Uint8List.fromList(List.generate(n, (i) => (start + i) & 0xff));

    Future<Person> person(int n) async {
      final private = seq(96, n * 13);
      final made = Person(n, kx1PublicKey: await Kx1.publicKeyOf(private));
      privateKeys[made.id] = private;
      return made;
    }

    Uint8List keyBytes(KeyRef key, int version) {
      if (key.isSpace) {
        return seq(32, version);
      }
      return seq(32, key.collection!.codeUnitAt(key.collection!.length - 1) * 3 + version);
    }

    setUpAll(() async {
      alice = await person(1);
      bob = await person(2);
      seals = SealRegistry(space, keyOf: keyBytes);
      await seals.prepare(keys: [const KeyRef.space(), KeyRef.collection(everyone)], versions: [1], people: [alice, bob]);
    });

    KmConnection connectionOf(FakeSpaceServer server, Person who) => KmConnection(
      api: KmApi(server.client),
      server: FakeSpaceServer.url,
      session: KmSession(
        userId: who.id,
        deviceId: '00000000-0000-4000-8000-0000000000d1',
        tokens: KmTokens(access: who.id, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
      ),
      save: (_) async {},
    );

    Map<String, Object?> facts(Person who) => {
      'email': '${who.id.substring(30)}@example.com',
      'name': 'Member ${who.id.substring(30)}',
      'publicBundle': b64urlEncode(who.bundle.bytes),
      'bundleSignature': b64urlEncode(who.bundleSignature),
      'userKeyVersion': who.keyVersion,
      'needsReconfirmation': false,
    };

    test('two members sync a space: the keys, the chain, the delta, a write and its manifest', () async {
      final checker = _checkerOn(null)..requireProof = false;
      final chain = ChainBuilder(space, seals: seals)
        ..create(alice, collection: everyone)
        ..invite(alice, bob, grants: {everyone: CollectionPermission.edit})
        ..confirm(alice, bob)
        ..seal(alice, [const KeyRef.space(), KeyRef.collection(everyone)]);
      final server = FakeSpaceServer(space, chain, seals: seals);
      await server.sealAll();
      var clock = DateTime.utc(2026, 11, 22, 12).millisecondsSinceEpoch;
      int tick() => clock += 60000;
      final login = Login(id: 'l1', name: 'Site', username: 'me', password: 'pw', addedAt: 1, updatedAt: 10, spaceId: space);
      final a = KmSpacePhone(
        server,
        alice,
        privateKeys[alice.id]!,
        heads: {},
        lists: Lists(logins: [login]),
        tick: tick,
      );
      final b = KmSpacePhone(server, bob, privateKeys[bob.id]!, heads: {}, lists: const Lists(), tick: tick);

      await a.run();
      await b.run();

      expect(b.lists.logins.single.id, 'l1');
      _expectClean(checker, [
        'GET /kem/v1/spaces/{id}',
        'GET /kem/v1/spaces/{id}/chain',
        'GET /kem/v1/sync',
        'POST /kem/v1/items:batch',
        'PUT /kem/v1/manifests/{owner}',
      ]);
    });

    test('a space is made with a create record, and the list shows it', () async {
      final checker = _checkerOn(null)..requireProof = false;
      final sigKeys = await Sig1.generate();
      final kxPrivate = Uint8List.fromList(List.generate(Kx1.privateKeyLength, (i) => (i * 7 + 3) & 0xff));
      final account = KmAccount(
        accountId: alice.id,
        keyVersion: 1,
        rootKey: Uint8List(64),
        kx1PrivateKey: kxPrivate,
        sig1PrivateKey: sigKeys.privateKey,
        kx1PublicKey: await Kx1.publicKeyOf(kxPrivate),
        sig1PublicKey: sigKeys.publicKey,
      );
      final server = FakeSpaceServer(space, ChainBuilder(space));
      final store = <String, Object?>{};
      final connection = connectionOf(server, alice);
      KmServerSpaces sourceOf() => KmServerSpaces(
        accountId: alice.id,
        run: <T>(action) => action(connection, account),
        loadValue: (key) async => store[key],
        saveValue: (key, value) async => store[key] = value,
      );

      final made = await sourceOf().make('Example Co');
      final listed = await sourceOf().load();

      expect(listed.single.id, made.id);
      _expectClean(checker, ['POST /kem/v1/spaces/{id}/chain', 'GET /kem/v1/spaces']);
    });

    test('the members an admin reads, the invitee\'s lookup, resend and answer, and the changes queued from outside', () async {
      final checker = _checkerOn(null)..requireProof = false;
      final chain = ChainBuilder(space)
        ..create(alice, collection: everyone)
        ..invite(alice, bob, grants: {everyone: CollectionPermission.edit});
      final theo = Person(4);
      final server = FakeSpaceServer(space, chain)
        ..accepted.add(bob.id)
        ..memberFacts[alice.id] = facts(alice)
        ..memberFacts[bob.id] = facts(bob)
        ..directory['theo@example.com'] = (account: theo.id, bundle: theo.bundle.bytes, bundleSignature: theo.bundleSignature)
        ..pending.add({
          'id': uuid(0x77),
          'queuedAt': 1795000000,
          'source': 'bitwarden',
          'requestedBy': {'via': 'bitwarden', 'email': 'sam@example.com'},
          'change': {'kind': 'add-member', 'account': theo.id, 'role': 'member'},
        });
      final asAlice = connectionOf(server, alice);

      final members = await SpaceMembersClient(
        connection: asAlice,
        server: FakeSpaceServer.url,
        space: space,
        crypto: const FakeChainCrypto(),
      ).read(chain.state);
      expect(members.offers.keys, [bob.id]);

      final invites = SpaceInviteClient(connection: asAlice, server: FakeSpaceServer.url, space: space, crypto: const FakeChainCrypto());
      expect((await invites.lookup('theo@example.com'))!.account, theo.id);
      await invites.resend(bob.id);

      final asBob = SpaceInviteClient(
        connection: connectionOf(server, bob),
        server: FakeSpaceServer.url,
        space: space,
        crypto: const FakeChainCrypto(),
      );
      await asBob.answer(accept: true);
      await asBob.answer(accept: false);

      final queue = SpacePendingClient(connection: asAlice, server: FakeSpaceServer.url, space: space);
      final queued = await queue.list();
      expect(queued, hasLength(1));
      await queue.drop(queued.single);

      _expectClean(checker, [
        'GET /kem/v1/spaces/{id}/members',
        'GET /kem/v1/spaces/{id}/lookup',
        'POST /kem/v1/spaces/{id}/members/{user}/resend',
        'POST /kem/v1/spaces/{id}/members/{user}/accept',
        'DELETE /kem/v1/spaces/{id}/members/{user}',
        'GET /kem/v1/spaces/{id}/chain/pending',
        'DELETE /kem/v1/spaces/{id}/chain/pending/{pending}',
      ]);
    });
  });

  group('13.2: a renamed field in a test-local copy of the spec', () {
    test('the request the client sends is reported when the server renamed `writes` of the batch', () async {
      final checker = _checkerOn(_renamed('TaggedBatchRequest', 'writes', 'entries'))..requireProof = false;

      await _syncWithFile();

      final found = [for (final violation in checker.violations) '$violation'];
      expect(found, contains(contains(r'$.entries is missing')));
      expect(found, contains(contains(r'$.writes is not in the spec')));
    });

    test('the answer of a fake is reported when the server renamed `cursor` of the delta', () async {
      final checker = _checkerOn(_renamed('SyncResponse', 'cursor', 'position'))..requireProof = false;

      await _syncWithFile();

      final found = [for (final violation in checker.violations) '$violation'];
      expect(found, contains(contains(r'$.position is missing')));
      expect(found, contains(contains(r'$.cursor is not in the spec')));
    });

    test('the flow is clean against the spec as copied', () async {
      final checker = _checkerOn(null)..requireProof = false;

      await _syncWithFile();

      expect([for (final violation in checker.violations) '$violation'], isEmpty);
    });
  });

  group('the routes the client calls', () {
    /// Each route the client code names, as it writes it (`{}` for an interpolation), with the method and where it comes
    /// from. A route the code gets without a literal path (the live socket) is marked in [_notLiteral].
    const routes = <(String, String, String)>[
      ('GET', '/config', 'km_api.dart, KmApi.config'),
      ('POST', '/auth/token', 'km_api.dart, KmApi.refresh'),
      ('GET', '/sync', 'km_api.dart, KmApi.sync'),
      ('POST', '/sync', 'km_api.dart, KmApi.sync with a cursor too long for the URL'),
      ('POST', '/items/{}/siblings/resolve', 'km_api.dart, KmApi.resolveSiblings'),
      ('POST', '/items:batch', 'km_api.dart, KmApi.batchTagged; server_spaces.dart, the space\'s writes'),
      ('GET', '/manifests/{}', 'km_api.dart, KmApi.manifest; server_spaces.dart, the space\'s manifest'),
      ('PUT', '/manifests/{}', 'km_api.dart, KmApi.putManifest'),
      ('GET', '/devices/key-copy', 'km_api.dart, KmApi.keyCopy'),
      ('PUT', '/devices/key-copy', 'km_api.dart, KmApi.putKeyCopy'),
      ('DELETE', '/devices/key-copy', 'km_api.dart, KmApi.deleteKeyCopy'),
      ('POST', '/items/{}/files', 'km_api.dart, KmApi.startFile'),
      ('POST', '/items/{}/files/{}/finish', 'km_api.dart, KmApi.uploadFile after a pre-signed upload'),
      ('PUT', '/items/{}/files/{}', 'km_api.dart, KmApi.uploadFile'),
      ('GET', '/items/{}/files/{}', 'km_api.dart, KmApi.downloadFile'),
      ('DELETE', '/items/{}/files/{}', 'km_api.dart, KmApi.deleteFile'),
      ('GET', '/live', 'km_host.dart, the live socket\'s upgrade request'),
      ('POST', '/auth/methods', 'km_auth_api.dart, KmAuthApi.methods'),
      ('POST', '/auth/prelogin', 'km_auth_api.dart, KmAuthApi.prelogin'),
      ('POST', '/auth/opaque/start', 'km_auth_api.dart, KmAuthApi.opaqueStart'),
      ('POST', '/auth/opaque/finish', 'km_auth_api.dart, KmAuthApi.opaqueFinish'),
      ('POST', '/auth/two-factor', 'km_auth_api.dart, KmAuthApi.twoFactor'),
      ('POST', '/auth/two-factor/email', 'km_auth_api.dart, KmAuthApi.twoFactor'),
      ('POST', '/auth/two-factor/recovery', 'km_auth_api.dart, KmAuthApi.twoFactor'),
      ('POST', '/auth/two-factor/email/send', 'km_auth_api.dart, KmAuthApi.sendEmailCode'),
      ('POST', '/auth/two-factor/webauthn/options', 'km_auth_api.dart, KmAuthApi.securityKeyOptions'),
      ('POST', '/auth/two-factor/webauthn', 'km_auth_api.dart, KmAuthApi.securityKeyStep'),
      ('POST', '/auth/bitwarden/start', 'km_auth_api.dart, KmAuthApi.bitwardenStart'),
      ('POST', '/auth/bitwarden/finish', 'km_auth_api.dart, KmAuthApi.bitwardenFinish'),
      ('GET', '/account/keys', 'km_auth_api.dart, KmAuthApi.accountKeys'),
      ('POST', '/account/keys/enrol', 'km_auth_api.dart, KmAuthApi.enrolKeys'),
      ('POST', '/auth/passkey/options', 'km_auth_api.dart, KmAuthApi.passkeyOptions'),
      ('POST', '/auth/passkey/verify', 'km_auth_api.dart, KmAuthApi.passkeyVerify'),
      ('GET', '/account/passkeys', 'km_auth_api.dart, KmAuthApi.accountPasskeys'),
      ('PUT', '/account/passkeys/{}/prf', 'km_auth_api.dart, KmAuthApi.setPasskeyPrf'),
      ('POST', '/auth/sso/start', 'km_auth_api.dart, KmAuthApi.ssoStart'),
      ('POST', '/auth/sso/finish', 'km_auth_api.dart, KmAuthApi.ssoFinish'),
      ('POST', '/auth/device/request', 'km_auth_api.dart, KmAuthApi.approvalRequest'),
      ('GET', '/auth/device/request/{}', 'km_auth_api.dart, KmAuthApi.approvalPoll'),
      ('POST', '/auth/device/challenge', 'km_auth_api.dart, KmAuthApi.deviceChallenge'),
      ('POST', '/auth/device/verify', 'km_auth_api.dart, KmAuthApi.deviceVerify'),
      ('POST', '/auth/device-key/challenge', 'km_auth_api.dart, KmAuthApi.replicaChallenge'),
      ('POST', '/auth/device-key/verify', 'km_auth_api.dart, KmAuthApi.replicaVerify'),
      ('GET', '/devices/approvals', 'km_auth_api.dart, KmAuthApi.approvals'),
      ('POST', '/devices/approvals/{}', 'km_auth_api.dart, KmAuthApi.answerApproval'),
      ('GET', '/devices', 'km_auth_api.dart, KmAuthApi.devices'),
      ('POST', '/devices/push-token', 'km_auth_api.dart, KmAuthApi.registerPushToken'),
      ('DELETE', '/devices/push-token', 'km_auth_api.dart, KmAuthApi.unregisterPushToken'),
      ('POST', '/devices/sign-out', 'km_auth_api.dart, KmAuthApi.signOutDevice'),
      ('GET', '/duplicates/settings', 'km_dedup_api.dart, KmDedupApi.settings'),
      ('PUT', '/duplicates/settings', 'km_dedup_api.dart, KmDedupApi.turnOn'),
      ('DELETE', '/duplicates/tags', 'km_dedup_api.dart, KmDedupApi.deleteTags'),
      ('GET', '/duplicates', 'km_dedup_api.dart, KmDedupApi.hints'),
      ('PUT', '/items/{}/tags', 'km_dedup_api.dart, KmDedupApi.putTags'),
      ('POST', '/duplicates/dismissals', 'km_dedup_api.dart, KmDedupApi.dismiss'),
      ('DELETE', '/duplicates/dismissals/{}', 'km_dedup_api.dart, KmDedupApi.undismiss'),
      ('POST', '/sends', 'km_sends_api.dart, KmSendsApi.create'),
      ('GET', '/sends', 'km_sends_api.dart, KmSendsApi.list'),
      ('GET', '/sends/{}', 'km_sends_api.dart, KmSendsApi.get'),
      ('PUT', '/sends/{}', 'km_sends_api.dart, KmSendsApi.update'),
      ('DELETE', '/sends/{}', 'km_sends_api.dart, KmSendsApi.delete'),
      ('PUT', '/sends/{}/file', 'km_sends_api.dart, KmSendsApi.upload'),
      ('POST', '/send-access/{}', 'km_sends_api.dart, KmSendsApi.access'),
      ('POST', '/send-access/{}/file', 'km_sends_api.dart, KmSendsApi.download'),
      ('GET', '/spaces', 'km_server_spaces.dart, the list of spaces'),
      ('GET', '/spaces/{}', 'server_spaces.dart, the keys sealed to the member'),
      ('GET', '/spaces/{}/chain', 'space_chain_client.dart, SpaceChainClient.read'),
      ('GET', '/spaces/{}/chain/{}/seals', 'space_chain_client.dart, SpaceChainClient.sealHashes'),
      ('POST', '/spaces/{}/chain', 'space_chain_client.dart, SpaceChainClient.append'),
      ('POST', '/spaces/{}/chain/pending/{}', 'space_chain_client.dart, SpaceChainClient.approvePending'),
      ('GET', '/spaces/{}/chain/pending', 'space_pending.dart, SpacePendingClient.list'),
      ('DELETE', '/spaces/{}/chain/pending/{}', 'space_pending.dart, SpacePendingClient.drop'),
      ('GET', '/spaces/{}/lookup', 'space_invites.dart, SpaceInviteClient.lookup'),
      ('POST', '/spaces/{}/members/{}/resend', 'space_invites.dart, SpaceInviteClient.resend'),
      ('POST', '/spaces/{}/members/me/accept', 'space_invites.dart, SpaceInviteClient.answer'),
      ('DELETE', '/spaces/{}/members/me', 'space_invites.dart, SpaceInviteClient.answer'),
      ('GET', '/spaces/{}/members', 'space_members.dart, SpaceMembersClient.read'),
    ];
    const notLiteral = {'/live'};

    /// The route literals of the client code: a string that starts with `/` and a first segment of the spec's paths.
    Set<String> scanned(OpenApiSpec spec) {
      final firsts = {for (final path in (spec.json['paths']! as Json).keys) path.split('/')[3]};
      final literal = RegExp(r"'(/[^'\s]*)'");
      final interpolation = RegExp(r'\$\{[^}]*\}|\$[A-Za-z_]\w*');
      final found = <String>{};
      for (final directory in const ['lib/features/sync/kemlock', 'lib/features/spaces', 'lib/features/sends'].expand(appAndCore)) {
        for (final file in directory.listSync().whereType<File>()) {
          if (!file.path.endsWith('.dart')) {
            continue;
          }
          for (final line in file.readAsLinesSync()) {
            if (line.trimLeft().startsWith('//')) {
              continue;
            }
            for (final match in literal.allMatches(line)) {
              final route = match.group(1)!.replaceAll(interpolation, '{}');
              if (firsts.contains(route.split('/')[1])) {
                found.add(route);
              }
            }
          }
        }
      }
      return found;
    }

    test('each (method, path) the client calls is in the spec', () {
      final spec = OpenApiSpec.fixture();
      final missing = <String>[];
      for (final (method, path, from) in routes) {
        final found = spec.find('/kem/v1${path.replaceAll('{}', 'x')}', method);
        if (found == null || !found.item.containsKey(method.toLowerCase())) {
          missing.add('$method /kem/v1$path ($from)');
        }
      }
      expect(missing, isEmpty, reason: 'the spec has no such operation');
    });

    test('each route string in the client code is in the list above, and each of the list is in the code', () {
      final spec = OpenApiSpec.fixture();
      final listed = {for (final (_, path, _) in routes) path};
      final code = scanned(spec);

      expect(code.difference(listed), isEmpty, reason: 'a route the code names that the list does not: add it, with its method');
      expect(listed.difference(code).difference(notLiteral), isEmpty, reason: 'a route of the list that no code names any more');
    });
  });
}
