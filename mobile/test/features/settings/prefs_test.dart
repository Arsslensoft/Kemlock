import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/models/json.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';

final _now = DateTime.utc(2026, 10, 16, 12);

void main() {
  late KeyValueStore store;
  late ProviderContainer container;

  setUp(() {
    store = KeyValueStore.memory();
    container = ProviderContainer(overrides: [keyValueStoreProvider.overrideWithValue(store), clockProvider.overrideWithValue(() => _now)]);
    addTearDown(container.dispose);
  });

  Prefs prefs() => container.read(prefsProvider);
  PrefsNotifier notifier() => container.read(prefsProvider.notifier);
  VaultRegistry vaults() => container.read(vaultRegistryProvider);

  test('starts with the defaults', () {
    expect(prefs().toJson(), {
      'clearClipboard': true,
      'lastBackupAt': null,
      'autoLockMinutes': 5,
      'lockOnHide': false,
      'accountSort': 'name',
      'backupNudgeDismissedAt': null,
    });
    expect(prefs(), Prefs.defaults);
  });

  test('reads what is stored over the defaults', () {
    store.setItem('backmycodes_prefs', '{"autoLockMinutes":15,"accountSort":"custom","lastBackupAt":1700000000000}');

    expect((prefs().autoLockMinutes, prefs().accountSort, prefs().lastBackupAt), (15, AccountSort.custom, 1700000000000));
    expect(prefs().clearClipboard, isTrue);
  });

  test('reads something that is not a JSON object as the defaults', () {
    for (final raw in ['', 'not json', 'null', '[1,2]', '42']) {
      store.setItem('backmycodes_prefs', raw);
      expect(prefs(), Prefs.defaults, reason: raw);
    }
  });

  test('keeps the default for a value of the wrong type', () {
    store.setItem('backmycodes_prefs', '{"clearClipboard":"no","autoLockMinutes":"15","accountSort":"date","lockOnHide":true}');

    expect(prefs(), const Prefs(lockOnHide: true));
  });

  test('stores every setting along with the keys it does not know, in the order setPref writes them', () {
    store.setItem('backmycodes_prefs', '{"theme":{"accent":"violet"},"lockOnHide":true}');

    notifier().update((prefs) => prefs.copyWith(autoLockMinutes: 15));

    expect(
      store.getItem('backmycodes_prefs'),
      '{"clearClipboard":true,"lastBackupAt":null,"autoLockMinutes":15,"lockOnHide":true,'
      '"accountSort":"name","backupNudgeDismissedAt":null,"theme":{"accent":"violet"}}',
    );
  });

  test('starts with autofill off and names in its suggestions on', () {
    expect((prefs().autofill, prefs().autofillNames), (false, true));
  });

  test('writes the autofill settings only once they are changed, after the others', () {
    notifier().update((prefs) => prefs.copyWith(autofill: true, autofillNames: false));

    expect(
      store.getItem('backmycodes_prefs'),
      '{"clearClipboard":true,"lastBackupAt":null,"autoLockMinutes":5,"lockOnHide":false,'
      '"accountSort":"name","backupNudgeDismissedAt":null,"autofill":true,"autofillNames":false}',
    );
    expect((prefs().autofill, prefs().autofillNames), (true, false));

    notifier().update((prefs) => prefs.copyWith(autofill: false, autofillNames: true));
    expect(store.getItem('backmycodes_prefs'), isNot(contains('autofill')));
  });

  test('starts with passwords off, and saving and suggesting on for when they are', () {
    expect((prefs().passwords, prefs().passwordSaving, prefs().passwordSuggesting), (false, true, true));
  });

  test('writes the password settings only once they are changed, after the others', () {
    final before = store.getItem('backmycodes_prefs');
    notifier().update((prefs) => prefs.copyWith(passwords: true, passwordSaving: false, passwordSuggesting: false));

    expect(
      store.getItem('backmycodes_prefs'),
      '{"clearClipboard":true,"lastBackupAt":null,"autoLockMinutes":5,"lockOnHide":false,'
      '"accountSort":"name","backupNudgeDismissedAt":null,"passwords":true,"passwordSaving":false,"passwordSuggesting":false}',
    );
    expect((prefs().passwords, prefs().passwordSaving, prefs().passwordSuggesting), (true, false, false));

    notifier().update((prefs) => prefs.copyWith(passwords: false, passwordSaving: true, passwordSuggesting: true));
    expect(store.getItem('backmycodes_prefs'), isNot(contains('password')));
    expect(before, anyOf(isNull, isNot(contains('password'))));
  });

  test('starts without asking before a secret shows, and writes the setting only while it is on', () {
    expect(prefs().askBeforeSecret, isFalse);

    notifier().update((prefs) => prefs.copyWith(askBeforeSecret: true));
    expect(prefs().askBeforeSecret, isTrue);
    expect(jsonDecode(store.getItem('backmycodes_prefs')!), containsPair('askBeforeSecret', true));

    notifier().update((prefs) => prefs.copyWith(askBeforeSecret: false));
    expect(prefs().askBeforeSecret, isFalse);
    expect(store.getItem('backmycodes_prefs'), isNot(contains('askBeforeSecret')));
  });

  test('tells whoever watches when the settings change, however they are written', () {
    final seen = <int>[];
    container.listen(prefsProvider, (_, next) => seen.add(next.autoLockMinutes), fireImmediately: true);

    notifier().update((prefs) => prefs.copyWith(autoLockMinutes: 60));
    prefs();
    store.setItem('backmycodes_prefs', '{"autoLockMinutes":1}');
    prefs();

    expect(seen, [5, 60, 1]);
  });

  test('stores the account order the list was sorted by', () {
    notifier().update((prefs) => prefs.copyWith(accountSort: AccountSort.custom));

    expect(prefs().accountSort, AccountSort.custom);
    expect(jsonDecode(store.getItem('backmycodes_prefs')!), containsPair('accountSort', 'custom'));
  });

  test('records a backup at the time now', () {
    notifier().recordBackup();

    expect(prefs().lastBackupAt, _now.millisecondsSinceEpoch);
  });

  test('clears a date', () {
    notifier().update((prefs) => prefs.copyWith(backupNudgeDismissedAt: 5));
    notifier().update((prefs) => prefs.copyWith(backupNudgeDismissedAt: unset));

    expect(prefs().backupNudgeDismissedAt, isNull);
    expect(jsonDecode(store.getItem('backmycodes_prefs')!), containsPair('backupNudgeDismissedAt', null));
  });

  test('starts with the password leak check off, and writes it only once it is on', () {
    expect(prefs().leakCheck, isFalse);
    expect(prefs().toJson().containsKey('leakCheck'), isFalse);

    notifier().update((prefs) => prefs.copyWith(leakCheck: true));

    expect(prefs().leakCheck, isTrue);
    expect(store.getItem('backmycodes_prefs'), endsWith('"backupNudgeDismissedAt":null,"leakCheck":true}'));

    notifier().update((prefs) => prefs.copyWith(leakCheck: false));
    expect(store.getItem('backmycodes_prefs'), isNot(contains('leakCheck')));
  });

  test('reads the leak check, keeps the default for a wrong type, and keeps unknown keys beside it', () {
    store.setItem('backmycodes_prefs', '{"leakCheck":true,"later":{"a":1}}');
    expect(prefs().leakCheck, isTrue);
    expect(prefs().extra, {
      'later': {'a': 1},
    });

    store.setItem('backmycodes_prefs', '{"leakCheck":"yes"}');
    expect(prefs().leakCheck, isFalse);
  });

  test('keeps the leak check of each vault apart', () async {
    notifier().update((prefs) => prefs.copyWith(leakCheck: true));

    vaults().active = 'work';
    await pumpEventQueue();

    expect(prefs().leakCheck, isFalse);
  });

  test('starts with updates of the breach list off, and writes the setting only once it is on', () {
    expect(prefs().breachRefresh, isFalse);
    expect(prefs().toJson().containsKey('breachRefresh'), isFalse);

    notifier().update((prefs) => prefs.copyWith(breachRefresh: true, leakCheck: true));

    expect(prefs().breachRefresh, isTrue);
    expect(store.getItem('backmycodes_prefs'), endsWith('"backupNudgeDismissedAt":null,"leakCheck":true,"breachRefresh":true}'));

    notifier().update((prefs) => prefs.copyWith(breachRefresh: false));
    expect(store.getItem('backmycodes_prefs'), isNot(contains('breachRefresh')));
    expect(prefs().leakCheck, isTrue);
  });

  test('reads updates of the breach list, keeps the default for a wrong type, and keeps them per vault', () async {
    store.setItem('backmycodes_prefs', '{"breachRefresh":true,"later":1}');
    expect(prefs().breachRefresh, isTrue);
    expect(prefs().extra, {'later': 1});

    vaults().active = 'work';
    await pumpEventQueue();
    expect(prefs().breachRefresh, isFalse);

    store.setItem('backmycodes_prefs::work', '{"breachRefresh":1}');
    expect(prefs().breachRefresh, isFalse);
  });

  test("keeps each vault's settings apart", () async {
    notifier().update((prefs) => prefs.copyWith(autoLockMinutes: 15));

    vaults().active = 'work';
    await pumpEventQueue();
    expect(prefs().autoLockMinutes, 5);
    notifier().update((prefs) => prefs.copyWith(lockOnHide: true));
    expect(store.getItem('backmycodes_prefs::work'), isNotNull);

    vaults().active = mainVault;
    await pumpEventQueue();
    expect((prefs().autoLockMinutes, prefs().lockOnHide), (15, false));
  });

  test('writes to the vault just opened, even before the settings have caught up with it', () {
    store.setItem('backmycodes_prefs', '{"autoLockMinutes":15}');
    expect(prefs().autoLockMinutes, 15);

    vaults().active = 'work';
    notifier().update((prefs) => prefs.copyWith(lockOnHide: true));

    expect(jsonDecode(store.getItem('backmycodes_prefs::work')!), containsPair('autoLockMinutes', 5));
    expect(store.getItem('backmycodes_prefs'), '{"autoLockMinutes":15}');
  });

  test('clears the clipboard 30 seconds after a copy, and writes the delay only once it is another', () {
    expect((prefs().clearClipboard, prefs().clipboardClearSeconds, prefs().clipboardDelay), (true, 30, const Duration(seconds: 30)));
    expect(prefs().toJson().containsKey('clipboardClearSeconds'), isFalse);

    notifier().update((prefs) => prefs.copyWith(clipboardClearSeconds: 120));

    expect(prefs().clipboardDelay, const Duration(minutes: 2));
    expect(store.getItem('backmycodes_prefs'), endsWith('"backupNudgeDismissedAt":null,"clipboardClearSeconds":120}'));
    notifier().update((prefs) => prefs.copyWith(clipboardClearSeconds: 30));
    expect(store.getItem('backmycodes_prefs'), isNot(contains('clipboardClearSeconds')));
  });

  test('reads each delay Settings offers', () {
    for (final seconds in [10, 30, 60, 120]) {
      store.setItem('backmycodes_prefs', '{"clipboardClearSeconds":$seconds}');
      expect(prefs().clipboardDelay, Duration(seconds: seconds), reason: '$seconds');
    }
    expect(clipboardClearOptions, [10, 30, 60, 120]);
  });

  test('reads any other delay as 30 seconds', () {
    for (final raw in ['0', '-10', '45', '3600', '"60"', 'true', 'null', '[60]']) {
      store.setItem('backmycodes_prefs', '{"clipboardClearSeconds":$raw}');
      expect(prefs().clipboardClearSeconds, 30, reason: raw);
    }
    // A whole number written as a double is still that number
    store.setItem('backmycodes_prefs', '{"clipboardClearSeconds":60.0}');
    expect(prefs().clipboardClearSeconds, 60);
  });

  test('reads clearing turned off, as an earlier version wrote it, as never, whatever the delay', () {
    store.setItem('backmycodes_prefs', '{"clearClipboard":false}');
    expect(prefs().clipboardDelay, isNull);

    store.setItem('backmycodes_prefs', '{"clearClipboard":false,"clipboardClearSeconds":10}');
    expect(prefs().clipboardDelay, isNull);
    expect(prefs().clipboardClearSeconds, 10);
  });

  test('keeps the keys it does not know beside the delay', () {
    store.setItem('backmycodes_prefs', '{"clipboardClearSeconds":60,"universalClipboard":true}');

    notifier().update((prefs) => prefs.copyWith(lockOnHide: true));

    expect(jsonDecode(store.getItem('backmycodes_prefs')!), containsPair('universalClipboard', true));
    expect(jsonDecode(store.getItem('backmycodes_prefs')!), containsPair('clipboardClearSeconds', 60));
    expect(prefs().extra, {'universalClipboard': true});
  });

  // Written before this version knew the two settings, when it kept them as keys it doesn't know:
  // what a version with key reminders stored comes back as it was from one without them.
  test('keeps the key reminder settings another version stored, through reading, writing and a change', () {
    const stored = '{"keyReminders":true,"keyRemindersOffered":true}';

    final parsed = Prefs.parse(stored);
    expect(parsed.toJson(), containsPair('keyReminders', true));
    expect(parsed.toJson(), containsPair('keyRemindersOffered', true));
    expect(Prefs.parse(jsonEncode(parsed.toJson())), parsed);

    store.setItem('backmycodes_prefs', stored);
    notifier().update((prefs) => prefs.copyWith(lockOnHide: true));

    final written = jsonDecode(store.getItem('backmycodes_prefs')!) as Map<String, Object?>;
    expect(written, containsPair('keyReminders', true));
    expect(written, containsPair('keyRemindersOffered', true));
    expect(written, containsPair('lockOnHide', true));
  });

  test('starts with key reminders off and never offered, and writes each only once it is set', () {
    expect((prefs().keyReminders, prefs().keyRemindersOffered), (false, false));
    expect(prefs().toJson().keys, isNot(contains('keyReminders')));
    expect(prefs().toJson().keys, isNot(contains('keyRemindersOffered')));

    notifier().update((prefs) => prefs.copyWith(keyRemindersOffered: true));
    expect(store.getItem('backmycodes_prefs'), endsWith('"backupNudgeDismissedAt":null,"keyRemindersOffered":true}'));
    expect((prefs().keyReminders, prefs().keyRemindersOffered), (false, true));

    notifier().update((prefs) => prefs.copyWith(keyReminders: true));
    expect(store.getItem('backmycodes_prefs'), endsWith('"backupNudgeDismissedAt":null,"keyReminders":true,"keyRemindersOffered":true}'));
    expect((prefs().keyReminders, prefs().keyRemindersOffered), (true, true));
  });

  test('clears key reminders by leaving them out, and keeps that they were offered', () {
    notifier().update((prefs) => prefs.copyWith(keyReminders: true, keyRemindersOffered: true));

    notifier().update((prefs) => prefs.copyWith(keyReminders: false));

    expect(prefs().keyReminders, isFalse);
    expect(store.getItem('backmycodes_prefs'), isNot(contains('"keyReminders"')));
    expect(store.getItem('backmycodes_prefs'), endsWith('"backupNudgeDismissedAt":null,"keyRemindersOffered":true}'));

    notifier().update((prefs) => prefs.copyWith(keyRemindersOffered: false));
    expect(store.getItem('backmycodes_prefs'), isNot(contains('keyReminders')));
    expect(prefs(), Prefs.defaults);
  });

  test('reads key reminders, keeps the default for a wrong type, and no longer holds them as unknown keys', () {
    store.setItem('backmycodes_prefs', '{"keyReminders":true,"keyRemindersOffered":true,"later":1}');
    expect((prefs().keyReminders, prefs().keyRemindersOffered), (true, true));
    expect(prefs().extra, {'later': 1});
    expect(prefs(), isNot(Prefs.defaults));
    expect(prefs().hashCode, isNot(Prefs.defaults.hashCode));

    store.setItem('backmycodes_prefs', '{"keyReminders":"yes","keyRemindersOffered":1}');
    expect((prefs().keyReminders, prefs().keyRemindersOffered), (false, false));
  });

  test('keeps key reminders of each vault apart', () async {
    notifier().update((prefs) => prefs.copyWith(keyReminders: true, keyRemindersOffered: true));

    vaults().active = 'work';
    await pumpEventQueue();

    expect((prefs().keyReminders, prefs().keyRemindersOffered), (false, false));
  });

  test('prefs without key reminders write the same JSON as before they existed', () {
    const before =
        '{"clearClipboard":true,"lastBackupAt":1700000000000,"autoLockMinutes":15,"lockOnHide":true,'
        '"accountSort":"custom","backupNudgeDismissedAt":null,"autofill":true,"leakCheck":true,"clipboardClearSeconds":60,"theme":"x"}';

    expect(jsonEncode(Prefs.parse(before).toJson()), before);
    expect(jsonEncode(Prefs.defaults.toJson()), jsonEncode(const Prefs(keyReminders: false, keyRemindersOffered: false).toJson()));
    expect(
      jsonEncode(Prefs.defaults.toJson()),
      '{"clearClipboard":true,"lastBackupAt":null,"autoLockMinutes":5,"lockOnHide":false,"accountSort":"name","backupNudgeDismissedAt":null}',
    );
  });
}
