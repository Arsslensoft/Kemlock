import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/storage/preferences_backend.dart';
import 'package:kemlock/features/lock/unlock_attempts.dart';
import 'package:kemlock/vault/vault_registry.dart';

/// Phone storage whose writes land only once the test lets them.
class _SlowPreferences extends MemoryPreferences {
  Completer<void> gate = Completer();

  @override
  Future<void> set(String key, String value) async {
    await gate.future;
    return super.set(key, value);
  }
}

void main() {
  final now = DateTime.utc(2026, 11, 16, 9, 41);
  late KeyValueStore store;
  late VaultRegistry vaults;
  late UnlockAttempts attempts;

  void addVault(String id, {bool listed = true}) {
    store.setItem(vaults.vaultKey(keyConfig, id), '{}');
    vaults.setListed(id, listed);
  }

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    attempts = UnlockAttempts(store, vaults, () => now);
    addVault(mainVault);
  });

  test('counts a try against the listed vault, with when it was', () async {
    addVault('work');

    expect(await attempts.countTry(mainVault), UnlockFailures.none);
    expect(await attempts.countTry(mainVault), UnlockFailures(count: 1, last: now.millisecondsSinceEpoch));

    expect(attempts.read(mainVault), UnlockFailures(count: 2, last: now.millisecondsSinceEpoch));
    expect(jsonDecode(store.getItem('backmycodes_unlock_failures')!), {'count': 2, 'last': now.millisecondsSinceEpoch});
    expect(attempts.read('work'), UnlockFailures.none);
    expect(store.getItem('backmycodes_unlock_failures::work'), isNull);
  });

  test('counts for the phone when no vault is listed', () async {
    await attempts.countTry(null);

    expect(attempts.read(null).count, 1);
    expect(store.getItem('backmycodes_unlock_failures_device'), isNotNull);
    expect(attempts.read(mainVault), UnlockFailures.none);
  });

  test('has the try in the phone’s storage before the call returns', () async {
    final backend = _SlowPreferences();
    final slow = await KeyValueStore.open(backend);
    final slowVaults = VaultRegistry(slow);
    slow.setItem(keyConfig, '{}');
    backend.gate.complete();
    await slow.flush();
    backend.gate = Completer();
    var returned = false;

    final counting = UnlockAttempts(slow, slowVaults, () => now).countTry(mainVault).then((_) => returned = true);
    await pumpEventQueue();
    expect(returned, isFalse, reason: 'the write hasn’t reached storage yet');
    expect(backend.values['backmycodes_unlock_failures'], isNull);

    backend.gate.complete();
    await counting;
    expect(returned, isTrue);
    expect(jsonDecode(backend.values['backmycodes_unlock_failures']!), containsPair('count', 1));
  });

  test('resets to zero and gives back what was there before the try that opened', () async {
    await attempts.countTry(mainVault);
    await attempts.countTry(mainVault);
    // The password of this try was the right one
    final before = await attempts.countTry(mainVault);

    final reported = attempts.reset(mainVault, before: before);

    expect(reported, UnlockFailures(count: 2, last: now.millisecondsSinceEpoch));
    expect(attempts.read(mainVault), UnlockFailures.none);
    expect(jsonDecode(store.getItem('backmycodes_unlock_failures')!), {'count': 0});
  });

  test('resets after an open that was no try, such as biometrics, giving back the count stored', () async {
    await attempts.countTry(mainVault);

    expect(attempts.reset(mainVault).count, 1);
    expect(attempts.read(mainVault).count, 0);
    // Nothing to reset writes nothing
    store.removeItem('backmycodes_unlock_failures');
    expect(attempts.reset(mainVault), UnlockFailures.none);
    expect(store.getItem('backmycodes_unlock_failures'), isNull);
  });

  test('writes nothing for a hidden vault', () async {
    addVault('diary', listed: false);
    final keys = store.storedKeys().toSet();

    expect(await attempts.countTry('diary'), UnlockFailures.none);
    attempts.reset('diary');

    expect(store.storedKeys().toSet(), keys);
    expect(store.storedKeys().where((key) => key.contains('unlock_failures')), isEmpty);
  });

  test('keeps the phone’s keys when the first vault is removed, and its own count goes with it', () async {
    addVault('work');
    await attempts.countTry(mainVault);
    await attempts.countTry('work');
    await attempts.countTry(null);
    store.setItem(keyUnlockErase, '{"after":10}');
    store.setItem(keyErased, '{"at":1,"after":10}');

    vaults.removeVaultData(mainVault);

    expect(store.getItem('backmycodes_unlock_failures'), isNull);
    expect(store.getItem('backmycodes_unlock_failures::work'), isNotNull);
    expect(store.getItem(keyUnlockFailuresDevice), isNotNull);
    expect(store.getItem(keyUnlockErase), '{"after":10}');
    expect(store.getItem(keyErased), isNotNull);
  });

  test('removes every count when every vault is wiped', () async {
    addVault('work');
    await attempts.countTry(mainVault);
    await attempts.countTry('work');
    await attempts.countTry(null);

    vaults.removeAllVaults();

    expect(store.storedKeys().where((key) => key.contains('unlock_failures')), isEmpty);
  });

  test('reads a count that isn’t one as none', () {
    for (final raw in ['not json', '[]', '{"count":"two"}', '{"count":-3}']) {
      store.setItem('backmycodes_unlock_failures', raw);
      expect(attempts.read(mainVault).count, 0, reason: raw);
    }
  });

  test('sets every count the lock screen shows back to zero, as when the erase is turned on', () async {
    addVault('work');
    for (var i = 0; i < 12; i++) {
      await attempts.countTry('work');
    }
    await attempts.countTry(mainVault);
    store.setItem(keyUnlockFailuresDevice, jsonEncode({'count': 30, 'last': now.millisecondsSinceEpoch}));
    expect(attempts.highestCount(), 30);

    attempts.resetAll();

    expect(attempts.highestCount(), 0);
    expect(attempts.read('work'), UnlockFailures.none);
    expect(attempts.read(mainVault), UnlockFailures.none);
    expect(attempts.read(null), UnlockFailures.none);
  });

  test('finds the highest count of any slot the lock screen shows', () async {
    addVault('work');
    addVault('diary', listed: false);
    await attempts.countTry('work');
    await attempts.countTry('work');
    await attempts.countTry(mainVault);

    expect(attempts.highestCount(), 2);
  });
}
