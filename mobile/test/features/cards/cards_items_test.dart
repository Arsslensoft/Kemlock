import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/vault/vault_items.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/vault/vault_controller.dart';

const _visa = PaymentCard(
  id: 'c1',
  name: 'Everyday Visa',
  cardholder: 'Ada Lovelace',
  number: '4111111111111111',
  brand: 'Visa',
  expMonth: 5,
  expYear: 2029,
  code: '123',
  pin: '4321',
  tags: ['bank'],
  addedAt: 1,
);
const _gift = PaymentCard(id: 'c2', name: 'Gift card', cardholder: 'Ada', pinned: true, addedAt: 2);
const _me = Identity(
  id: 'i1',
  name: 'Me',
  givenName: 'Ada',
  familyName: 'Lovelace',
  company: 'Analytical Engines',
  email: 'ada@example.org',
  phone: '+44 20 7946 0000',
  address: IdentityAddress(lines: ['1 Example Road'], city: 'London'),
  documents: [IdentityDocument(id: 'd1', type: 'passport', number: '123456789')],
  tags: ['personal'],
  addedAt: 3,
);
const _work = Identity(id: 'i2', name: 'Work', email: 'ada@work.example', addedAt: 4);

const _state = VaultState(
  phase: VaultPhase.unlocked,
  cards: [_visa, _gift],
  identities: [_me, _work],
  vault: VaultInfo(id: 'main'),
);

List<String> _titles(List<VaultListItem> items) => [for (final item in items) item.title];

// the add-cards-identities-and-websites plan, task 4.1
void main() {
  test('lists cards and identities under their own filters, pinned first', () {
    final cards = vaultListItems(_state, filter: VaultFilter.cards);
    expect(_titles(cards.pinned), ['Gift card']);
    expect(_titles(cards.rest), ['Everyday Visa']);
    expect(cards.rest.single.kind, VaultItemKind.card);

    final identities = vaultListItems(_state, filter: VaultFilter.identities);
    expect(_titles(identities.rest), ['Me', 'Work']);
    expect(identities.rest.first.kind, VaultItemKind.identity);

    final all = vaultListItems(_state);
    expect(all.total, 4);
    expect(_titles([...all.pinned, ...all.rest]), ['Gift card', 'Everyday Visa', 'Me', 'Work']);
  });

  test('a card row shows its brand and last four digits, or its cardholder without a number', () {
    final rows = vaultListItems(_state, filter: VaultFilter.cards);
    expect(rows.rest.single.subtitle, 'Visa · 1111');
    expect(rows.pinned.single.subtitle, 'Ada');
  });

  test('a card past its expiry carries the tag it is given, in the danger colour', () {
    final rows = vaultListItems(_state, filter: VaultFilter.cards, cardTags: const {'c1': 'Expired'});
    expect(rows.rest.single.tag, 'Expired');
    expect(rows.rest.single.tagTone, isNotNull);
    expect(rows.pinned.single.tag, isNull);
  });

  test('an identity row shows the full name, else the email', () {
    final rows = vaultListItems(_state, filter: VaultFilter.identities).rest;
    expect(rows[0].subtitle, 'Ada Lovelace');
    expect(rows[1].subtitle, 'ada@work.example');
  });

  for (final (query, found) in [
    ('1111', ['Everyday Visa']),
    ('visa', ['Everyday Visa']),
    ('lovelace', ['Everyday Visa', 'Me']),
    ('bank', ['Everyday Visa']),
    ('ada@example.org', ['Me']),
    ('analytical', ['Me']),
    ('personal', ['Me']),
  ]) {
    test('search for "$query" finds ${found.join(' and ')}', () {
      final items = vaultListItems(_state, query: query);
      expect(_titles([...items.pinned, ...items.rest]), found);
    });
  }

  for (final query in ['11111111', '4111111111111111', '123', '4321', '123456789', '+44', 'Example Road']) {
    test('search for "$query" finds nothing: a full number, a code, a PIN, a phone, an address and a document number are not searched', () {
      final items = vaultListItems(_state, query: query);
      expect(items.pinned, isEmpty);
      expect(items.rest, isEmpty);
    });
  }
}
