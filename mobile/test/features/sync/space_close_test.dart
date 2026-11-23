// Closing the WebDAV copy of a moved space (docs/plans/add-server-spaces.md, design 7 and task 8.4), against the fake folder and
// the fake server with real keys: the Owner closes it, or it closes on its own after a removal, and from then on no moved phone
// reads or writes the file. The closed file stays in the folder unchanged, and what is left syncs through the server space.
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/spaces/space_bridge.dart';
import 'package:kemlock/features/spaces/space_move.dart' show SpaceMoveError, SpaceMoveProblem;
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_kinds.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';

import 'space_bridge_kit.dart';
import 'space_scheduler_kit.dart';

void main() {
  late KmAccount sam;

  setUpAll(() async => sam = await realAccount(1));

  const timeout = Timeout(Duration(minutes: 3));

  // The family moved. Sam's first phone bridges it; his second phone found the space by its id and joined it; an older phone
  // stays on the file. Every one of them has synced once.
  Future<({MovedFamily family, SchedulerRig mover, SchedulerRig joined, OlderPhone older})> moved() async {
    final family = await MovedFamily.make(sam);
    final entries = familyEntries();
    final lists = Lists(accounts: entries.accounts, logins: entries.logins);
    final bridged = familySpace(family.target.key).withOnServer(SpaceOnServer(state: SpaceCopy.bridged, uuid: familyUuid, at: 1));
    final mover = await openRig(
      settings: SyncSettings(kemlock: rigTarget, spaces: [bridged]),
      source: sourceOn(family.server, sam, comparedStore(family.server)),
      webDav: family.webDav,
      lists: lists,
      states: {
        familyId: ScopeState(known: [...family.mover.state.known], lastSyncAt: 1000),
      },
    );
    // The person of that phone had compared the space's fingerprint, and agreed to merge into it
    final joining = familySpace(family.target.key).withOnServer(SpaceOnServer(state: SpaceCopy.joining, uuid: familyUuid, at: 1));
    final joined = await openRig(
      settings: SyncSettings(kemlock: rigTarget, spaces: [joining]),
      source: await anchoredSourceOn(family.server, sam, <String, Object?>{}),
      webDav: family.webDav,
      lists: lists,
      states: {
        familyId: ScopeState(known: [...family.mover.state.known], lastSyncAt: 1000),
      },
    );
    expect(mover.space(familyId).onServer!.state, SpaceCopy.bridged);
    expect(joined.space(familyId).onServer!.state, SpaceCopy.joined);
    final older = family.olderPhone();
    await older.sync(now: 2000);
    return (family: family, mover: mover, joined: joined, older: older);
  }

  /// The requests the folder has seen so far.
  int touches(MovedFamily family) => family.dav.requests.length;

  group('the Owner closes the copy', () {
    test('no moved phone reads or writes the file afterwards, the file stays as it was, and the server space goes on', () async {
      final (:family, :mover, :joined, :older) = await moved();
      // Before it is closed, the bridge reads and writes the file: the older phone's edit goes through it
      older
        ..edit('acc-3', issuer: 'Edited on the older phone', at: 5000)
        ..add('acc-from-file', at: 5000);
      await older.sync(now: 5001);
      await mover.sync();
      expect(mover.account('acc-3').issuer, 'Edited on the older phone');
      final open = touches(family);
      expect(open, greaterThan(0));

      // The Owner closes it from the Spaces sheet: one marker item in the space, the chain untouched
      await sourceOn(family.server, sam, comparedStore(family.server)).closeCopy(familyId);
      final markers = [
        for (final item in family.server.items.values)
          if (item.kind == KmKind.bridgeClosed) item,
      ];
      expect(markers, hasLength(1));
      expect(family.server.chain.entries, hasLength(1), reason: 'no chain record, and no route that the server lacks');
      final filed = await family.filePlaintext();
      final requests = touches(family);

      // Each moved phone learns it at its next run, and does not touch the file in that run or in any after it
      await mover.sync();
      await joined.sync();
      expect(touches(family), requests, reason: 'neither moved phone sent a request to the folder');
      expect(mover.space(familyId).onServer!.state, SpaceCopy.closed);
      expect(mover.space(familyId).onServer!.reason, SpaceCopyClosed.owner);
      expect(joined.space(familyId).onServer!.state, SpaceCopy.closed);
      expect(joined.space(familyId).onServer!.reason, SpaceCopyClosed.owner);

      // The older phone goes on writing the file; nothing of it reaches the server space, and nothing of the server space
      // reaches it
      older
        ..edit('acc-4', issuer: 'Older, after the close', at: 8000)
        ..add('acc-after-close', at: 8000);
      await older.sync(now: 8001);
      final server = family.serverPhone();
      await server.run(now: 8100);
      server
        ..edit('acc-5', issuer: 'Server, after the close', at: 9000)
        ..add('acc-new-server', at: 9000);
      await server.run(now: 9001);
      final before = touches(family);
      await mover.sync();
      await joined.sync();
      await mover.sync();
      expect(touches(family), before, reason: 'no moved phone reads or writes the file afterwards');
      expect(mover.lists.accounts.map((account) => account.id), isNot(contains('acc-after-close')));
      expect(mover.account('acc-4').issuer, isNot('Older, after the close'));
      expect((await family.file()).accounts.map((account) => account.id), isNot(contains('acc-new-server')));
      expect((await family.file()).accounts.firstWhere((account) => account.id == 'acc-5').issuer, isNot('Server, after the close'));
      expect(await family.filePlaintext(), isNot(filed), reason: 'the older phone wrote it; the moved ones did not');

      // The server space is all that syncs: both moved phones have what was made there, and the phones agree
      expect(mover.account('acc-5').issuer, 'Server, after the close');
      expect(joined.account('acc-5').issuer, 'Server, after the close');
      expect(mover.account('acc-new-server').id, 'acc-new-server');
      expect(mover.space(familyId).onServer!.fileDeleted, isFalse, reason: 'deleting the file is an offer, never done by itself');
    }, timeout: timeout);

    test('an Owner who never compared the space’s fingerprint can’t close it, and opens no key and writes nothing', () async {
      final family = await MovedFamily.make(sam);
      final store = <String, Object?>{};
      final events = family.server.events.length;

      await expectLater(
        sourceOn(family.server, sam, store).closeCopy(familyId),
        throwsA(isA<SpaceMoveError>().having((e) => e.problem, 'problem', SpaceMoveProblem.exists)),
      );
      await expectLater(syncFor(family.server, sam, store).markBridge(closed: true, now: 30000), throwsA(isA<SpaceMoveError>()));
      expect(family.server.items.values.where((item) => item.kind == KmKind.bridgeClosed), isEmpty, reason: 'no closed marker went up');
      expect(family.server.events, hasLength(events), reason: 'the items of the space were not read');
      expect(store.keys.where((key) => key.startsWith('backmycodes_kemlock_space_')), isEmpty, reason: 'no key was opened, nothing kept');
    }, timeout: timeout);

    test('an account that is not in the space can’t close it, and writes nothing', () async {
      final family = await MovedFamily.make(sam);
      final stranger = await realAccount(2);

      await expectLater(sourceOn(family.server, stranger, <String, Object?>{}).closeCopy(familyId), throwsA(anything));
      expect(family.server.items.values.where((item) => item.kind == KmKind.bridgeClosed), isEmpty);
    }, timeout: timeout);
  });

  group('the copy closes on its own', () {
    test('after a removal: every moved phone derives it from the chain, and none touches the file again', () async {
      final (:family, :mover, :joined, older: _) = await moved();
      final bob = await realAccount(2);

      await removeMember(family.server, sam, bob);

      final filed = await family.filePlaintext();
      final requests = touches(family);
      await mover.sync();
      await joined.sync();

      expect(touches(family), requests, reason: 'the run that learns of the removal does not touch the file either');
      expect(mover.space(familyId).onServer!.state, SpaceCopy.closed);
      expect(mover.space(familyId).onServer!.reason, SpaceCopyClosed.removal);
      expect(joined.space(familyId).onServer!.state, SpaceCopy.closed);
      expect(joined.space(familyId).onServer!.reason, SpaceCopyClosed.removal);
      expect(family.server.items.values.where((item) => item.kind == KmKind.bridgeClosed), isEmpty, reason: 'the chain says it');
      expect(await family.filePlaintext(), filed, reason: 'the file stays in the folder unchanged');
      await mover.sync();
      expect(touches(family), requests);
    }, timeout: timeout);

    test('a failure of the server space after its chain showed the copy closed does not reopen it', () async {
      final (:family, :mover, joined: _, older: _) = await moved();
      final bob = await realAccount(2);
      await removeMember(family.server, sam, bob);
      family.server.syncStatus = 503;
      final filed = await family.filePlaintext();
      final requests = touches(family);

      await mover.sync();

      expect(mover.space(familyId).onServer!.state, SpaceCopy.closed, reason: 'the chain closed it, whatever failed after it');
      expect(mover.space(familyId).onServer!.reason, SpaceCopyClosed.removal);
      expect(mover.status[familyId]?.problem, SyncProblem.server, reason: 'the failure is still shown');
      expect(touches(family), requests, reason: 'the file was neither read nor written');
      expect(await family.filePlaintext(), filed);
    }, timeout: timeout);

    test('a bridged phone whose server space fails reads the file and does not write it', () async {
      final (:family, :mover, joined: _, :older) = await moved();
      older
        ..edit('acc-3', issuer: 'Edited on the older phone', at: 5000)
        ..add('acc-from-file', at: 5000);
      await older.sync(now: 5001);
      family.server.syncStatus = 503;
      final writes = family.fileWrites;

      await mover.sync();

      expect(family.fileWrites, writes, reason: 'its chain, which it could not read, may close the copy: nothing is written');
      expect(mover.account('acc-3').issuer, 'Edited on the older phone', reason: 'what others wrote still comes in');
      expect(mover.space(familyId).onServer!.state, SpaceCopy.bridged);
      expect(mover.status[familyId]?.problem, SyncProblem.server);
    }, timeout: timeout);

    test('a phone that finds its account is no longer a confirmed member closes its copy, and does not touch the file', () async {
      final family = await MovedFamily.make(sam);
      final stranger = await realAccount(2);
      final entries = familyEntries();
      final bridged = familySpace(family.target.key).withOnServer(SpaceOnServer(state: SpaceCopy.bridged, uuid: familyUuid, at: 1));
      final requests = touches(family);

      final phone = await openRig(
        settings: SyncSettings(kemlock: rigTarget, spaces: [bridged]),
        source: sourceOn(family.server, stranger, <String, Object?>{}),
        webDav: family.webDav,
        lists: Lists(accounts: entries.accounts, logins: entries.logins),
      );

      expect(phone.space(familyId).onServer!.state, SpaceCopy.closed);
      expect(phone.space(familyId).onServer!.reason, SpaceCopyClosed.left);
      expect(touches(family), requests);
      expect(phone.spaces.runs, isEmpty);
    }, timeout: timeout);
  });
}
