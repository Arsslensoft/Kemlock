// The WebDAV space file and the `bmc-space:` invite stay what the app has always written, with spaces on Kemlock Server and the
// bridge in place (docs/plans/add-server-spaces.md, design 7 and task 8.5). They are released formats that older phones read:
//
// - every case of `test/fixtures/sync/sync.json`, which the TypeScript app wrote, still opens to what it records, and is written
//   again byte for byte;
// - a file written by a bridged sync, with the entries of a space that has one collection, is the file today's sync writes for the
//   same entries: the same plaintext bytes and the same envelope, and no `collection` anywhere in it. A second collection closes the
//   bridge instead, so the file never holds what a collection restricts.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/encoding.dart' show CorruptedException;
import 'package:kemlock/crypto/account/kx1.dart';
import 'package:kemlock/crypto/account/legacy_ids.dart';
import 'package:kemlock/crypto/account/manifest.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/spaces/server_spaces.dart';
import 'package:kemlock/features/spaces/space_bridge.dart';
import 'package:kemlock/features/spaces/space_chain.dart';
import 'package:kemlock/features/spaces/space_manifest.dart';
import 'package:kemlock/features/spaces/space_scope.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/features/spaces/space_verify.dart' show ChainAnchor;
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_backend.dart' show KmSyncResult;
import 'package:kemlock/features/sync/kemlock/km_cache.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/features/sync/space_bridge_run.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../spaces/chain_kit.dart';
import '../spaces/fake_space_server.dart';
import 'fake_webdav.dart';

typedef _Json = Map<String, Object?>;

/// A fake server with one space, the engine of its one member and how a bridged phone runs it.
typedef _ServerSpace = ({
  FakeSpaceServer server,
  KmSpaceSync Function(Map<String, Object?> store) engine,
  Future<KmSyncResult> Function(KmSpaceSync scope, Lists entries, ScopeState kept, int now) run,
});

final _fixtures = jsonDecode(File('test/fixtures/sync/sync.json').readAsStringSync()) as _Json;

List<_Json> _list(Object? list) => [for (final item in list! as List<Object?>) item! as _Json];

Uint8List _hex(String text) =>
    Uint8List.fromList([for (var i = 0; i < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16)]);

/// Hands out, in order, the bytes the TypeScript drew from `crypto.getRandomValues`.
class _Replay {
  _Replay(String hex) : _bytes = _hex(hex);

  final Uint8List _bytes;
  var _next = 0;

  bool get done => _next == _bytes.length;

  Uint8List call(int length) {
    if (_next + length > _bytes.length) {
      throw StateError('Drew more bytes than the TypeScript did');
    }
    return Uint8List.fromList(_bytes.sublist(_next, _next += length));
  }
}

// scrypt at the real parameters, once for each password and salt.
final _derived = <String, Future<Uint8List>>{};
Future<Uint8List> _derive(String password, Uint8List salt) =>
    _derived.putIfAbsent('$password ${b64(salt)}', () => deriveVaultKey(password, salt));

Future<String> _verdict(Future<Object?> Function() run) async {
  try {
    await run();
    return 'ok';
  } on SyncFileError catch (e) {
    return e.problem.name;
  } on InviteError catch (e) {
    return e.problem.name;
  } catch (e) {
    return 'error: ${e.runtimeType}';
  }
}

/// A manifest signature of the tests: a MAC under the signer's public key, in place of `sig1`'s.
class _FakeManifestCrypto implements SpaceManifestCrypto {
  const _FakeManifestCrypto(this.publicKey);

  final Uint8List publicKey;

  @override
  Future<Uint8List> sign(Manifest manifest, Uint8List sig1PrivateKey) async => fakeSignature(publicKey, 'manifest', manifest.bytes);

  @override
  Future<Manifest> verify(Uint8List bytes, Uint8List signature, Uint8List signerPublicKey) async {
    final manifest = Manifest.parse(bytes);
    if (!constantTimeEquals(signature, fakeSignature(signerPublicKey, 'manifest', bytes))) {
      throw const CorruptedException('the manifest signature does not verify');
    }
    return manifest;
  }
}

/// The plaintext a sync file seals, exactly as its writer made it.
Future<String> _plaintext(String text, String key) async {
  final envelope = jsonDecode(text) as _Json;
  return utf8.decode(await aesGcmDecrypt(unb64(key), unb64(envelope['nonce']! as String), unb64(envelope['ct']! as String)));
}

