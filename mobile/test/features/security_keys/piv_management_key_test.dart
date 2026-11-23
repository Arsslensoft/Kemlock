import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/security_keys/piv_management_key_sheet.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/security_key/piv/piv_commands.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';
import 'package:kemlock/security_key/piv/piv_operations.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/crashing_store.dart';
import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_piv_card.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import 'piv_harness.dart';

/// A note that keeps [key] of [algorithm] for the security key [keyId].
SecureNote _note(String keyId, List<int> key, {String algorithm = 'aes256', String id = 'n1'}) => SecureNote(
  id: id,
  title: 'Management key – Example Key 5C $keyId',
  text: formatPivManagementKey(key),
  addedAt: 1,
  piv: NotePivKey(key: keyId, algorithm: algorithm, managementKey: [for (final b in key) b.toRadixString(16).padLeft(2, '0')].join()),
);

final _aes = List.generate(32, (i) => 0x40 + i);

/// Removes the certificate in 9e through its sheet: an operation that
/// needs the management key, and nothing else.
Future<void> _removeCertificate(PivRig rig) async {
  await rig.openCertificates();
  await rig.tapSlot(PivSlot.cardAuthentication);
  await rig.keys.tapRow('piv.remove.row');
  await rig.tester.tap(find.widgetWithText(FilledButton, t('piv.remove.button')));
  await rig.tester.pumpAndSettle();
}

Future<FakePivCard> _withCertificate(FakePivCard card) async {
  card.putCertificate(
    PivSlot.cardAuthentication,
    await selfSignedFor(card.generate(PivSlot.cardAuthentication, PivAlgorithm.eccP256), notBefore: pivNow, notAfter: DateTime.utc(2028)),
  );
  return card;
}

/// Opens the management key sheet from its row.
Future<void> _openManagementKey(PivRig rig) async {
  await rig.openCertificates();
  await rig.keys.tapRow('piv.managementKey');
  expect(find.byType(PivManagementKeySheet), findsOneWidget);
}

