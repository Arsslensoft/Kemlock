// Signing and decrypting with a vault key whose private half is on a
// security key (openspec: add-openpgp-card, task 6.4), through the PGP
// sheets, the card job's bridge and the fake card.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/openpgp/writer.dart' show cardStubKey;
import 'package:kemlock/crypto/keys/pgp.dart' as pgp;
import 'package:kemlock/features/keys/card_key_use.dart';
import 'package:kemlock/features/keys/card_keys.dart';
import 'package:kemlock/features/pgp/pgp_controller.dart';
import 'package:kemlock/features/pgp/pgp_job.dart';
import 'package:kemlock/features/pgp/pgp_people.dart';
import 'package:kemlock/features/security_keys/card_pin_forms.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_openpgp_card.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import '../contacts/contacts_kit.dart';
import '../pgp/pgp_kit.dart';

const _nfc = {SecurityKeyLinkKind.nfc};

/// A card job on the test's isolate, its private steps through [card].
class _CardJob implements PgpJob {
  _CardJob(PgpRequest request, PgpCardBridge card) {
    result = runPgpRequest(request, card: card);
  }

  @override
  late final Future<PgpOutcome> result;

  @override
  ValueListenable<double> get progress => ValueNotifier(0);

  @override
  void cancel() {}
}

/// The PGP sheets' app with a fake phone, and card jobs run on the test's isolate.
class _CardApp extends PgpApp {
  _CardApp(super.tester);

  final phone = FakeSecurityKeys();

  @override
  List<Override> get overrides => [
    ...super.overrides,
    phone.asOverride,
    pgpCardJobStarterProvider.overrideWithValue((request, {directory, required card}) {
      requests.add(request);
      return _CardJob(request, card);
    }),
  ];
}

final _secret = File('test/fixtures/keys/gnupg/ed25519.secret.gpg').readAsBytesSync();
final _public = File('test/fixtures/keys/gnupg/ed25519.public.gpg').readAsBytesSync();
const _primary = '1FCDA135EE42400EC2B77CE677249ABE661CF8DB';
const _subkey = '4BA83174FC8CE762A23BF0A4841A40E3B199EA67';

/// The GnuPG Ed25519 fixture key, its secret parts on [card] and the vault
/// keeping it as a card key.
Future<VaultKey> _onCard(FakeOpenPgpCard card) async {
  await card.loadPgpKey(_secret);
  return VaultKey(
    id: 'k-card',
    name: 'Card key',
    kind: KeyKind.pgp,
    algorithm: 'pgp',
    privateKey: b64(cardStubKey(_public, cardAid: card.fullAid, onCard: [unhexBytes(_primary), unhexBytes(_subkey)])),
    publicKey: b64(_public),
    origin: KeyOrigin.imported,
    protected: true,
    addedAt: 0,
    card: cardObject(cardHex(card.fullAid), {CardPlace.signature: _primary, CardPlace.decryption: _subkey}),
  );
}

Uint8List unhexBytes(String hex) =>
    Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);