void main() {
  group('the released files and invites', () {
    final files = {for (final file in _list(_fixtures['files'])) file['name']! as String: file};

    test('every case of the fixture opens to what it records and is written again byte for byte', () async {
      expect(files, isNotEmpty);
      for (final MapEntry(key: name, value: file) in files.entries) {
        final text = file['text']! as String;
        final key = unb64(file['key']! as String);
        final doc = await decryptSyncFile(text, key);
        expect(doc.toJson(), file['decrypted'], reason: name);
        // The partial file holds a list that is no list ("backupServices":"no"), which every version reads as empty and writes as a list:
        // it opens to what it records, and no write of that document is that file (sync_fixtures_test.dart reads it alone)
        if (name != 'partial' && file['random'] != null) {
          final random = _Replay(file['random']! as String);
          expect(
            await encryptSyncFile(doc, key, kdf: readKdf(text), random: random.call),
            text,
            reason: name,
          );
          expect(random.done, isTrue, reason: name);
        }
      }
    });

    test('every broken file and every other kind of file reads as the TypeScript read it', () async {
      final key = unb64(files['space']!['key']! as String);
      for (final verdict in _list(_fixtures['fileVerdicts'])) {
        final text = verdict['text']! as String;
        expect(await _verdict(() => decryptSyncFile(text, key)), verdict['decrypt'], reason: text);
      }
    });

    test('the invite opens with its code and is sealed again byte for byte, and every typed code and verdict reads as before', () async {
      final fixture = _fixtures['invite']! as _Json;
      final text = fixture['text']! as String;
      final code = fixture['code']! as String;
      final json = fixture['invite']! as _Json;
      final invite = SpaceInvite(
        id: json['id']! as String,
        name: json['name']! as String,
        file: json['file']! as String,
        key: unb64(json['key']! as String),
      );

      expect(await openInvite(text, code, derive: _derive), invite);
      final random = _Replay(fixture['sealRandom']! as String);
      expect(await sealInvite(invite, code, derive: _derive, random: random.call), text);
      expect(random.done, isTrue);
      for (final typed in _list(fixture['typed'])) {
        final typedCode = typed['code']! as String;
        expect(await _verdict(() => openInvite(text, typedCode, derive: _derive)), typed['open'], reason: typedCode);
      }
      for (final verdict in _list(fixture['verdicts'])) {
        final input = verdict['text']! as String;
        expect(isInvite(input), verdict['isInvite'], reason: input);
        expect(await _verdict(() => openInvite(input, code, derive: _derive)), verdict['open'], reason: input);
      }
    });

    test('a moved space’s note changes neither the invite nor the file its settings entry names', () async {
      final fixture = _fixtures['invite']! as _Json;
      final json = fixture['invite']! as _Json;
      final space = Space(
        id: json['id']! as String,
        name: json['name']! as String,
        target: SyncTarget(
          dav: const DavAccount(url: 'https://dav.example.com/', username: 'me', password: 'pw'),
          file: json['file']! as String,
          key: json['key']! as String,
        ),
        joinedAt: 1,
      );
      final moved = Space.fromJson({
        ...space.toJson(),
        'server': {'state': 'bridged', 'uuid': spaceUuid(space.id), 'at': 5},
      });

      // What an invite and the file are made from is the id, the name, the file name and the key, which the note leaves alone
      SpaceInvite inviteOf(Space of) => SpaceInvite(id: of.id, name: of.name, file: of.target.file, key: unb64(of.target.key));
      expect(inviteOf(moved), inviteOf(space));
      expect(moved.target.toJson(), space.target.toJson());
      final random = _Replay(fixture['sealRandom']! as String);
      expect(await sealInvite(inviteOf(moved), fixture['code']! as String, derive: _derive, random: random.call), fixture['text']);
    });
  });

  group('a bridged sync writes the file that today’s sync writes', () {
    final space = uuid(0x5a);
    final everyone = uuid(0xe0);
    final finance = uuid(0xf1);
    const webDavId = 'fam-01';

    Uint8List seq(int n, int start) => Uint8List.fromList(List.generate(n, (i) => (start + i) & 0xff));
    Uint8List keyBytes(KeyRef key, int version) {
      if (key.isSpace) {
        return seq(32, version);
      }
      return seq(32, key.collection!.codeUnitAt(key.collection!.length - 1) * 3 + version);
    }

    OtpAccount account(String id, {int at = 100, String? issuer}) => OtpAccount(
      id: id,
      issuer: issuer ?? 'Issuer $id',
      label: 'me',
      secret: 'JBSWY3DPEHPK3PXP',
      spaceId: webDavId,
      addedAt: at,
      updatedAt: at,
    );

    Login login(String id, {int at = 100, String? name}) =>
        Login(id: id, name: name ?? 'Site $id', username: 'me', password: 'pw-$id', spaceId: webDavId, addedAt: at, updatedAt: at);

    // One member, one phone, a server space with "Everyone", and "Finance" too when [second] is set
    Future<_ServerSpace> serverSpace({required bool second}) async {
      final priv = seq(Kx1.privateKeyLength, 13);
      final alice = Person(1, kx1PublicKey: await Kx1.publicKeyOf(priv));
      const spaceRef = KeyRef.space();
      final everyoneRef = KeyRef.collection(everyone);
      final financeRef = KeyRef.collection(finance);
      final seals = SealRegistry(space, keyOf: keyBytes);
      await seals.prepare(keys: [spaceRef, everyoneRef, if (second) financeRef], versions: [1], people: [alice]);
      final chain = ChainBuilder(space, seals: seals)..create(alice, collection: everyone);
      if (second) {
        chain.collection(alice, finance, grants: {'user:${alice.id}': CollectionPermission.manage});
      }
      final server = FakeSpaceServer(space, chain, seals: seals);
      await server.sealAll();
      // The member compared the space's fingerprint before: its anchor is stored with the record of the comparison
      final anchor = ChainAnchor.of(chain.state, chain.entries)!;

      KmSpaceSync engine(Map<String, Object?> store) => KmSpaceSync(
        connection: KmConnection(
          api: KmApi(server.client),
          server: FakeSpaceServer.url,
          session: KmSession(
            userId: alice.id,
            deviceId: '00000000-0000-4000-8000-0000000000d1',
            tokens: KmTokens(access: alice.id, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
          ),
          save: (_) async {},
        ),
        server: FakeSpaceServer.url,
        account: KmAccount(
          accountId: alice.id,
          keyVersion: alice.keyVersion,
          rootKey: Uint8List(64),
          kx1PrivateKey: priv,
          sig1PrivateKey: Uint8List(64),
          kx1PublicKey: alice.bundle.kx1PublicKey,
          sig1PublicKey: alice.bundle.sig1PublicKey,
        ),
        space: space,
        loadCache: () async => KmCache.fromJson(store['cache'] == null ? null : jsonDecode(jsonEncode(store['cache']))),
        saveCache: (cache) async => store['cache'] = jsonDecode(jsonEncode(cache.toJson())),
        loadAnchor: (id) async => anchor,
        loadCompared: (id) async => true,
        saveAnchor: (id, moved, {afterFence = false, compared = false}) async {},
        chainCrypto: const FakeChainCrypto(),
        manifestCrypto: _FakeManifestCrypto(alice.bundle.sig1PublicKey),
        signRecord: (entry, _) async => SignedChainEntry(entry, fakeSignature(alice.bundle.sig1PublicKey, 'space-chain', entry.bytes)),
      );

      Future<KmSyncResult> serverRun(KmSpaceSync scope, Lists entries, ScopeState kept, int now) async {
        final result = await scope.sync(rescopedTo(entries, space), kept, now: now);
        return (doc: result.doc, known: result.known, state: result.state, skipped: result.skipped);
      }

      return (server: server, engine: engine, run: serverRun);
    }

    const dav = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');

    test('with entries in the space’s one collection it is the same bytes, and the collection is nowhere in it', () async {
      final (:server, :engine, run: serverRun) = await serverSpace(second: false);

      // The family's entries: codes and logins, all in "Everyone"
      var lists = Lists(accounts: [account('a1'), account('a2')], logins: [login('l1'), login('l2'), login('l3')]);
      var state = const ScopeState(known: []);

      final bridgedFolder = FakeWebDav();
      final plainFolder = FakeWebDav();
      final target = SyncTarget(dav: dav, file: spaceFile(webDavId), key: b64(seq(32, 77)));
      final path = '/files/me/Kemlock/${target.file}';
      final scope = engine({});

      // First run: the bridge uploads to the server space and writes the file
      final first = await runBridged(
        webDav: WebDav(bridgedFolder.client),
        target: target,
        scope: webDavId,
        local: scopeLists(lists, webDavId),
        state: state,
        now: 1000,
        server: (entries, kept) => serverRun(scope, entries, kept, 1000),
      );
      lists = applyScope(lists, webDavId, first.doc);
      state = ScopeState(known: first.known, lastSyncAt: 1000, extra: first.state);

      expect(first.failure, isNull);
      expect(first.signal, isNot(BridgeSignal.closed), reason: 'one collection and no hidden password: the copy stays open');
      final collections = {for (final item in server.items.values) item.collection};
      expect(collections, {everyone}, reason: 'the entries went into the one collection of the server space');

      // Today's sync, on its own folder, with the same entries
      final plain = await syncScope(WebDav(plainFolder.client), target, scopeLists(lists, webDavId), const [], now: 1000);
      final bridgedBytes = await _plaintext(bridgedFolder.files[path]!.text, target.key);
      expect(bridgedBytes, await _plaintext(plainFolder.files[path]!.text, target.key), reason: 'the plaintext is the same, byte for byte');
      final bridgedEnvelope = jsonDecode(bridgedFolder.files[path]!.text) as _Json;
      final plainEnvelope = jsonDecode(plainFolder.files[path]!.text) as _Json;
      expect(bridgedEnvelope.keys.toList(), plainEnvelope.keys.toList(), reason: 'the envelope has the members it always had');
      for (final member in ['app', 'kind', 'version']) {
        expect(bridgedEnvelope[member], plainEnvelope[member], reason: member);
      }
      expect(bridgedBytes.contains('collection'), isFalse, reason: 'a collection is the server’s metadata and never enters an entry');
      expect(RegExp('"spaceId":"$webDavId"').allMatches(bridgedBytes), hasLength(5), reason: 'the entries name the WebDAV id');

      // Another member edits an entry on the server; the bridge carries it into the file
      final other = <String, Object?>{};
      final otherScope = engine(other);
      var otherLists = Lists(accounts: [...lists.accounts], logins: [...lists.logins]);
      otherLists = rescopedTo(otherLists, space);
      otherLists = Lists(
        accounts: [
          for (final a in otherLists.accounts)
            if (a.id == 'a2') a.copyWith(issuer: 'Edited in Everyone', updatedAt: 3000) else a,
        ],
        logins: [
          for (final l in otherLists.logins)
            if (l.id == 'l2') l.copyWith(name: 'Edited too', updatedAt: 3000) else l,
        ],
      );
      await otherScope.sync(otherLists, ScopeState(known: state.known, extra: state.extra), now: 3001);

      final second = await runBridged(
        webDav: WebDav(bridgedFolder.client),
        target: target,
        scope: webDavId,
        local: scopeLists(lists, webDavId),
        state: state,
        now: 4000,
        server: (entries, kept) => serverRun(scope, entries, kept, 4000),
      );
      lists = applyScope(lists, webDavId, second.doc);
      state = ScopeState(known: second.known, lastSyncAt: 4000, extra: second.state);
      expect(second.failure, isNull);
      expect(lists.accounts.firstWhere((a) => a.id == 'a2').issuer, 'Edited in Everyone');
      expect(lists.logins.firstWhere((l) => l.id == 'l2').name, 'Edited too');

      await syncScope(WebDav(plainFolder.client), target, scopeLists(lists, webDavId), plain.known, now: 4000, seen: plain.seq);
      final bridgedAgain = await _plaintext(bridgedFolder.files[path]!.text, target.key);
      expect(bridgedAgain, await _plaintext(plainFolder.files[path]!.text, target.key), reason: 'still the same bytes after the edits');
      expect(bridgedAgain, contains('Edited too'));
      expect(bridgedAgain.contains('collection'), isFalse);
    });

    test('with a second collection the bridge closes instead: the file holds none of what a collection restricts', () async {
      final (server: _, :engine, run: serverRun) = await serverSpace(second: true);
      final lists = Lists(accounts: [account('a1'), account('a2')], logins: [login('l1'), login('l2'), login('l3')]);
      final folder = FakeWebDav();
      final target = SyncTarget(dav: dav, file: spaceFile(webDavId), key: b64(seq(32, 77)));

      final run = await runBridged(
        webDav: WebDav(folder.client),
        target: target,
        scope: webDavId,
        local: scopeLists(lists, webDavId),
        state: const ScopeState(known: []),
        now: 1000,
        server: (entries, kept) => serverRun(engine({}), entries, kept, 1000),
      );

      expect(run.signal, BridgeSignal.closed);
      expect(run.reason, SpaceCopyClosed.restricted);
      expect(run.failure, isNull);
      expect(folder.requests, isEmpty, reason: 'a closed copy is neither read nor written, so nothing of "Finance" can reach the file');
    });
  });
}
