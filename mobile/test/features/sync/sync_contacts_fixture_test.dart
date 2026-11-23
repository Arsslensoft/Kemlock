import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/contacts/contact_standing.dart';
import 'package:kemlock/features/sync/sync_merge.dart';

import '../../compat/before_vault_items/sync_merge.dart' as old;
import '../../vault/contacts_fixture_inputs.dart';
import '../contacts/contacts_kit.dart';

// test/fixtures/vault-items/sync-with-contacts.json: the decrypted sync file of a vault holding a checked and
// an unchecked contact, written once when contacts joined sync (openspec: add-pgp-contacts, task 7.3; see
// CONTACTS.md beside it). Phones hold files in this form, so every later version must read it.

Map<String, Object?> _file() =>
    jsonDecode(File('test/fixtures/vault-items/sync-with-contacts.json').readAsStringSync()) as Map<String, Object?>;

void main() {
  test('reads with every kind, both contacts and their checks, and the deletion of a contact', () {
    final doc = SyncDoc.fromJson(_file());

    expect(doc.contacts, fixtureContacts());
    expect([for (final contact in doc.contacts) contactStanding(contact, contactsNow).checked], [true, false]);
    expect(doc.contacts.first.checkedFingerprint, graceFingerprint);
    expect(doc.accounts, fixtureAccounts);
    expect(doc.keys, fixtureKeys);
    expect(doc.notes, fixtureNotes);
    expect(doc.passkeys, fixturePasskeys);
    expect([for (final tomb in doc.deleted) tomb.id], ['a-gone', 'c-gone']);
    expect(doc.extra, isEmpty);
  });

  test('is written back as it was, and is what this version still writes', () {
    final doc = SyncDoc.fromJson(_file());

    expect(canonical(doc.toJson()), canonical(_file()));
    expect(
      const JsonEncoder.withIndent('  ').convert(fixtureSyncDoc().toJson()),
      File('test/fixtures/vault-items/sync-with-contacts.json').readAsStringSync(),
    );
  });

  test('merging it with a phone that holds the same entries changes nothing', () {
    final doc = SyncDoc.fromJson(_file());

    final merged = mergeScope(scopeLists(doc, null), doc.ids.toList(), doc, now: 1793700000000);

    expect(sameDoc(merged.doc, doc), isTrue);
    expect(merged.known, unorderedEquals(doc.ids));
  });

  test('a phone from before keys, notes, passkeys and contacts writes the contacts and their deletion back', () {
    final remote = old.SyncDoc.fromJson(_file());

    final merged = old.mergeScope(old.Lists(accounts: fixtureAccounts), ['a1'], remote, now: 1793700000000);

    final written = jsonDecode(jsonEncode(merged.doc.toJson())) as Map<String, Object?>;
    expect(written['contacts'], _file()['contacts']);
    expect(written['deleted'], _file()['deleted']);
  });
}
