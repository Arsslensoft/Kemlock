import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/cards/card_sheet.dart';
import 'package:kemlock/features/links/link_picker_sheet.dart';
import 'package:kemlock/features/logins/login_sheet.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock_core/models/item_link.dart';
import 'package:kemlock_core/vault/item_links.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

// The Linked items section of an item's sheet: a login and a card here, which are linked to each other
const _loginId = '11111111-1111-4111-8111-111111111111';
const _cardId = '22222222-2222-4222-8222-222222222222';
const _goneId = '99999999-9999-4999-8999-999999999999';

const _visa = PaymentCard(id: _cardId, name: 'Everyday Visa', cardholder: 'Ada Lovelace', number: '4111111111111111', addedAt: 0);

Login _proton({List<ItemLink> links = const []}) =>
    Login(id: _loginId, name: 'Proton', username: 'sam', password: 'pw', websites: const ['proton.me'], links: links, addedAt: 0);

void main() {
  Future<TestApp> open(WidgetTester tester, {Login? login, PaymentCard? card, bool linked = false}) async {
    final app = TestApp();
    await startApp(tester, app);
    await createVault(tester);
    final controller = app.container.read(vaultControllerProvider.notifier);
    if (login != null) {
      await controller.addLogin(login);
    }
    if (card != null) {
      await controller.addCard(card);
    }
    if (linked) {
      final state = app.container.read(vaultControllerProvider);
      await controller.linkItems(state.logins.single, state.cards.single);
    }
    // The toasts of the adds are gone before anything is tapped
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    return app;
  }

  VaultState vault(TestApp app) => app.container.read(vaultControllerProvider);
  Finder inLogin(Finder finder) => find.descendant(of: find.byType(LoginSheet), matching: finder);
  Finder inCard(Finder finder) => find.descendant(of: find.byType(CardSheet), matching: finder);
  Finder inPicker(Finder finder) => find.descendant(of: find.byType(LinkPicker), matching: finder);

  testWidgets('a login lists the item it is linked to, with its kind, and opens it', (tester) async {
    await open(tester, login: _proton(), card: _visa, linked: true);
    await tapOn(tester, find.text('Proton'));

    expect(inLogin(find.text(t('links.title').toUpperCase())), findsOneWidget);
    expect(inLogin(find.text('Everyday Visa')), findsOneWidget);
    expect(inLogin(find.text(t('links.kind.card'))), findsOneWidget);

    await tapOn(tester, inLogin(find.text('Everyday Visa')));
    expect(find.byType(CardSheet), findsOneWidget);
  });

  testWidgets('the linked item lists the login too: a link shows on both items', (tester) async {
    await open(tester, login: _proton(), card: _visa, linked: true);
    await tapOn(tester, find.text(t('vault.filter.cards')));
    await tapOn(tester, find.text('Everyday Visa'));

    expect(inCard(find.text('Proton')), findsOneWidget);
    expect(inCard(find.text(t('links.kind.login'))), findsOneWidget);
  });

  testWidgets('a link that only one end names shows normally, and Fix writes the other end', (tester) async {
    final app = await open(tester, login: _proton(), card: _visa.withLinks(const [ItemLink(_loginId)]));
    await tapOn(tester, find.text(t('vault.filter.cards')));
    await tapOn(tester, find.text('Everyday Visa'));

    expect(inCard(find.text('Proton')), findsOneWidget);
    await tapOn(tester, inCard(find.byKey(const ValueKey('linked-menu:$_loginId'))));
    await tapOn(tester, find.text(t('links.fix')));

    expect(vault(app).logins.single.links.ids, {_cardId});
    expect(vault(app).cards.single.links.ids, {_loginId});
  });

  testWidgets('a link to an item the vault does not hold stays, as not available', (tester) async {
    final app = await open(tester, login: _proton(links: const [ItemLink(_goneId)]));
    await tapOn(tester, find.text('Proton'));

    expect(inLogin(find.text(t('links.unavailable'))), findsOneWidget);
    expect(vault(app).logins.single.links.ids, {_goneId});
  });

  testWidgets('Link an item searches the vault, leaves out the item itself and links both ends', (tester) async {
    final app = await open(tester, login: _proton(), card: _visa);
    await tapOn(tester, find.text('Proton'));
    await tapOn(tester, inLogin(find.text(t('links.add'))));

    expect(inPicker(find.text('Everyday Visa')), findsOneWidget);
    expect(inPicker(find.text('Proton')), findsNothing);

    await tester.enterText(inPicker(find.byType(TextField)), 'nothing like it');
    await tester.pumpAndSettle();
    expect(inPicker(find.text(t('links.picker.noMatch'))), findsOneWidget);
    await tester.enterText(inPicker(find.byType(TextField)), 'lovelace');
    await tester.pumpAndSettle();
    await tapOn(tester, inPicker(find.text('Everyday Visa')));

    expect(find.byType(LinkPicker), findsNothing);
    expect(vault(app).logins.single.links.ids, {_cardId});
    expect(vault(app).cards.single.links.ids, {_loginId});
    expect(inLogin(find.text('Everyday Visa')), findsOneWidget);
  });

  testWidgets('an item with no item id yet offers no Link an item', (tester) async {
    // An id that is not a UUID has no item id, and the test vault has no Kemlock Server account to make one
    await open(
      tester,
      login: const Login(id: 'legacy-login', name: 'Proton', username: 'sam', password: 'pw', addedAt: 0),
      card: _visa,
    );
    await tapOn(tester, find.text('Proton'));

    expect(find.byType(LoginSheet), findsOneWidget);
    expect(inLogin(find.text(t('links.add'))), findsNothing);
  });

  testWidgets('the picker does not offer an item that is linked already', (tester) async {
    await open(tester, login: _proton(), card: _visa, linked: true);
    await tapOn(tester, find.text('Proton'));
    await tapOn(tester, inLogin(find.text(t('links.add'))));

    expect(inPicker(find.text('Everyday Visa')), findsNothing);
    expect(inPicker(find.text(t('links.picker.none'))), findsOneWidget);
  });

  testWidgets("Unlink in the row's menu removes both ends", (tester) async {
    final app = await open(tester, login: _proton(), card: _visa, linked: true);
    await tapOn(tester, find.text('Proton'));

    await tapOn(tester, inLogin(find.byKey(const ValueKey('linked-menu:$_cardId'))));
    await tapOn(tester, find.text(t('links.unlink')));

    expect(vault(app).logins.single.links, isEmpty);
    expect(vault(app).cards.single.links, isEmpty);
    expect(inLogin(find.text('Everyday Visa')), findsNothing);
  });

  testWidgets("deleting the card takes it out of the login's links", (tester) async {
    final app = await open(tester, login: _proton(), card: _visa, linked: true);
    await tapOn(tester, find.text(t('vault.filter.cards')));
    await tapOn(tester, find.text('Everyday Visa'));

    await tapOn(tester, inCard(find.text(t('cards.delete'))));
    await tapOn(tester, find.text(t('cards.delete.confirm')));

    expect(vault(app).cards, isEmpty);
    expect(vault(app).logins.single.links, isEmpty);
    expect(linkedItemsOf(vault(app).lists, vault(app).logins.single), isEmpty);
  });
}