void main() {
  late FakeOpenPgpCard card;

  Future<_CardApp> start(WidgetTester tester, {List<String> keys = const []}) async {
    final app = _CardApp(tester);
    await app.start(keys: keys);
    card = FakeOpenPgpCard();
    final key = (await tester.runAsync(() => _onCard(card)))!;
    await tester.runAsync(() => app.app.container.read(vaultControllerProvider.notifier).addKey(key));
    await tester.pump();
    app.hideToast();
    await app.settle();
    return app;
  }

  /// The card is held to the phone.
  Future<void> present(_CardApp app, FakeOpenPgpCard which) async {
    app.phone.arrive(FakeKey(applets: [which]).device(kinds: _nfc));
    await app.settle();
  }

  Future<void> typePin(_CardApp app, String pin) async {
    await app.tester.enterText(find.descendant(of: find.byType(CardPinPrompt), matching: find.byType(TextField)), pin);
    await app.tester.pump();
    await app.tap(find.text(t('securityKeys.pin.continue')));
  }

  /// Gives up on the card, which ends the job.
  Future<void> cancel(_CardApp app) async {
    await app.tap(find.descendant(of: find.byType(CardUseSheet), matching: find.text(t('export.cancel'))));
    expect(find.byType(CardUseSheet), findsNothing);
  }

  Future<void> sign(_CardApp app) async {
    await app.open('sign');
    await app.enter(t('pgp.sign.message'), 'signed on the card');
    await app.tap(find.text(t('pgp.sign.button')));
  }

  Future<void> decrypt(_CardApp app, List<Uint8List> recipients) async {
    final message = (await app.tester.runAsync(
      () => pgp.encrypt(data: pgp.PgpData.bytes(utf8.encode('opened on the card')), recipients: recipients, text: true, now: testNow),
    ))!;
    await app.open('decrypt');
    await app.enter(t('pgp.decrypt.field'), utf8.decode(message));
    await app.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
  }

  testWidgets('signs on the card once it is presented and its PIN typed, and the signature verifies', (tester) async {
    final app = await start(tester);
    await sign(app);

    expect(find.byType(CardUseSheet), findsOneWidget);
    await present(app, card);
    expect(find.byType(CardPinPrompt), findsOneWidget);
    expect(card.pinsSent, isEmpty, reason: 'nothing sent before the PIN is typed');
    await typePin(app, FakeOpenPgpCard.factoryPin);

    expect(find.byType(CardUseSheet), findsNothing);
    final signed = app.files.sharedTexts.single;
    final verified = (await tester.runAsync(
      () => pgp.verify(signed: pgp.PgpData.bytes(utf8.encode(signed)), verifiers: [_public], now: testNow),
    ))!;
    expect(verified.signatures.single.verdict, pgp.SignatureVerdict.good);
    expect(card.log, contains('sign'));
  });

  testWidgets('opens a message to the card key on the card', (tester) async {
    final app = await start(tester);
    await decrypt(app, [_public]);

    await present(app, card);
    await typePin(app, FakeOpenPgpCard.factoryPin);

    expect(find.text('opened on the card'), findsOneWidget);
    expect(card.log, contains('decipher'));
  });

  testWidgets('a wrong PIN shows the tries left, and one try left warns', (tester) async {
    final app = await start(tester);
    await sign(app);
    await present(app, card);

    await typePin(app, '000000');
    expect(find.textContaining(t('securityKeys.pin.wrong')), findsOneWidget);
    expect(find.textContaining(t('securityKeys.pin.triesLeft', {'count': 2})), findsOneWidget);

    await typePin(app, '111111');
    expect(find.textContaining(t('securityKeys.pin.triesLeft', {'count': 1})), findsOneWidget);
    expect(find.textContaining(t('securityKeys.openpgp.pin.lastTry')), findsOneWidget);
    await app.closeSheet();
    expect(find.byType(CardUseSheet), findsNothing, reason: 'giving up at the PIN ends the step');
  });

  testWidgets('a PIN the card failed on is asked for again, and "Try again" does not send it a second time', (tester) async {
    final app = await start(tester);
    // A card that counts the PIN and then fails with a status of its own
    card.nextVerifyStatus = 0x6f00;
    await sign(app);
    await present(app, card);
    await typePin(app, FakeOpenPgpCard.factoryPin);

    expect(find.byKey(const ValueKey('card-use-error')), findsOneWidget);
    expect(card.pinsSent, hasLength(1));
    expect(card.pinTries, 2);

    await app.tap(find.text(t('securityKeys.openpgp.use.tryAgain')));

    expect(find.byType(CardPinPrompt), findsOneWidget, reason: 'the PIN is asked for again');
    expect(card.pinsSent, hasLength(1), reason: 'nothing was sent without the person typing it');
    expect(card.pinTries, 2);
    await app.closeSheet();
  });

  testWidgets('with no try left sends nothing and offers unblocking', (tester) async {
    final app = await start(tester);
    card.pinTries = 0;
    await sign(app);
    await present(app, card);

    expect(find.byType(CardPinPrompt), findsNothing);
    expect(find.text(t('securityKeys.openpgp.use.blocked')), findsOneWidget);
    expect(find.text(t('securityKeys.openpgp.use.unblock')), findsOneWidget);
    expect(card.pinsSent, isEmpty);
    expect(card.log.where((entry) => entry.startsWith('verify') || entry == 'sign'), isEmpty);
    await cancel(app);
  });

  testWidgets('a card without the key is refused before any PIN, naming the one to use', (tester) async {
    final app = await start(tester);
    final other = FakeOpenPgpCard(serial: 0x87654321);
    await sign(app);
    await present(app, other);

    expect(find.byType(CardPinPrompt), findsNothing);
    expect(find.text(t('securityKeys.openpgp.use.wrongCard', {'name': 'Card key', 'serial': '1234 5678'})), findsOneWidget);
    expect(other.pinsSent, isEmpty);
    await cancel(app);
  });

  testWidgets('a second card with the same key signs, whatever its serial', (tester) async {
    final app = await start(tester);
    final twin = FakeOpenPgpCard(serial: 0x11112222);
    await tester.runAsync(() => twin.loadPgpKey(_secret));
    await sign(app);
    await present(app, twin);
    await typePin(app, FakeOpenPgpCard.factoryPin);

    expect(app.files.sharedTexts, hasLength(1));
    expect(twin.log, contains('sign'));
  });

  testWidgets('a message also encrypted to a vault key is opened by it, and the card is not asked for', (tester) async {
    final app = await start(tester, keys: ['rsa']);
    final rsa = (await tester.runAsync(() => crypto.readPrivateKey(fixtureBytes(fixtureKeys['rsa']!.$1))))!.public!;
    await decrypt(app, [_public, rsa]);

    expect(find.byType(CardUseSheet), findsNothing);
    expect(find.text('opened on the card'), findsOneWidget);
    expect(card.log, isEmpty);
  });

  testWidgets('cancelling at the PIN prompt sends nothing and leaves the message closed', (tester) async {
    final app = await start(tester);
    await decrypt(app, [_public]);
    await present(app, card);

    await app.closeSheet();
    await app.settle();

    expect(find.text('opened on the card'), findsNothing);
    expect(card.pinsSent, isEmpty);
    expect(card.log.where((entry) => entry == 'decipher'), isEmpty);
  });

  // Joined with add-pgp-contacts: the people the sheets choose from
  testWidgets("is one of the vault's own people, beside the contacts", (tester) async {
    final app = await start(tester);
    final vault = app.app.container.read(vaultControllerProvider.notifier);
    await tester.runAsync(() => vault.addContact(contactOf(grace1)));
    await app.settle();

    final people = app.app.container.read(pgpPeopleProvider);

    final own = people.singleWhere((person) => person.isOwn);
    expect((own.vaultKeyId, own.fingerprint, own.isChecked, own.isUsable), ('k-card', _primary, true, true));
    expect(own.name, userIdName(crypto.readPgpKeyInfo(_public).mainUserId!));
    expect(own.publicKey, _public);
    final contact = people.singleWhere((person) => person.isContact);
    expect((contact.contactId, contact.fingerprint, contact.isChecked), ('c1', graceFingerprint, false));
  });
}
