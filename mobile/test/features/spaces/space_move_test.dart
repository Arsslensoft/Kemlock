// Moving a WebDAV space to Kemlock Server (docs/plans/add-server-spaces.md, design 7 and task 8.1), against the fake server
// with the account's real keys: the space is made under the legacy-id UUID of its WebDAV id, every entry goes to "Everyone"
// under its own id or its legacy-id UUID and keeps its own id inside, the manifest is signed, and the space is read back and
// compared before it counts as moved. A difference keeps the space on WebDAV.
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/spaces/space_bridge.dart';
import 'package:kemlock/features/spaces/space_chain.dart';
import 'package:kemlock/features/spaces/space_move.dart';
import 'package:kemlock/features/spaces/space_scope.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_kinds.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';

import 'chain_kit.dart';
import 'fake_space_server.dart';
import 'space_move_kit.dart';

void main() {
  late KmAccount sam;

  setUpAll(() async => sam = await realAccount(1));

  // The server holds no space yet; the move makes it under the UUID every member computes from the WebDAV id
  FakeSpaceServer newServer() => FakeSpaceServer(familyUuid, ChainBuilder(familyUuid));

  Lists familyLists() {
    final family = familyEntries();
    return Lists(accounts: family.accounts, logins: family.logins);
  }

  List<FakeSpaceItem> entryItems(FakeSpaceServer server) => [
    for (final item in server.items.values)
      if (item.kind != KmKind.bridgeOpen && item.kind != KmKind.bridgeClosed) item,
  ];

  const timeout = Timeout(Duration(minutes: 3));

  group('moving a WebDAV space', () {
    test('40 entries arrive in "Everyone", each under its own or its legacy-id UUID, with its own id inside', () async {
      final server = newServer();
      final local = familyLists();
      expect(local.ids, hasLength(40));
      final steps = <SpaceMoveStep>[];

      final result = await sourceOn(server, sam, {}).moveSpace(
        appSpaceId: familyId,
        name: 'Family',
        local: local,
        onProgress: (step, done, total) {
          if (!steps.contains(step)) {
            steps.add(step);
          }
        },
      );

      expect(result.uuid, familyUuid);
      expect(result.moved, 40);
      expect(steps, SpaceMoveStep.values);
      expect(familyUuid, isNot(familyId), reason: 'the WebDAV id is no UUID, so the server knows the space by its legacy-id UUID');
      // The space was made as the chain's `create`, under that UUID, by the mover, who is its Owner, with one collection
      expect(server.chain.entries.single.entry.kind, ChainKind.create);
      expect(server.chain.entries.single.entry.space, familyUuid);
      expect(server.state.member(sam.accountId)!.role, SpaceRole.owner);
      expect(server.state.collections, hasLength(1), reason: '"Everyone"');
      expect(server.events.where((e) => e == 'created'), hasLength(1));

      final items = entryItems(server);
      expect(items, hasLength(40));
      expect({for (final item in items) item.collection}, {server.state.collections.keys.single});
      expect({for (final item in items) item.id}, {for (final id in local.ids) serverItemUuid(id, familyUuid)});
      expect(serverItemUuid('acc-1', familyUuid), isNot('acc-1'), reason: 'an older id takes its legacy-id UUID under the space');
      expect(serverItemUuid(uuid(0x1001), familyUuid), uuid(0x1001), reason: 'a UUID id is its own');
      expect(items.every((item) => item.revision == 1 && item.ciphertext != null), isTrue);

      // The manifest of the space was signed by the mover, and the marker that the move is whole was written once
      expect(server.manifest!.signer, sam.accountId);
      expect(server.items.values.where((item) => item.kind == KmKind.bridgeOpen), hasLength(1));

      // Another phone of the account reads the space from nothing: every entry has the id it had on WebDAV inside
      final reader = await anchoredSourceOn(server, sam, {});
      final read = await reader.syncSpace(familyUuid, const Lists(), const ScopeState(known: []), now: 5000);
      expect(idsOf(read.doc), idsOf(local));
      expect(read.doc.accounts.map((account) => account.id), containsAll(['acc-1', 'acc-20']));
      expect(read.doc.logins.map((login) => login.id), containsAll([uuid(0x1001), '3f2c9a71e4b0d80b']));
      // The server's copy of an entry names the space the server knows
      expect(read.doc.logins.every((login) => login.spaceId == familyUuid), isTrue);
    }, timeout: timeout);

    test('every entry keeps its own id: an id that is a UUID is never mapped, and none is lost or doubled', () async {
      final server = newServer();
      final local = familyLists();

      await sourceOn(server, sam, {}).moveSpace(appSpaceId: familyId, name: 'Family', local: local);

      final ids = {for (final item in entryItems(server)) item.id};
      expect(ids, hasLength(40));
      for (final login in local.logins.where((login) => login.id.length == 36)) {
        expect(ids, contains(login.id));
      }
    }, timeout: timeout);

    test('a read-back that differs stops the move, writes no marker and keeps the space on WebDAV', () async {
      final server = newServer();
      final local = familyLists();
      // The server holds one entry back, as one that lost it would
      server.withheld.add(serverItemUuid('acc-7', familyUuid));
      final saved = <Space>[];

      await expectLater(
        moveWebDavSpace(
          space: familySpace(newFileKey()),
          mover: sourceOn(server, sam, {}),
          lists: local,
          save: (space) async => saved.add(space),
          now: () => 5000,
        ),
        throwsA(isA<SpaceMoveError>().having((e) => e.problem, 'problem', SpaceMoveProblem.mismatch)),
      );

      // Marked moving before anything went up, and never bridged: the space is a WebDAV space that syncs the file alone
      expect([for (final space in saved) space.onServer!.state], [SpaceCopy.moving]);
      expect(saved.single.movedToServer, isFalse);
      expect(plainWebDavSpaceIds(saved), {familyId});
      expect(server.items.values.where((item) => item.kind == KmKind.bridgeOpen), isEmpty, reason: 'the move is not complete');
    }, timeout: timeout);

    test('a move that stopped is run again: the space is not made twice, nothing is rewritten, and it ends bridged', () async {
      final server = newServer();
      final local = familyLists();
      final source = sourceOn(server, sam, {});
      final saved = <Space>[];
      final space = familySpace(newFileKey());
      server.withheld.add(serverItemUuid('acc-7', familyUuid));
      await expectLater(
        moveWebDavSpace(space: space, mover: source, lists: local, save: (next) async => saved.add(next), now: () => 5000),
        throwsA(isA<SpaceMoveError>()),
      );

      server.withheld.clear();
      final moved = await moveWebDavSpace(
        space: space,
        mover: source,
        lists: local,
        save: (next) async => saved.add(next),
        now: () => 6000,
      );

      expect(moved.onServer!.state, SpaceCopy.bridged);
      expect(moved.onServer!.uuid, familyUuid);
      expect(moved.movedToServer, isTrue);
      expect([for (final space in saved) space.onServer!.state], [SpaceCopy.moving, SpaceCopy.moving, SpaceCopy.bridged]);
      expect(server.events.where((e) => e == 'created'), hasLength(1), reason: 'the space was made once');
      expect(entryItems(server), hasLength(40));
      expect(entryItems(server).every((item) => item.revision == 1), isTrue, reason: 'an entry that went up is not written again');
      expect(server.items.values.where((item) => item.kind == KmKind.bridgeOpen), hasLength(1));
    }, timeout: timeout);

    test('a move run again after the space changed compares what the run merged, and the phone takes it', () async {
      final server = newServer();
      final local = familyLists();
      await sourceOn(server, sam, {}).moveSpace(appSpaceId: familyId, name: 'Family', local: local);
      // Another phone of the account edits an entry on the server, later than the file's copy of it
      final onServer = rescopedTo(local, familyUuid);
      final edited = Lists(
        accounts: [
          for (final a in onServer.accounts)
            if (a.id == 'acc-3') a.copyWith(issuer: 'Edited on the server', updatedAt: 9000) else a,
        ],
        logins: onServer.logins,
      );
      await (await anchoredSourceOn(server, sam, {})).syncSpace(familyUuid, edited, ScopeState(known: [...local.ids]), now: 9001);

      // The move runs again with the file's older copy. What the server holds is the merge, which the read-back must find
      Lists? taken;
      final moved = await moveWebDavSpace(
        space: familySpace(newFileKey()),
        mover: await anchoredSourceOn(server, sam, {}),
        lists: local,
        save: (space) async {},
        now: () => 10000,
        applyMerged: (doc) async => taken = doc,
      );

      expect(moved.onServer!.state, SpaceCopy.bridged, reason: 'the read-back compared the merged copy, not the entries that went in');
      expect(taken!.accounts.firstWhere((a) => a.id == 'acc-3').issuer, 'Edited on the server', reason: 'the phone takes the merge');
      expect(idsOf(taken!), idsOf(local));
    }, timeout: timeout);

    test('a space whose server copy is someone else’s is not filled by a move', () async {
      final server = newServer();
      final other = await realAccount(2);
      // Another account made the space under this id and invited Sam, who has not been confirmed
      final made = await sourceOn(server, other, {}).moveSpace(appSpaceId: familyId, name: 'Family', local: familyLists());
      expect(made.uuid, familyUuid);
      server.chain.invite(Person(2), Person(1), grants: {server.state.collections.keys.single: CollectionPermission.edit});

      await expectLater(
        sourceOn(server, sam, {}).moveSpace(appSpaceId: familyId, name: 'Family', local: familyLists()),
        throwsA(isA<SpaceMoveError>().having((e) => e.problem, 'problem', SpaceMoveProblem.exists)),
      );
      expect(entryItems(server), hasLength(40), reason: 'nothing was written by the account that is not in the space');
    }, timeout: timeout);
  });

  group('the note of a moved space', () {
    test('lives in the settings entry, keeps what it doesn’t know, and never enters the space’s file or its invite', () {
      final space = familySpace(newFileKey());
      final note = SpaceOnServer(state: SpaceCopy.bridged, uuid: familyUuid, at: 9);
      final stored = space.withOnServer(note);

      expect(Space.fromJson(stored.toJson()).onServer, note);
      expect(stored.toJson()['server'], {'state': 'bridged', 'uuid': familyUuid, 'at': 9});
      // The target, which is what the invite and the file are made from, is untouched
      expect(stored.target, space.target);
      expect(stored.withOnServer(null).toJson(), space.toJson());
      // A later build's state, and a key it added, are kept as they were
      final later = Space.fromJson({
        ...space.toJson(),
        'server': {'state': 'unheardOf', 'uuid': familyUuid, 'at': 1},
      });
      expect(later.onServer, isNull, reason: 'a state this version doesn’t know reads as a WebDAV space');
      expect(later.toJson()['server'], {'state': 'unheardOf', 'uuid': familyUuid, 'at': 1});
    });

    test('only a space that moved or agreed to join is a server space’s; one that is moving or offered is still a WebDAV space', () {
      final base = familySpace(newFileKey());
      for (final entry in {
        SpaceCopy.moving: false,
        SpaceCopy.offered: false,
        SpaceCopy.bridged: true,
        SpaceCopy.joining: true,
        SpaceCopy.joined: true,
        SpaceCopy.closed: true,
      }.entries) {
        final space = base.withOnServer(SpaceOnServer(state: entry.key, uuid: familyUuid, at: 1));
        expect(space.movedToServer, entry.value, reason: entry.key.name);
        expect(plainWebDavSpaceIds([space]), entry.value ? isEmpty : {familyId}, reason: entry.key.name);
      }
      expect(plainWebDavSpaceIds([base]), {familyId});
    });
  });
}
