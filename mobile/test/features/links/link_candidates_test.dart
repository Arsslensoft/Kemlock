import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/links/link_candidates.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_entry.dart';
import 'package:kemlock_core/models/item_link.dart';

// What the "Link an item" picker offers: not the item itself, not what it is linked to already, and what the person can change
const _login = '11111111-1111-4111-8111-111111111111';
const _note = '22222222-2222-4222-8222-222222222222';
const _card = '33333333-3333-4333-8333-333333333333';
const _identity = '44444444-4444-4444-8444-444444444444';
const _shared = '55555555-5555-4555-8555-555555555555';

void main() {
  Login login({List<ItemLink> links = const []}) =>
      Login(id: _login, name: 'Proton', username: 'sam', websites: const ['proton.me'], links: links, addedAt: 0);
  SecureNote note({List<ItemLink> links = const []}) => SecureNote(id: _note, title: 'Recovery plan', links: links, addedAt: 0);
  const card = PaymentCard(id: _card, name: 'Everyday Visa', cardholder: 'Ada Lovelace', brand: 'Visa', addedAt: 0);
  const identity = Identity(id: _identity, name: 'Me', email: 'ada@example.org', addedAt: 0);
  const shared = Login(id: _shared, name: 'Team wiki', username: 'team', spaceId: 'team', addedAt: 0);

  List<String> names(Lists lists, VaultEntry<Object?> entry, {String query = '', bool Function(VaultEntry<Object?>)? canEdit}) => [
    for (final candidate in linkCandidates(lists, entry, query: query, canEdit: canEdit))
      switch (candidate) {
        final Login login => login.name,
        final SecureNote note => note.title,
        final PaymentCard card => card.name,
        final Identity identity => identity.name,
        _ => '?',
      },
  ];

  test('offers every item but the one itself, by name', () {
    final lists = Lists(logins: [login(), shared], notes: [note()], cards: const [card], identities: const [identity]);

    expect(names(lists, login()), ['Everyday Visa', 'Me', 'Recovery plan', 'Team wiki']);
  });

  test('leaves out the items already linked to it, from whichever end names the link', () {
    // The login names the note; the card names the login
    final lists = Lists(
      logins: [login(links: const [ItemLink(_note)])],
      notes: [note()],
      cards: [card.withLinks(const [ItemLink(_login)])],
      identities: const [identity],
    );

    expect(names(lists, lists.logins.single), ['Me']);
  });

  test('leaves out an item the person may not change, as one of a space they only read', () {
    final lists = Lists(logins: [login(), shared], notes: [note()]);

    expect(names(lists, login(), canEdit: (candidate) => candidate.spaceId == null), ['Recovery plan']);
  });

  test('narrows by every word, in the name or in what the kind is found by', () {
    final lists = Lists(logins: [login(), shared], notes: [note()], cards: const [card], identities: const [identity]);

    expect(names(lists, note(), query: 'proton'), ['Proton']);
    expect(names(lists, note(), query: 'PROTON.ME sam'), ['Proton']);
    expect(names(lists, note(), query: 'lovelace'), ['Everyday Visa']);
    expect(names(lists, note(), query: 'ada@example'), ['Me']);
    expect(names(lists, note(), query: 'nothing like it'), isEmpty);
  });
}
