import 'package:flutter_test/flutter_test.dart';

import '../../fakes/crashing_store.dart';

void main() {
  test('keeps the writes before the one it dies at, and none from it on', () {
    final store = CrashingStore(diesAt: 3);
    final keys = ['backmycodes_a', 'backmycodes_b', 'backmycodes_c', 'backmycodes_d', 'backmycodes_e'];

    var died = 0;
    for (final (i, key) in keys.indexed) {
      try {
        store.setItem(key, '$i');
      } on StoreDied catch (error) {
        died = error.write;
        break;
      }
    }

    expect(died, 3);
    final next = store.reopen();
    expect([for (final key in keys) next.getItem(key)], ['0', '1', null, null, null]);
    expect(next.storedKeys(), ['backmycodes_a', 'backmycodes_b']);
  });

  test('stays dead after the write it died at', () {
    final store = CrashingStore(diesAt: 1);

    expect(() => store.setItem('backmycodes_a', '1'), throwsA(isA<StoreDied>()));
    expect(() => store.setItem('backmycodes_b', '2'), throwsA(isA<StoreDied>()));
    expect(store.reopen().storedKeys(), isEmpty);
  });

  test('counts removing a key it holds as a write, and removing one it lacks as none', () {
    final store = CrashingStore(diesAt: 2, values: {'backmycodes_a': '1'});

    store.removeItem('backmycodes_missing');
    store.removeItem('backmycodes_a');
    expect(store.writes, 1);
    expect(() => store.setItem('backmycodes_b', '2'), throwsA(isA<StoreDied>()));
    expect(store.reopen().storedKeys(), isEmpty);
  });

  test('never dies without a write to die at', () {
    final store = CrashingStore();
    for (var i = 0; i < 100; i++) {
      store.setItem('backmycodes_$i', '$i');
    }

    expect(store.reopen().storedKeys(), hasLength(100));
  });
}
