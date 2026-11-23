import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/features/contacts/add_contact_sheet.dart';
import 'package:kemlock/features/contacts/contact_sheet.dart';
import 'package:kemlock/features/keys/key_standing.dart';
import 'package:kemlock/features/vault/add_to_vault_sheet.dart';
import 'package:kemlock/features/vault/vault_items.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/test_app.dart';
import '../contacts/contacts_app.dart';
import '../contacts/contacts_kit.dart';

const _notes = [
  SecureNote(id: 'n1', title: 'wi-fi', text: 'hunter2', addedAt: 3),
  SecureNote(
    id: 'n2',
    title: 'Passport',
    text: 'In the drawer\nleft side',
    tags: ['travel'],
    addedAt: 2,
    attachments: [NoteAttachment(id: 'f1', name: 'passport-scan.pdf', size: 1, key: 'AA==', addedAt: 2)],
  ),
  SecureNote(id: 'n3', title: 'Alarm code', text: '4711', pinned: true, addedAt: 1),
  SecureNote(id: 'n4', title: 'Bank', text: 'Branch 12', pinned: true, tags: ['money'], addedAt: 4),
];

const _state = VaultState(
  phase: VaultPhase.unlocked,
  notes: _notes,
  vault: VaultInfo(id: 'main'),
);

List<String> _titles(List<VaultListItem> items) => [for (final item in items) item.title];

