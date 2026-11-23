// The progress record of a move (move-off-vaultwarden-sync, task 2.1): it round trips, keeps the keys
// it doesn't know, is trimmed after the go-back window, and is stored through the vault's sealed values.
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_move_record.dart';

import 'km_phone_kit.dart';

const _stored = {
  'v': 1,
  'source': 'vaultwarden',
  'server': 'https://vault.example.com',
  'home': 'home-1',
  'mode': 'sealed',
  'step': 'copy',
  'sent': {'a1': 'aGFzaA'},
  'files': {'f1': 'ZmlsZQ'},
  'checked': false,
  'closed': false,
  'startedAt': 1795300000000,
};

void main() {
  test('reads the stored form and writes it back whole', () {
    final record = KmMoveRecord.tryParse(_stored)!;

    expect(record.source, 'vaultwarden');
    expect(record.step, KmMoveStep.copy);
    expect(record.sent, {'a1': 'aGFzaA'});
    expect(record.files, {'f1': 'ZmlsZQ'});
    expect(record.sealedHome, isTrue);
    expect(record.toJson(), _stored);
  });

  test('keeps the keys it does not know, and the step it reaches', () {
    final record = KmMoveRecord.tryParse({
      ..._stored,
      'fromLater': {'a': 1},
    })!;

    final next = record.copyWith(step: KmMoveStep.files, sent: {'a1': 'aGFzaA', 'a2': 'Yg'});

    expect(next.toJson()['fromLater'], {'a': 1});
    expect(next.toJson()['step'], 'files');
    expect(next.sent.keys, ['a1', 'a2']);
  });

  test('writes redo only when there is something to redo', () {
    final record = KmMoveRecord.tryParse(_stored)!;

    expect(record.toJson().containsKey('redo'), isFalse);
    expect(record.copyWith(redo: ['a1']).toJson()['redo'], ['a1']);
    expect(KmMoveRecord.tryParse(record.copyWith(redo: ['a1']).toJson())!.redo, ['a1']);
  });

  test('is trimmed to its source, done and finish time after the window', () {
    final record = KmMoveRecord.tryParse({..._stored, 'step': 'done', 'closed': true, 'finishedAt': 1795400000000})!;

    final trimmed = record.trimmed();

    expect(trimmed.toJson(), {'v': 1, 'source': 'vaultwarden', 'done': true, 'finishedAt': 1795400000000});
    final again = KmMoveRecord.tryParse(trimmed.toJson())!;
    expect(again.isDone, isTrue);
    expect(again.isTrimmed, isTrue);
    expect(again.toJson(), trimmed.toJson());
  });

  test('offers going back for 30 days after a close, and not after', () {
    final closedAt = DateTime.utc(2026, 11, 22);
    final record = KmMoveRecord.tryParse({..._stored, 'step': 'done', 'closed': true, 'finishedAt': closedAt.millisecondsSinceEpoch})!;

    expect(record.goBackOpen(closedAt.add(const Duration(days: 29))), isTrue);
    expect(record.goBackOpen(closedAt.add(const Duration(days: 30))), isFalse);
    expect(record.trimmed().goBackOpen(closedAt), isFalse);
  });

  test('is null for what is not a record of this version, and a newer build is told apart', () {
    expect(KmMoveRecord.tryParse(null), isNull);
    expect(KmMoveRecord.tryParse('x'), isNull);
    expect(KmMoveRecord.tryParse({..._stored, 'v': 2}), isNull);
    expect(KmMoveRecord.newer({..._stored, 'v': 2}), isTrue);
    expect(KmMoveRecord.newer(_stored), isFalse);
  });

  test('is kept in the vault’s sealed values and read back', () async {
    final values = KmMemoryValues();
    final store = KmMoveStore(values);
    expect(await store.load(), isNull);

    await store.save(KmMoveRecord.tryParse(_stored)!);

    expect(values.values.containsKey(keyKemlockMove), isTrue);
    expect((await store.load())!.toJson(), _stored);
    store.remove();
    expect(await store.load(), isNull);
  });
}