void main() {
  appMain();

  group('finding it', () {
    testWidgets('the factory key, from metadata, with no attempt beforehand', (tester) async {
      final card = await _withCertificate(FakePivCard());
      final rig = await openPivRig(tester, card: card);
      expect(card.log.where((line) => line == 'auth'), isEmpty, reason: 'metadata told');
      await _removeCertificate(rig);
      expect(card.certificate(PivSlot.cardAuthentication), isNull);
      expect(find.textContaining(t('piv.managementKey.used.factory')), findsOneWidget);
    });

    testWidgets('the factory key, on a card without metadata, found by one attempt when it is read', (tester) async {
      final card = await _withCertificate(FakePivCard(makerCommands: false));
      final rig = await openPivRig(tester, card: card);
      expect(card.log.where((line) => line == 'auth'), hasLength(2), reason: 'one exchange, when the card was read');
      await _removeCertificate(rig);
      expect(card.certificate(PivSlot.cardAuthentication), isNull);
    });

    testWidgets('the vault’s note for this key, and a note for another key ignored', (tester) async {
      final card = await _withCertificate(FakePivCard(managementKeyType: PivManagementKeyType.aes256, managementKey: _aes));
      final notes = FakePivNotes()
        ..notes.add(_note('87654321', List.filled(32, 1), id: 'other'))
        ..notes.add(_note('12345678', _aes));
      final rig = await openPivRig(tester, card: card, notes: notes);
      await _removeCertificate(rig);
      expect(card.certificate(PivSlot.cardAuthentication), isNull);
      expect(find.textContaining(t('piv.managementKey.used.vault')), findsOneWidget);
      expect(find.text(t('piv.managementKey.ask.notFound')), findsNothing);
    });

    testWidgets('a note for another key only: the key is asked for, saying a note may be in another vault', (tester) async {
      final card = await _withCertificate(FakePivCard(managementKeyType: PivManagementKeyType.aes256, managementKey: _aes));
      final notes = FakePivNotes()..notes.add(_note('87654321', _aes));
      final rig = await openPivRig(tester, card: card, notes: notes);
      await _removeCertificate(rig);
      expect(find.text(t('piv.managementKey.ask.notFound')), findsOneWidget);
      expect(card.log.where((line) => line == 'auth'), isEmpty, reason: 'the other key’s note was not tried');
    });

    testWidgets('a note whose key is refused says it no longer matches, and the typed key is used', (tester) async {
      final card = await _withCertificate(FakePivCard(managementKeyType: PivManagementKeyType.aes256, managementKey: _aes));
      final notes = FakePivNotes()..notes.add(_note('12345678', List.filled(32, 9)));
      final rig = await openPivRig(tester, card: card, notes: notes);
      await _removeCertificate(rig);

      expect(find.text(t('piv.managementKey.ask.vaultRefused')), findsOneWidget);
      await rig.type('piv.managementKey.field', formatPivManagementKey(_aes).toLowerCase());
      await rig.keys.tap('piv.continue');
      expect(card.certificate(PivSlot.cardAuthentication), isNull);
      expect(find.textContaining(t('piv.managementKey.used.typed')), findsOneWidget);
    });

    testWidgets('a typed key that is not hex of a management key’s length is refused on the phone', (tester) async {
      final card = await _withCertificate(FakePivCard(managementKeyType: PivManagementKeyType.aes256, managementKey: _aes));
      final rig = await openPivRig(tester, card: card);
      await _removeCertificate(rig);
      await rig.type('piv.managementKey.field', 'not a key');
      await rig.keys.tap('piv.continue');
      expect(find.text(t('piv.managementKey.invalid')), findsOneWidget);
      expect(card.log.where((line) => line == 'auth'), isEmpty);
    });
  });

  group('changing it', () {
    testWidgets('a random AES-256 key, kept in a note saved before it is set, and only it is taken after', (tester) async {
      final rig = await openPivRig(tester);
      await _openManagementKey(rig);
      expect(find.text(t('piv.managementKey.keep')), findsOneWidget);
      await rig.keys.tap('piv.changeManagementKey');

      final note = rig.notes.notes.single;
      final piv = note.piv!;
      final key = parsePivManagementKey(piv.managementKey)!;
      expect(rig.card.managementKeyType, PivManagementKeyType.aes256);
      expect(rig.card.managementKey, key);
      expect((piv.key, piv.algorithm), ('12345678', 'aes256'));
      expect(note.spaceId, isNull, reason: 'never in a shared space');
      expect(note.title, t('piv.note.title', {'name': 'Example Key 5C 12345678'}));
      expect(note.text, contains(formatPivManagementKey(key)));
      expect(note.text, contains('AES-256'));
      expect(note.text, contains('Nov 16, 2026'));
      // The note was saved before the key was asked to change.
      expect(rig.notes.log, ['add ${note.title}']);
      expect(find.textContaining(t('piv.managementKey.used.factory')), findsOneWidget);

      // The factory key no longer works; the new one does.
      expect(find.text(t('piv.factoryDefault').toUpperCase()), findsNothing);
      expect(find.text(t('piv.managementKey.inVault')), findsWidgets);
    });

    testWidgets('a card that refuses AES ends on a triple DES key, and says which kind was set', (tester) async {
      final rig = await openPivRig(tester, card: FakePivCard()..refusesAes = true);
      await _openManagementKey(rig);
      await rig.keys.tap('piv.changeManagementKey');

      final piv = rig.notes.notes.single.piv!;
      final key = parsePivManagementKey(piv.managementKey)!;
      expect((rig.card.managementKeyType, piv.algorithm), (PivManagementKeyType.tripleDes, '3des'));
      expect(rig.card.managementKey, key);
      expect(key, withOddParity(key));
      expect(isWeakTripleDesKey(key), isFalse);
      expect(rig.notes.notes.single.text, contains('Triple DES'));
      expect(find.textContaining('Triple DES'), findsWidgets);
    });

    testWidgets('a card that refuses the change keeps its key and is left no note', (tester) async {
      final rig = await openPivRig(tester, card: FakePivCard()..refusesNewManagementKey = true);
      await _openManagementKey(rig);
      await rig.keys.tap('piv.changeManagementKey');

      expect(rig.notes.notes, isEmpty);
      expect(rig.card.managementKey, pivFactoryManagementKey);
      expect(find.text(t('piv.managementKey.refused')), findsOneWidget);
    });

    testWidgets('a vault that cannot save changes nothing on the card', (tester) async {
      final rig = await openPivRig(tester, notes: FakePivNotes()..failAdd = true);
      await _openManagementKey(rig);
      await rig.keys.tap('piv.changeManagementKey');

      expect(rig.card.managementKey, pivFactoryManagementKey);
      expect(rig.card.log.where((line) => line.startsWith('set management key')), isEmpty);
      expect(find.text(t('piv.managementKey.notSaved')), findsOneWidget);
    });

    testWidgets('a key taken away while the new key is set keeps the note, and says to try the new key first', (tester) async {
      final rig = await openPivRig(tester, kinds: nfc);
      await _openManagementKey(rig);
      rig.phone.removeWhen = (frame) => frame.length > 3 && frame[1] == 0xff && frame[2] == 0xff;
      await rig.keys.tap('piv.changeManagementKey');

      expect(rig.notes.notes, hasLength(1));
      expect(find.text(t('piv.managementKey.dropped')), findsOneWidget);
    });

    testWidgets('"show it to me instead" stores no note and changes nothing until "I wrote it down"', (tester) async {
      final rig = await openPivRig(tester);
      await _openManagementKey(rig);
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      await rig.keys.tap('piv.managementKey.showInstead');

      expect(find.text(t('piv.managementKey.show.warning')), findsOneWidget);
      expect(rig.card.log.where((line) => line == 'auth' || line.startsWith('set')), isEmpty);
      await tester.tap(find.text(t('export.cancel')).last);
      await tester.pumpAndSettle();
      expect(rig.card.managementKey, pivFactoryManagementKey);

      await rig.keys.tap('piv.managementKey.showInstead');
      final shown = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
      await rig.keys.tap('piv.managementKey.show.wrote');

      expect(rig.card.managementKey, parsePivManagementKey(shown));
      expect(rig.notes.notes, isEmpty);
      expect(rig.notes.log, isEmpty);
    });

    testWidgets('a card without the maker’s commands says it cannot change it from Kemlock', (tester) async {
      final rig = await openPivRig(tester, card: FakePivCard(makerCommands: false));
      await _openManagementKey(rig);
      expect(find.text(t('piv.managementKey.cannot')), findsWidgets);
      expect(find.text(t('piv.changeManagementKey')), findsNothing);
    });
  });
}

