import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/links/linked_items_section.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/models/vault_entry.dart';
import 'package:kemlock_core/models/item_link.dart';
import 'package:kemlock_core/vault/item_links.dart';

// Which actions a linked item's menu offers: Fix and Unlink write only the ends they change, so only those ends must be the
// person's to change
const _loginId = '11111111-1111-4111-8111-111111111111';
const _cardId = '22222222-2222-4222-8222-222222222222';

void main() {
  Login login({List<ItemLink> links = const [], String? spaceId}) =>
      Login(id: _loginId, name: 'Proton', username: 'sam', links: links, spaceId: spaceId, addedAt: 0);
  PaymentCard card({List<ItemLink> links = const [], String? spaceId}) =>
      PaymentCard(id: _cardId, name: 'Visa', cardholder: 'Ada', links: links, spaceId: spaceId, addedAt: 0);

  // The person may change the vault's own items and not the ones of the space "read"
  bool canEdit(VaultEntry<Object?> entry) => entry.spaceId != 'read';

  LinkedItem itemOf(Lists lists, VaultEntry<Object?> from) => linkedItemsOf(lists, from).single;

  group('a link only this end names', () {
    test('Fix writes the other end: offered when that one is the person\'s, not when it is read only', () {
      final mine = login(links: const [ItemLink(_cardId)]);
      final writable = Lists(logins: [mine], cards: [card()]);
      final readOnly = Lists(logins: [mine], cards: [card(spaceId: 'read')]);

      expect(mayFixLink(itemOf(writable, mine), mine, canEdit, null), isTrue);
      expect(mayFixLink(itemOf(readOnly, mine), mine, canEdit, null), isFalse);
    });

    test('Unlink writes only this end: offered although the other end is read only', () {
      final mine = login(links: const [ItemLink(_cardId)]);
      final lists = Lists(logins: [mine], cards: [card(spaceId: 'read')]);

      expect(mayUnlinkLink(itemOf(lists, mine), mine, canEdit, null), isTrue);
    });
  });

  group('a link only the other end names', () {
    test('Fix writes this end: offered although the other end is read only, which Unlink would have to write', () {
      final mine = login();
      final theirs = card(links: const [ItemLink(_loginId)], spaceId: 'read');
      final lists = Lists(logins: [mine], cards: [theirs]);

      expect(mayFixLink(itemOf(lists, mine), mine, canEdit, null), isTrue);
      expect(mayUnlinkLink(itemOf(lists, mine), mine, canEdit, null), isFalse);
    });

    test('Fix is not offered when this end is read only', () {
      final mine = login(spaceId: 'read');
      final theirs = card(links: const [ItemLink(_loginId)]);
      final lists = Lists(logins: [mine], cards: [theirs]);

      expect(mayFixLink(itemOf(lists, mine), mine, canEdit, null), isFalse);
      expect(mayUnlinkLink(itemOf(lists, mine), mine, canEdit, null), isTrue);
    });
  });

  group('a link both ends name', () {
    test('Unlink needs both ends, and there is nothing to fix', () {
      final mine = login(links: const [ItemLink(_cardId)]);
      final theirs = card(links: const [ItemLink(_loginId)]);
      final writable = Lists(logins: [mine], cards: [theirs]);
      final readOnly = Lists(logins: [mine], cards: [card(links: const [ItemLink(_loginId)], spaceId: 'read')]);

      expect(mayFixLink(itemOf(writable, mine), mine, canEdit, null), isFalse);
      expect(mayUnlinkLink(itemOf(writable, mine), mine, canEdit, null), isTrue);
      expect(mayUnlinkLink(itemOf(readOnly, mine), mine, canEdit, null), isFalse);
    });
  });

  test('a code and its login tied by the code\'s linkedLoginId unlink by writing the code', () {
    const code = OtpAccount(
      id: '33333333-3333-4333-8333-333333333333',
      issuer: 'Proton',
      label: 'sam',
      secret: 'JBSWY3DPEHPK3PXP',
      linkedLoginId: _loginId,
      addedAt: 0,
    );
    final lists = Lists(logins: [login(spaceId: 'read')], accounts: const [code]);

    // Only the code holds the pointer, so a read only login doesn't stop the unlink
    expect(mayUnlinkLink(itemOf(lists, code), code, canEdit, null), isTrue);
  });
}
