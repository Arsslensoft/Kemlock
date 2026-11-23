// Server matching in a Kemlock Server run (add-duplicate-cleaner, tasks 7.1, 7.3 and 7.4), against the fake server
// with the duplicate cleaner's routes: which tags ride with a write, that nothing but a login's `cred` tags is ever
// sent, the backfill of the items the server holds none for, the hints a run reads, and the tags made again under a
// key version a replacement moved.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/dedup.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/bytes.dart' show randomBytes;
import 'package:kemlock/features/duplicates/duplicate_rules.dart' show TagKind;
import 'package:kemlock/features/duplicates/duplicate_tags.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_backend.dart' show KmSyncResult;
import 'package:kemlock/features/sync/kemlock/km_cache.dart';
import 'package:kemlock/features/sync/kemlock/km_dedup.dart';
import 'package:kemlock/features/sync/kemlock/km_dedup_api.dart';
import 'package:kemlock/features/sync/kemlock/km_move_server.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/features/sync/kemlock/km_sync.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/models/secure_note.dart';

import 'fake_dedup_server.dart';
import 'fake_kemlock_server.dart';
import 'fake_km_crypto.dart';
import 'km_sync_kit.dart';

const _a = '3f2c9a71-e4b0-4856-8a00-0000000000a1';
const _b = '3f2c9a71-e4b0-4856-8a00-0000000000b2';
const _c = '3f2c9a71-e4b0-4856-8a00-0000000000c3';
const _d = '3f2c9a71-e4b0-4856-8a00-0000000000d4';
const _e = '3f2c9a71-e4b0-4856-8a00-0000000000e5';
const _f = '3f2c9a71-e4b0-4856-8a00-0000000000f6';
const _g = '3f2c9a71-e4b0-4856-8a00-0000000000a7';
const _h = '3f2c9a71-e4b0-4856-8a00-0000000000a8';

/// The fake account crypto with a user key, so a phone can make its dedup key.
class _Crypto extends FakeKmCrypto implements KmDedupKeys {
  _Crypto(this._userKey);

  final Uint8List _userKey;

  @override
  Uint8List dedupKeyAt(int version) => dedupKey(_userKey, owner, version);
}

FakeDedupServer _server() => FakeDedupServer()..checkTokens = false;

Login _login(String id, {String password = 'hunter2', List<String> sites = const ['larkspur.example'], String username = 'sam'}) =>
    Login(id: id, name: 'Larkspur $id', username: username, password: password, websites: sites, addedAt: 1);

