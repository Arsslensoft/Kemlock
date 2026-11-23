// The move's runner (move-off-vaultwarden-sync, task 3.5): the steps in order, nothing sent to the Kemlock API
// before the old store's run passed, the old store untouched before the check passed, and a runner killed
// at any save resumed to the same server state, against the fake Kemlock Server.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/attachment_format.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/kemlock/km_move.dart';
import 'package:kemlock/features/sync/kemlock/km_move_old_store.dart';
import 'package:kemlock/features/sync/kemlock/km_move_record.dart';
import 'package:kemlock/features/sync/kemlock/km_move_server.dart';
import 'package:kemlock/features/sync/kemlock/km_move_source.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/models/secure_note.dart';

import 'km_move_kit.dart';
import 'km_phone_kit.dart';
import 'km_sync_kit.dart';

class _Killed implements Exception {}

/// The old store's run, which hands back the vault as it is, or throws.
class _Source implements KmMoveSource {
  _Source(this.lists);

  final Lists lists;
  Object? error;
  var runs = 0;

  @override
  String get name => vaultwardenSource;

  @override
  String get server => 'https://vault.example.com';

  @override
  String? get home => 'home-1';

  @override
  String? get mode => 'sealed';

  @override
  Future<KmMoveSynced> sync(Lists local, ScopeState state, {required int now, RemovalChoice? choice}) async {
    runs++;
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    final doc = SyncDoc(
      accounts: local.accounts,
      backupServices: local.backupServices,
      keys: local.keys,
      notes: local.notes,
      passkeys: local.passkeys,
      keyAccounts: local.keyAccounts,
      contacts: local.contacts,
      logins: local.logins,
      cards: local.cards,
      identities: local.identities,
    );
    return KmMoveSynced(doc: doc, known: doc.ids.toList(), state: {'revision': runs});
  }
}

class _OldStore implements KmMoveOldStore {
  var calls = 0;
  Set<String> confirmed = const {};

  @override
  Future<KmOldStoreResult> finish(Set<String> confirmed) async {
    calls++;
    this.confirmed = confirmed;
    return const KmOldStoreResult(KmOldStore.closed, changed: 3);
  }
}

/// The vault's sealed values, which stop answering saves after [killAfter] of them: a phone killed.
class _KillValues extends KmMemoryValues {
  int? killAfter;
  var saves = 0;

  @override
  Future<void> save(String key, Object? value) async {
    if (killAfter != null && saves >= killAfter!) {
      throw _Killed();
    }
    saves++;
    await super.save(key, value);
  }
}

/// One phone's move over the fake server.
class _Move {
  _Move({MoveRig? rig, _KillValues? values, Lists? lists, FakeFileStore? files, _Source? source, _OldStore? old})
    : rig = rig ?? MoveRig(),
      values = values ?? _KillValues(),
      files = files ?? FakeFileStore(),
      old = old ?? _OldStore(),
      current = lists ?? _vault() {
    this.source = source ?? _Source(current);
    store = KmMoveStore(this.values);
  }

  final MoveRig rig;
  final _KillValues values;
  final FakeFileStore files;
  final _OldStore old;
  late final _Source source;
  late final KmMoveStore store;
  Lists current;

  KmMoveRunner runner() => KmMoveRunner(
    store: store,
    source: source,
    server: rig.moveServer,
    files: files,
    oldStore: old,
    lists: () => current,
    oldState: () async => const ScopeState(known: []),
    applySynced: (synced) async => current = synced.doc,
    clock: () => DateTime.fromMillisecondsSinceEpoch(moveNow),
  );
}

/// Three accounts and a note with a file: every step has something to do.
Lists _vault() {
  final note = SecureNote(
    id: uuidN(9),
    title: 'Passport',
    addedAt: 1,
    attachments: [NoteAttachment(id: 'f1', name: 'scan.txt', size: 13, key: b64(Uint8List(32)), addedAt: 1)],
  );
  return Lists(accounts: [for (var i = 1; i <= 3; i++) account(uuidN(i))], notes: [note]);
}

/// The file `_vault` names, as the phone keeps it: KMA1 under the key the attachment says.
FakeFileStore _fileStore() {
  final plain = Uint8List.fromList(utf8.encode('passport scan'));
  return FakeFileStore()..files['f1'] = kma1EncryptSync(plain, Uint8List(32));
}

