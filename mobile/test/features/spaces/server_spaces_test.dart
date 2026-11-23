import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/kem1.dart';
import 'package:kemlock/crypto/account/kx1.dart';
import 'package:kemlock/crypto/account/manifest.dart';
import 'package:kemlock/crypto/bytes.dart' show constantTimeEquals;
import 'package:kemlock/features/spaces/server_spaces.dart';
import 'package:kemlock/features/spaces/server_spaces_list.dart';
import 'package:kemlock/features/spaces/space_chain.dart';
import 'package:kemlock/features/spaces/space_invites.dart';
import 'package:kemlock/features/spaces/space_keys.dart';
import 'package:kemlock/features/spaces/space_listing.dart';
import 'package:kemlock/features/spaces/space_manifest.dart';
import 'package:kemlock/features/spaces/space_replace.dart';
import 'package:kemlock/features/spaces/space_scope.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/features/spaces/space_verify.dart';
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_cache.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/models/login.dart';

import 'chain_kit.dart';
import 'fake_space_server.dart';

Uint8List _seq(int n, int start) => Uint8List.fromList(List.generate(n, (i) => (start + i) & 0xff));

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

// The sync of a space on Kemlock Server against a fake server, between phones of different members: the chain,
// the sealed keys, the items under their collections, the manifest. The chain and the manifest of a space are
// behind "server: to confirm", so they come from the fake.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final finance = uuid(0xf1);
  final engineering = uuid(0xf2);

  late Person alice;
  late Person bob;
  late Person carol;
  late Person theo;
  final privateKeys = <String, Uint8List>{};

  Future<Person> person(int n) async {
    final priv = _seq(96, n * 13);
    final made = Person(n, kx1PublicKey: await Kx1.publicKeyOf(priv));
    privateKeys[made.id] = priv;
    return made;
  }

  setUpAll(() async {
    alice = await person(1);
    bob = await person(2);
    carol = await person(3);
    theo = await person(4);
  });

  Uint8List collectionKey(String collection, int version) => _seq(32, collection.codeUnitAt(collection.length - 1) * 3 + version);
  Uint8List keyBytes(KeyRef key, int version) => key.isSpace ? _seq(32, version) : collectionKey(key.collection!, version);
  const spaceRef = KeyRef.space();
  final everyoneRef = KeyRef.collection(everyone);
  final financeRef = KeyRef.collection(finance);
  final engineeringRef = KeyRef.collection(engineering);

  // The chains commit to the real boxes of these keys, prepared once for everyone and for the two versions the tests use
  final seals = SealRegistry(space, keyOf: keyBytes);
  setUpAll(() async {
    await seals.prepare(keys: [spaceRef, everyoneRef, financeRef, engineeringRef], versions: [1, 2], people: [alice, bob, carol, theo]);
  });

  FakeSpaceServer serverOf(ChainBuilder chain) => FakeSpaceServer(space, chain, seals: seals);

  /// Serves each member the boxes the chain committed to them, as the admin's app published them.
  Future<void> sealAll(FakeSpaceServer server) => server.sealAll();

  int clock = DateTime.utc(2026, 11, 22, 12).millisecondsSinceEpoch;
  int tick() => clock += 60000;

  /// One phone of one member of the space.
  KmSpacePhone phone(
    FakeSpaceServer server,
    Person who, {
    Map<String, ChainAnchor>? heads,
    Set<String>? compared,
    bool contact = true,
    Lists lists = const Lists(),
  }) => KmSpacePhone(
    server,
    who,
    privateKeys[who.id]!,
    heads: heads ?? {},
    compared: compared ?? {},
    lists: lists,
    tick: tick,
    contact: contact,
  );

  Login login(String id, {String name = 'Site', int at = 1, int updatedAt = 10}) =>
      Login(id: id, name: name, username: 'me', password: 'pw', addedAt: at, updatedAt: updatedAt, spaceId: space);

  // Alice makes the space, invites Bob with edit on "Everyone", confirms him and seals him the keys he awaits
  ChainBuilder twoMembers() => ChainBuilder(space, seals: seals)
    ..create(alice, collection: everyone)
    ..invite(alice, bob, grants: {everyone: CollectionPermission.edit})
    ..confirm(alice, bob)
    ..seal(alice, [spaceRef, everyoneRef]);

  group('a space as a scope', () {
    test('two members see each other’s edits, each item in its collection, with one manifest for a run that wrote', () async {
      final server = serverOf(twoMembers());
      await sealAll(server);
      final a = phone(server, alice, lists: Lists(logins: [login('l1')]));
      final b = phone(server, bob);

      await a.run();
      expect(server.items, hasLength(1));
      expect(server.items.values.single.collection, everyone);
      expect(server.items.values.single.keyVersion, 1);
      expect(server.events.where((e) => e == 'manifest'), hasLength(1), reason: 'a run that wrote sends one manifest');
      expect(server.manifest!.signer, alice.id);

      await b.run();
      expect(b.lists.logins.single.id, 'l1');
      expect(server.events.where((e) => e == 'manifest'), hasLength(1), reason: 'a run that only read signs nothing');

      b.lists = Lists(logins: [b.lists.logins.single.copyWith(name: 'Bob’s edit').stamped(clock + 1000)]);
      await b.run();
      expect(server.events.where((e) => e == 'manifest'), hasLength(2));
      await a.run();
      expect(a.lists.logins.single.name, 'Bob’s edit');
      expect(a.lists.logins.single.id, 'l1');

      // The ciphertext in the server is under the collection key, whoever wrote it, and bound to the space
      final item = server.items.values.single;
      expect(item.revision, 2);
      expect(item.keyVersion, 1);
    });

    test('keeps each entry’s collection in the scope state and never in the entry', () async {
      final chain = twoMembers()..collection(alice, finance, grants: {'user:${alice.id}': CollectionPermission.manage});
      final server = serverOf(chain);
      await sealAll(server);
      final a = phone(server, alice, lists: Lists(logins: [login('l1'), login('l2')]));
      a.state = ScopeState(known: const [], extra: withSpaceCollections({}, {'l2': finance}));

      await a.run();

      final byEntry = {for (final item in server.items.values) item.id: item.collection};
      expect(byEntry[serverItemUuid('l1', space)], everyone, reason: 'a new entry goes in the first collection');
      expect(byEntry[serverItemUuid('l2', space)], finance);
      expect(spaceCollectionsOf(a.state.extra), {'l1': everyone, 'l2': finance});
      for (final login in a.lists.logins) {
        expect(login.toJson().containsKey('collectionId'), isFalse);
      }
    });

    test('refuses an id that the vault’s own entries sync under, and one that is not a UUID', () {
      final server = serverOf(twoMembers());
      for (final id in ['personal', 'vaultwarden', 'fam-01']) {
        expect(() => phone(server, alice).scopeFor(id), throwsArgumentError, reason: id);
      }
    });

    test('a member who is only invited, and one who was removed, hold nothing of the space', () async {
      final chain = twoMembers()
        ..invite(alice, carol)
        ..remove(alice, bob, replace: [spaceRef, everyoneRef])
        ..keys(alice, [spaceRef, everyoneRef]);
      final server = serverOf(chain);
      await sealAll(server);
      await phone(server, alice, lists: Lists(logins: [login('l1')])).run();

      final invited = phone(server, carol, lists: Lists(logins: [login('mine')]));
      final result = await invited.run();
      expect(result.confirmed, isFalse);
      expect(invited.lists.logins, isEmpty, reason: 'the space’s entries leave a device that is not a confirmed member');

      final removed = phone(server, bob, lists: Lists(logins: [login('l1')]));
      await removed.run();
      expect(removed.lists.logins, isEmpty);
    });
  });

  group('the chain', () {
    test('a chain that can’t be checked stops the run and keeps what the phone had', () async {
      final chain = twoMembers();
      final server = serverOf(chain);
      await sealAll(server);
      final a = phone(server, alice, lists: Lists(logins: [login('l1')]));
      await a.run();
      final before = a.lists;

      // The server serves a chain in which a Member added someone
      chain.invite(bob, carol);
      await expectLater(
        a.run(),
        throwsA(
          isA<SpaceSyncError>()
              .having((e) => e.issue, 'issue', SpaceSyncIssue.cantBeChecked)
              .having((e) => e.chain, 'chain', ChainProblem.notAllowed),
        ),
      );
      expect(a.lists, before);
    });

    test('a shorter chain than the one a phone accepted is refused, and so is a different one', () async {
      final chain = twoMembers()..invite(alice, carol);
      final server = serverOf(chain);
      await sealAll(server);
      final heads = <String, ChainAnchor>{};
      final compared = <String>{};
      final a = phone(server, alice, heads: heads, compared: compared);
      await a.run();
      expect(heads[space]!.seq, 4);

      final shorter = twoMembers();
      final older = serverOf(shorter);
      await sealAll(older);
      await expectLater(
        phone(older, alice, heads: heads, compared: compared).run(),
        throwsA(isA<SpaceSyncError>().having((e) => e.chain, 'chain', ChainProblem.rolledBack)),
      );

      final other = twoMembers()..invite(alice, theo);
      await expectLater(
        phone(serverOf(other)..sealedSpaceKeys.addAll(server.sealedSpaceKeys), alice, heads: heads, compared: compared).run(),
        throwsA(isA<SpaceSyncError>().having((e) => e.chain, 'chain', ChainProblem.forked)),
      );
    });

    test('a space no fingerprint was compared for holds nothing: no anchor is made by reading it, no key opens, no item merges', () async {
      final chain = twoMembers();
      final server = serverOf(chain);
      await sealAll(server);
      await phone(server, alice, lists: Lists(logins: [login('l1')])).run();
      final heads = <String, ChainAnchor>{};
      final uncompared = phone(server, bob, heads: heads, contact: false);

      final result = await uncompared.run();

      expect(result.confirmed, isFalse, reason: 'the chain confirms Bob, but this phone never compared a fingerprint');
      expect(result.doc.logins, isEmpty, reason: 'the server’s items are not merged');
      expect(heads, isEmpty, reason: 'reading the chain stored no anchor');
      expect(uncompared.comparedSpaces, isEmpty);
      expect(uncompared.cache.items, isEmpty, reason: 'nothing was opened or cached');

      await uncompared.firstContact();
      expect(heads[space]!.seq, 3, reason: 'first contact anchors the chain it verified');
      expect(uncompared.comparedSpaces, {space});
      expect((await uncompared.run()).doc.logins.map((login) => login.id), ['l1']);
    });
  });

  group('the guard against a space item under the id of the vault’s own login', () {
    test('a changed space item under that id leaves the login in place, and is reported as held elsewhere', () async {
      final server = serverOf(twoMembers());
      await sealAll(server);
      // Alice writes a space item whose entry id is the id of a login Bob keeps in his own vault, with other contents
      await phone(
        server,
        alice,
        lists: Lists(
          logins: [login('mine', name: 'Planted').copyWith(password: 'planted').stamped(900000000000)],
        ),
      ).run();

      const own = Login(id: 'mine', name: 'Site', username: 'me', password: 'pw', addedAt: 1, updatedAt: 10);
      final all = const Lists(logins: [own]);
      final b = phone(server, bob);
      final result = await b.runScoped(all);

      expect(result.doc.logins.single.password, 'planted');
      expect(heldElsewhere(all, space, result.doc), {'mine'});
      final applied = applyScope(all, space, result.doc);
      expect(applied.logins.single.password, 'pw');
      expect(applied.logins.single.spaceId, isNull);
    });
  });

  group('the manifest', () {
    test('is refused when a member with a view-only grant signed it, and a view-only phone signs none', () async {
      final chain = twoMembers()
        ..invite(alice, carol, grants: {everyone: CollectionPermission.view})
        ..confirm(alice, carol)
        ..seal(alice, [spaceRef, everyoneRef]);
      final server = serverOf(chain);
      await sealAll(server);
      await phone(server, alice, lists: Lists(logins: [login('l1')])).run();
      expect(server.events.where((e) => e == 'manifest'), hasLength(1));

      // A view-only phone's edit is not written, and signs nothing
      final c = phone(server, carol);
      await c.run();
      c.lists = Lists(logins: [c.lists.logins.single.copyWith(name: 'Carol’s edit').stamped(clock + 5000)]);
      await c.run();
      expect(server.items.values.single.revision, 1);
      expect(server.events.where((e) => e == 'manifest'), hasLength(1));

      // A manifest signed by carol anyway is refused by everyone
      final forged = buildSpaceManifest(owner: Owner.space(space), counter: 9, items: const []);
      server.manifest = (
        manifest: forged.bytes,
        signature: fakeSignature(carol.bundle.sig1PublicKey, 'manifest', forged.bytes),
        signer: carol.id,
        counter: 9,
      );
      await expectLater(
        phone(server, bob).run(),
        throwsA(isA<SpaceSyncError>().having((e) => e.manifest, 'manifest', SpaceManifestProblem.signerNotAllowed)),
      );
    });

    group('checked as a member with part of the grants', () {
      late FakeSpaceServer server;
      late String financeItem;
      late String engineeringItem;

      setUp(() async {
        final chain = ChainBuilder(space, seals: seals)
          ..create(alice, collection: everyone)
          ..collection(alice, finance, grants: {'user:${alice.id}': CollectionPermission.manage})
          ..collection(alice, engineering, grants: {'user:${alice.id}': CollectionPermission.manage})
          ..invite(alice, theo, grants: {engineering: CollectionPermission.edit})
          ..confirm(alice, theo)
          ..seal(alice, [spaceRef, engineeringRef]);
        server = serverOf(chain);
        await sealAll(server);
        final a = phone(server, alice, lists: Lists(logins: [login('f1'), login('e1')]));
        a.state = ScopeState(known: const [], extra: withSpaceCollections({}, {'f1': finance, 'e1': engineering}));
        await a.run();
        financeItem = serverItemUuid('f1', space);
        engineeringItem = serverItemUuid('e1', space);
      });

      test('a full sync doesn’t stop on the envelopes it can’t open, and lists only what it can', () async {
        expect(server.items.keys, {financeItem, engineeringItem});
        expect(server.manifest!.counter, 1);
        final t = phone(server, theo);
        final result = await t.run();

        expect([for (final login in result.doc.logins) login.id], ['e1']);
        expect(result.skipped, 1, reason: 'Finance’s item is kept untouched, not read');
        // The cache holds both envelopes, so the manifest check covers Finance too
        final cache = t.cache;
        expect(cache.items.keys, {financeItem, engineeringItem});
        expect(cache.items[financeItem]!.opaque, isTrue);
        expect(cache.items[engineeringItem]!.applied, isTrue);
        expect(cache.items[financeItem]!.heldSince, isNull, reason: 'the manifest lists it');
      });

      test('an item the server withholds is reported missing, even in a collection the member can’t open', () async {
        server.withheld.add(financeItem);
        await expectLater(
          phone(server, theo).run(),
          throwsA(
            isA<SpaceSyncError>()
                .having((e) => e.issue, 'issue', SpaceSyncIssue.older)
                .having((e) => e.detail, 'detail', contains('missing')),
          ),
        );
      });

      test('an item rolled back in a collection the member can’t open is reported too', () async {
        final t = phone(server, theo);
        await t.run();
        // Finance's item is served at an older revision than the manifest lists
        server.items[financeItem]!
          ..revision = 0
          ..seq = 99;
        await expectLater(t.run(), throwsA(isA<SpaceSyncError>().having((e) => e.issue, 'issue', SpaceSyncIssue.older)));
      });
    });

    test('a removed member’s later write, under a key kept from before, is held and flagged, not applied', () async {
      final chain = twoMembers()
        ..invite(alice, carol, grants: {everyone: CollectionPermission.edit})
        ..confirm(alice, carol)
        ..seal(alice, [spaceRef, everyoneRef]);
      final server = serverOf(chain);
      await sealAll(server);
      // Carol keeps the keys she held before the replacement
      final carolKeyring = SpaceKeyring.fromKeys(
        space: space,
        member: carol.id,
        spaceKeyVersion: 1,
        spaceKey: keyBytes(spaceRef, 1),
        collectionKeys: {
          everyone: {1: keyBytes(everyoneRef, 1)},
        },
      );
      final a = phone(server, alice, lists: Lists(logins: [login('l1')]));
      await a.run();

      // Carol is removed and the keys are replaced; carol keeps the old keys and a server that lets her write
      chain
        ..remove(alice, carol, replace: [spaceRef, everyoneRef])
        ..keys(alice, [spaceRef, everyoneRef]);
      await sealAll(server);
      final planted = await SpaceItemCrypto(space: space, keyring: carolKeyring).sealItem(
        itemId: serverItemUuid('x1', space),
        revision: 1,
        kind: 'login',
        collection: everyone,
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(login('x1', name: 'Planted').toJson()))),
      );
      server.put(
        FakeSpaceItem(
          id: serverItemUuid('x1', space),
          kind: 'login',
          collection: everyone,
          revision: 1,
          keyVersion: planted.keyVersion,
          seq: 0,
          ciphertext: planted.ciphertext,
          itemKey: planted.itemKey,
        ),
      );

      final result = await a.run();

      expect([for (final login in result.doc.logins) login.id], ['l1'], reason: 'the planted entry is not applied');
      final cached = a.cache.items[serverItemUuid('x1', space)]!;
      expect(cached.heldSince, isNotNull, reason: 'no permitted signer lists it: held and flagged');
      expect(result.skipped, 1);
    });

    test('a manifest above one the phone verified is kept, and one below it is refused as older', () async {
      final server = serverOf(twoMembers());
      await sealAll(server);
      final a = phone(server, alice, lists: Lists(logins: [login('l1')]));
      await a.run();
      expect(a.cache.manifest, isNotNull);
      final held = server.manifest!;

      final lower = buildSpaceManifest(owner: Owner.space(space), counter: 0, items: const []);
      server.manifest = (
        manifest: lower.bytes,
        signature: fakeSignature(alice.bundle.sig1PublicKey, 'manifest', lower.bytes),
        signer: alice.id,
        counter: 0,
      );
      await expectLater(a.run(), throwsA(isA<SpaceSyncError>().having((e) => e.manifest, 'manifest', SpaceManifestProblem.rolledBack)));

      // The server no longer has it at all
      server.manifest = null;
      await expectLater(a.run(), throwsA(isA<SpaceSyncError>().having((e) => e.manifest, 'manifest', SpaceManifestProblem.vanished)));
      server.manifest = held;
      await a.run();
    });
  });

  group('replacing keys after a removal', () {
    late FakeSpaceServer server;
    late ChainBuilder chain;
    late KmSpacePhone a;

    final ids = ['l1', 'l2', 'l3', 'l4', 'l5'];

    /// Alice (an Owner) and Bob hold the space with Carol, who has edit on "Everyone"; Alice wrote five logins.
    Future<void> setUpSpace() async {
      chain = twoMembers()
        ..invite(alice, carol, grants: {everyone: CollectionPermission.edit})
        ..confirm(alice, carol)
        ..seal(alice, [spaceRef, everyoneRef]);
      server = serverOf(chain);
      await sealAll(server);
      a = phone(
        server,
        alice,
        lists: Lists(logins: [for (final id in ids) login(id, name: 'Site $id')]),
      );
      await a.run();
      expect(server.items.values.every((item) => item.keyVersion == 1), isTrue);
    }

    /// Carol is removed, which marks the space key and "Everyone".
    void removeCarol() => chain.remove(alice, carol, replace: [spaceRef, everyoneRef]);

    test('a concurrent edit ends merged under the new key, and the space ends read back and signed', () async {
      await setUpSpace();
      final b = phone(server, bob);
      await b.run();
      removeCarol();
      expect(server.state.keysNeedReplacing, isTrue);

      // While Alice's first batch is on its way, Bob's phone, which has the new key, edits l2
      final bobKeys = SpaceKeyring.fromKeys(
        space: space,
        member: bob.id,
        spaceKeyVersion: 2,
        spaceKey: keyBytes(spaceRef, 2),
        collectionKeys: {
          everyone: {2: keyBytes(everyoneRef, 2)},
        },
      );
      final l2 = serverItemUuid('l2', space);
      final edit = await SpaceItemCrypto(space: space, keyring: bobKeys).sealItem(
        itemId: l2,
        revision: server.items[l2]!.revision + 1,
        kind: 'login',
        collection: everyone,
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(login('l2', name: 'Bob’s edit', updatedAt: 99).toJson()))),
      );
      server.beforeBatch = () => server.put(
        FakeSpaceItem(
          id: l2,
          kind: 'login',
          collection: everyone,
          revision: server.items[l2]!.revision + 1,
          keyVersion: edit.keyVersion,
          seq: 0,
          ciphertext: edit.ciphertext,
          itemKey: edit.itemKey,
        ),
      );

      final result = await a.replace(makeKey: keyBytes);

      expect(result.rotated, {spaceRef, everyoneRef});
      expect(server.state.keysNeedReplacing, isFalse);
      expect(server.state.collections[everyone]!.keyVersion, 2);
      expect(server.state.spaceKeyVersion, 2);
      expect(server.items.values.map((item) => item.keyVersion).toSet(), {2}, reason: 'every item ends under the new key');
      expect(result.rewritten, 4, reason: 'l2 was already under the new key when Bob wrote it');
      expect(a.cache.items[l2]!.entry!['name'], 'Bob’s edit', reason: 'the concurrent edit is kept, not overwritten by the old copy');
      expect(server.manifest!.signer, alice.id, reason: 'the manifest is signed after the last batch');
      expect(server.events.where((e) => e == 'chain'), hasLength(1));

      // Bob's phone reads the space under the new keys: the edit and the rest
      await b.run();
      expect(
        {for (final login in b.lists.logins) login.id: login.name},
        {'l1': 'Site l1', 'l2': 'Bob’s edit', 'l3': 'Site l3', 'l4': 'Site l4', 'l5': 'Site l5'},
      );
    });

    test('a run stopped after two batches resumes from the first item not yet under the new key', () async {
      await setUpSpace();
      removeCarol();

      await expectLater(
        a.replace(
          makeKey: keyBytes,
          batchSize: 2,
          onBatch: (done, total) {
            if (done == 2) {
              throw StateError('the app was closed');
            }
          },
        ),
        throwsStateError,
      );
      final under = [for (final item in server.items.values) item.keyVersion];
      expect(under.where((version) => version == 2), hasLength(4), reason: 'two batches of two went up');
      expect(under.where((version) => version == 1), hasLength(1));
      expect(server.state.keysNeedReplacing, isFalse, reason: 'the keys record is in; what is left is the items');

      final result = await a.replace(makeKey: keyBytes, batchSize: 2);

      expect(result.rotated, isEmpty);
      expect(result.rewritten, 1);
      expect(result.batches, 1);
      expect(server.items.values.map((item) => item.keyVersion).toSet(), {2});
      expect(server.events.where((e) => e == 'chain'), hasLength(1), reason: 'the keys record isn’t sent twice');
    });

    test('a head that moved under the keys record is answered by reading the chain again and building it again', () async {
      await setUpSpace();
      removeCarol();
      // Another Owner's record lands between the phone's read of the chain and its append
      server.beforeAppend = () => chain.policies(alice, {'twoStep': true});

      final result = await a.replace(makeKey: keyBytes);

      expect(result.rotated, {spaceRef, everyoneRef});
      expect(server.state.keysNeedReplacing, isFalse);
      expect(server.state.policies['twoStep'], isTrue, reason: 'the record that took the place is part of the chain');
      expect(server.events.where((e) => e == 'chain'), hasLength(1), reason: 'the refused append took nothing');
      expect(server.items.values.map((item) => item.keyVersion).toSet(), {2});
    });

    test('the removed member’s key opens nothing written afterwards, and the new keys were sealed to nobody else', () async {
      await setUpSpace();
      final carolKeys = SpaceKeyring.fromKeys(
        space: space,
        member: carol.id,
        spaceKeyVersion: 1,
        spaceKey: keyBytes(spaceRef, 1),
        collectionKeys: {
          everyone: {1: keyBytes(everyoneRef, 1)},
        },
      );
      final before = server.items.values.first;
      final carolCrypto = SpaceItemCrypto(space: space, keyring: carolKeys);
      Kem1Item wire(FakeSpaceItem item) => Kem1Item(
        id: item.id,
        owner: Owner.space(space),
        kind: item.kind,
        revision: item.revision,
        keyVersion: item.keyVersion,
        ciphertext: item.ciphertext,
        itemKey: item.itemKey,
      );
      expect(await carolCrypto.openItem(wire(before), everyone), isNotEmpty, reason: 'her old key opens what was written before');

      removeCarol();
      await a.replace(makeKey: keyBytes);

      for (final item in server.items.values) {
        await expectLater(carolCrypto.openItem(wire(item), everyone), throwsA(isA<NoCollectionKey>()), reason: item.id);
      }
      final keysSeq = chain.entries.last.entry.seq;
      expect({for (final hash in chain.sealLog[keysSeq]!) hash.member}, {alice.id, bob.id});
      expect(server.state.sealOf(everyoneRef, carol.id), isNull);
    });

    test('a phone offline across a replacement reads the chain, opens the new keys, and writes only under them', () async {
      await setUpSpace();
      final b = phone(server, bob);
      await b.run();
      expect(b.lists.logins, hasLength(5));
      expect(server.items.values.map((item) => item.keyVersion).toSet(), {1});

      // Bob's phone goes offline, with the old keys' items in its cache. The keys are replaced meanwhile, and Bob edits l2
      removeCarol();
      await a.replace(makeKey: keyBytes);
      expect(server.items.values.map((item) => item.keyVersion).toSet(), {2});
      final l2 = serverItemUuid('l2', space);
      b.lists = Lists(
        logins: [
          for (final login in b.lists.logins)
            if (login.id == 'l2') login.copyWith(name: 'Bob offline').stamped(clock + 1000) else login,
        ],
      );

      // A write under the old version is refused by the server, whoever tries it
      final oldKeys = SpaceKeyring.fromKeys(
        space: space,
        member: bob.id,
        spaceKeyVersion: 1,
        spaceKey: keyBytes(spaceRef, 1),
        collectionKeys: {
          everyone: {1: keyBytes(everyoneRef, 1)},
        },
      );
      final revision = server.items[l2]!.revision;
      final old = await SpaceItemCrypto(space: space, keyring: oldKeys).sealItem(
        itemId: l2,
        revision: revision + 1,
        kind: 'login',
        collection: everyone,
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(login('l2', name: 'Under the old key', updatedAt: 99).toJson()))),
      );
      final refused = await server.client.post(
        Uri.parse('${FakeSpaceServer.url}/kem/v1/items:batch'),
        headers: {'Authorization': 'DPoP ${bob.id}', 'content-type': 'application/json'},
        body: jsonEncode({
          'writes': [
            {
              'expectedRevision': revision,
              'item': {
                ...Kem1Item(
                  id: l2,
                  owner: Owner.space(space),
                  kind: 'login',
                  revision: revision + 1,
                  keyVersion: old.keyVersion,
                  ciphertext: old.ciphertext,
                  itemKey: old.itemKey,
                ).toJson(),
                'collectionId': everyone,
              },
            },
          ],
        }),
      );
      expect(refused.statusCode, 409);
      expect(server.items[l2]!.keyVersion, 2, reason: 'nothing was stored under the old version');
      expect(server.items[l2]!.revision, revision);

      // It comes back: reads the chain, opens the new keys through it, merges and writes under the new version
      final result = await b.run();

      expect(result.confirmed, isTrue);
      expect(b.heads[space]!.seq, server.state.headSeq, reason: 'the chain was read to its head');
      expect(server.state.collections[everyone]!.keyVersion, 2);
      expect(server.items[l2]!.keyVersion, 2);
      expect(server.items[l2]!.revision, revision + 1, reason: 'one write, under the new key');
      expect(server.items.values.map((item) => item.keyVersion).toSet(), {2});
      expect(b.cache.items[l2]!.entry!['name'], 'Bob offline');
      expect({for (final login in b.lists.logins) login.id: login.name}.length, 5, reason: 'merged with the rest, nothing lost');

      await a.run();
      expect(a.lists.logins.firstWhere((login) => login.id == 'l2').name, 'Bob offline');
    });
  });

  group('leaving a space', () {
    test('the leaver’s devices drop the space’s entries, and the admins see that the keys need replacing', () async {
      final server = serverOf(twoMembers());
      await sealAll(server);
      await phone(server, alice, lists: Lists(logins: [login('l1'), login('l2')])).run();
      final first = phone(server, bob);
      final second = phone(server, bob);
      await first.run();
      await second.run();
      expect(first.lists.logins, hasLength(2));
      expect(second.lists.logins, hasLength(2));

      // Bob leaves from one phone: a `remove` of himself that names the keys he held
      final after = await first.scope.actions().leave();

      expect(after.member(bob.id)!.status, MemberStatus.removed);
      expect(server.state.keysNeedReplacing, isTrue);
      expect(serverSpaceStatus(server.state, alice.id), 'keysNeedReplacing', reason: 'the admins see "Keys need replacing"');
      expect(serverSpaceStatus(server.state, bob.id), 'removed');

      // At the next sync every device of his drops what it held of the space
      for (final device in [first, second]) {
        final result = await device.run();
        expect(result.confirmed, isFalse);
        expect(device.lists.logins, isEmpty);
      }

      // And the admin's phone replaces the keys the leaver held, which no remaining member loses
      final a = phone(server, alice);
      await a.replace(makeKey: keyBytes);
      expect(server.state.keysNeedReplacing, isFalse);
      expect(server.state.sealOf(everyoneRef, bob.id), isNull);
    });
  });

  group('inviting by email', () {
    late FakeSpaceServer server;
    late ChainBuilder chain;

    SpaceInviteClient invitesOf(KmSpacePhone who) =>
        SpaceInviteClient(connection: who.scope.connection, server: FakeSpaceServer.url, space: space, crypto: const FakeChainCrypto());

    setUp(() async {
      chain = twoMembers();
      server = serverOf(chain);
      await sealAll(server);
      server.directory['carol@example.com'] = (account: carol.id, bundle: carol.bundle.bytes, bundleSignature: carol.bundleSignature);
    });

    test('looks the account up, invites it, and seals nothing until it is confirmed', () async {
      final a = phone(server, alice);
      final sealsBefore = chain.sealLog.length;

      final found = await invitesOf(a).lookup('carol@example.com');
      expect(found!.account, carol.id);
      expect(server.events, contains('lookup'));

      final after = await a.scope.actions().invite(found.account, SpaceRole.member, grants: {everyone: CollectionPermission.edit});

      expect(after.member(carol.id)!.status, MemberStatus.invited);
      expect(chain.sealLog.length, sealsBefore, reason: 'the invite record committed no seal');
      expect(server.sealedSpaceKeys.containsKey(carol.id), isFalse);
      expect(server.collectionKeys[carol.id] ?? const [], isEmpty);
      expect(after.entitled(spaceRef), isNot(contains(carol.id)));
      expect(after.awaiting(spaceRef), isNot(contains(carol.id)));
      expect(after.awaiting(everyoneRef), isNot(contains(carol.id)));

      // Her own phone holds nothing of the space
      final c = phone(server, carol);
      final result = await c.run();
      expect(result.confirmed, isFalse);
      expect(c.lists.logins, isEmpty);
    });

    test('is limited to the space’s Owners, Admins and manage-users members, and an unknown email is no account', () async {
      await expectLater(
        invitesOf(phone(server, bob)).lookup('carol@example.com'),
        throwsA(isA<InviteLookupError>().having((e) => e.problem, 'problem', InviteLookupProblem.notAllowed)),
      );
      expect(server.events, isNot(contains('lookup')));
      expect(await invitesOf(phone(server, alice)).lookup('nobody@example.com'), isNull);
    });

    test('is rate-limited', () async {
      server.lookupsLeft = 1;
      final invites = invitesOf(phone(server, alice));

      expect(await invites.lookup('carol@example.com'), isNotNull);
      await expectLater(
        invites.lookup('carol@example.com'),
        throwsA(isA<InviteLookupError>().having((e) => e.problem, 'problem', InviteLookupProblem.rateLimited)),
      );
    });

    test('an invitation can be sent again once per 10 minutes, and only while it is an invitation', () async {
      chain.invite(alice, carol, grants: {everyone: CollectionPermission.edit});
      final invites = invitesOf(phone(server, alice));

      await invites.resend(carol.id);
      expect(server.resends, [carol.id]);
      await expectLater(invites.resend(carol.id), throwsA(isA<ResendError>().having((e) => e.problem, 'problem', ResendProblem.tooSoon)));
      await expectLater(
        invites.resend(bob.id),
        throwsA(isA<ResendError>().having((e) => e.problem, 'problem', ResendProblem.notAllowed)),
        reason: 'Bob is confirmed',
      );
    });

    test('the invitee accepts, which the list shows and the chain doesn’t, and still holds no key', () async {
      chain.invite(alice, carol, grants: {everyone: CollectionPermission.edit});
      final c = phone(server, carol);

      await invitesOf(c).answer(accept: true);

      final raw = await c.scope.connection.call(
        (token) => c.scope.connection.api.callValue('GET', FakeSpaceServer.url, '/spaces', token: token),
      );
      final listed = parseSpaceList(raw).single;
      expect(listed.id, space);
      expect(listed.accepted, isTrue);
      expect(server.state.member(carol.id)!.status, MemberStatus.invited, reason: 'only an admin’s confirmation changes the chain');
      expect(server.sealedSpaceKeys.containsKey(carol.id), isFalse);
      expect(server.events, contains('accepted'));
    });
  });

  group('who a key is sealed to', () {
    test('only the members the chain confirms and grants it, not an extra key the server lists', () async {
      final chain = twoMembers()
        ..invite(alice, carol, grants: {everyone: CollectionPermission.view})
        ..invite(alice, theo);
      final server = serverOf(chain);
      final eve = Person(9, kx1PublicKey: await Kx1.publicKeyOf(_seq(96, 5)));
      final state = server.state;

      final plan = planSeals(
        state: state,
        collection: everyone,
        serverMembers: [
          (id: alice.id, bundle: alice.bundle.bytes),
          (id: bob.id, bundle: bob.bundle.bytes),
          // Invited, not confirmed
          (id: carol.id, bundle: carol.bundle.bytes),
          (id: theo.id, bundle: theo.bundle.bytes),
          // Nobody the chain knows
          (id: eve.id, bundle: eve.bundle.bytes),
        ],
      );

      expect(plan.recipients.keys.toSet(), {alice.id, bob.id});
      expect({for (final ignored in plan.ignored) ignored.id}, {carol.id, theo.id, eve.id});
      expect(plan.ignored.every((ignored) => ignored.reason.contains('chain')), isTrue);

      final boxes = await sealCollectionKeyFor(
        plan: plan,
        key: collectionKey(everyone, 1),
        space: space,
        collection: everyone,
        keyVersion: 1,
      );
      expect(boxes.keys.toSet(), {alice.id, bob.id}, reason: 'no seal goes to anyone else');
      expect(
        await openCollectionKey(
          box: boxes[bob.id]!,
          kx1PrivateKey: privateKeys[bob.id]!,
          space: space,
          collection: everyone,
          keyVersion: 1,
          member: bob.id,
        ),
        collectionKey(everyone, 1),
      );
    });

    test(
      'a confirmed member whose server key is not the one the chain recorded gets the chain’s key, and the difference is logged',
      () async {
        final server = serverOf(twoMembers());
        final swapped = Person(2, keyVersion: 1, kx1PublicKey: await Kx1.publicKeyOf(_seq(96, 200)));
        final plan = planSeals(state: server.state, collection: everyone, serverMembers: [(id: bob.id, bundle: swapped.bundle.bytes)]);

        expect(plan.recipients[bob.id]!.kx1PublicKey, bob.bundle.kx1PublicKey, reason: 'the chain’s key, never the server’s');
        expect([for (final ignored in plan.ignored) ignored.id], [bob.id]);
        expect(plan.ignored.single.reason, contains('other than the one the chain recorded'));
      },
    );

    test('a member the chain removed is not a recipient, and a collection nobody is granted has none', () async {
      final chain = twoMembers()..remove(alice, bob, replace: [spaceRef, everyoneRef]);
      final state = serverOf(chain).state;
      expect(planSeals(state: state, collection: everyone).recipients.keys, [alice.id]);
    });
  });

  group('held items', () {
    late ChainBuilder chain;
    late FakeSpaceServer server;
    late KmSpacePhone a;
    late Uint8List carolOldKey;

    /// Carol is removed after writing with the keys she kept: she edits l1 (which Alice had accepted) and plants x1, both
    /// under key version 1. Alice's app then replaces the keys and names what it didn't accept held.
    Future<void> setUpHeld() async {
      chain = twoMembers()
        ..invite(alice, carol, grants: {everyone: CollectionPermission.edit})
        ..confirm(alice, carol)
        ..seal(alice, [spaceRef, everyoneRef]);
      server = serverOf(chain);
      await sealAll(server);
      a = phone(
        server,
        alice,
        lists: Lists(logins: [login('l1', name: 'Site l1')]),
      );
      await a.run();
      carolOldKey = keyBytes(everyoneRef, 1);
      chain.remove(alice, carol, replace: [spaceRef, everyoneRef]);

      final carolKeys = SpaceKeyring.fromKeys(
        space: space,
        member: carol.id,
        spaceKeyVersion: 1,
        spaceKey: keyBytes(spaceRef, 1),
        collectionKeys: {
          everyone: {1: carolOldKey},
        },
      );
      Future<void> write(String id, String name, int revision) async {
        final sealed = await SpaceItemCrypto(space: space, keyring: carolKeys).sealItem(
          itemId: serverItemUuid(id, space),
          revision: revision,
          kind: 'login',
          collection: everyone,
          plaintext: Uint8List.fromList(utf8.encode(jsonEncode(login(id, name: name, updatedAt: 99).toJson()))),
        );
        server.put(
          FakeSpaceItem(
            id: serverItemUuid(id, space),
            kind: 'login',
            collection: everyone,
            revision: revision,
            keyVersion: sealed.keyVersion,
            seq: 0,
            ciphertext: sealed.ciphertext,
            itemKey: sealed.itemKey,
          ),
        );
      }

      await write('l1', 'Carol’s edit', server.items[serverItemUuid('l1', space)]!.revision + 1);
      await write('x1', 'Planted', 1);
      await a.replace(makeKey: keyBytes);
    }

    test('the list holds what the server named held, and a keep needs a copy this phone accepted', () async {
      await setUpHeld();
      final l1 = serverItemUuid('l1', space);
      final x1 = serverItemUuid('x1', space);
      expect(server.heldItems, {l1, x1}, reason: 'the replacer named the revisions it did not accept');

      final held = await a.scope.heldItems(now: tick());

      expect([for (final item in held) item.id], [l1, x1]..sort());
      final byId = {for (final item in held) item.id: item};
      expect(byId[l1]!.canKeep, isTrue, reason: 'Alice accepted a copy of l1 before');
      expect(byId[l1]!.name, 'Site l1');
      expect(byId[l1]!.keyVersion, 1, reason: 'the held revision is under the old key');
      expect(byId[x1]!.canKeep, isFalse, reason: 'nothing of x1 was ever accepted');
      expect(byId[x1]!.name, isNull);
    });

    test('keeping writes the accepted copy under the new key, which releases it, and nobody gets Carol’s edit', () async {
      await setUpHeld();
      final l1 = serverItemUuid('l1', space);
      final before = server.items[l1]!;

      await a.scope.keepHeld(l1, now: tick());

      final after = server.items[l1]!;
      expect(after.revision, before.revision + 1);
      expect(after.keyVersion, 2, reason: 'under the collection’s current key version');
      expect(server.heldItems, isNot(contains(l1)));
      expect(await a.scope.heldItems(now: tick()), hasLength(1), reason: 'only x1 is left');
      expect(server.manifest!.signer, alice.id, reason: 'the write is listed by a manifest');

      final b = phone(server, bob);
      await b.run();
      expect({for (final login in b.lists.logins) login.id: login.name}, {'l1': 'Site l1'});
    });

    test('keeping an item with no accepted copy is refused, and deleting it releases it', () async {
      await setUpHeld();
      final x1 = serverItemUuid('x1', space);

      await expectLater(
        a.scope.keepHeld(x1, now: tick()),
        throwsA(isA<HeldItemError>().having((e) => e.problem, 'problem', HeldItemProblem.cantKeep)),
      );
      expect(server.heldItems, contains(x1), reason: 'nothing was written');

      await a.scope.deleteHeld(x1, now: tick());

      expect(server.items[x1]!.ciphertext, isNull, reason: 'a tombstone');
      expect(server.heldItems, isNot(contains(x1)));
    });

    test('an item the server doesn’t hold, and one held for a member without edit, are refused', () async {
      await setUpHeld();
      await expectLater(
        a.scope.keepHeld(serverItemUuid('nope', space), now: tick()),
        throwsA(isA<HeldItemError>().having((e) => e.problem, 'problem', HeldItemProblem.notHeld)),
      );
      // Theo can only view: the server serves him the held item, but only a member with edit may release it
      chain
        ..invite(alice, theo, grants: {everyone: CollectionPermission.view})
        ..confirm(alice, theo);
      final viewOnly = phone(server, theo);
      await expectLater(
        viewOnly.scope.deleteHeld(serverItemUuid('x1', space), now: tick()),
        throwsA(isA<HeldItemError>().having((e) => e.problem, 'problem', HeldItemProblem.notAllowed)),
      );
    });
  });
}

