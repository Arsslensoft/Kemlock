import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_reminders.dart';
import 'package:kemlock/features/keys/key_standing.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../../fakes/fake_reminders.dart';
import '../../helpers/test_app.dart';
import 'expiry_kit.dart';

/// A key expiring at 17:00 UTC on 1 January 2095, as the `future` fixture does.
final _expiry = DateTime.utc(2095, 1, 1, 17);

crypto.PgpKeyInfo _infoExpiring(DateTime expires) => crypto.PgpKeyInfo(
  crypto.PgpKey(
    version: 4,
    fingerprint: Uint8List(20),
    algorithm: 'ed25519',
    created: DateTime.utc(2020),
    expires: expires,
    hasSecret: false,
    protected: false,
    revoked: false,
  ),
  const ['Ada <ada@example.org>'],
  const [],
);

KeyStanding _expiring(DateTime expires, DateTime now) => keyStanding(_infoExpiring(expires), now);

/// A PGP key whose public half is the one byte [day]: the reader below
/// takes it for a key expiring at 17:00 UTC on that day of January 2095.
VaultKey _keyExpiringOn(int day) => VaultKey(
  id: 'k$day',
  name: 'Key $day',
  kind: KeyKind.pgp,
  algorithm: 'pgp',
  privateKey: 'AA==',
  publicKey: base64.encode([day]),
  origin: KeyOrigin.imported,
  addedAt: 0,
);

crypto.PgpKeyInfo _readDay(Uint8List public) => _infoExpiring(DateTime.utc(2095, 1, public.single, 17));