/// Kemlock as a phone runs it, with a vault open from [password] and the
/// Security key sheet open on a key with [card], then its management key
/// sheet.
Future<void> _inTheApp(WidgetTester tester, TestApp app, String password, FakePivCard card) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final phone = FakeSecurityKeys(start: pivNow);
  await app.pump(tester, overrides: [phone.asOverride]);
  await app.controller.open(await app.vaultStore.unlockAnyVault(password, app.vaults.startingVault()));
  app.controller.biometricOffered();
  await tester.pumpAndSettle();
  app.container.read(routerProvider).go('/settings');
  await tester.pumpAndSettle();
  final row = find.widgetWithText(GroupRow, t('securityKeys.settings.row'));
  await tester.ensureVisible(row);
  await tester.tap(row);
  await tester.pumpAndSettle();
  phone.arrive(FakeKey(productName: 'Example Key 5C', ctap: FakeFidoKey(), applets: [card]).device(kinds: usb));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(GroupRow, t('piv.title')));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(GroupRow, t('piv.managementKey')));
  await tester.pumpAndSettle();
  expect(find.byType(PivManagementKeySheet), findsOneWidget);
}

Future<void> _change(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, t('piv.changeManagementKey')).last);
  await tester.pumpAndSettle();
}

/// Everything the phone's storage holds, by key.
Map<String, String?> _stored(TestApp app) => {for (final key in app.store.storedKeys()) key: app.store.getItem(key)};

void appMain() {
  group('in the app', () {
    testWidgets('the note is in the open vault, as a note of its own, outside any space', (tester) async {
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      final card = FakePivCard();
      await _inTheApp(tester, app, 'pw', card);
      await _change(tester);

      final notes = app.container.read(vaultControllerProvider).notes;
      expect(notes, hasLength(1));
      expect(notes.single.spaceId, isNull);
      expect(parsePivManagementKey(notes.single.piv!.managementKey), card.managementKey);
      expect(app.store.storedKeys().any((key) => (app.store.getItem(key) ?? '').contains('Management key')), isFalse);
    });

    testWidgets('a vault whose save fails leaves the card’s management key as it was', (tester) async {
      final store = CrashingStore();
      final app = TestApp(store: store);
      await tester.runAsync(() => app.createVault('pw'));
      final card = FakePivCard();
      await _inTheApp(tester, app, 'pw', card);

      store.diesAt = store.writes + 1;
      await _change(tester);

      expect(card.managementKey, pivFactoryManagementKey);
      expect(card.log.where((line) => line.startsWith('set management key')), isEmpty);
      expect(find.text(t('piv.managementKey.notSaved')), findsOneWidget);
      expect(app.container.read(vaultControllerProvider).notes, isEmpty);
    });

    testWidgets('from a hidden vault the note is in that vault only, and nothing else stored changes', (tester) async {
      final app = TestApp();
      await tester.runAsync(() async {
        await app.createVault('pw');
        await app.vaultStore.setupVault('hidden pw', id: 'c0ffee012345');
      });
      final card = FakePivCard();
      await _inTheApp(tester, app, 'hidden pw', card);
      final before = _stored(app);
      await _change(tester);
      final after = _stored(app);

      expect(app.container.read(vaultControllerProvider).notes, hasLength(1));
      final changed = {
        for (final key in {...before.keys, ...after.keys})
          if (before[key] != after[key]) key,
      };
      expect(changed, isNotEmpty);
      expect(changed.every((key) => key.startsWith('backmycodes_note_data')), isTrue, reason: '$changed');
      expect(app.vaults.hiddenVaultIds(), ['c0ffee012345'], reason: 'still unlisted');
      final hex = card.managementKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      for (final value in after.values) {
        expect(value!.contains('12345678') || value.contains(hex) || value.contains('Example Key'), isFalse);
      }

      // The listed vault knows nothing of it.
      app.controller.lock();
      await tester.pumpAndSettle();
      await app.controller.open(await app.vaultStore.unlockAnyVault('pw', app.vaults.startingVault()));
      await tester.pumpAndSettle();
      expect(app.container.read(vaultControllerProvider).notes, isEmpty);
    });
  });
}