/// One phone of one member: its entries, what its last run kept, its sealed cache, the heads it accepted and the spaces
/// whose fingerprint it compared. A phone does first contact before its first run unless [contact] is false (a run of a
/// space nobody compared holds nothing).
class KmSpacePhone {
  KmSpacePhone(
    this.server,
    this.who,
    this.kx1Private, {
    required this.heads,
    required this.lists,
    required this.tick,
    Set<String>? compared,
    this.contact = true,
  }) : comparedSpaces = compared ?? {} {
    scope = scopeFor(server.space);
  }

  final FakeSpaceServer server;
  final Person who;
  final Uint8List kx1Private;
  final Map<String, ChainAnchor> heads;
  final Set<String> comparedSpaces;
  final bool contact;
  final int Function() tick;
  late KmSpaceSync scope;
  Lists lists;
  ScopeState state = const ScopeState(known: []);
  Object? stored;

  /// An engine for the space [id] of this phone, to show what it refuses.
  KmSpaceSync scopeFor(String id) {
    final session = KmSession(
      userId: who.id,
      deviceId: '00000000-0000-4000-8000-0000000000d1',
      tokens: KmTokens(access: who.id, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
    );
    final connection = KmConnection(api: KmApi(server.client), server: FakeSpaceServer.url, session: session, save: (_) async {});
    return KmSpaceSync(
      connection: connection,
      server: FakeSpaceServer.url,
      account: KmAccount(
        accountId: who.id,
        keyVersion: who.keyVersion,
        rootKey: Uint8List(64),
        kx1PrivateKey: kx1Private,
        sig1PrivateKey: Uint8List(64),
        kx1PublicKey: who.bundle.kx1PublicKey,
        sig1PublicKey: who.bundle.sig1PublicKey,
      ),
      space: id,
      loadCache: () async => KmCache.fromJson(stored == null ? null : jsonDecode(jsonEncode(stored))),
      saveCache: (cache) async => stored = jsonDecode(jsonEncode(cache.toJson())),
      loadAnchor: (space) async => heads[space],
      loadCompared: (space) async => comparedSpaces.contains(space),
      saveAnchor: (space, anchor, {afterFence = false, compared = false}) async {
        heads[space] = anchor;
        if (compared) {
          comparedSpaces.add(space);
        }
      },
      chainCrypto: const FakeChainCrypto(),
      manifestCrypto: _FakeManifestCrypto(who.bundle.sig1PublicKey),
      signRecord: (entry, _) async => SignedChainEntry(entry, fakeSignature(who.bundle.sig1PublicKey, 'space-chain', entry.bytes)),
    );
  }

  /// Replaces the keys the chain marks, as this member's app does after a removal. The names are the same text every time.
  Future<({Set<KeyRef> rotated, int rewritten, int held, int batches})> replace({
    required KeyMaker makeKey,
    int batchSize = 500,
    void Function(int done, int total)? onBatch,
  }) => scope.replaceKeys(
    now: tick(),
    readNames: (state, keyring) async => {
      const NameTarget.space(): 'Example Co',
      for (final id in state.collections.keys) NameTarget.collection(id): 'Collection $id',
      for (final id in state.groups.keys) NameTarget.group(id): 'Group $id',
    },
    makeKey: makeKey,
    batchSize: batchSize,
    onBatch: onBatch,
  );

  KmCache get cache => KmCache.fromJson(stored);

  /// First contact with the space, as the first-contact screen does once the digits matched: the chain as verified is
  /// anchored, and recorded as compared.
  Future<void> firstContact() async {
    if (comparedSpaces.contains(server.space)) {
      return;
    }
    await scope.rememberAnchor((await scope.chainForContact()).anchor!);
  }

  /// Runs once and takes the merged document, as the scheduler does.
  Future<SpaceSyncResult> run() async {
    if (contact) {
      await firstContact();
    }
    final now = tick();
    final result = await scope.sync(lists, state, now: now);
    lists = result.doc;
    state = ScopeState(known: result.known, lastSyncAt: now, extra: result.state);
    return result;
  }

  /// Runs once for a phone whose vault holds [all], of which the space's scope is empty.
  Future<SpaceSyncResult> runScoped(Lists all) async {
    if (contact) {
      await firstContact();
    }
    final now = tick();
    return scope.sync(scopeLists(all, server.space), state, now: now);
  }
}
