// The bridge of a moved WebDAV space (docs/plans/add-server-spaces.md, design 7 and task 8.2): a moved member's phone syncs the
// WebDAV file as a second target of the space's scope, both ways, and writes the file as today's sync does. A phone that stays
// on WebDAV is simulated with the frozen merge in `test/compat/before_vault_items`, which is what a phone that never learns
// of Kemlock Server runs: its edits reach the server space, the server space's edits reach it, and neither side loses the
// other's.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/features/spaces/space_bridge.dart';
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/webdav.dart';

import 'space_bridge_kit.dart';

void main() {
  late KmAccount sam;

  setUpAll(() async => sam = await realAccount(1));

  const timeout = Timeout(Duration(minutes: 3));

  // The family moved, with an older phone that has read the file and a phone that reads the server space
  Future<({MovedFamily family, OlderPhone older, ServerPhone other})> moved() async {
    final family = await MovedFamily.make(sam);
    final older = family.olderPhone();
    await older.sync(now: 2000);
    final other = family.serverPhone();
    await other.run(now: 2000);
    // The mover's first bridged run settles what the move left: nothing differs, so nothing is written to either side
    final settled = await family.mover.run(now: 3000);
    expect(settled.failure, isNull);
    return (family: family, older: older, other: other);
  }

  group('the bridge', () {
    test('an edit by a phone on the frozen merge reaches the server space', () async {
      final (:family, :older, :other) = await moved();
      older
        ..edit('acc-3', issuer: 'Edited on the older phone', at: 5000)
        ..add('acc-new-old', at: 5000);
      await older.sync(now: 5001);

      final writes = family.fileWrites;
      final run = await family.mover.run(now: 6000);

      expect(run.failure, isNull);
      expect(run.signal, BridgeSignal.open, reason: 'the server space says the move is whole');
      expect(family.fileWrites, writes, reason: 'the file already held the edit: the bridge writes it only when it differs');
      // The mover took the edit and the new account
      expect(family.mover.account('acc-3').issuer, 'Edited on the older phone');
      expect(family.mover.account('acc-new-old').issuer, 'Issuer acc-new-old');
      // And another phone that reads the server space alone sees them, under the ids they have on WebDAV
      await other.run(now: 7000);
      expect(other.account('acc-3').issuer, 'Edited on the older phone');
      expect(other.account('acc-new-old').id, 'acc-new-old');
      expect(other.lists.accounts, hasLength(21));
      expect(other.lists.logins, hasLength(20), reason: 'what the older phone cannot read passes through the file untouched');
    }, timeout: timeout);

    test('an edit in the server space reaches the file, and the phone on the frozen merge takes it', () async {
      final (:family, :older, :other) = await moved();
      other
        ..edit('acc-4', issuer: 'Edited on the server', at: 5000)
        ..add('acc-new-server', at: 5000);
      await other.run(now: 5001);

      final run = await family.mover.run(now: 6000);

      expect(run.failure, isNull);
      // The mover took it and wrote it to the file
      expect(family.mover.account('acc-4').issuer, 'Edited on the server');
      final file = await family.file();
      expect(file.accounts.firstWhere((account) => account.id == 'acc-4').issuer, 'Edited on the server');
      expect(file.accounts.map((account) => account.id), contains('acc-new-server'));
      expect(
        file.accounts.firstWhere((account) => account.id == 'acc-new-server').spaceId,
        familyId,
        reason: 'the file names the WebDAV id',
      );
      expect(file.logins, hasLength(20));
      // The phone that never heard of Kemlock Server syncs as it always did, and has both
      await older.sync(now: 7000);
      expect(older.account('acc-4')!.issuer, 'Edited on the server');
      expect(older.account('acc-new-server'), isNotNull);
      expect(older.accounts, hasLength(21));
      expect((await family.file()).logins, hasLength(20), reason: 'the frozen merge writes the lists it does not know back as they were');
    }, timeout: timeout);

    test('one run carries both ways: what the file brought goes up and what the server brought goes into the file', () async {
      final (:family, :older, :other) = await moved();
      older.add('acc-from-file', at: 5000);
      await older.sync(now: 5001);
      other.add('acc-from-server', at: 5002);
      await other.run(now: 5003);

      final run = await family.mover.run(now: 6000);

      expect(run.failure, isNull);
      final file = await family.file();
      expect(file.accounts.map((account) => account.id), containsAll(['acc-from-file', 'acc-from-server']));
      await other.run(now: 7000);
      expect(other.lists.accounts.map((account) => account.id), containsAll(['acc-from-file', 'acc-from-server']));
      expect(family.mover.lists.accounts, hasLength(22));
    }, timeout: timeout);

    test('writes the file only when it differs, and keeps it as today’s sync writes it', () async {
      final (:family, older: _, :other) = await moved();
      final writes = family.fileWrites;

      // Nothing changed anywhere: no write to the file, and the server space is not written either
      final revisions = {for (final item in family.server.items.values) item.id: item.revision};
      await family.mover.run(now: 6000);
      expect(family.fileWrites, writes);
      expect({for (final item in family.server.items.values) item.id: item.revision}, revisions);

      // A change from the server: the file is written once, by the ordinary run of a WebDAV space
      other
        ..edit('acc-2', issuer: 'Changed', at: 7000)
        ..edit('acc-3', issuer: 'Changed too', at: 7000);
      await other.run(now: 7001);
      await family.mover.run(now: 8000);
      expect(family.fileWrites, writes + 1);
    }, timeout: timeout);
  });

  group('which side wins', () {
    test('the later change wins, on both sides, whichever side made it', () async {
      final (:family, :older, :other) = await moved();
      older.edit('acc-5', issuer: 'File, later', at: 9000);
      other
        ..edit('acc-5', issuer: 'Server, earlier', at: 8000)
        ..edit('acc-6', issuer: 'Server, later', at: 9000);
      older.edit('acc-6', issuer: 'File, earlier', at: 8000);
      await older.sync(now: 9001);
      await other.run(now: 9002);

      await family.mover.run(now: 10000);

      for (final (id, winner) in [('acc-5', 'File, later'), ('acc-6', 'Server, later')]) {
        expect(family.mover.account(id).issuer, winner, reason: id);
        expect((await family.file()).accounts.firstWhere((account) => account.id == id).issuer, winner, reason: id);
      }
      await other.run(now: 11000);
      expect(other.account('acc-5').issuer, 'File, later');
      expect(other.account('acc-6').issuer, 'Server, later');
    }, timeout: timeout);

    test('a deletion on either side is carried to the other', () async {
      final (:family, :older, :other) = await moved();
      older.delete('acc-9');
      await older.sync(now: 5000);
      other.delete('acc-10');
      await other.run(now: 5001);

      await family.mover.run(now: 6000);

      expect(family.mover.lists.accounts.map((account) => account.id), isNot(anyOf(contains('acc-9'), contains('acc-10'))));
      expect((await family.file()).accounts.map((account) => account.id), isNot(anyOf(contains('acc-9'), contains('acc-10'))));
      await other.run(now: 7000);
      expect(other.lists.accounts.map((account) => account.id), isNot(contains('acc-9')));
      await older.sync(now: 7001);
      expect(older.accounts.map((account) => account.id), isNot(contains('acc-10')));
      expect(older.accounts, hasLength(18));
    }, timeout: timeout);
  });

  test('leaves the two markers out of the count of items left alone', () async {
    final (:family, older: _, other: _) = await moved();

    final run = await family.mover.run(now: 6000);

    expect(run.failure, isNull);
    expect(run.skipped, 0, reason: 'the open marker is no entry the app could not read');
  }, timeout: timeout);

  group('a failure on one side', () {
    test('a file that can’t be reached leaves the server space syncing, and the run says so', () async {
      final (:family, older: _, :other) = await moved();
      other.edit('acc-7', issuer: 'Edited on the server', at: 5000);
      await other.run(now: 5001);
      family.dav.respond = (request) async => http.Response('', 500);

      final run = await family.mover.run(now: 6000);

      expect(run.failure, isA<DavError>());
      expect(family.mover.account('acc-7').issuer, 'Edited on the server', reason: 'the server space went on');
    }, timeout: timeout);

    test('a server that can’t be reached leaves the file read and never written, and the run says so', () async {
      final (:family, :older, other: _) = await moved();
      older.edit('acc-8', issuer: 'Edited on the older phone', at: 5000);
      await older.sync(now: 5001);
      final writes = family.fileWrites;

      final run = await family.mover.run(now: 6000, server: (entries, kept) async => throw const KmError(KmProblem.network));

      expect(run.failure, isA<KmError>());
      expect(family.mover.account('acc-8').issuer, 'Edited on the older phone', reason: 'the file was read');
      expect(family.fileWrites, writes, reason: 'its chain may close the copy, so nothing is written to it');
    }, timeout: timeout);

    test('a failure after the chain closed the copy closes it, and the file is neither read nor written', () async {
      final (:family, older: _, other: _) = await moved();
      final requests = family.dav.requests.length;

      final run = await family.mover.run(
        now: 6000,
        server: (entries, kept) async => throw const ClosedRunError(SpaceCopyClosed.removal, KmError(KmProblem.network)),
      );

      expect(run.signal, BridgeSignal.closed);
      expect(run.reason, SpaceCopyClosed.removal);
      expect(run.failure, isA<KmError>(), reason: 'the failure is still the run’s problem');
      expect(family.dav.requests.length, requests);
      expect(family.mover.lists.accounts, hasLength(20), reason: 'nothing was taken or deleted');
    }, timeout: timeout);

    test('both failing is a failure of the run, the server’s first', () async {
      final (:family, older: _, other: _) = await moved();
      family.dav.respond = (request) async => http.Response('', 500);

      await expectLater(
        family.mover.run(now: 6000, server: (entries, kept) async => throw const KmError(KmProblem.network)),
        throwsA(isA<KmError>()),
      );
    }, timeout: timeout);

    test('a server that says this account isn’t a member never empties the file or the phone', () async {
      final (:family, older: _, other: _) = await moved();
      final before = await family.filePlaintext();

      final run = await family.mover.run(
        now: 6000,
        server: (entries, kept) async =>
            (doc: const SyncDoc(), known: const <String>[], state: withBridgeSignal(kept.extra, BridgeSignal.gone), skipped: 0),
      );

      expect(run.signal, BridgeSignal.gone);
      expect(await family.filePlaintext(), before, reason: 'an empty answer is no deletion of anything');
      expect(family.mover.lists.accounts, hasLength(20));
      expect(family.mover.lists.logins, hasLength(20));
    }, timeout: timeout);
  });
}
