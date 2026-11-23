import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../helpers/test_app.dart';
import 'keys_kit.dart';

void main() {
  testWidgets('makes an Ed25519 SSH key by default, under its name, with an ssh-ed25519 line', (tester) async {
    final keys = KeysApp(tester);
    await keys.start();
    await keys.openAdd('vault.add.generateKey');

    expect(find.text(t('keys.generate.default', {'name': 'Ed25519'})), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, t('keys.generate.name')), 'laptop');
    await keys.tap(find.text(t('keys.generate.button')));
    expect(find.text(t('keys.generate.working')), findsOneWidget);
    final generation = keys.generations.single;
    expect((generation.request as crypto.NewKeyRequest).algorithm, crypto.GeneratedAlgorithm.ed25519);
    await tester.runAsync(generation.finish);
    await keys.settle();

    final key = keys.keys.single;
    expect((key.name, key.kind, key.algorithm, key.origin), ('laptop', KeyKind.ssh, 'ed25519', KeyOrigin.generated));
    await keys.tap(find.text('laptop'));
    expect(find.textContaining(RegExp(r'^ssh-ed25519 \S+ laptop$')), findsOneWidget);
  });

  testWidgets('a PGP key needs a name and an email, and says which is missing', (tester) async {
    final keys = KeysApp(tester);
    await keys.start();
    await keys.openAdd('vault.add.generateKey');

    await keys.tap(find.text(t('keys.generate.kind.pgp')));
    await tester.enterText(find.widgetWithText(TextField, t('keys.generate.pgp.name')), 'Ada Lovelace');
    await keys.tap(find.text(t('keys.generate.button')));

    expect(find.text(t('keys.generate.pgp.emailMissing')), findsOneWidget);
    expect(find.text(t('keys.generate.pgp.nameMissing')), findsNothing);
    expect(keys.generations, isEmpty);

    await tester.enterText(find.widgetWithText(TextField, t('keys.generate.pgp.email')), 'ada@example.org');
    await keys.tap(find.text(t('keys.generate.button')));
    final request = keys.generations.single.request as crypto.PgpKeyRequest;
    // The standard post-quantum key, chosen first since add-post-quantum-pgp
    expect((request.name, request.email, request.type), ('Ada Lovelace', 'ada@example.org', crypto.PgpKeyType.pqStandard));
  });

  testWidgets('a cancelled generation adds nothing', (tester) async {
    final keys = KeysApp(tester);
    await keys.start();
    await keys.openAdd('vault.add.generateKey');
    await tester.enterText(find.widgetWithText(TextField, t('keys.generate.name')), 'big');

    await keys.tap(find.text(t('keys.generate.button')));
    await keys.tap(find.text(t('keys.generate.cancel')));
    await tester.runAsync(keys.generations.single.finish);
    await keys.settle();

    expect(keys.generations.single.cancelled, isTrue);
    expect(keys.keys, isEmpty);
    // The sheet is ready to go again
    expect(find.text(t('keys.generate.button')), findsOneWidget);
  });

  testWidgets('a vault that locks while a key is made gets nothing of it', (tester) async {
    final keys = KeysApp(tester);
    await keys.start();
    await keys.openAdd('vault.add.generateKey');
    await tester.enterText(find.widgetWithText(TextField, t('keys.generate.name')), 'late');
    await keys.tap(find.text(t('keys.generate.button')));

    keys.app.container.read(vaultControllerProvider.notifier).lock();
    await tester.pump();
    await tester.runAsync(keys.generations.single.finish);
    await keys.settle();

    expect(keys.generations.single.cancelled, isTrue);
    expect(keys.app.container.read(vaultControllerProvider).keys, isEmpty);
    expect(keys.app.store.getItem('backmycodes_key_data'), isNull);
  });

  testWidgets('offers each kind its algorithms, default first', (tester) async {
    final keys = KeysApp(tester);
    await keys.start();
    await keys.openAdd('vault.add.generateKey');

    await keys.tap(find.text(t('keys.generate.kind.exchange')));
    expect(find.text(t('keys.generate.default', {'name': 'X25519'})), findsOneWidget);
    await keys.tap(find.text(t('keys.generate.default', {'name': 'X25519'})));
    expect(find.text('ML-KEM-768'), findsWidgets);
    expect(find.text('ML-KEM-1024'), findsWidgets);
  });

  // openspec: add-post-quantum-pgp, task 6.5
  testWidgets('the sheet keeps drawing frames while a long generation runs elsewhere', (tester) async {
    final keys = KeysApp(tester);
    await keys.start();
    await keys.openAdd('vault.add.generateKey');
    await tester.enterText(find.widgetWithText(TextField, t('keys.generate.name')), 'slow');
    await keys.tap(find.text(t('keys.generate.button')));
    // The fake generation stays unfinished, as a long one would
    // Each frame asked for is drawn: nothing holds the UI isolate
    var frames = 0;
    for (var i = 0; i < 60; i++) {
      tester.binding.scheduleFrameCallback((_) => frames++);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(frames, greaterThanOrEqualTo(60));
    expect(find.text(t('keys.generate.working')), findsOneWidget);
    await keys.tap(find.text(t('keys.generate.cancel')));
    await tester.runAsync(keys.generations.single.finish);
    await keys.settle();
    expect(keys.keys, isEmpty);
  });

  // openspec: add-post-quantum-pgp, task 7.2
  group('the PGP key types', () {
    Future<KeysApp> openPgp(WidgetTester tester) async {
      final keys = KeysApp(tester);
      await keys.start();
      await keys.openAdd('vault.add.generateKey');
      await keys.tap(find.text(t('keys.generate.kind.pgp')));
      return keys;
    }

    Future<crypto.PgpKeyRequest> generate(KeysApp keys) async {
      await keys.tester.enterText(find.widgetWithText(TextField, t('keys.generate.pgp.name')), 'Ada Lovelace');
      await keys.tester.enterText(find.widgetWithText(TextField, t('keys.generate.pgp.email')), 'ada@example.org');
      await keys.tap(find.text(t('keys.generate.button')));
      return keys.generations.single.request as crypto.PgpKeyRequest;
    }

    testWidgets('four cards in order, each with its caption, the standard one chosen and recommended', (tester) async {
      await openPgp(tester);
      final cards = tester.widgetList<OptionCard>(find.byType(OptionCard)).toList();
      expect(
        [for (final card in cards) card.title],
        [t('keys.generate.pgp.ed25519'), t('keys.generate.pgp.pqStandard'), t('keys.generate.pgp.pqGnupg'), t('keys.generate.pgp.rsa4096')],
      );
      expect(
        [for (final card in cards) card.caption],
        [
          t('keys.generate.pgp.ed25519.caption'),
          t('keys.generate.pgp.pqStandard.caption'),
          t('keys.generate.pgp.pqGnupg.caption'),
          t('keys.generate.pgp.rsa4096.caption'),
        ],
      );
      expect([for (final card in cards) card.selected], [false, true, false, false]);
      expect([for (final card in cards) card.tag], [null, t('keys.generate.pgp.recommended'), null, null]);
      expect(t('keys.generate.pgp.pqStandard.caption'), contains('Sequoia and Proton, not by GnuPG'));
      expect(t('keys.generate.pgp.pqGnupg.caption'), contains('signatures stay Ed25519'));
      expect(t('keys.generate.pgp.ed25519.caption'), contains('Not post-quantum'));
    });

    testWidgets('the request carries the chosen type and expiry', (tester) async {
      final keys = await openPgp(tester);
      await keys.tap(find.text(t('keys.generate.pgp.pqGnupg')));
      expect(tester.widget<OptionCard>(find.byKey(const ValueKey('pgp-type-pqGnupg'))).selected, isTrue);
      await keys.tap(find.byKey(const ValueKey('pgp-expiry')));
      await keys.tap(find.text(t('keys.generate.expires.in5')).last);
      expect(
        find.descendant(of: find.byKey(const ValueKey('pgp-expiry')), matching: find.text(t('keys.generate.expires.in5'))),
        findsOneWidget,
      );
      final request = await generate(keys);
      expect((request.type, request.expiresInYears), (crypto.PgpKeyType.pqGnupg, 5));
    });

    testWidgets('Ed25519 with "Never" makes the request it made before', (tester) async {
      final keys = await openPgp(tester);
      await keys.tap(find.text(t('keys.generate.pgp.ed25519')));
      await keys.tap(find.byKey(const ValueKey('pgp-expiry')));
      await keys.tap(find.text(t('keys.generate.expires.never')).last);
      final request = await generate(keys);
      expect(
        (request.name, request.email, request.type, request.expiresInYears),
        ('Ada Lovelace', 'ada@example.org', crypto.PgpKeyType.ed25519, null),
      );
    });

    // Task 9.4: key editing can push the date back, so design decision 11's two years
    testWidgets('the expiry is two years unless changed, and nothing says it cannot be moved later', (tester) async {
      final keys = await openPgp(tester);
      expect(
        find.descendant(of: find.byKey(const ValueKey('pgp-expiry')), matching: find.text(t('keys.generate.expires.in2'))),
        findsOneWidget,
      );
      expect(find.textContaining('cannot move this date'), findsNothing);
      expect((await generate(keys)).expiresInYears, 2);
    });

    testWidgets('a post-quantum key: the working row and Cancel, and a vault that locks adds nothing', (tester) async {
      final keys = await openPgp(tester);
      await generate(keys);
      expect(find.text(t('keys.generate.working')), findsOneWidget);
      expect(find.text(t('keys.generate.cancel')), findsOneWidget);
      // The cards cannot be changed meanwhile
      expect(tester.widget<OptionCard>(find.byKey(const ValueKey('pgp-type-ed25519'))).onTap, isNull);
      keys.app.container.read(vaultControllerProvider.notifier).lock();
      await tester.pump();
      await tester.runAsync(keys.generations.single.finish);
      await keys.settle();
      expect(keys.generations.single.cancelled, isTrue);
      expect(keys.app.container.read(vaultControllerProvider).keys, isEmpty);
    });

    testWidgets('a post-quantum key is made', (tester) async {
      final keys = await openPgp(tester);
      await generate(keys);
      await tester.runAsync(keys.generations.single.finish);
      await keys.settle();
      expect(keys.keys.single.kind, KeyKind.pgp);
    });
  });
}