void main() {
  group('the reminders keys call for', () {
    test('a key expiring in 40 days gives four: 30, 7 and 1 days before and the day, at 09:00', () {
      final now = _expiry.subtract(const Duration(days: 40));

      expect(wantedReminders([_expiring(_expiry, now)], now), [
        (when: DateTime.utc(2094, 12, 2, 9), daysLeft: 30, count: 1),
        (when: DateTime.utc(2094, 12, 25, 9), daysLeft: 7, count: 1),
        (when: DateTime.utc(2094, 12, 31, 9), daysLeft: 1, count: 1),
        (when: DateTime.utc(2095, 1, 1, 9), daysLeft: 0, count: 1),
      ]);
    });

    test('a key expiring in 5 days gives two: the day before and the day', () {
      final now = _expiry.subtract(const Duration(days: 5));

      expect(wantedReminders([_expiring(_expiry, now)], now), [
        (when: DateTime.utc(2094, 12, 31, 9), daysLeft: 1, count: 1),
        (when: DateTime.utc(2095, 1, 1, 9), daysLeft: 0, count: 1),
      ]);
    });

    test('a key expiring today gives one before 09:00 and none after', () {
      final early = DateTime.utc(2095, 1, 1, 8, 59);
      final late = DateTime.utc(2095, 1, 1, 9, 1);

      expect(wantedReminders([_expiring(_expiry, early)], early), [(when: DateTime.utc(2095, 1, 1, 9), daysLeft: 0, count: 1)]);
      expect(wantedReminders([_expiring(_expiry, late)], late), isEmpty);
      // At 09:00 sharp its time has come
      final sharp = DateTime.utc(2095, 1, 1, 9);
      expect(wantedReminders([_expiring(_expiry, sharp)], sharp), isEmpty);
    });

    test('two keys expiring on one date share each notification, which counts two', () {
      final now = _expiry.subtract(const Duration(days: 40));
      final other = DateTime.utc(2095, 1, 1, 3);

      final wanted = wantedReminders([_expiring(_expiry, now), _expiring(other, now)], now);

      expect(
        [for (final reminder in wanted) (reminder.when.day, reminder.daysLeft, reminder.count)],
        [(2, 30, 2), (25, 7, 2), (31, 1, 2), (1, 0, 2)],
      );
    });

    test('keys of different dates meeting on one morning give one notification, for the nearer', () {
      // The first key's day and the day before the second's are both 1 January
      final now = DateTime.utc(2094, 12, 31, 12);
      final dayAfter = DateTime.utc(2095, 1, 2, 17);

      expect(wantedReminders([_expiring(_expiry, now), _expiring(dayAfter, now)], now), [
        (when: DateTime.utc(2095, 1, 1, 9), daysLeft: 0, count: 1),
        (when: DateTime.utc(2095, 1, 2, 9), daysLeft: 0, count: 1),
      ]);
    });

    test('an expired, a revoked and a never-expiring key give none', () async {
      final now = DateTime.utc(2026, 11, 16, 10);
      final standings = [
        for (final name in ['expired', 'revoked', 'revoked-expired', 'never'])
          keyStanding(crypto.readPgpKeyInfo((await crypto.readPrivateKey(expiryFixtureText(name))).public!), now),
        // Revoked, with an expiry still ahead
        KeyStanding(standing: Standing.revoked, expires: now.add(const Duration(days: 3))),
        KeyStanding.ok,
      ];

      expect(wantedReminders(standings, now), isEmpty);
    });

    test('more than 60 are cut to the 60 soonest', () {
      final now = DateTime.utc(2094, 6, 1, 12);
      final standings = [for (var i = 0; i < 40; i++) _expiring(DateTime.utc(2094, 8, 1 + i * 2, 17), now)];

      final all = wantedReminders(standings, now, limit: 1000);
      final wanted = wantedReminders(standings, now);

      expect(all.length, greaterThan(60));
      expect(wanted, hasLength(60));
      expect(wanted, all.sublist(0, 60));
      expect(wanted.last.when.isBefore(all[60].when), isTrue);
    });

    test('counts days on the local calendar for a local clock', () {
      final expires = DateTime(2095, 1, 10, 23, 30);
      final now = DateTime(2095, 1, 8, 12);

      expect(wantedReminders([_expiring(expires, now)], now), [
        (when: DateTime(2095, 1, 9, 9), daysLeft: 1, count: 1),
        (when: DateTime(2095, 1, 10, 9), daysLeft: 0, count: 1),
      ]);
    });

    test('ids are stable, differ by vault and by day, and fit 31 bits', () {
      final day = DateTime.utc(2095, 1, 1, 9);

      expect(reminderId('main', day), reminderId('main', DateTime.utc(2095, 1, 1, 23)));
      expect(reminderId('main', day), isNot(reminderId('work', day)));
      expect(reminderId('main', day), isNot(reminderId('main', DateTime.utc(2095, 1, 2, 9))));
      for (final id in [reminderId('main', day), reminderId('a1b2c3d4e5f6', day), reminderId('', DateTime.utc(1970))]) {
        expect(id, inInclusiveRange(0, 0x7fffffff));
      }
    });
  });

  group('keeping the scheduled notifications right', () {
    late KeyValueStore store;
    late FakeReminders fake;
    late ProviderContainer container;
    late DateTime now;
    const main = VaultInfo(id: mainVault);
    const work = VaultInfo(id: 'work', name: 'Work');
    const hidden = VaultInfo(id: 'secret', name: 'Secret', hidden: true);

    setUp(() {
      now = DateTime.utc(2094, 12, 20, 12);
      store = KeyValueStore.memory();
      // Two listed vaults and a hidden one, each with reminders on
      store.setItem(keyConfig, '{}');
      store.setItem('$keyConfig::work', '{"name":"Work"}');
      store.setItem('$keyConfig::secret', '{"name":"Secret"}');
      store.setItem('backmycodes_vaults', '{"listed":["main","work"]}');
      for (final suffix in ['', '::work', '::secret']) {
        store.setItem('backmycodes_prefs$suffix', '{"keyReminders":true}');
      }
      fake = FakeReminders();
      container = ProviderContainer(
        overrides: [
          messageCatalogProvider.overrideWithValue(testCatalog),
          keyValueStoreProvider.overrideWithValue(store),
          clockProvider.overrideWithValue(() => now),
          fake.asOverride,
          pgpKeyInfoReaderProvider.overrideWithValue(_readDay),
        ],
      );
      addTearDown(container.dispose);
    });

    KeyReminders reminders() => container.read(keyRemindersProvider);
    List<(int, String)> scheduled() => [for (final reminder in fake.inOrder) (reminder.when.day, reminder.body)];

    test('a first run schedules what the keys call for', () async {
      await reminders().sync(main, [_keyExpiringOn(1), _keyExpiringOn(10)]);

      expect(scheduled(), [
        (25, '1 key expires in 7 days'),
        (31, '1 key expires tomorrow'),
        (1, '1 key expires today'),
        (3, '1 key expires in 7 days'),
        (9, '1 key expires tomorrow'),
        (10, '1 key expires today'),
      ]);
      expect(fake.inOrder.every((reminder) => reminder.title == 'A key in Kemlock expires soon' && reminder.when.hour == 9), isTrue);
      expect(fake.scheduled.keys, contains(reminderId(mainVault, DateTime.utc(2095, 1, 1))));
    });

    test('a second run with the same keys schedules and cancels nothing', () async {
      final keys = [_keyExpiringOn(1), _keyExpiringOn(10)];
      await reminders().sync(main, keys);
      fake.calls.clear();

      await reminders().sync(main, keys);

      expect(fake.calls, isEmpty);
      expect(fake.scheduled, hasLength(6));
    });

    test('deleting a key cancels its days only', () async {
      await reminders().sync(main, [_keyExpiringOn(1), _keyExpiringOn(10)]);
      fake.calls.clear();

      await reminders().sync(main, [_keyExpiringOn(10)]);

      expect(fake.calls, hasLength(3));
      expect(fake.calls.every((call) => call.startsWith('cancel ')), isTrue);
      expect(scheduled(), [(3, '1 key expires in 7 days'), (9, '1 key expires tomorrow'), (10, '1 key expires today')]);
    });

    // openspec: add-pgp-key-editing, design decision 8
    test('a key whose expiry was changed moves its reminders to the new date', () async {
      final key = _keyExpiringOn(1);
      await reminders().sync(main, [key]);
      fake.calls.clear();

      // The same key, its public half now saying the 10th
      await reminders().sync(main, [
        key.withHalves(privateKey: key.privateKey, publicKey: base64.encode([10]), protected: false),
      ]);

      expect(fake.calls.where((call) => call.startsWith('cancel ')), hasLength(3));
      expect(scheduled(), [(3, '1 key expires in 7 days'), (9, '1 key expires tomorrow'), (10, '1 key expires today')]);
    });

    test('a second key on the same date says two keys, under the same ids', () async {
      await reminders().sync(main, [_keyExpiringOn(1)]);
      final ids = fake.scheduled.keys.toSet();

      await reminders().sync(main, [_keyExpiringOn(1), _keyExpiringOn(1).copyWith(id: 'twin')]);

      expect(fake.scheduled.keys.toSet(), ids);
      expect(scheduled(), [(25, '2 keys expire in 7 days'), (31, '2 keys expire tomorrow'), (1, '2 keys expire today')]);
    });

    test('a notification the phone lost is scheduled again', () async {
      final keys = [_keyExpiringOn(1)];
      await reminders().sync(main, keys);
      // A restore from a backup, or a phone that dropped its alarms
      fake.scheduled.clear();
      fake.calls.clear();

      await reminders().sync(main, keys);

      expect(fake.calls, hasLength(3));
      expect(fake.scheduled, hasLength(3));
    });

    test('a reminder whose morning has passed is no longer wanted', () async {
      final keys = [_keyExpiringOn(1)];
      await reminders().sync(main, keys);

      now = DateTime.utc(2094, 12, 31, 10);
      await reminders().sync(main, keys);

      expect(scheduled(), [(1, '1 key expires today')]);
    });

    test('a hidden vault schedules nothing and leaves the listed vault alone', () async {
      await reminders().sync(main, [_keyExpiringOn(1)]);
      final before = Map.of(fake.scheduled);
      final stored = store.getItem(keyKeyReminders);
      fake.calls.clear();

      await reminders().sync(hidden, [_keyExpiringOn(10)]);

      expect(fake.calls, isEmpty);
      expect(fake.scheduled, before);
      expect(store.getItem(keyKeyReminders), stored);
      expect(stored, isNot(contains('secret')));
    });

    test('a vault the registry does not list is hidden, whatever it is said to be', () async {
      await reminders().sync(const VaultInfo(id: 'secret', name: 'Secret'), [_keyExpiringOn(10)]);

      expect(fake.calls, isEmpty);
      expect(store.getItem(keyKeyReminders), isNull);
    });

    test('a vault that is hidden after it scheduled takes its notifications back', () async {
      await reminders().sync(main, [_keyExpiringOn(1)]);
      await reminders().sync(work, [_keyExpiringOn(10)]);
      expect(fake.scheduled, hasLength(6));

      container.read(vaultRegistryProvider).setListed('work', false);
      await reminders().sync(const VaultInfo(id: 'work', name: 'Work', hidden: true), [_keyExpiringOn(10)]);

      expect(scheduled(), [(25, '1 key expires in 7 days'), (31, '1 key expires tomorrow'), (1, '1 key expires today')]);
      expect(store.getItem(keyKeyReminders), isNot(contains('work')));
    });

    test("turning reminders off cancels all of the vault's, and no other vault's", () async {
      await reminders().sync(main, [_keyExpiringOn(1)]);
      await reminders().sync(work, [_keyExpiringOn(10)]);

      store.setItem('backmycodes_prefs', '{}');
      await reminders().sync(main, [_keyExpiringOn(1)]);

      expect(scheduled(), [(3, '1 key expires in 7 days'), (9, '1 key expires tomorrow'), (10, '1 key expires today')]);
      expect((jsonDecode(store.getItem(keyKeyReminders)!) as Map).keys, ['work']);
    });

    test('reminders that were never turned on schedule nothing, and store nothing', () async {
      store.setItem('backmycodes_prefs', '{}');

      await reminders().sync(main, [_keyExpiringOn(1)]);

      expect(fake.calls, isEmpty);
      expect(store.getItem(keyKeyReminders), isNull);
    });

    test("deleting a vault cancels its notifications while another vault's stay", () async {
      await reminders().sync(main, [_keyExpiringOn(1)]);
      await reminders().sync(work, [_keyExpiringOn(10)]);

      await reminders().cancelVault(mainVault);

      expect(scheduled(), [(3, '1 key expires in 7 days'), (9, '1 key expires tomorrow'), (10, '1 key expires today')]);
    });

    test('erasing every vault leaves no notification, even with the record of them gone', () async {
      await reminders().sync(main, [_keyExpiringOn(1)]);
      await reminders().sync(work, [_keyExpiringOn(10)]);
      // What removeAllVaults does before the app can look
      store.removeItem(keyKeyReminders);

      await reminders().cancelAll();

      expect(fake.scheduled, isEmpty);
      expect(store.getItem(keyKeyReminders), isNull);
    });

    test('what is stored holds ids, dates and counts, and nothing of a key', () async {
      await reminders().sync(main, [_keyExpiringOn(1)]);

      final stored = jsonDecode(store.getItem(keyKeyReminders)!) as Map<String, Object?>;
      expect(stored.keys, [mainVault]);
      expect((stored[mainVault]! as Map).values, ['2094-12-25 7 1 en', '2094-12-31 1 1 en', '2095-01-01 0 1 en']);
      expect(store.getItem(keyKeyReminders), isNot(contains('Key 1')));
      // It belongs to the phone, not to the first vault: deleting that vault leaves it
      expect(container.read(vaultRegistryProvider).keysOf(mainVault), isNot(contains(keyKeyReminders)));
    });

    test('the vaults share the room the phone gives: 60 pending in all', () async {
      now = DateTime.utc(2094, 6, 1, 12);
      final many = [for (var day = 1; day <= 31; day++) _keyExpiringOn(day)];
      await reminders().sync(main, many);
      expect(fake.scheduled.length, lessThanOrEqualTo(60));
      final mine = fake.scheduled.length;

      await reminders().sync(work, many);

      expect(fake.scheduled.length, lessThanOrEqualTo(60));
      expect(fake.scheduled.length, greaterThanOrEqualTo(mine));
    });

    test('a key that cannot be read, and a key of another kind, call for nothing', () async {
      const broken = VaultKey(
        id: 'b',
        name: 'Broken',
        kind: KeyKind.pgp,
        algorithm: 'pgp',
        privateKey: 'AA==',
        publicKey: '!!',
        origin: KeyOrigin.imported,
        addedAt: 0,
      );

      await reminders().sync(main, [broken, sshKey()]);

      expect(fake.calls, isEmpty);
    });
  });

  group('what a notification says', () {
    test('every title and body of the fixture keys names no key, address or vault', () async {
      final future = await expiryFixtureKey('future', title: 'Zanzibar signing key');
      final keys = [future, future.copyWith(id: 'twin'), await expiryFixtureKey('expired', title: 'Quokka key')];
      final texts = <String>{};
      for (final locale in AppLocale.values) {
        // 40 days, 8 days, 2 days and a day before the `future` key expires
        for (final daysBefore in [40, 8, 2, 1]) {
          final now = futureExpiry.subtract(Duration(days: daysBefore));
          final store = KeyValueStore.memory()
            ..setItem(keyConfig, '{"name":"Xylophone vault"}')
            ..setItem('backmycodes_prefs', '{"keyReminders":true}')
            ..setItem(keyLocale, locale.name);
          final fake = FakeReminders();
          final container = ProviderContainer(
            overrides: [
              messageCatalogProvider.overrideWithValue(testCatalog),
              keyValueStoreProvider.overrideWithValue(store),
              clockProvider.overrideWithValue(() => now),
              fake.asOverride,
            ],
          );
          addTearDown(container.dispose);

          await container.read(keyRemindersProvider).sync(const VaultInfo(id: mainVault, name: 'Xylophone vault'), keys);

          expect(fake.scheduled, isNotEmpty);
          for (final reminder in fake.scheduled.values) {
            texts
              ..add(reminder.title)
              ..add(reminder.body);
          }
        }
      }

      expect(
        texts,
        containsAll(['A key in Kemlock expires soon', '2 keys expire in 30 days', '2 keys expire today', '2 clés expirent demain']),
      );
      const secrets = ['Zanzibar', 'Quokka', 'Xylophone', 'Fixture', 'Future', 'future@example.org', 'example.org', '@', 'vault', 'coffre'];
      for (final text in texts) {
        for (final secret in secrets) {
          expect(text.toLowerCase(), isNot(contains(secret.toLowerCase())), reason: '"$text" must not hold "$secret"');
        }
        // Only the count and the days are numbers: no fingerprint, key ID or date
        expect(RegExp(r'\d+').allMatches(text).map((m) => m[0]), everyElement(isIn(['1', '2', '7', '30'])), reason: text);
      }
    });
  });
}