/// One phone with server matching on (unless [matching] is false), over the fake server.
class _Phone {
  _Phone(this.server, this.clock, {this.lists = const Lists(), bool matching = true, int perRun = 300}) {
    final token = server.issueTokens('jkt')['accessToken']! as String;
    final session = KmSession(
      userId: server.userId,
      deviceId: FakeKemlockServer.deviceId,
      tokens: KmTokens(access: token, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
    );
    connection = KmConnection(api: KmApi(server.client), server: FakeKemlockServer.url, session: session, save: (_) async {});
    scope = KmScopeSync(
      connection: connection,
      server: FakeKemlockServer.url,
      crypto: crypto,
      dedup: matching ? KmDedup(keys: crypto, onHints: hints.add, onSettings: settings.add, perRun: perRun) : null,
      loadCache: () async => KmCache.fromJson(stored == null ? null : jsonDecode(jsonEncode(stored))),
      saveCache: (cache) async => stored = jsonDecode(jsonEncode(cache.toJson())),
    );
  }

  final FakeDedupServer server;
  final KmClock clock;
  final crypto = _Crypto(randomBytes(32));
  late final KmConnection connection;
  late final KmScopeSync scope;

  Lists lists;
  ScopeState state = const ScopeState(known: []);
  Object? stored;

  /// What the run told: the server's groups, and whether the server had matching on, each time it was asked.
  final hints = <KmHints>[];
  final settings = <bool>[];

  KmCache get cache => KmCache.fromJson(stored);

  Uint8List key(int version) => crypto.dedupKeyAt(version);

  Future<KmSyncResult> run() async {
    final now = clock.tick();
    final result = await scope.sync(kmTarget, lists, state, now: now);
    lists = result.doc;
    state = ScopeState(known: result.known, lastSyncAt: now, extra: result.state);
    return result;
  }
}

/// A phone of the same account that sends no tags, as a Bitwarden client doesn't.
KmPhone _untagged(_Phone phone, {Lists lists = const Lists()}) =>
    KmPhone(phone.server, clock: phone.clock, crypto: phone.crypto.alike(), lists: lists);

String _cred(Uint8List key, String site, String user, String password) => b64urlEncode(dedupTag(key, 'cred', [site, user, password]));

/// The tags of every item of [lists] under [key], of every kind, as base64url.
Set<String> _everyTag(Uint8List key, Lists lists, {bool credOnly = false}) => {
  for (final item in <Object>[
    ...lists.logins,
    ...lists.accounts,
    ...lists.notes,
    ...lists.backupServices,
    ...lists.passkeys,
    ...lists.cards,
    ...lists.identities,
  ])
    for (final tag in itemTags(item, key))
      if (!credOnly || tag.kind == TagKind.cred) b64urlEncode(tag.bytes),
};

Set<String> _everyNonCredTag(Uint8List key, Lists lists) => _everyTag(key, lists).difference(_everyTag(key, lists, credOnly: true));

/// The items every batch request carried, as the JSON the server read.
List<Map<String, Object?>> _sentItems(FakeDedupServer server) => [
  for (final request in server.requests.where((request) => request.url.path.endsWith('/items:batch')))
    for (final write in ((jsonDecode(request.body) as Map<String, Object?>)['writes']! as List<Object?>).cast<Map<String, Object?>>())
      write['item']! as Map<String, Object?>,
];

void main() {
  group('writes carry cred tags when matching is on (7.1)', () {
    test('a login with two websites writes two cred tags and no account tag, under the version the server holds', () async {
      final server = _server()..turnOn();
      final phone = _Phone(
        server,
        KmClock(),
        lists: Lists(
          logins: [
            _login(_a, sites: ['alpha.example', 'beta.example']),
          ],
        ),
      );

      await phone.run();

      final key = phone.key(1);
      final expected = {_cred(key, 'alpha.example', 'sam', 'hunter2'), _cred(key, 'beta.example', 'sam', 'hunter2')};
      final write = server.tagWrites.single;
      expect(write.route, 'batch');
      expect(write.version, 1);
      expect(write.tags, hasLength(2));
      expect(write.tags.toSet(), expected);
      final account = {
        b64urlEncode(dedupTag(key, 'account', ['alpha.example', 'sam'])),
        b64urlEncode(dedupTag(key, 'account', ['beta.example', 'sam'])),
      };
      expect(write.tags.toSet().intersection(account), isEmpty);
      expect(server.tags[_a]!.tags.toSet(), expected);
    });

    test('the tags are made under the version the server holds, not the first one', () async {
      final server = _server()..turnOn(version: 3);
      final phone = _Phone(server, KmClock(), lists: Lists(logins: [_login(_a)]));

      await phone.run();

      expect(server.tagWrites.single.version, 3);
      expect(server.tagWrites.single.tags, [_cred(phone.key(3), 'larkspur.example', 'sam', 'hunter2')]);
      expect(server.validTags, contains(_a));
    });

    test('a code, note, passkey, card, backup-code list, identity and a login with no password write no tag at all', () async {
      final server = _server()..turnOn();
      final lists = Lists(
        accounts: [acct(_b)],
        notes: [const SecureNote(id: _c, title: 'Wifi', text: 'the password is on the fridge', addedAt: 1)],
        backupServices: [
          const BackupService(
            id: _d,
            serviceName: 'GitLab',
            codes: [BackupCode(code: 'a1b2c3d4')],
            addedAt: 1,
          ),
        ],
        identities: [const Identity(id: _e, name: 'Sam', givenName: 'Sam', email: 'sam@example.org', addedAt: 1)],
        cards: [const PaymentCard(id: _f, name: 'Visa', number: '4111111111111111', addedAt: 1)],
        passkeys: [
          const Passkey(
            id: _g,
            credentialId: 'Y3JlZA',
            rpId: 'example.com',
            userHandle: 'aA',
            userName: 'sam',
            privateKey: 'a2V5',
            addedAt: 1,
          ),
        ],
        logins: [
          _login(_a),
          const Login(id: _h, name: 'No password', username: 'sam', websites: ['larkspur.example'], addedAt: 1),
        ],
      );
      final phone = _Phone(server, KmClock(), lists: lists);

      await phone.run();

      expect(server.tagWrites.map((write) => write.item), [_a], reason: 'only the login that has a password');
      for (final item in _sentItems(server)) {
        if (item['id'] != _a) {
          expect(item, isNot(contains('tags')), reason: '${item['kind']}');
          expect(item, isNot(contains('tagVersion')), reason: '${item['kind']}');
        }
      }
      expect(server.items.keys, hasLength(8), reason: 'every item was written');
    });

    test('no tag of any other kind ever reaches a request', () async {
      final server = _server()..turnOn();
      final lists = Lists(
        accounts: [acct(_b)],
        notes: [const SecureNote(id: _c, title: 'Wifi', text: 'the password is on the fridge', addedAt: 1)],
        backupServices: [
          const BackupService(
            id: _d,
            serviceName: 'GitLab',
            codes: [BackupCode(code: 'a1b2c3d4')],
            addedAt: 1,
          ),
        ],
        identities: [const Identity(id: _e, name: 'Sam', givenName: 'Sam', email: 'sam@example.org', addedAt: 1)],
        cards: [const PaymentCard(id: _f, name: 'Visa', number: '4111111111111111', addedAt: 1)],
        passkeys: [
          const Passkey(
            id: _g,
            credentialId: 'Y3JlZA',
            rpId: 'example.com',
            userHandle: 'aA',
            userName: 'sam',
            privateKey: 'a2V5',
            addedAt: 1,
          ),
        ],
        logins: [
          _login(_a, sites: ['alpha.example', 'beta.example']),
          _login(_h, password: 'other'),
        ],
      );
      final phone = _Phone(server, KmClock(), lists: lists);
      await phone.run();
      // Something edited, so a second batch goes too
      phone.lists = Lists(
        accounts: phone.lists.accounts,
        notes: phone.lists.notes,
        backupServices: phone.lists.backupServices,
        identities: phone.lists.identities,
        cards: phone.lists.cards,
        passkeys: phone.lists.passkeys,
        logins: [
          for (final login in phone.lists.logins)
            if (login.id == _a) login.copyWith(password: 'changed', updatedAt: phone.clock.ms + 10) else login,
        ],
      );
      await phone.run();

      // What the other kinds of tag would have been, under the key the cred tags are made with, at every version
      final nonCred = {
        for (final version in [1, 2]) ..._everyNonCredTag(phone.key(version), lists),
      };
      expect(nonCred.length, greaterThan(8), reason: 'the account tags and every other kind have tags to leak');
      final sent = {for (final write in server.tagWrites) ...write.tags};
      expect(sent, isNotEmpty);
      expect(sent.intersection(nonCred), isEmpty);
      for (final request in server.requests) {
        for (final tag in nonCred) {
          expect(request.body.contains(tag), isFalse, reason: '${request.method} ${request.url.path} carried a tag that is not a cred one');
        }
      }
      // What was sent is the cred tags of the logins as they were and as they were changed, and nothing else
      final changed = {_cred(phone.key(1), 'alpha.example', 'sam', 'changed'), _cred(phone.key(1), 'beta.example', 'sam', 'changed')};
      expect(sent.difference(_everyTag(phone.key(1), lists, credOnly: true)).difference(changed), isEmpty);
    });

    test('with the phone’s switch off nothing is sent: no tag, no tags route and no duplicates route', () async {
      final server = _server()..turnOn();
      final phone = _Phone(server, KmClock(), lists: Lists(logins: [_login(_a)]), matching: false);

      await phone.run();

      expect(server.tagWrites, isEmpty);
      expect(_sentItems(server), isNotEmpty);
      for (final item in _sentItems(server)) {
        expect(item, isNot(contains('tags')));
        expect(item, isNot(contains('tagVersion')));
      }
      expect(server.requests.where((r) => r.url.path.contains('/duplicates') || r.url.path.endsWith('/tags')), isEmpty);
      expect(phone.hints, isEmpty);
    });

    test('a server with matching off sends the phone no tags to make, and the phone says so', () async {
      final server = _server();
      final phone = _Phone(server, KmClock(), lists: Lists(logins: [_login(_a)]));

      await phone.run();

      expect(server.tagWrites, isEmpty);
      expect(phone.settings, [false], reason: 'the phone’s switch follows the server’s');
      expect(server.items, contains(_a));
    });

    test('the move’s batches carry the same tags, and none for a note', () async {
      final server = _server()..turnOn();
      final phone = _Phone(server, KmClock());
      final tags = KmCredTags(key: phone.key(1), version: 1);
      final moved = KmMoveServer(connection: phone.connection, server: FakeKemlockServer.url, crypto: phone.crypto, tags: tags);

      await moved.send([
        KmMoveWrite(itemId: _a, entryId: _a, kind: 'login', revision: 1, json: _login(_a).toJson()),
        KmMoveWrite(
          itemId: _c,
          entryId: _c,
          kind: 'note',
          revision: 1,
          json: const SecureNote(id: _c, title: 'Wifi', text: 'fridge', addedAt: 1).toJson(),
        ),
      ]);

      expect(server.tagWrites.map((write) => write.item), [_a]);
      expect(server.tags[_a]!.tags, [_cred(phone.key(1), 'larkspur.example', 'sam', 'hunter2')]);
    });
  });

  group('the backfill (7.3)', () {
    test('an item another device wrote without tags is given them with PUT …/tags and If-Match', () async {
      final server = _server();
      final phone = _Phone(server, KmClock(), lists: Lists(logins: [_login(_a)]));
      await phone.run();
      server.turnOn();
      // Another client changes the item and sends no tags
      final other = _untagged(phone);
      await other.run();
      other.lists = Lists(
        logins: [other.lists.logins.single.copyWith(note: 'edited elsewhere', updatedAt: phone.clock.ms + 10)],
      );
      await other.run();
      expect(server.items[_a]!.revision, 2);
      expect(server.validTags, isEmpty);
      server.requests.clear();

      await phone.run();

      final put = server.requests.singleWhere((request) => request.method == 'PUT');
      expect(put.url.path, '/kem/v1/items/$_a/tags');
      expect(put.headers['If-Match'], '2');
      expect(server.tags[_a]!.revision, 2);
      expect(server.tags[_a]!.version, 1);
      expect(server.tags[_a]!.tags, [_cred(phone.key(1), 'larkspur.example', 'sam', 'hunter2')]);
      expect(phone.cache.items[_a]!.taggedFor(1), isTrue);
    });

    test('a stale revision is skipped, and retried at the next sync', () async {
      final server = _server();
      final phone = _Phone(server, KmClock(), lists: Lists(logins: [_login(_a)]));
      await phone.run();
      server.turnOn();
      var refused = false;
      server.respond = (request) async {
        if (!refused && request.method == 'PUT' && request.url.path.endsWith('/tags')) {
          refused = true;
          return server.problem(409, 'stale-revision', extra: {'itemId': _a, 'currentRevision': 5});
        }
        return server.handle(request);
      };

      await phone.run();

      expect(refused, isTrue);
      expect(server.validTags, isEmpty);
      expect(phone.cache.items[_a]!.taggedFor(1), isFalse);

      await phone.run();

      expect(server.validTags, contains(_a));
      expect(phone.cache.items[_a]!.taggedFor(1), isTrue);
    });

    test('an item with tags stored for its revision is not sent again', () async {
      final server = _server()..turnOn();
      final phone = _Phone(server, KmClock(), lists: Lists(logins: [_login(_a)]));
      await phone.run();
      server.requests.clear();

      await phone.run();
      await phone.run();

      expect(server.requests.where((request) => request.url.path.endsWith('/tags')), isEmpty);
      expect(server.tagWrites, hasLength(1));
    });

    test('a long backlog is spread over the runs', () async {
      final server = _server();
      final ids = [_a, _b, _c];
      final phone = _Phone(server, KmClock(), lists: Lists(logins: [for (final id in ids) _login(id)]), perRun: 2);
      await phone.run();
      server.turnOn();

      await phone.run();
      expect(server.tagWrites.where((write) => write.route == 'tags'), hasLength(2));

      await phone.run();
      expect(server.tagWrites.where((write) => write.route == 'tags'), hasLength(3));
      expect(server.validTags.keys, unorderedEquals(ids));
    });

    test('matching turned off at the server stops the backfill and the phone is told', () async {
      final server = _server();
      final phone = _Phone(server, KmClock(), lists: Lists(logins: [_login(_a)]));
      await phone.run();
      server.turnOn();
      server.respond = (request) async {
        if (request.method == 'PUT' && request.url.path.endsWith('/tags')) {
          server.of(server.owner).enabled = false;
        }
        return server.handle(request);
      };

      await phone.run();

      expect(phone.settings.last, isFalse);
      expect(server.validTags, isEmpty);
    });
  });

  group('the hints a run reads (7.3)', () {
    test('are the server’s groups of ids, with the logins this phone knows the server holds tags for', () async {
      final server = _server()..turnOn();
      final phone = _Phone(
        server,
        KmClock(),
        lists: Lists(
          logins: [
            _login(_a),
            _login(_b),
            _login(_c, password: 'other'),
          ],
        ),
      );

      await phone.run();

      final seen = phone.hints.last;
      expect(seen.enabled, isTrue);
      expect(seen.tagVersion, 1);
      expect(seen.groups, [
        [_a, _b],
      ]);
      expect(seen.tagged, {_a, _b, _c});
      expect(seen.at, phone.clock.ms);
    });

    test('are not read with matching off at the server', () async {
      final server = _server();
      final phone = _Phone(server, KmClock(), lists: Lists(logins: [_login(_a), _login(_b)]));

      await phone.run();

      expect(phone.hints, isEmpty);
      expect(server.requests.where((request) => request.url.path == '/kem/v1/duplicates'), isEmpty);
    });
  });

  group('a key replacement moves the version (7.4)', () {
    test('every re-wrapped login gets tags of the new version, and none of the old one is sent again', () async {
      final server = _server()..turnOn();
      final phone = _Phone(
        server,
        KmClock(),
        lists: Lists(
          logins: [
            _login(_a),
            _login(_b, password: 'other'),
          ],
        ),
      );
      await phone.run();
      final before = Map.of(server.tags);
      expect(before.values.map((row) => row.version), [1, 1]);
      server.tagWrites.clear();

      // The server moves the version and deletes the tags; the re-wrapped items come back as new revisions, which another
      // device wrote and which carry none
      expect(server.rotate(), 2);
      final other = _untagged(phone);
      await other.run();
      other.lists = Lists(
        logins: [for (final login in other.lists.logins) login.copyWith(note: 're-wrapped', updatedAt: phone.clock.ms + 10)],
      );
      await other.run();
      expect(server.items.values.map((item) => item.revision), [2, 2]);
      expect(server.validTags, isEmpty);

      await phone.run();

      final after = server.validTags;
      expect(after.keys, unorderedEquals([_a, _b]));
      expect(after.values.map((row) => row.version), [2, 2]);
      expect(after[_a]!.tags, [_cred(phone.key(2), 'larkspur.example', 'sam', 'hunter2')]);
      expect(after[_b]!.tags, [_cred(phone.key(2), 'larkspur.example', 'sam', 'other')]);
      expect(after[_a]!.tags, isNot(before[_a]!.tags), reason: 'a tag of the old version matches nothing');
      expect(server.tagWrites.every((write) => write.version == 2), isTrue);
      expect(server.tagWrites.map((write) => write.item), unorderedEquals([_a, _b]));
    });

    test('a write made under the version the server has since moved on from is dropped, not stored, and tagged by the next run', () async {
      final server = _server()..turnOn();
      final phone = _Phone(server, KmClock(), lists: Lists(logins: [_login(_a)]));
      // The version moves between the run's read of the settings and its batch
      var moved = false;
      server.respond = (request) async {
        if (!moved && request.url.path.endsWith('/items:batch')) {
          moved = true;
          server.rotate();
        }
        return server.handle(request);
      };

      await phone.run();

      expect(server.items, contains(_a), reason: 'the item is written either way');
      expect(server.tagWrites.single.version, 1);
      expect(server.validTags, isEmpty);

      await phone.run();

      expect(server.validTags[_a]!.version, 2);
    });
  });
}
