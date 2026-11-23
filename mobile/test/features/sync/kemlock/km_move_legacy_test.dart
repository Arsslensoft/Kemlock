// Task 8.2 of move-off-vaultwarden-sync: the vault of `legacy-v0.1.0.json` (never regenerated) moved through the
// fake Kemlock API. Its ids, such as `acc-1`, aren't UUIDs: each travels as its legacy-id UUID, and the entry keeps
// its own id inside, which the check reads back.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_move.dart';
import 'package:kemlock/features/sync/kemlock/km_move_old_store.dart';
import 'package:kemlock/features/sync/kemlock/km_move_record.dart';
import 'package:kemlock/features/sync/kemlock/km_move_source.dart';
import 'package:kemlock/features/sync/removal_guard.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';

import 'km_move_kit.dart';
import 'km_phone_kit.dart';
import 'km_sync_kit.dart';

class _Source implements KmMoveSource {
  _Source(this.lists);

  final Lists lists;

  @override
  String get name => vaultwardenSource;

  @override
  String get server => 'https://vault.example.com';

  @override
  String? get home => 'home-1';

  @override
  String? get mode => 'plain';

  @override
  Future<KmMoveSynced> sync(Lists local, ScopeState state, {required int now, RemovalChoice? choice}) async {
    final doc = SyncDoc(accounts: lists.accounts, backupServices: lists.backupServices);
    return KmMoveSynced(doc: doc, known: doc.ids.toList(), state: const {});
  }
}

class _Old implements KmMoveOldStore {
  @override
  Future<KmOldStoreResult> finish(Set<String> confirmed) async => const KmOldStoreResult(KmOldStore.copyKept);
}

void main() {
  test('the 0.1.0 vault moves with its ids inside its entries, under their legacy-id UUIDs, and the check passes', () async {
    final fixture = jsonDecode(File('test/fixtures/legacy-v0.1.0.json').readAsStringSync()) as Map<String, Object?>;
    final expected = fixture['expected']! as Map<String, Object?>;
    final lists = Lists(
      accounts: [for (final a in expected['accounts']! as List<Object?>) OtpAccount.fromJson(a! as Map<String, Object?>)],
      backupServices: [for (final s in expected['backupServices']! as List<Object?>) BackupService.fromJson(s! as Map<String, Object?>)],
    );
    final rig = MoveRig();
    final store = KmMoveStore(KmMemoryValues());
    var current = lists;
    final outcome = await KmMoveRunner(
      store: store,
      source: _Source(lists),
      server: rig.moveServer,
      files: FakeFileStore(),
      oldStore: _Old(),
      lists: () => current,
      oldState: () async => const ScopeState(known: []),
      applySynced: (synced) async => current = synced.doc,
      clock: () => DateTime.fromMillisecondsSinceEpoch(moveNow),
    ).run();

    expect(outcome.record.isDone, isTrue);
    expect(outcome.record.checked, isTrue);
    expect(outcome.record.sent.keys, containsAll(['acc-1', 'acc-2', 'svc-1']));
    final read = await rig.read();
    for (final id in ['acc-1', 'acc-2', 'svc-1']) {
      final itemId = rig.itemUuidOf(id);
      expect(itemId, isNot(id), reason: 'the item id is a UUID');
      expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(itemId), isTrue);
      final item = read.items[itemId]!;
      expect(item.entryId, id);
      expect(item.entry!['id'], id, reason: 'the entry keeps its own id inside the item');
    }
  });
}