void main() {
  test('runs the sync, copy, files, check and old store in order, signing one manifest after the last batch', () async {
    final move = _Move(files: _fileStore());

    final outcome = await move.runner().run();

    expect(outcome.record.isDone, isTrue);
    expect(outcome.record.checked, isTrue);
    expect(outcome.record.closed, isTrue);
    expect(move.source.runs, 1);
    expect(move.old.calls, 1);
    expect(move.old.confirmed, hasLength(4));
    expect(outcome.oldStore!.outcome, KmOldStore.closed);
    expect(outcome.cache!.items, hasLength(4));
    final events = move.rig.server.events;
    expect(events.where((event) => event == 'manifest'), hasLength(1));
    expect(events.lastIndexOf('batch'), lessThan(events.indexOf('manifest')));
    expect(events.indexOf('file'), lessThan(events.indexOf('manifest')));
    expect(outcome.record.result!['moved'], {'otp': 3, 'note': 1});
    expect(outcome.record.result!['files'], 1);
    expect(outcome.record.result!['oldStore'], 'closed');
  });

  test('stops with the old run’s own error before any request reaches the Kemlock API, and resumes at the sync', () async {
    final move = _Move(files: _fileStore());
    move.source.error = const VwSyncError(VwSyncIssue.removals, count: 8);

    await expectLater(move.runner().run(), throwsA(isA<VwSyncError>()));

    expect(move.rig.server.requests, isEmpty);
    expect((await move.store.load())!.step, KmMoveStep.sync);
    expect(move.old.calls, 0);

    move.source.error = null;
    final outcome = await move.runner().run();
    expect(outcome.record.isDone, isTrue);
  });

  test('leaves the old store alone while the check fails, and sends the missing item again at the next run', () async {
    final move = _Move(files: _fileStore());
    var dropped = false;
    move.rig.server.respond = (request) async {
      // As the manifest arrives, the server loses an item
      if (!dropped && request.method == 'PUT' && request.url.path.contains('/manifests/')) {
        dropped = true;
        move.rig.server.items.remove(move.rig.itemUuidOf(uuidN(2)));
      }
      return move.rig.server.handle(request);
    };

    await expectLater(move.runner().run(), throwsA(isA<KmMoveError>().having((e) => e.issue, 'issue', KmMoveIssue.checkFailed)));

    expect(move.old.calls, 0, reason: 'nothing changes in the old store before the check passes');
    final stopped = (await move.store.load())!;
    expect(stopped.step, KmMoveStep.copy);
    expect(stopped.redo, [uuidN(2)]);

    final outcome = await move.runner().run();

    expect(outcome.record.isDone, isTrue);
    expect(move.old.calls, 1);
    expect(move.rig.server.items.containsKey(move.rig.itemUuidOf(uuidN(2))), isTrue);
  });

  test('a move resumed after the check goes straight to the old store, signing nothing again', () async {
    final move = _Move(files: _fileStore());
    await move.store.save(
      KmMoveRecord(source: vaultwardenSource, server: 'https://vault.example.com', startedAt: 1, step: KmMoveStep.oldStore, checked: true),
    );

    final outcome = await move.runner().run();

    expect(move.rig.server.events, isEmpty);
    expect(move.old.calls, 1);
    expect(outcome.record.isDone, isTrue);
    expect(outcome.cache, isNull, reason: 'the first Kemlock sync reads the vault itself');
  });

  test('leaves a record of a newer build alone', () async {
    final move = _Move();
    await move.values.save(keyKemlockMove, {'v': 2, 'source': 'vaultwarden', 'step': 'copy'});

    await expectLater(move.runner().run(), throwsA(isA<KmMoveError>().having((e) => e.issue, 'issue', KmMoveIssue.newer)));

    expect(move.rig.server.requests, isEmpty);
    expect((await move.values.load(keyKemlockMove))! as Map<String, Object?>, containsPair('v', 2));
  });

  test('killed at any save, a new runner resumes to the same server state', () async {
    // The saves an uninterrupted move makes, and the items it leaves
    final reference = _Move(files: _fileStore());
    await reference.runner().run();
    final total = reference.values.saves;
    final expected = reference.rig.server.items.keys.toSet();
    expect(total, greaterThan(5));

    for (var kill = 0; kill < total; kill++) {
      final move = _Move(files: _fileStore());
      move.values.killAfter = kill;
      await expectLater(move.runner().run(), throwsA(isA<_Killed>()), reason: 'killed after $kill saves');

      move.values.killAfter = null;
      final outcome = await move.runner().run();

      expect(outcome.record.isDone, isTrue, reason: 'killed after $kill saves');
      expect(move.rig.server.items.keys.toSet(), expected, reason: 'killed after $kill saves');
      expect(move.rig.server.items.values.map((item) => item.deleted), everyElement(isFalse));
      expect(move.rig.server.files.values.where((file) => file.bytes != null), isNotEmpty);
      // A close killed before the record said so is run again, which is idempotent: the home is already gone
      expect(move.old.calls, anyOf(1, 2), reason: 'the old store is dealt with after the check ($kill)');
    }
  });
}
