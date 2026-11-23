import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/storage/preferences_backend.dart';

void main() {
  late MemoryPreferences phone;

  setUp(() => phone = MemoryPreferences());

  test("serves what native storage holds, and only the app's keys", () async {
    phone.values['backmycodes_vault_config'] = '{"salt":"a"}';
    phone.values['other_plugin_key'] = 'ignored';

    final store = await KeyValueStore.open(phone);

    expect(store.getItem('backmycodes_vault_config'), '{"salt":"a"}');
    expect(store.getItem('other_plugin_key'), isNull);
    expect(store.storedKeys(), ['backmycodes_vault_config']);
  });

  test('keeps the data the next time the app opens', () async {
    final store = await KeyValueStore.open(phone);
    store.setItem('backmycodes_vault_data', 'secret');
    await store.flush();

    final reopened = await KeyValueStore.open(phone);

    expect(reopened.getItem('backmycodes_vault_data'), 'secret');
  });

  test('writes through to native storage in order', () async {
    final store = await KeyValueStore.open(phone);
    store.setItem('backmycodes_k', '1');
    store.setItem('backmycodes_k', '2');
    store.removeItem('backmycodes_gone');
    store.setItem('backmycodes_k', '3');

    expect(store.getItem('backmycodes_k'), '3');
    await store.flush();
    expect(phone.log, ['set backmycodes_k=1', 'set backmycodes_k=2', 'set backmycodes_k=3']);
    expect(phone.values['backmycodes_k'], '3');
  });

  test('removes from native storage', () async {
    phone.values['backmycodes_k'] = 'v';
    final store = await KeyValueStore.open(phone);

    store.removeItem('backmycodes_k');
    await store.flush();

    expect(store.getItem('backmycodes_k'), isNull);
    expect(phone.values.containsKey('backmycodes_k'), isFalse);
  });

  test('keeps going after a failed native write', () async {
    final store = await KeyValueStore.open(phone);
    phone.failNextWrite = Exception('disk full');

    store.setItem('backmycodes_a', '1');
    store.setItem('backmycodes_b', '2');
    await store.flush();

    expect(phone.values['backmycodes_b'], '2');
    expect(store.getItem('backmycodes_a'), '1');
  });

  test('tells listeners about writes to their key', () {
    final store = KeyValueStore.memory();
    final heard = <String>[];
    final stop = store.listen('backmycodes_prefs', () => heard.add(store.getItem('backmycodes_prefs') ?? 'gone'));

    store.setItem('backmycodes_prefs', 'a');
    store.setItem('backmycodes_other', 'b');
    store.removeItem('backmycodes_prefs');
    stop();
    store.setItem('backmycodes_prefs', 'c');

    expect(heard, ['a', 'gone']);
  });
}
