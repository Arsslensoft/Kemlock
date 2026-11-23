import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/features/cards/card_edit_sheet.dart';
import 'package:kemlock/features/cards/card_sheet.dart';
import 'package:kemlock/features/identities/identity_edit_sheet.dart';
import 'package:kemlock/features/identities/identity_sheet.dart';
import 'package:kemlock/features/lock/gate_widgets.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/features/vault/add_to_vault_sheet.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_clipboard.dart';
import '../../fakes/fake_owner_check.dart';
import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

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
  addedAt: 0,
);

const _me = Identity(
  id: 'i1',
  name: 'Me',
  givenName: 'Ada',
  familyName: 'Lovelace',
  email: 'ada@example.org',
  address: IdentityAddress(lines: ['1 Example Road'], city: 'London', country: 'GB'),
  documents: [IdentityDocument(id: 'd1', type: 'passport', number: '123456789', issuingCountry: 'GB', expiresOn: '2031-03-14')],
  addedAt: 0,
);

// the add-cards-identities-and-websites plan, tasks 4.2 to 4.4
void main() {
  Future<TestApp> open(
    WidgetTester tester, {
    List<PaymentCard> cards = const [],
    List<Identity> identities = const [],
    List<Override> overrides = const [],
  }) async {
    final app = TestApp();
    await startApp(tester, app, overrides: overrides);
    await createVault(tester);
    final controller = app.container.read(vaultControllerProvider.notifier);
    for (final card in cards) {
      await controller.addCard(card);
    }
    for (final identity in identities) {
      await controller.addIdentity(identity);
    }
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    return app;
  }

  // A field low in the sheet is under the test window's bottom edge, where
  // enterText can't focus it: scroll it into view first, as a person would.
  Future<void> typeInto(WidgetTester tester, Finder finder, String text) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.enterText(finder, text);
  }

  List<PaymentCard> cards(TestApp app) => app.container.read(vaultControllerProvider).cards;
  List<Identity> identities(TestApp app) => app.container.read(vaultControllerProvider).identities;
  Finder inSheet(Finder finder) => find.descendant(of: find.byType(CardSheet), matching: finder);
  Finder inEdit(Finder finder) => find.descendant(of: find.byType(CardEditSheet), matching: finder);
  Finder addButton() => find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault')));

  testWidgets('the add button lists a new card and a new identity, each opening its form', (tester) async {
    await open(tester);
    await tapOn(tester, addButton());
    expect(find.text(t('vault.add.card')), findsOneWidget);
    expect(find.text(t('vault.add.identity')), findsOneWidget);

    await tapOn(tester, find.text(t('vault.add.card')));
    expect(find.byType(AddToVaultSheet), findsNothing);
    expect(find.byType(CardEditSheet), findsOneWidget);
  });

  testWidgets('a card is listed under Cards, shows its last four digits and Expired when its month has ended', (tester) async {
    await open(tester, cards: [_visa.copyWith(expYear: 2020)]);
    await tapOn(tester, find.text(t('vault.filter.cards')));

    expect(find.text('Everyday Visa'), findsOneWidget);
    expect(find.text('Visa · 1111'), findsOneWidget);
    expect(find.text(t('vault.card.expired').toUpperCase()), findsOneWidget);
  });

  testWidgets('the number is masked and the code hidden; each shows only when asked and copies through the clipboard that clears', (
    tester,
  ) async {
    final copies = <String>[];
    answerSensitiveCopies(copies.add);
    await open(tester, cards: [_visa]);
    await tapOn(tester, find.text(t('vault.filter.cards')));
    await tapOn(tester, find.text('Everyday Visa'));

    expect(inSheet(find.text('•••• 1111')), findsOneWidget);
    expect(inSheet(find.text('4111111111111111')), findsNothing);
    expect(inSheet(find.text('123')), findsNothing);
    await tapOn(tester, inSheet(find.byType(RevealPasswordButton)).first);
    expect(inSheet(find.text('4111 1111 1111 1111')), findsOneWidget);

    await tapOn(tester, inSheet(find.byTooltip(t('cards.copy.code'))));
    expect(copies, contains('123'));
    expect(find.text(t('cards.copied.code')), findsOneWidget);
    await tapOn(tester, inSheet(find.byTooltip(t('cards.copy.number'))));
    expect(copies, contains('4111111111111111'));
  });

  testWidgets('asks who it is before showing a secret when Settings says so, and copies without asking', (tester) async {
    final copies = <String>[];
    answerSensitiveCopies(copies.add);
    final check = FakeOwnerCheck(passes: false);
    final app = await open(tester, cards: [_visa], overrides: [check.asOverride]);
    app.container.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(askBeforeSecret: true));
    await tapOn(tester, find.text(t('vault.filter.cards')));
    await tapOn(tester, find.text('Everyday Visa'));

    await tapOn(tester, inSheet(find.byType(RevealPasswordButton)).last);
    expect(check.reasons, [t('cards.reveal.confirm')]);
    expect(inSheet(find.text('4321')), findsNothing);

    await tapOn(tester, inSheet(find.byTooltip(t('cards.copy.pin'))));
    expect(copies, contains('4321'));
    expect(check.reasons, hasLength(1));

    check.passes = true;
    await tapOn(tester, inSheet(find.byType(RevealPasswordButton)).last);
    expect(inSheet(find.text('4321')), findsOneWidget);
  });

  testWidgets('adds, edits and deletes a card, with Undo', (tester) async {
    final app = await open(tester);
    await tapOn(tester, addButton());
    await tapOn(tester, find.text(t('vault.add.card')));

    // A name alone can not be saved
    await typeInto(tester, inEdit(field(t('cards.field.name'))), 'Everyday Visa');
    await tester.pump();
    expect(find.text(t('cards.needsDetail')), findsOneWidget);
    expect(tester.widget<FilledButton>(inEdit(find.byType(FilledButton))).onPressed, isNull);

    await typeInto(tester, inEdit(field(t('cards.field.number'))), '4111-1111 1111-1111');
    await typeInto(tester, inEdit(field(t('cards.field.expiry'))), '05/29');
    await tester.pump();
    await tapOn(tester, inEdit(find.text(t('cards.save'))));

    final saved = cards(app).single;
    expect((saved.number, saved.brand, saved.expMonth, saved.expYear), ('4111111111111111', 'Visa', 5, 2029));

    // Edited, once the saved toast has gone from over the sheet's buttons
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, find.text(t('vault.filter.cards')));
    await tapOn(tester, find.text('Everyday Visa'));
    await tapOn(tester, inSheet(find.text(t('cards.edit'))));
    await typeInto(tester, inEdit(field(t('cards.field.name'))), 'Travel Visa');
    await tester.pump();
    await tapOn(tester, inEdit(find.text(t('cards.save'))));
    expect(cards(app).single.name, 'Travel Visa');

    // Deleted, and put back with Undo
    await tapOn(tester, inSheet(find.text(t('cards.delete'))));
    await tapOn(tester, find.text(t('cards.delete.confirm')));
    expect(cards(app), isEmpty);
    await tapOn(tester, find.text(t('app.undo')));
    expect(cards(app).single.name, 'Travel Visa');
  });

  testWidgets('a number that fails the Luhn check warns and still saves, and one with letters can not be saved', (tester) async {
    final app = await open(tester);
    await tapOn(tester, addButton());
    await tapOn(tester, find.text(t('vault.add.card')));
    await typeInto(tester, inEdit(field(t('cards.field.name'))), 'Odd card');

    await typeInto(tester, inEdit(field(t('cards.field.number'))), '4111 abcd');
    await tester.pump();
    expect(find.text(t('cards.number.digits')), findsOneWidget);
    expect(tester.widget<FilledButton>(inEdit(find.byType(FilledButton))).onPressed, isNull);

    await typeInto(tester, inEdit(field(t('cards.field.number'))), '4111 1111 1111 1112');
    await tester.pump();
    expect(find.text(t('cards.number.luhn')), findsOneWidget);
    await tapOn(tester, inEdit(find.text(t('cards.save'))));
    expect(cards(app).single.number, '4111111111111112');
  });

  testWidgets('an identity shows its details and hides a document number until asked', (tester) async {
    final copies = <String>[];
    answerSensitiveCopies(copies.add);
    await open(tester, identities: [_me]);
    await tapOn(tester, find.text(t('vault.filter.identities')));
    expect(find.text('Ada Lovelace'), findsOneWidget);
    await tapOn(tester, find.text('Me'));
    Finder inIdentity(Finder finder) => find.descendant(of: find.byType(IdentitySheet), matching: finder);

    expect(inIdentity(find.text('ada@example.org')), findsOneWidget);
    expect(inIdentity(find.textContaining('United Kingdom')), findsWidgets);
    expect(inIdentity(find.text('123456789')), findsNothing);
    await tapOn(tester, inIdentity(find.byType(RevealPasswordButton)));
    expect(inIdentity(find.text('123456789')), findsOneWidget);
    await tapOn(tester, inIdentity(find.byTooltip(t('identities.copy.number'))));
    expect(copies, contains('123456789'));
  });

  testWidgets('adds an identity with two documents, keeping a picked country as its ISO code', (tester) async {
    final app = await open(tester);
    await tapOn(tester, addButton());
    await tapOn(tester, find.text(t('vault.add.identity')));
    Finder inForm(Finder finder) => find.descendant(of: find.byType(IdentityEditSheet), matching: finder);

    await tester.enterText(inForm(field(t('identities.field.name'))), 'Me');
    await tester.pump();
    expect(find.text(t('identities.needsDetail')), findsOneWidget);
    await tester.enterText(inForm(field(t('identities.field.email'))), 'ada@example.org');
    await tester.pump();

    await tester.ensureVisible(inForm(field(t('identities.field.country'))));
    await tester.enterText(inForm(field(t('identities.field.country'))), 'United King');
    await tester.pump();
    await tapOn(tester, inForm(find.widgetWithText(ActionChip, 'United Kingdom')));

    for (final number in ['123456789', '987654321']) {
      await tester.ensureVisible(inForm(find.text(t('identities.documentAdd'))));
      await tapOn(tester, inForm(find.text(t('identities.documentAdd'))));
      await tester.enterText(inForm(field(t('identities.field.documentNumber'))).last, number);
      await tester.pump();
    }
    await tester.ensureVisible(inForm(find.text(t('identities.save'))));
    await tapOn(tester, inForm(find.text(t('identities.save'))));

    final saved = identities(app).single;
    expect(saved.address?.country, 'GB');
    expect(saved.documents!.map((document) => document.number), ['123456789', '987654321']);
  });
}
