import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/keys/key_widgets.dart';
import 'package:kemlock/features/keys/verify_sheet.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/vault/vault_items.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../fakes/fake_reminders.dart';
import '../features/keys/expiry_kit.dart';
import '../features/keys/ssh_kit.dart';
import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';
import 'flow_kit.dart';

/// The Vault tab through the real router: reached from every other tab,
/// empty at first, and where a note is written and found again.
void main() {
  final search = find.descendant(of: find.byType(SearchField), matching: find.byType(TextField));

  Future<TestApp> openVault(WidgetTester tester) async {
    final app = await startApp(tester, TestApp());
    await createVault(tester);
    return app;
  }

  testWidgets('opens from each other tab and shows the empty vault', (tester) async {
    final app = await openVault(tester);

    for (final from in ['nav.codes', 'nav.backup', 'nav.settings']) {
      await tapOn(tester, tab(from));
      await tapOn(tester, tab('nav.vault'));

      expect(location(app), '/vault');
      expect(tester.getSemantics(tab('nav.vault')), selected);
      expect(tester.getSemantics(tab(from)), isNot(selected));
      expect(find.text(t('vault.empty.title')), findsOneWidget);
    }
  });

  testWidgets('the Add button on the Vault tab offers a new note', (tester) async {
    final app = await openVault(tester);
    await tapOn(tester, tab('nav.vault'));

    await tapOn(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));
    expect(find.text(t('vault.add.title')), findsWidgets);
    await tapOn(tester, find.text(t('vault.add.note')));

    expect(location(app), '/vault/notes/new');
    expect(find.text(t('notes.new')), findsOneWidget);
  });

  testWidgets('a note written on its page is listed and found by search', (tester) async {
    final app = await openVault(tester);
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.text(t('vault.empty.action')));
    await tapOn(tester, find.text(t('vault.add.note')));

    await tester.enterText(field(t('notes.field.title')), 'Passport');
    await tester.enterText(field(t('notes.field.text')), 'In the drawer, left side');
    await tapOn(tester, find.widgetWithText(FilledButton, t('notes.save')));

    expect(location(app), '/vault');
    expect(find.text('Passport'), findsOneWidget);
    expect(find.text('In the drawer, left side'), findsOneWidget);
    final notes = app.container.read(vaultControllerProvider).notes;
    expect(notes.single.title, 'Passport');
    // Nothing of it is stored in the clear
    expect(storedText(app), isNot(contains('Passport')));

    await tester.enterText(search, 'drawer');
    await tester.pumpAndSettle();
    expect(find.text('Passport'), findsOneWidget);
    await tester.enterText(search, 'safe');
    await tester.pumpAndSettle();
    expect(find.text('Passport'), findsNothing);
    expect(find.text(t('vault.noMatches.title', {'query': 'safe'})), findsOneWidget);
  });

  testWidgets('a note opens again from the list', (tester) async {
    final app = await openVault(tester);
    await app.container
        .read(vaultControllerProvider.notifier)
        .addNote(const SecureNote(id: 'n1', title: 'Wi-Fi', text: 'hunter2', addedAt: 0));
    await tapOn(tester, tab('nav.vault'));

    await tapOn(tester, find.text('Wi-Fi'));

    expect(location(app), '/vault/notes/n1');
    expect(find.widgetWithText(TextField, 'hunter2'), findsOneWidget);
  });

  testWidgets('"Add to vault" says how passkeys are added', (tester) async {
    await openVault(tester);
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));

    await tapOn(tester, find.text(t('vault.add.passkey')));

    expect(find.text(t('passkeys.how.title')), findsWidgets);
    expect(find.text(t('passkeys.how.create')), findsOneWidget);
    expect(find.text(t('passkeys.how.import')), findsOneWidget);
    await tapOn(tester, find.text(t('passkeys.how.done')));
    expect(find.text(t('passkeys.how.create')), findsNothing);
  });

  group('PGP keys that expire or were revoked', () {
    // A week before the `future` key expires, long after the `expired` ones did
    final weekBefore = futureExpiry.subtract(const Duration(days: 7));
    Finder row(String name) => find.byKey(ValueKey('key:pgp-$name'));
    Finder inRow(String name, Finder what) => find.descendant(of: row(name), matching: what);
    Finder tagOf(String name) => inRow(name, find.byType(KeyStandingTag));
    Finder filter(String id) => find.descendant(of: find.byType(SegmentedControl<VaultFilter>), matching: find.text(t(id)));

    /// The app a week before the `future` key expires, with [keys] in its vault, on the Vault tab.
    Future<TestApp> openWith(WidgetTester tester, List<VaultKey> keys) async {
      final app = await startApp(tester, TestApp(now: () => weekBefore));
      await createVault(tester);
      for (final key in keys) {
        expect(await app.controller.addKey(key), isTrue);
      }
      await tapOn(tester, tab('nav.vault'));
      return app;
    }

    Future<List<VaultKey>> fixtures(List<String> names) async => [for (final name in names) await expiryFixtureKey(name)];

    testWidgets('each carries a tag saying so; a key in order and an SSH key carry none', (tester) async {
      await openWith(tester, [
        ...await fixtures(['expired', 'revoked', 'revoked-expired', 'future', 'never', 'subkey-expired']),
        sshKey(),
      ]);

      expect(inRow('expired', find.text(t('keys.standing.expired').toUpperCase())), findsOneWidget);
      expect(inRow('revoked', find.text(t('keys.standing.revoked').toUpperCase())), findsOneWidget);
      // Revoked wins over expired
      expect(inRow('revoked-expired', find.text(t('keys.standing.revoked').toUpperCase())), findsOneWidget);
      expect(inRow('future', find.text('EXPIRES IN 7 DAYS')), findsOneWidget);
      expect(tester.widget<StatusTag>(inRow('future', find.byType(StatusTag))).tone, StatusTone.warning);
      expect(tester.widget<StatusTag>(inRow('expired', find.byType(StatusTag))).tone, StatusTone.danger);

      expect(tagOf('never'), findsNothing);
      // Its encryption subkey expired, which its sheet explains
      expect(tagOf('subkey-expired'), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('key:ssh-1')), matching: find.byType(StatusTag)), findsNothing);
      expect(find.byType(StatusTag), findsNWidgets(4));
    });

    testWidgets('a tagged key still opens its sheet, and is read out with its tag', (tester) async {
      final semantics = tester.ensureSemantics();
      await openWith(tester, await fixtures(['revoked']));

      expect(tester.getSemantics(find.text('revoked')), isSemantics(isButton: true, label: 'revoked\nOpenPGP\nRevoked'));
      await tapOn(tester, find.text('revoked'));

      expect(find.text(t('keys.private.title').toUpperCase()), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('searching "expired" and "revoked" finds the keys tagged so', (tester) async {
      await openWith(tester, await fixtures(['expired', 'revoked', 'future', 'never']));

      await tester.enterText(search, 'expired');
      await tester.pumpAndSettle();
      expect(row('expired'), findsOneWidget);
      for (final name in ['revoked', 'future', 'never']) {
        expect(row(name), findsNothing, reason: name);
      }

      await tester.enterText(search, 'Revoked');
      await tester.pumpAndSettle();
      expect(row('revoked'), findsOneWidget);
      for (final name in ['expired', 'future', 'never']) {
        expect(row(name), findsNothing, reason: name);
      }

      await tester.enterText(search, 'expires in');
      await tester.pumpAndSettle();
      expect(row('future'), findsOneWidget);
      expect(row('expired'), findsNothing);
    });

    testWidgets('a tag follows the clock: the key that had a week left has expired', (tester) async {
      var now = weekBefore;
      final app = await startApp(tester, TestApp(now: () => now));
      await createVault(tester);
      await app.controller.addKey(await expiryFixtureKey('future'));
      await tapOn(tester, tab('nav.vault'));
      expect(inRow('future', find.text('EXPIRES IN 7 DAYS')), findsOneWidget);

      now = futureExpiry.add(const Duration(seconds: 1));
      await tapOn(tester, tab('nav.settings'));
      await tapOn(tester, tab('nav.vault'));

      expect(inRow('future', find.text(t('keys.standing.expired').toUpperCase())), findsOneWidget);
      // Nothing of the standing is kept with the key
      expect(app.state.keys.single.toJson().keys, isNot(contains('standing')));
    });

    testWidgets('the Keys filter lists them together under "PGP keys", pinned first, with their address and algorithm', (tester) async {
      await openWith(tester, [
        await expiryFixtureKey('revoked', title: 'Old work key'),
        await expiryFixtureKey('future', title: 'Ada Lovelace'),
        await expiryFixtureKey('never', title: 'Zed', pinned: true),
        sshKey(),
      ]);
      // Under All, nothing is grouped: the keys sit with the rest, as before
      expect(find.text(t('vault.section.pgp').toUpperCase()), findsNothing);
      expect(find.text(t('accounts.section.pinned').toUpperCase()), findsOneWidget);
      expect(find.text(t('vault.section.all').toUpperCase()), findsOneWidget);
      expect(inRow('future', find.text('OpenPGP')), findsOneWidget);
      expect(find.text('PGP'), findsNothing);

      await tapOn(tester, filter('vault.filter.keys'));

      expect(find.text(t('vault.section.pgp').toUpperCase()), findsOneWidget);
      final group = find.byKey(const ValueKey('pgp-keys'));
      expect(find.descendant(of: group, matching: find.byType(GroupRow)), findsNWidgets(3));
      // The pinned key first, then by name
      final names = [
        for (final row in tester.widgetList<GroupRow>(find.descendant(of: group, matching: find.byType(GroupRow)))) row.primary,
      ];
      expect(names, ['Zed', 'Ada Lovelace', 'Old work key']);
      expect(find.descendant(of: group, matching: find.text('PGP')), findsNWidgets(3));
      expect(inRow('future', find.text('future@example.org · Ed25519')), findsOneWidget);
      expect(inRow('revoked', find.text('revoked@example.org · Ed25519')), findsOneWidget);
      expect(inRow('future', find.text('EXPIRES IN 7 DAYS')), findsOneWidget);
      expect(inRow('revoked', find.text('REVOKED')), findsOneWidget);
      // A key that is over is written faint, on a plain tile
      expect((tester.widget<GroupRow>(row('revoked')).muted, tester.widget<GroupRow>(row('revoked')).accent), (true, false));
      expect((tester.widget<GroupRow>(row('future')).muted, tester.widget<GroupRow>(row('future')).accent), (false, true));
      // The SSH key is listed after them, outside the group, under its own label
      expect(find.text(t('vault.section.ssh').toUpperCase()), findsOneWidget);
      expect(find.text(t('vault.section.otherKeys').toUpperCase()), findsNothing);
      expect(find.descendant(of: group, matching: find.text('laptop')), findsNothing);
      expect(find.text('laptop'), findsOneWidget);
      expect(find.text(t('accounts.section.pinned').toUpperCase()), findsNothing);

      await tapOn(tester, find.descendant(of: group, matching: find.text('Ada Lovelace')));
      expect(find.text(t('keys.private.title').toUpperCase()), findsOneWidget);
    });

    testWidgets('going back to All puts them with the rest again', (tester) async {
      await openWith(tester, await fixtures(['never']));

      await tapOn(tester, filter('vault.filter.keys'));
      expect(find.text(t('vault.section.pgp').toUpperCase()), findsOneWidget);
      // Nothing but PGP keys: no second group under them
      expect(find.text(t('vault.section.otherKeys').toUpperCase()), findsNothing);
      expect(find.text(t('vault.section.all').toUpperCase()), findsNothing);

      await tapOn(tester, filter('vault.filter.all'));
      expect(find.text(t('vault.section.pgp').toUpperCase()), findsNothing);
      expect(find.text(t('vault.section.all').toUpperCase()), findsOneWidget);
    });

    testWidgets('a vault with no PGP key shows no "PGP keys" label under the Keys filter', (tester) async {
      await openWith(tester, [sshKey()]);

      await tapOn(tester, filter('vault.filter.keys'));

      expect(find.text(t('vault.section.pgp').toUpperCase()), findsNothing);
      expect(find.text(t('vault.section.otherKeys').toUpperCase()), findsNothing);
      // Nothing but an SSH key: it sits under its own label, with no second one
      expect(find.text(t('vault.section.ssh').toUpperCase()), findsOneWidget);
      expect(find.text(t('vault.section.all').toUpperCase()), findsNothing);
      expect(find.text('laptop'), findsOneWidget);
    });
  });

  group('the offer to warn before a key expires', () {
    final dayBefore8 = futureExpiry.subtract(const Duration(days: 8));
    final offer = find.byKey(const ValueKey('key-reminders-offer'));
    final accept = find.widgetWithText(TextButton, t('keys.reminders.offer.accept'));
    final dismiss = find.widgetWithText(TextButton, t('keys.reminders.offer.dismiss'));

    /// The app eight days before the `future` key expires, [keys] in its vault, on the Vault tab.
    Future<TestApp> openWith(WidgetTester tester, List<String> keys, {bool granted = true}) async {
      final app = await startApp(
        tester,
        TestApp(
          now: () => dayBefore8,
          reminders: FakeReminders(granted: granted),
        ),
      );
      await createVault(tester);
      for (final name in keys) {
        expect(await app.controller.addKey(await expiryFixtureKey(name)), isTrue);
      }
      // The toast of the last key would sit over the buttons
      await tester.pump(const Duration(seconds: 10));
      await tapOn(tester, tab('nav.vault'));
      return app;
    }

    Map<String, Object?> prefs(TestApp app) => jsonDecode(app.store.getItem(prefsKey) ?? '{}') as Map<String, Object?>;

    testWidgets('is made for a key with an expiry ahead, saying what the notification holds back', (tester) async {
      final app = await openWith(tester, ['future']);

      expect(offer, findsOneWidget);
      expect(find.text(t('keys.reminders.offer.title')), findsOneWidget);
      expect(find.text(t('keys.reminders.offer.body')), findsOneWidget);
      expect(t('keys.reminders.offer.body'), contains('names no key'));
      // Nothing is asked of the phone before the person answers
      expect(app.reminders.permissionRequests, 0);
      expect(app.reminders.scheduled, isEmpty);
    });

    testWidgets('accepting asks the phone, turns reminders on and schedules them, and the card is gone', (tester) async {
      final app = await openWith(tester, ['future']);

      await tapOn(tester, accept);

      expect(app.reminders.permissionRequests, 1);
      expect(prefs(app), allOf(containsPair('keyReminders', true), containsPair('keyRemindersOffered', true)));
      expect(
        [for (final reminder in app.reminders.inOrder) reminder.body],
        ['1 key expires in 7 days', '1 key expires tomorrow', '1 key expires today'],
      );
      expect(offer, findsNothing);
    });

    testWidgets('"Not now" puts it away for good: another expiring key brings no second offer', (tester) async {
      var app = await openWith(tester, ['future']);

      await tapOn(tester, dismiss);

      expect(offer, findsNothing);
      expect(prefs(app), containsPair('keyRemindersOffered', true));
      expect(prefs(app).containsKey('keyReminders'), isFalse);
      expect(app.reminders.permissionRequests, 0);

      // Another key with an expiry ahead; the fixture's own pair is in the vault already
      await app.controller.applySynced(
        Lists(
          keys: [
            ...app.state.keys,
            (await expiryFixtureKey('future')).copyWith(id: 'second', name: 'Second'),
          ],
        ),
      );
      await tester.pump(const Duration(seconds: 10));
      await tapOn(tester, tab('nav.settings'));
      await tapOn(tester, tab('nav.vault'));
      expect(offer, findsNothing);

      app = await app.restart(tester);
      await app.unlock(tester, masterPassword);
      await tapOn(tester, tab('nav.vault'));
      expect(offer, findsNothing);
      expect(app.reminders.scheduled, isEmpty);
    });

    testWidgets('accepting when the phone refuses leaves reminders off, says why, and does not ask again', (tester) async {
      final app = await openWith(tester, ['future'], granted: false);

      await tapOn(tester, accept);

      expect(find.text(t('settings.keyReminders.denied')), findsOneWidget);
      expect(prefs(app), containsPair('keyRemindersOffered', true));
      expect(prefs(app).containsKey('keyReminders'), isFalse);
      expect(app.reminders.scheduled, isEmpty);
      expect(offer, findsNothing);
    });

    testWidgets('is not made for a vault whose keys never expire, have expired or were revoked', (tester) async {
      final app = await openWith(tester, ['never', 'expired', 'revoked', 'subkey-expired']);
      await app.controller.addKey(sshKey());
      await tester.pumpAndSettle();

      expect(offer, findsNothing);
      expect(prefs(app).containsKey('keyRemindersOffered'), isFalse);
    });

    testWidgets('is not made once reminders are on', (tester) async {
      final app = await startApp(tester, TestApp(now: () => dayBefore8));
      await createVault(tester);
      app.store.setItem(prefsKey, '{"keyReminders":true}');
      await app.controller.addKey(await expiryFixtureKey('future'));

      await tapOn(tester, tab('nav.vault'));

      expect(offer, findsNothing);
      expect(app.reminders.scheduled, hasLength(3));
    });

    testWidgets('is never made in a hidden vault, whose expiring key is tagged all the same', (tester) async {
      final app = await openWith(tester, ['future']);
      expect(offer, findsOneWidget);

      app.vaults.setListed(mainVault, false);
      app.controller.vaultChanged();
      await tester.pumpAndSettle();

      expect(app.state.vault.hidden, isTrue);
      expect(offer, findsNothing);
      expect(find.text('EXPIRES IN 8 DAYS'), findsOneWidget);
      expect(app.reminders.scheduled, isEmpty);
      expect(app.reminders.permissionRequests, 0);
    });
  });

  group('SSH keys', () {
    final print = sshFixtureFingerprints['ed25519']!;
    Finder row(String name) => find.byKey(ValueKey('key:ssh-$name'));
    Finder inRow(String name, Finder what) => find.descendant(of: row(name), matching: what);
    Finder filter(String id) => find.descendant(of: find.byType(SegmentedControl<VaultFilter>), matching: find.text(t(id)));
    final group = find.byKey(const ValueKey('ssh-keys'));

    /// A key of test/fixtures/keys/openssl as the vault keeps an imported one.
    Future<VaultKey> opensslKey(String file, String name) async => vaultKeyOf(
      await crypto.readPrivateKey(File('test/fixtures/keys/openssl/$file').readAsBytesSync()),
      id: name,
      name: name,
      origin: KeyOrigin.imported,
    );

    Future<TestApp> openWith(WidgetTester tester, List<VaultKey> keys) async {
      final app = await startApp(tester, TestApp());
      await createVault(tester);
      for (final key in keys) {
        expect(await app.controller.addKey(key), isTrue);
      }
      await tapOn(tester, tab('nav.vault'));
      return app;
    }

    testWidgets('sit under "SSH keys" in the Keys filter, each with an SSH tile and its fingerprint shortened', (tester) async {
      await openWith(tester, [
        await sshFixtureKey('ed25519', title: 'laptop'),
        await sshFixtureKey('rsa3072', title: 'Server'),
        await opensslKey('ed25519.pkcs8.pem', 'release signing'),
      ]);
      // Under All nothing is grouped or labelled, and the row is the same
      expect(find.text(t('vault.section.ssh').toUpperCase()), findsNothing);
      expect(group, findsNothing);
      expect(inRow('ed25519', find.text('SHA256:41s5…UAW4')), findsOneWidget);
      expect(inRow('ed25519', find.text(t('keys.ssh.tile'))), findsOneWidget);

      await tapOn(tester, filter('vault.filter.keys'));

      expect(find.text(t('vault.section.ssh').toUpperCase()), findsOneWidget);
      final names = [
        for (final row in tester.widgetList<GroupRow>(find.descendant(of: group, matching: find.byType(GroupRow)))) row.primary,
      ];
      expect(names, ['laptop', 'Server']);
      expect(find.descendant(of: group, matching: find.text(t('keys.ssh.tile'))), findsNWidgets(2));
      expect(inRow('ed25519', find.text('SHA256:41s5…UAW4')), findsOneWidget);
      expect(inRow('rsa3072', find.text('SHA256:mbgQ…g2bM')), findsOneWidget);
      // The fingerprint is in the monospace face, and the algorithm is no longer in the row
      expect(tester.widget<Text>(inRow('ed25519', find.text('SHA256:41s5…UAW4'))).style!.fontFamily, fontMono);
      expect(inRow('ed25519', find.text('Ed25519')), findsNothing);
      expect(inRow('ed25519', find.byIcon(Icons.chevron_right_rounded)), findsOneWidget);
      // The signing key comes after, outside the group, as it was
      expect(find.text(t('vault.section.otherKeys').toUpperCase()), findsOneWidget);
      expect(find.descendant(of: group, matching: find.text('release signing')), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('key:release signing')), matching: find.text('Ed25519')), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('key:release signing')), matching: find.byIcon(Icons.key_rounded)),
        findsOneWidget,
      );

      await tapOn(tester, find.descendant(of: group, matching: find.text('laptop')));
      expect(find.text(t('keys.private.title').toUpperCase()), findsOneWidget);
      expect(find.text(print), findsOneWidget);
    });

    testWidgets('a pinned SSH key stays with the pinned items, with the same row', (tester) async {
      await openWith(tester, [
        await sshFixtureKey('ed25519', title: 'laptop', pinned: true),
        await sshFixtureKey('rsa3072', title: 'Server'),
      ]);
      await tapOn(tester, filter('vault.filter.keys'));

      expect(find.text(t('accounts.section.pinned').toUpperCase()), findsOneWidget);
      expect(find.descendant(of: group, matching: find.text('laptop')), findsNothing);
      expect(find.descendant(of: group, matching: find.text('Server')), findsOneWidget);
      expect(inRow('ed25519', find.text('SHA256:41s5…UAW4')), findsOneWidget);
      expect(inRow('ed25519', find.text(t('keys.ssh.tile'))), findsOneWidget);
    });

    testWidgets('is found by its whole fingerprint and by its algorithm, in one list of results', (tester) async {
      await openWith(tester, [await sshFixtureKey('ed25519', title: 'laptop'), await sshFixtureKey('rsa3072', title: 'Server')]);
      await tapOn(tester, filter('vault.filter.keys'));

      await tester.enterText(search, print);
      await tester.pumpAndSettle();
      expect(row('ed25519'), findsOneWidget);
      expect(row('rsa3072'), findsNothing);
      expect(find.text(t('vault.section.ssh').toUpperCase()), findsNothing);
      expect(find.text(t('accounts.section.results').toUpperCase()), findsOneWidget);

      await tester.enterText(search, 'Ed25519');
      await tester.pumpAndSettle();
      expect(row('ed25519'), findsOneWidget);
      expect(row('rsa3072'), findsNothing);

      await tester.enterText(search, 'rsa 3072');
      await tester.pumpAndSettle();
      expect(row('rsa3072'), findsOneWidget);
      expect(row('ed25519'), findsNothing);
    });

    testWidgets('is read out with its whole fingerprint, not the shortened one', (tester) async {
      final semantics = tester.ensureSemantics();
      await openWith(tester, [await sshFixtureKey('ed25519', title: 'laptop')]);
      await tapOn(tester, filter('vault.filter.keys'));

      expect(tester.getSemantics(find.text('laptop')), isSemantics(isButton: true, label: 'laptop\n$print'));
      semantics.dispose();
    });

    testWidgets('signing, exchange and PGP rows are as they were', (tester) async {
      await openWith(tester, [
        await sshFixtureKey('ed25519', title: 'laptop'),
        await opensslKey('ed25519.pkcs8.pem', 'release signing'),
        await opensslKey('x25519.pkcs8.pem', 'exchange'),
        await expiryFixtureKey('never'),
      ]);
      await tapOn(tester, filter('vault.filter.keys'));

      for (final (id, line) in [('release signing', 'Ed25519'), ('exchange', 'X25519')]) {
        final other = find.byKey(ValueKey('key:$id'));
        expect(find.descendant(of: other, matching: find.text(line)), findsOneWidget);
        expect(find.descendant(of: other, matching: find.byIcon(Icons.key_rounded)), findsOneWidget);
        expect(find.descendant(of: other, matching: find.text(t('keys.ssh.tile'))), findsNothing);
        expect(tester.widget<GroupRow>(other).secondarySemanticsLabel, isNull);
      }
      final pgp = find.byKey(const ValueKey('key:pgp-never'));
      expect(find.descendant(of: pgp, matching: find.text('PGP')), findsOneWidget);
      expect(find.descendant(of: pgp, matching: find.text('never@example.org · Ed25519')), findsOneWidget);
      expect(find.descendant(of: group, matching: find.byType(GroupRow)), findsOneWidget);
    });

    testWidgets('the Keys filter ends with "Verify an SSH signature", which opens the verify sheet; no other filter has it', (
      tester,
    ) async {
      final entry = find.byKey(const ValueKey('verify-ssh'));
      final app = await openWith(tester, [await sshFixtureKey('ed25519', title: 'laptop'), await expiryFixtureKey('never')]);
      await app.controller.addNote(const SecureNote(id: 'n1', title: 'Wi-Fi', text: 'hunter2', addedAt: 0));
      await tester.pumpAndSettle();
      expect(entry, findsNothing);

      for (final other in ['vault.filter.notes', 'vault.filter.passkeys', 'vault.filter.all']) {
        await tapOn(tester, filter(other));
        expect(entry, findsNothing, reason: other);
        expect(find.text(t('keys.verify.entry')), findsNothing, reason: other);
      }

      await tapOn(tester, filter('vault.filter.keys'));
      expect(find.descendant(of: entry, matching: find.text(t('keys.verify.entry'))), findsOneWidget);
      // After every key
      expect(tester.getTopLeft(entry).dy, greaterThan(tester.getBottomLeft(group).dy));
      expect(tester.getTopLeft(entry).dy, greaterThan(tester.getBottomLeft(find.byKey(const ValueKey('pgp-keys'))).dy));

      await tapOn(tester, find.text(t('keys.verify.entry')));
      expect(find.byType(VerifySheet), findsOneWidget);
      // The page behind has the PGP actions' own Verify button
      expect(find.descendant(of: find.byType(VerifySheet), matching: find.text(t('keys.verify.submit'))), findsOneWidget);
    });

    testWidgets('a vault with no key at all still offers to verify an SSH signature under the Keys filter', (tester) async {
      final app = await openWith(tester, const []);
      await app.controller.addNote(const SecureNote(id: 'n1', title: 'Wi-Fi', text: 'hunter2', addedAt: 0));
      await tester.pumpAndSettle();

      await tapOn(tester, filter('vault.filter.keys'));

      expect(find.text(t('vault.noneOfKind')), findsOneWidget);
      expect(find.text(t('vault.section.ssh').toUpperCase()), findsNothing);
      await tapOn(tester, find.text(t('keys.verify.entry')));
      expect(find.byType(VerifySheet), findsOneWidget);
    });
  });
}
