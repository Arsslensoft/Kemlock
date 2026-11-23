// A member who holds the WebDAV space finds the server space by its id (docs/plans/add-server-spaces.md, design 7 and task 8.3),
// against the fake folder and the fake server: the phone computes the same UUID from the WebDAV id and finds the space among the
// ones it is confirmed in. That UUID is computable by anyone who can list the folder, so nothing joins on the server's word
// alone: the account must already have compared a fingerprint for the space (an anchor is stored with the record of that
// comparison, and none is made here), and the person is asked first, naming the Owner. Once they agree, the phone merges its copy
// of the file into the space once and writes the file no more. The phone that moved the space goes on bridging it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/features/spaces/hidden_passwords.dart';
import 'package:kemlock/features/spaces/space_bridge.dart';
import 'package:kemlock/features/spaces/space_head_store.dart' show SpaceAnchors;
import 'package:kemlock/features/spaces/space_scope.dart' show serverItemUuid;
import 'package:kemlock/features/spaces/space_types.dart' show SpaceRole;
import 'package:kemlock/features/spaces/space_verify.dart' show ChainAnchor;
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/models/otp_account.dart';

import 'space_bridge_kit.dart';
import 'space_scheduler_kit.dart';

void main() {
  late KmAccount sam;

  setUpAll(() async => sam = await realAccount(1));

  const timeout = Timeout(Duration(minutes: 3));

  // Sam's other phone: it holds the WebDAV space `fam-01` as it last synced it, and an entry it made since. By default the account
  // compared the space's fingerprint before (its anchor is stored) and the person agreed to merge into it ([state] joining)
  Future<({MovedFamily family, SchedulerRig phone, int writesBefore, Map<String, Object?> store})> joiningPhone(
    KmAccount account, {
    void Function(RigSpaces spaces)? configure,
    bool breakFile = false,
    bool anchored = true,
    bool compared = true,
    SpaceCopy? state = SpaceCopy.joining,
    MovedFamily? family,
  }) async {
    family ??= await MovedFamily.make(sam);
    final entries = familyEntries();
    final mine = OtpAccount(
      id: 'acc-joiner',
      issuer: 'Made here',
      label: 'me',
      secret: 'JBSWY3DPEHPK3PXP',
      spaceId: familyId,
      addedAt: 900,
    );
    final lists = Lists(accounts: [...entries.accounts, mine], logins: entries.logins);
    final writesBefore = family.fileWrites;
    if (breakFile) {
      family.dav.respond = (request) async => http.Response('', 500);
    }
    final store = <String, Object?>{};
    // An anchor without the record of a comparison is what a chain read once leaves: the phone never compared anyone's digits
    if (anchored && !compared) {
      final seen = ChainAnchor.of(family.server.state, family.server.chain.entries)!;
      store['anchors'] = jsonDecode(jsonEncode(SpaceAnchors({familyUuid: seen}).toJson()));
    }
    final source = anchored && compared ? await anchoredSourceOn(family.server, account, store) : sourceOn(family.server, account, store);
    final plain = familySpace(family.target.key);
    final phone = await openRig(
      settings: SyncSettings(
        kemlock: rigTarget,
        spaces: [if (state == null) plain else plain.withOnServer(SpaceOnServer(state: state, uuid: familyUuid, at: 1))],
      ),
      source: source,
      webDav: family.webDav,
      lists: lists,
      states: {
        // What its last sync of the file kept: every entry but the one made since
        familyId: ScopeState(known: [...entries.accounts.map((a) => a.id), ...entries.logins.map((l) => l.id)], lastSyncAt: 1000),
      },
      configure: configure,
    );
    return (family: family, phone: phone, writesBefore: writesBefore, store: store);
  }

  group('a member that holds the WebDAV space', () {
    test('finds the server space by the WebDAV id, merges its copy once, and writes the file no more', () async {
      final (:family, :phone, :writesBefore, store: _) = await joiningPhone(sam);
      final fileWrites = family.fileWrites;

      // Found by the id it holds: the phone ran the server space, under the UUID the WebDAV id gives, and no other
      expect(phone.spaces.runs.toSet(), {familyUuid});
      final note = phone.space(familyId).onServer!;
      expect(note.state, SpaceCopy.joined);
      expect(note.uuid, familyUuid);
      expect(phone.settings.spaces, hasLength(1), reason: 'the space is listed once');
      expect(fileWrites, writesBefore, reason: 'merging the copy in wrote nothing to the file');

      // Its copy was merged into the server space by id: the entry it made went up, and the rest was not doubled
      final reader = family.serverPhone();
      await reader.run(now: 20000);
      expect(reader.lists.accounts, hasLength(21));
      expect(reader.account('acc-joiner').issuer, 'Made here');
      expect(reader.lists.logins, hasLength(20));
      // Its own entries kept the WebDAV id
      expect(phone.lists.accounts.every((account) => account.spaceId == familyId), isTrue);
      expect(phone.lists.accounts, hasLength(21));

      // It reads and writes the file no more: an older phone's edit and its own edit go through the server space
      final older = family.olderPhone();
      await older.sync(now: 21000);
      older
        ..edit('acc-3', issuer: 'Edited on the older phone', at: 22000)
        ..add('acc-from-file', at: 22000);
      await older.sync(now: 22001);
      final requests = family.dav.requests.length;
      phone.lists = Lists(
        accounts: [
          for (final account in phone.lists.accounts)
            if (account.id == 'acc-4') account.copyWith(issuer: 'Edited on the joined phone', updatedAt: 23000) else account,
        ],
        logins: phone.lists.logins,
      );
      await phone.sync();
      expect(family.dav.requests.length, requests, reason: 'no request of the joined phone went to the folder');
      expect(phone.space(familyId).onServer!.state, SpaceCopy.joined);
      expect(phone.lists.accounts.map((account) => account.id), isNot(contains('acc-from-file')), reason: 'the file is not read again');

      // The phone that moved the space carries the file to the server space and the server space to the file
      await family.mover.run(now: 24000);
      await phone.sync();
      expect(phone.account('acc-3').issuer, 'Edited on the older phone');
      expect(phone.account('acc-from-file').id, 'acc-from-file');
      expect((await family.file()).accounts.firstWhere((account) => account.id == 'acc-4').issuer, 'Edited on the joined phone');
    }, timeout: timeout);

    test('does not join a space it is not confirmed in: the file is synced as any WebDAV space’s', () async {
      final stranger = await realAccount(2);
      // A stranger reads nothing of the space (the server answers 404 to its chain), so it has compared no fingerprint of it
      final (:family, :phone, writesBefore: _, store: _) = await joiningPhone(stranger, anchored: false, state: null);

      expect(phone.spaces.runs, isEmpty, reason: 'the server lists no space this account is confirmed in');
      expect(phone.space(familyId).onServer, isNull);
      expect(phone.status[familyId]?.problem, isNull);
      final file = await family.file();
      expect(file.accounts.map((account) => account.id), contains('acc-joiner'), reason: 'the file is written, as always');
    }, timeout: timeout);

    test('does not join a space on first sight: no anchor is stored, so nothing is opened, made, offered or uploaded', () async {
      final made = await MovedFamily.make(sam);
      final itemsBefore = made.server.items.length;
      final revisions = {for (final item in made.server.items.values) item.id: item.revision};

      // The phone has never compared a fingerprint for this space: the server lists it, under the UUID anyone can compute
      final (:family, :phone, writesBefore: _, :store) = await joiningPhone(sam, anchored: false, state: null, family: made);

      expect(phone.spaces.offers, [familyUuid], reason: 'the offer was looked for');
      expect(phone.spaces.runs, isEmpty, reason: 'the space was not synced');
      expect(phone.space(familyId).onServer, isNull, reason: 'neither joined nor offered');
      expect(store['anchors'], isNull, reason: 'no anchor was made from what the server said');
      expect(family.server.items.length, itemsBefore);
      expect({for (final item in family.server.items.values) item.id: item.revision}, revisions, reason: 'nothing was uploaded');
      expect(phone.lists.accounts, hasLength(21), reason: 'nothing of the server space reached the phone');
      expect((await family.file()).accounts.map((account) => account.id), contains('acc-joiner'), reason: 'the file syncs as always');
    }, timeout: timeout);

    test('does not offer a space whose anchor was stored with no record that a fingerprint was compared', () async {
      final made = await MovedFamily.make(sam);
      final itemsBefore = made.server.items.length;

      final (:family, :phone, writesBefore: _, :store) = await joiningPhone(sam, compared: false, state: null, family: made);

      expect(phone.spaces.offers, [familyUuid], reason: 'the offer was looked for');
      expect(phone.spaces.runs, isEmpty, reason: 'the space was not synced');
      expect(phone.space(familyId).onServer, isNull, reason: 'neither joined nor offered');
      expect(family.server.items.length, itemsBefore);
      expect(SpaceAnchors.fromJson(store['anchors']).compared, isEmpty, reason: 'a stored anchor is no comparison');
    }, timeout: timeout);

    test('a phone that agreed but whose anchor holds no comparison merges nothing and makes none', () async {
      final made = await MovedFamily.make(sam);
      final revisions = {for (final item in made.server.items.values) item.id: item.revision};

      final (:family, :phone, writesBefore: _, :store) = await joiningPhone(sam, compared: false, family: made);

      expect(phone.space(familyId).onServer!.state, SpaceCopy.joining, reason: 'it is not joined');
      expect(phone.status[familyId]?.problem, SyncProblem.spaceCantBeChecked);
      expect(SpaceAnchors.fromJson(store['anchors']).compared, isEmpty);
      expect({for (final item in family.server.items.values) item.id: item.revision}, revisions, reason: 'nothing was uploaded');
      final kept = store.keys.where((key) => key.startsWith('backmycodes_kemlock_space_'));
      expect(kept, isEmpty, reason: 'no key was opened and nothing of the space kept');
    }, timeout: timeout);

    test('offers the merge, naming the Owner, once an anchor is stored, and merges nothing until the person agrees', () async {
      final made = await MovedFamily.make(sam);
      made.server.memberFacts[sam.accountId] = {'name': 'Sam'};
      final revisions = {for (final item in made.server.items.values) item.id: item.revision};

      final (:family, :phone, writesBefore: _, store: _) = await joiningPhone(sam, state: null, family: made);

      final note = phone.space(familyId).onServer!;
      expect(note.state, SpaceCopy.offered);
      expect(note.owner, 'Sam');
      expect(note.uuid, familyUuid);
      expect(phone.space(familyId).movedToServer, isFalse, reason: 'still a WebDAV space until the person agrees');
      expect(phone.spaces.runs, isEmpty, reason: 'the space was not synced');
      expect({for (final item in family.server.items.values) item.id: item.revision}, revisions, reason: 'nothing was uploaded');
      expect((await family.file()).accounts.map((account) => account.id), contains('acc-joiner'), reason: 'the file syncs as always');

      // Another run does not join either: only the person's word does
      await phone.sync();
      expect(phone.space(familyId).onServer!.state, SpaceCopy.offered);
      expect(phone.spaces.runs, isEmpty);
    }, timeout: timeout);

    test('waits for the move to be whole: without its marker nothing is offered, merged or uploaded', () async {
      final made = await MovedFamily.make(sam, markerWritten: false);
      final revisions = {for (final item in made.server.items.values) item.id: item.revision};

      // Nothing is offered for a space whose marker isn't there
      final (family: _, phone: unoffered, writesBefore: _, store: _) = await joiningPhone(sam, state: null, family: made);
      expect(unoffered.spaces.offers, [familyUuid]);
      expect(unoffered.space(familyId).onServer, isNull);

      // A phone that agreed anyway merges nothing and is not marked joined
      final (:family, :phone, writesBefore: _, store: _) = await joiningPhone(sam, family: made);
      expect(phone.space(familyId).onServer!.state, SpaceCopy.joining, reason: 'the move is not whole, so it is not joined');
      expect(phone.status[familyId]?.problem, isNull, reason: 'waiting is no failure');
      expect({for (final item in family.server.items.values) item.id: item.revision}, revisions, reason: 'nothing was uploaded');
      expect(family.server.items.containsKey(serverItemUuid('acc-joiner', familyUuid)), isFalse, reason: 'its own entry did not go up');

      // The Owner's move finishes: the next run joins
      await syncFor(family.server, sam, <String, Object?>{}, compared: true).markBridge(closed: false, now: 30000);
      await phone.sync();
      expect(phone.space(familyId).onServer!.state, SpaceCopy.joined);
      expect(family.server.items.containsKey(serverItemUuid('acc-joiner', familyUuid)), isTrue, reason: 'its entry was merged in');
    }, timeout: timeout);

    test('never writes over a note that changed while its run went', () async {
      final (:family, :phone, writesBefore: _, store: _) = await joiningPhone(sam, breakFile: true);
      expect(phone.space(familyId).onServer!.state, SpaceCopy.joining);

      // The run that would join the space is going when the note changes: the Owner's close reaches this phone
      family.dav.respond = null;
      phone.spaces.duringRun = () async {
        phone.spaces.duringRun = null;
        final current = phone.settings;
        final space = current.spaces.single;
        await phone.store.saveSettings(
          current.copyWith(spaces: [space.withOnServer(space.onServer!.to(SpaceCopy.closed, 5, reason: SpaceCopyClosed.owner))]),
          phone.session,
        );
      };
      await phone.sync();
      await phone.sync();

      expect(phone.space(familyId).onServer!.state, SpaceCopy.closed, reason: 'the newer note was not overwritten with joined');
      expect(phone.space(familyId).onServer!.reason, SpaceCopyClosed.owner);
    }, timeout: timeout);

    test('leaves a space alone while its move runs on this phone', () async {
      final (:family, :phone, writesBefore: _, store: _) = await joiningPhone(sam, state: null);
      final requests = family.dav.requests.length;
      final asked = phone.spaces.offers.length;

      phone.store.setMoving(familyId, moving: true);
      await phone.sync();

      expect(family.dav.requests.length, requests, reason: 'the file was neither read nor written while the entries are copied');
      expect(phone.spaces.offers.length, asked);
      expect(phone.spaces.runs, isEmpty);

      phone.store.setMoving(familyId, moving: false);
      await phone.sync();
      expect(family.dav.requests.length, greaterThan(requests), reason: 'it syncs again once the move ended');
    }, timeout: timeout);

    for (final state in [SpaceCopy.joined, SpaceCopy.joining]) {
      test('a “not a member” answer deletes nothing of a ${state.name} space and is no leaving of a space never joined', () async {
        // Bob is invited and never confirmed: he reads the chain, which answers that he is no confirmed member. A stranger the
        // space doesn't know at all is answered 404, which is no "not a member" answer and gets no anchor to compare
        final bob = await realAccount(2);
        final made = await MovedFamily.make(sam);
        await syncFor(made.server, sam, {}).actions().invite(bob.accountId, SpaceRole.member);
        final (:family, :phone, writesBefore: _, store: _) = await joiningPhone(
          bob,
          state: state,
          family: made,
          configure: (spaces) => spaces.confirmedOverride = [familyUuid],
        );

        expect(phone.lists.accounts, hasLength(21), reason: 'the empty answer is no deletion of the phone’s entries');
        expect(phone.lists.logins, hasLength(20));
        final note = phone.space(familyId).onServer!;
        if (state == SpaceCopy.joined) {
          expect(note.state, SpaceCopy.closed);
          expect(note.reason, SpaceCopyClosed.left);
        } else {
          expect(note.state, SpaceCopy.joining, reason: 'a phone that never joined has left nothing');
        }
        final file = await family.file();
        expect(file.accounts.map((account) => account.id), isNot(contains('acc-joiner')), reason: 'the file is not written');
      }, timeout: timeout);
    }

    for (final state in [SpaceCopy.bridged, SpaceCopy.joined]) {
      test('a ${state.name} space whose anchor holds no comparison is no leaving: the note stays, and nothing is written', () async {
        final made = await MovedFamily.make(sam);
        final revisions = {for (final item in made.server.items.values) item.id: item.revision};

        // The server lists the account confirmed in the space, but this phone never compared its fingerprint: the anchor it holds
        // is a chain seen once
        final (:family, :phone, :writesBefore, :store) = await joiningPhone(sam, compared: false, state: state, family: made);

        final note = phone.space(familyId).onServer!;
        expect(note.state, state, reason: 'nothing was learnt of the copy, and not being compared is no leaving');
        expect(note.reason, isNull);
        expect(family.fileWrites, writesBefore, reason: 'the file is never written');
        expect(phone.lists.accounts, hasLength(21), reason: 'the entry made here is kept');
        expect(phone.lists.logins, hasLength(20));
        if (state == SpaceCopy.bridged) {
          expect(phone.status[familyId]?.problem, SyncProblem.spaceCantBeChecked, reason: 'the person is told to compare the fingerprint');
        }
        expect(SpaceAnchors.fromJson(store['anchors']).compared, isEmpty, reason: 'no comparison was made up');
        expect({for (final item in family.server.items.values) item.id: item.revision}, revisions, reason: 'nothing was uploaded');
        final kept = store.keys.where((key) => key.startsWith('backmycodes_kemlock_space_'));
        expect(kept, isEmpty, reason: 'no key was opened and nothing of the space kept');

        // The next run is the same: the space is still what it was
        await phone.sync();
        expect(phone.space(familyId).onServer!.state, state);
        expect(family.fileWrites, writesBefore);
      }, timeout: timeout);
    }

    test('a phone that agreed but holds no anchor merges nothing and makes none', () async {
      final made = await MovedFamily.make(sam);
      final revisions = {for (final item in made.server.items.values) item.id: item.revision};

      final (:family, :phone, writesBefore: _, :store) = await joiningPhone(sam, anchored: false, family: made);

      expect(phone.space(familyId).onServer!.state, SpaceCopy.joining, reason: 'it is not joined');
      expect(phone.status[familyId]?.problem, SyncProblem.spaceCantBeChecked);
      expect(store['anchors'], isNull);
      expect({for (final item in family.server.items.values) item.id: item.revision}, revisions, reason: 'nothing was uploaded');
      final kept = store.keys.where((key) => key.startsWith('backmycodes_kemlock_space_'));
      expect(kept, isEmpty, reason: 'no key was opened and nothing of the space kept');
    }, timeout: timeout);

    test('a list that can’t be read leaves the space as it was', () async {
      final (:family, :phone, writesBefore: _, store: _) = await joiningPhone(
        sam,
        configure: (spaces) => spaces.listFailure = const KmError(KmProblem.network),
        state: null,
      );

      expect(phone.spaces.runs, isEmpty);
      expect(phone.space(familyId).onServer, isNull);
      expect(phone.status[kemlockSpacesScope]?.problem, SyncProblem.network);
      expect((await family.file()).accounts.map((account) => account.id), contains('acc-joiner'));
    }, timeout: timeout);

    test('a file that can’t be read is no merge: the space stays joining, and the next run tries again', () async {
      final (:family, :phone, writesBefore: _, store: _) = await joiningPhone(sam, breakFile: true);

      expect(phone.space(familyId).onServer!.state, SpaceCopy.joining, reason: 'the merge is not done: it is not marked joined');
      expect(phone.status[familyId]?.problem, SyncProblem.server, reason: 'the file is the side that failed');

      // The server's entries reached the vault while the join is not whole: the space is a server space's already, so none of its
      // passwords shows as a WebDAV space's would
      final hidden = const HiddenPasswords().withSettings(phone.settings);
      expect(hidden.hides(phone.lists.logins.first), isTrue);

      family.dav.respond = null;
      await phone.sync();

      expect(phone.space(familyId).onServer!.state, SpaceCopy.joined);
      expect(phone.status[familyId]?.problem, isNull);
    }, timeout: timeout);

    test('a space that moved on this phone is not joined: it bridges', () async {
      final family = await MovedFamily.make(sam);
      final entries = familyEntries();
      final bridged = familySpace(family.target.key).withOnServer(SpaceOnServer(state: SpaceCopy.bridged, uuid: familyUuid, at: 1));
      final phone = await openRig(
        settings: SyncSettings(kemlock: rigTarget, spaces: [bridged]),
        source: sourceOn(family.server, sam, comparedStore(family.server)),
        webDav: family.webDav,
        lists: Lists(accounts: entries.accounts, logins: entries.logins),
        states: {
          familyId: ScopeState(known: [...family.mover.state.known], lastSyncAt: 1000),
        },
      );

      expect(phone.spaces.runs, [familyUuid]);
      expect(phone.space(familyId).onServer!.state, SpaceCopy.bridged);
      expect(
        family.dav.requests.where((request) => request.method == 'GET').length,
        greaterThan(1),
        reason: 'the file is read by the bridge',
      );
    }, timeout: timeout);
  });
}