void main() {
  group('the Vault tab list', () {
    test('puts pinned items first, each part by name whatever the case', () {
      final items = vaultListItems(_state);

      expect(_titles(items.pinned), ['Alarm code', 'Bank']);
      expect(_titles(items.rest), ['Passport', 'wi-fi']);
      expect(items.total, 4);
    });

    test("shows a note's first line under its title", () {
      final passport = vaultListItems(_state).rest.first;

      expect(passport.subtitle, 'In the drawer');
      expect(passport.kind, VaultItemKind.note);
    });

    for (final (field, query, found) in [
      ('title', 'passport', ['Passport']),
      ('text', 'drawer', ['Passport']),
      ('text, across lines', 'left', ['Passport']),
      ('tags', 'money', ['Bank']),
      ('every word', 'branch bank', ['Bank']),
      ("attached files' names", 'scan', ['Passport']),
    ]) {
      test('searches the $field', () {
        final items = vaultListItems(_state, query: query);

        expect([..._titles(items.pinned), ..._titles(items.rest)], found);
        // The total is the whole vault's, not the results'
        expect(items.total, 4);
      });
    }

    test('finds nothing for words no item holds', () {
      final items = vaultListItems(_state, query: 'safe');

      expect(items.pinned, isEmpty);
      expect(items.rest, isEmpty);
    });

    test('filters by kind', () {
      expect(vaultListItems(_state, filter: VaultFilter.notes).rest, hasLength(2));
      expect(vaultListItems(_state, filter: VaultFilter.keys).rest, isEmpty);
      expect(vaultListItems(_state, filter: VaultFilter.passkeys).pinned, isEmpty);
    });
  });

  group('keys on the Vault tab list', () {
    VaultKey key(String id, String name, {String kind = KeyKind.pgp, bool pinned = false}) => VaultKey(
      id: id,
      name: name,
      kind: kind,
      algorithm: kind == KeyKind.pgp ? 'pgp' : 'ed25519',
      privateKey: 'AA==',
      publicKey: 'AA==',
      origin: KeyOrigin.imported,
      pinned: pinned ? true : null,
      addedAt: 0,
    );

    final expires = DateTime.utc(2026, 11, 23);
    final state = VaultState(
      phase: VaultPhase.unlocked,
      notes: _notes,
      keys: [
        key('k-old', 'Old work key'),
        key('k-ada', 'Ada Lovelace'),
        key('k-soon', 'Soon'),
        key('k-fine', 'Fine', pinned: true),
        key('k-sub', 'Subkey only'),
        key('k-ssh', 'laptop', kind: KeyKind.ssh),
        key('k-ssh2', 'bastion', kind: KeyKind.ssh, pinned: true),
      ],
      vault: const VaultInfo(id: 'main'),
    );
    final listings = {
      'k-old': const KeyListing(
        standing: KeyStanding(standing: Standing.revoked),
        tag: 'Revoked',
        pgpLine: 'ada@oldjob.example · RSA 4096',
      ),
      'k-ada': KeyListing(
        standing: KeyStanding(standing: Standing.expired, expires: expires),
        tag: 'Expired',
        pgpLine: 'ada@example.org · Ed25519',
      ),
      'k-soon': KeyListing(
        standing: KeyStanding(standing: Standing.expiringSoon, expires: expires, daysLeft: 7),
        tag: 'Expires in 7 days',
        pgpLine: 'soon@example.org · Ed25519',
      ),
      'k-fine': const KeyListing(standing: KeyStanding.ok, pgpLine: 'fine@example.org · Ed25519'),
      'k-sub': const KeyListing(
        standing: KeyStanding(
          standing: Standing.ok,
          subkeys: [KeyStanding(standing: Standing.expired)],
        ),
        pgpLine: 'sub@example.org · Ed25519',
      ),
    };
    List<VaultListItem> everything(
      ({
        List<VaultListItem> pgp,
        List<VaultListItem> ssh,
        List<VaultListItem> pinned,
        List<VaultListItem> rest,
        List<VaultListItem> contacts,
        int total,
      })
      items,
    ) => [...items.pgp, ...items.ssh, ...items.pinned, ...items.rest];

    test('a key that is expired, revoked or expiring carries its tag; one in order and an SSH key carry none', () {
      final byTitle = {for (final item in everything(vaultListItems(state, keyListings: listings))) item.title: item};

      expect(byTitle['Old work key']!.tag, 'Revoked');
      expect(byTitle['Ada Lovelace']!.tag, 'Expired');
      expect(byTitle['Soon']!.tag, 'Expires in 7 days');
      expect(byTitle['Soon']!.standing!.daysLeft, 7);
      expect(byTitle['Fine']!.tag, isNull);
      expect(byTitle['laptop']!.tag, isNull);
      expect(byTitle['laptop']!.standing, isNull);
    });

    test('a key whose subkey alone expired has no tag', () {
      final item = everything(vaultListItems(state, keyListings: listings)).firstWhere((item) => item.title == 'Subkey only');

      expect(item.tag, isNull);
      expect(item.standing!.subkeyProblem, Standing.expired);
    });

    for (final (query, found) in [
      ('expired', ['Ada Lovelace']),
      ('revoked', ['Old work key']),
      ('REVOKED', ['Old work key']),
      ('expires', ['Soon']),
      ('7 days', ['Soon']),
      ('oldjob', ['Old work key']),
      ('ada@example.org', ['Ada Lovelace']),
    ]) {
      test('searching "$query" finds the keys tagged or addressed so', () {
        expect(_titles(everything(vaultListItems(state, query: query, keyListings: listings))), found);
      });
    }

    test('a key with no listing is listed as before, by its name and algorithm', () {
      final item = everything(vaultListItems(state)).firstWhere((item) => item.title == 'Ada Lovelace');

      expect((item.subtitle, item.tag, item.standing, item.isPgp), ('OpenPGP', null, null, true));
      expect(_titles(everything(vaultListItems(state, query: 'expired'))), isEmpty);
    });

    test('the Keys filter lists the PGP keys in a group of their own, the pinned ones first, then by name', () {
      final items = vaultListItems(state, filter: VaultFilter.keys, keyListings: listings);

      expect(_titles(items.pgp), ['Fine', 'Ada Lovelace', 'Old work key', 'Soon', 'Subkey only']);
      expect(items.pgp.first.pgpLine, 'fine@example.org · Ed25519');
      // The SSH keys have their own group, but for the pinned one
      expect(_titles(items.pinned), ['bastion']);
      expect(_titles(items.ssh), ['laptop']);
      expect(items.rest, isEmpty);
      expect(items.total, 11);
    });

    test('the Keys filter searches inside the group', () {
      final items = vaultListItems(state, filter: VaultFilter.keys, query: 'revoked', keyListings: listings);

      expect(_titles(items.pgp), ['Old work key']);
      expect(items.pinned, isEmpty);
      expect(items.rest, isEmpty);
    });

    test('every other filter leaves the PGP keys where they were', () {
      final all = vaultListItems(state, keyListings: listings);
      expect(all.pgp, isEmpty);
      expect(_titles(all.pinned), ['Alarm code', 'Bank', 'bastion', 'Fine']);
      expect(_titles(all.rest), ['Ada Lovelace', 'laptop', 'Old work key', 'Passport', 'Soon', 'Subkey only', 'wi-fi']);

      expect(vaultListItems(state, filter: VaultFilter.notes, keyListings: listings).pgp, isEmpty);
      expect(vaultListItems(state, filter: VaultFilter.passkeys, keyListings: listings).pgp, isEmpty);
    });

    test('a vault with no PGP key has no group', () {
      final sshOnly = VaultState(
        phase: VaultPhase.unlocked,
        keys: [key('k-ssh', 'laptop', kind: KeyKind.ssh)],
        vault: const VaultInfo(id: 'main'),
      );

      final items = vaultListItems(sshOnly, filter: VaultFilter.keys);
      expect(items.pgp, isEmpty);
      expect(_titles(items.ssh), ['laptop']);
      expect(items.rest, isEmpty);
    });
  });

  group('keys on a security key on the Vault tab list', () {
    VaultKey key(String id, String name, {bool onCard = false}) => VaultKey(
      id: id,
      name: name,
      kind: KeyKind.pgp,
      algorithm: 'pgp',
      privateKey: 'AA==',
      publicKey: 'AA==',
      origin: KeyOrigin.imported,
      addedAt: 0,
      card: onCard ? const {'aid': 'D276000124010304FFFF123456780000', 'slots': <String, Object?>{}} : null,
    );

    final state = VaultState(
      phase: VaultPhase.unlocked,
      keys: [key('k-card', 'Card key', onCard: true), key('k-soon', 'Card key expiring', onCard: true), key('k-file', 'File key')],
      vault: const VaultInfo(id: 'main'),
    );
    final listings = {
      'k-card': const KeyListing(standing: KeyStanding.ok, cardTag: 'On your key', cardWords: 'security key card'),
      'k-soon': KeyListing(
        standing: KeyStanding(standing: Standing.expiringSoon, expires: DateTime.utc(2026, 11, 23), daysLeft: 7),
        tag: 'Expires in 7 days',
        cardTag: 'On your key',
        cardWords: 'security key card',
      ),
      'k-file': const KeyListing(standing: KeyStanding.ok),
    };
    Map<String, VaultListItem> byTitle([String query = '']) => {
      for (final item in vaultListItems(state, filter: VaultFilter.keys, query: query, keyListings: listings).pgp) item.title: item,
    };

    test('carry the "On your key" tag, and a key in the vault none', () {
      final items = byTitle();

      expect(items['Card key']!.cardTag, 'On your key');
      expect(items['Card key']!.tag, isNull);
      expect(items['File key']!.cardTag, isNull);
    });

    test('carry their expiry tag beside it', () {
      final item = byTitle()['Card key expiring']!;

      expect(item.cardTag, 'On your key');
      expect(item.tag, 'Expires in 7 days');
    });

    for (final query in ['on your key', 'ON YOUR KEY', 'security key', 'card']) {
      test('are found by "$query"', () {
        expect(byTitle(query).keys, unorderedEquals(['Card key', 'Card key expiring']));
      });
    }
  });

  group('SSH keys on the Vault tab list', () {
    const laptopPrint = 'SHA256:41s5PBHoZEOR0cJ/tvgDufVKulMqGbNyELiLyECUAW4';
    const serverPrint = 'SHA256:mbgQkBCI/n6+2Z/EVBwEvUdGixwoFo5k7g+teZng2bM';
    VaultKey key(String id, String name, String kind, {String algorithm = 'ed25519', int? bits, bool pinned = false}) => VaultKey(
      id: id,
      name: name,
      kind: kind,
      algorithm: algorithm,
      bits: bits,
      privateKey: 'AA==',
      publicKey: 'AA==',
      origin: KeyOrigin.imported,
      pinned: pinned ? true : null,
      addedAt: 0,
    );
    final state = VaultState(
      phase: VaultPhase.unlocked,
      notes: _notes,
      keys: [
        key('s-laptop', 'laptop', KeyKind.ssh),
        key('s-server', 'Server', KeyKind.ssh, algorithm: 'rsa', bits: 3072),
        key('s-pinned', 'bastion', KeyKind.ssh, pinned: true),
        key('s-unread', 'unreadable', KeyKind.ssh),
        key('g-sign', 'release signing', KeyKind.signing),
        key('x-exchange', 'exchange', KeyKind.exchange, algorithm: 'x25519'),
        key('p-ada', 'Ada Lovelace', KeyKind.pgp, algorithm: 'pgp'),
      ],
      vault: const VaultInfo(id: 'main'),
    );
    const listings = {
      's-laptop': KeyListing(sshFingerprint: laptopPrint),
      's-server': KeyListing(sshFingerprint: serverPrint),
      's-pinned': KeyListing(sshFingerprint: 'SHA256:2Zkkw/B6LrkdE2VFIbEVtPKk9IejguYDxi0yg2+xtS4'),
      'p-ada': KeyListing(standing: KeyStanding.ok, pgpLine: 'ada@example.org · Ed25519'),
      // A fingerprint given for a key that is not an SSH key is not shown
      'g-sign': KeyListing(sshFingerprint: 'SHA256:wMVbj/Jt6yy6Qt3JEuQ6XmpwC/kJSMIpk4DJwDPx5Gw'),
    };
    VaultListItem named(String title, {VaultFilter filter = VaultFilter.all}) {
      final items = vaultListItems(state, filter: filter, keyListings: listings);
      return [...items.pgp, ...items.ssh, ...items.pinned, ...items.rest].singleWhere((item) => item.title == title);
    }

    test('a row shows the name and the fingerprint shortened to its first and last four characters', () {
      final laptop = named('laptop');

      expect((laptop.title, laptop.subtitle, laptop.fingerprint, laptop.isSsh), ('laptop', 'SHA256:41s5…UAW4', laptopPrint, true));
      expect(named('Server').subtitle, 'SHA256:mbgQ…g2bM');
      expect(named('laptop', filter: VaultFilter.keys).subtitle, 'SHA256:41s5…UAW4');
    });

    test('the Keys filter lists the SSH keys that are not pinned in a group of their own, by name', () {
      final items = vaultListItems(state, filter: VaultFilter.keys, keyListings: listings);

      expect(_titles(items.ssh), ['laptop', 'Server', 'unreadable']);
      expect(_titles(items.pgp), ['Ada Lovelace']);
      expect(_titles(items.rest), ['exchange', 'release signing']);
    });

    test('a pinned SSH key stays with the pinned items, with the same row', () {
      final items = vaultListItems(state, filter: VaultFilter.keys, keyListings: listings);

      expect(_titles(items.pinned), ['bastion']);
      expect((items.pinned.single.subtitle, items.pinned.single.isSsh), ('SHA256:2Zkk…xtS4', true));
      expect(_titles(vaultListItems(state, keyListings: listings).pinned), ['Alarm code', 'Bank', 'bastion']);
    });

    test('every other filter has no SSH group, and shows the same row', () {
      final all = vaultListItems(state, keyListings: listings);

      expect(all.ssh, isEmpty);
      expect(_titles(all.rest), containsAll(['laptop', 'Server', 'unreadable']));
      expect(named('laptop').subtitle, 'SHA256:41s5…UAW4');
      expect(vaultListItems(state, filter: VaultFilter.notes, keyListings: listings).ssh, isEmpty);
      expect(vaultListItems(state, filter: VaultFilter.passkeys, keyListings: listings).ssh, isEmpty);
    });

    for (final (what, query, found) in [
      ('the whole fingerprint', laptopPrint, ['laptop']),
      ('the whole fingerprint, whatever the case', laptopPrint.toLowerCase(), ['laptop']),
      ('a part of the fingerprint', 'mbgQkBCI/n6+', ['Server']),
      ('the algorithm, which the row no longer shows', 'RSA 3072', ['Server']),
      ('the name', 'bastion', ['bastion']),
    ]) {
      test('searching $what finds the key', () {
        final items = vaultListItems(state, query: query, keyListings: listings);

        expect([..._titles(items.pinned), ..._titles(items.rest)], found);
      });
    }

    test('searching "Ed25519" finds the SSH keys of that algorithm with the others', () {
      final items = vaultListItems(state, query: 'Ed25519', keyListings: listings);

      expect(_titles(items.pinned), ['bastion']);
      expect(_titles(items.rest), ['Ada Lovelace', 'laptop', 'release signing', 'unreadable']);
    });

    test('search results under the Keys filter stay one list, not grouped by SSH', () {
      final items = vaultListItems(state, filter: VaultFilter.keys, query: 'laptop', keyListings: listings);

      expect(items.ssh, isEmpty);
      expect(_titles(items.rest), ['laptop']);
    });

    test('an SSH key whose fingerprint cannot be worked out is listed by its algorithm, as before', () {
      final unreadable = named('unreadable', filter: VaultFilter.keys);

      expect((unreadable.subtitle, unreadable.fingerprint, unreadable.isSsh), ('Ed25519', null, true));
    });

    test('signing, exchange and PGP rows are as they were', () {
      final signing = named('release signing');
      final exchange = named('exchange');
      final pgp = named('Ada Lovelace');

      expect((signing.subtitle, signing.fingerprint, signing.isSsh), ('Ed25519', null, false));
      expect((exchange.subtitle, exchange.fingerprint, exchange.isSsh), ('X25519', null, false));
      expect(
        (pgp.subtitle, pgp.pgpLine, pgp.fingerprint, pgp.isSsh, pgp.isPgp),
        ('OpenPGP', 'ada@example.org · Ed25519', null, false, true),
      );
      expect(_titles([...vaultListItems(state, query: 'SHA256:wMVbj', keyListings: listings).rest]), isEmpty);
    });
  });

  // openspec: add-pgp-contacts, task 5.1
  group("other people's keys on the Vault tab", () {
    final thisYear = DateTime(2026, 11, 3, 9).millisecondsSinceEpoch;
    final lastYear = DateTime(2025, 11, 3, 9).millisecondsSinceEpoch;
    Finder filter(String id) => find.descendant(of: find.byType(SegmentedControl<VaultFilter>), matching: find.text(t(id)));
    Finder section() => find.text(t('vault.section.contacts').toUpperCase());

    Future<ContactsApp> open(WidgetTester tester, List<Contact> held) async {
      final contacts = ContactsApp(tester);
      await contacts.start();
      for (final contact in held) {
        await contacts.hold(contact);
      }
      return contacts;
    }

    testWidgets('are listed in their own section under All and Keys, and not under Notes or Passkeys', (tester) async {
      await open(tester, [contactOf(grace1, checkedAt: thisYear), contactOf(alan, id: 'c2', name: 'Alan Turing')]);

      for (final (id, listed) in [
        ('vault.filter.all', true),
        ('vault.filter.keys', true),
        ('vault.filter.notes', false),
        ('vault.filter.passkeys', false),
      ]) {
        await tapOn(tester, filter(id));
        expect(section(), listed ? findsOneWidget : findsNothing, reason: id);
        expect(find.text('Grace Hopper'), listed ? findsOneWidget : findsNothing, reason: id);
        expect(find.text('Alan Turing'), listed ? findsOneWidget : findsNothing, reason: id);
      }
    });

    testWidgets('say when each was checked, with the year when it is not this one, or that it was not', (tester) async {
      await open(tester, [
        contactOf(grace1, checkedAt: thisYear),
        contactOf(alan, id: 'c2', name: 'Alan Turing'),
        contactOf(signOnly, id: 'c3', name: 'Old Friend', checkedAt: lastYear),
      ]);

      expect(find.text('Checked on 3 November'), findsOneWidget);
      expect(find.text('Checked on 3 November 2025'), findsOneWidget);
      final unchecked = tester.widget<Text>(find.text(t('contacts.notChecked')));
      expect(unchecked.style!.color, tester.element(find.text(t('contacts.notChecked'))).palette.warning);
      // By name, each with its initials on the tile
      expect(tester.getTopLeft(find.text('Alan Turing')).dy, lessThan(tester.getTopLeft(find.text('Grace Hopper')).dy));
      for (final initials in ['GH', 'AT', 'OF']) {
        expect(find.text(initials), findsOneWidget);
      }
    });

    testWidgets('a revoked key carries the tag, and a key in order none', (tester) async {
      await open(tester, [contactOf(grace3, name: 'Grace Hopper'), contactOf(alan, id: 'c2', name: 'Alan Turing')]);

      expect(
        find.descendant(of: find.byKey(const ValueKey('contact:c1')), matching: find.text(t('keys.standing.revoked').toUpperCase())),
        findsOneWidget,
      );
      expect(find.descendant(of: find.byKey(const ValueKey('contact:c2')), matching: find.byType(StatusTag)), findsNothing);
    });

    testWidgets('are found by name, by an address in a user ID and by the fingerprint', (tester) async {
      await open(tester, [contactOf(grace1, name: 'G. H.'), contactOf(alan, id: 'c2', name: 'Alan Turing')]);

      for (final (query, found) in [
        ('turing', 'Alan Turing'),
        ('grace@example.org', 'G. H.'),
        (graceFingerprint, 'G. H.'),
        ('894f6aac', 'G. H.'),
      ]) {
        await tester.enterText(find.byType(TextField), query);
        await tester.pumpAndSettle();

        expect(find.text(found), findsOneWidget, reason: query);
        expect(find.text(found == 'G. H.' ? 'Alan Turing' : 'G. H.'), findsNothing, reason: query);
      }
    });

    testWidgets('count in the total, and a vault holding only them is not shown the empty state', (tester) async {
      await open(tester, [contactOf(grace1), contactOf(alan, id: 'c2', name: 'Alan Turing')]);

      expect(find.text(t('vault.empty.title')), findsNothing);
      expect(section(), findsOneWidget);
      expect(find.text(t('vault.section.all').toUpperCase()), findsNothing);
      expect(find.text(t('vault.search', {'count': 2})), findsOneWidget);
    });

    testWidgets('a vault without any shows no section', (tester) async {
      final contacts = await open(tester, const []);
      await tester.runAsync(() => contacts.app.controller.addNote(_notes.first));
      await tester.pumpAndSettle();

      expect(find.text('wi-fi'), findsOneWidget);
      expect(section(), findsNothing);
      await tapOn(tester, filter('vault.filter.keys'));
      expect(section(), findsNothing);
    });

    testWidgets('a row opens the sheet of that contact', (tester) async {
      await open(tester, [contactOf(grace1, checkedAt: thisYear)]);

      await tapOn(tester, find.text('Grace Hopper'));

      expect(find.byType(ContactSheet), findsOneWidget);
    });

    test('are a group of their own, by name, never pinned and never among the rest', () {
      final state = VaultState(
        phase: VaultPhase.unlocked,
        notes: _notes,
        contacts: [
          contactOf(grace1),
          contactOf(alan, id: 'c2', name: 'alan turing'),
        ],
        vault: const VaultInfo(id: 'main'),
      );

      final items = vaultListItems(state, contactListings: const {'c1': ContactListing(checked: true, line: 'Checked on 3 November')});

      expect(_titles(items.contacts), ['alan turing', 'Grace Hopper']);
      expect(
        (items.contacts.last.subtitle, items.contacts.last.unchecked, items.contacts.first.unchecked),
        ('Checked on 3 November', false, true),
      );
      expect(items.contacts.every((item) => item.kind == VaultItemKind.contact && !item.pinned), isTrue);
      expect([..._titles(items.pinned), ..._titles(items.rest)], isNot(contains('Grace Hopper')));
      expect(items.total, 6);
      expect(vaultListItems(state, filter: VaultFilter.notes).contacts, isEmpty);
      expect(vaultListItems(state, filter: VaultFilter.notes).total, 6);
    });
  });

  // openspec: add-pgp-contacts, task 4.3
  testWidgets('"Add someone’s key" in Add to vault, after Import a key, opens the add sheet', (tester) async {
    final contacts = ContactsApp(tester);
    await contacts.start();
    await tapOn(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));

    final row = find.text(t('vault.add.contact'));
    expect(row, findsOneWidget);
    expect(tester.getTopLeft(row).dy, greaterThan(tester.getTopLeft(find.text(t('vault.add.importKey'))).dy));
    expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(find.text(t('vault.add.note'))).dy));
    await tapOn(tester, row);

    expect(find.byType(AddToVaultSheet), findsNothing);
    expect(find.byType(AddContactSheet), findsOneWidget);
    expect(find.text(t('contacts.add.scan')), findsOneWidget);
  });
}
