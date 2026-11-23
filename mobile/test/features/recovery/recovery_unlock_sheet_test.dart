import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/time.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/recovery/recovery_shares.dart';
import 'package:kemlock/features/recovery/recovery_unlock_sheet.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_scanner.dart';
import '../../helpers/test_app.dart';
import 'recovery_harness.dart';

Finder get _field => find.widgetWithText(TextField, t('recovery.collect.field'));
Finder get _add => find.widgetWithText(FilledButton, t('recovery.collect.add'));
Finder get _newPassword => find.widgetWithText(TextField, t('changePw.field.new'));
Finder get _confirm => find.widgetWithText(TextField, t('changePw.field.confirm'));
Finder get _save => find.widgetWithText(FilledButton, t('recovery.unlock.save'));

/// Pastes [text] into the piece field and taps Add piece.
Future<void> _addPiece(WidgetTester tester, String text) async {
  await tester.enterText(_field, text);
  await tester.pump();
  await tester.ensureVisible(_add);
  await tester.tap(_add);
  await tester.pumpAndSettle();
}

/// A vault with the password [password] and a kit of [threshold] of [shares] pieces.
Future<List<String>> _vaultWithKit(RecoveryVaults vaults, String password, {int threshold = 2, int shares = 3}) async {
  final session = await vaults.vaults.setupVault(password);
  final kit = makeKit(threshold, shares);
  await vaults.vaults.setRecoveryKey(
    session,
    RecoveryKey(kitId: kit.kitId, key: kit.key, threshold: threshold, shares: shares, createdAt: isoString(testNow)),
  );
  return kit.pieces;
}

/// Opens the sheet; what it resolved to lands in the returned list.
Future<List<VaultSession?>> _open(WidgetTester tester, RecoveryVaults vaults, {List<Override> overrides = const []}) async {
  final results = <VaultSession?>[];
  await pumpLauncher(tester, vaults, (context) async => results.add(await showRecoveryUnlockSheet(context)), overrides: overrides);
  return results;
}

/// Gets past the pieces of a one-piece kit to the new password.
Future<List<VaultSession?>> _openToNewPassword(WidgetTester tester, RecoveryVaults vaults) async {
  final pieces = await _vaultWithKit(vaults, 'forgotten', threshold: 1, shares: 1);
  final results = await _open(tester, vaults);
  await _addPiece(tester, pieces.single);
  expect(find.text(t('recovery.unlock.opened')), findsOneWidget);
  return results;
}

void main() {
  testWidgets('opens the vault from typed pieces, then sets a new password', (tester) async {
    final vaults = RecoveryVaults();
    final pieces = await _vaultWithKit(vaults, 'forgotten');
    final results = await _open(tester, vaults);
    expect(find.text(t('recovery.unlock.title')), findsOneWidget);
    expect(find.text(t('recovery.unlock.body')), findsOneWidget);

    await _addPiece(tester, pieces[2].toLowerCase());
    expect(find.text(t('recovery.collect.progress', {'count': 1, 'needed': 2})), findsOneWidget);

    // A piece typed twice is refused
    await _addPiece(tester, pieces[2]);
    expect(find.text(t('recovery.piece.error.duplicate')), findsOneWidget);

    await _addPiece(tester, pieces[0]);
    expect(find.text(t('recovery.unlock.opened')), findsOneWidget);
    expect(find.text(t('recovery.unlock.newPassword')), findsOneWidget);

    await tester.enterText(_newPassword, 'brand new password');
    await tester.enterText(_confirm, 'brand new password');
    await tester.pump();
    await tester.ensureVisible(_save);
    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(results, [isA<VaultSession>()]);
    expect(find.text(t('recovery.unlock.newPassword')), findsNothing);
    await expectLater(vaults.vaults.unlockVault('brand new password'), completion(isA<VaultSession>()));
    await expectLater(vaults.vaults.unlockVault('forgotten'), throwsA(anything));
  });

  testWidgets('opens the vault from scanned pieces', (tester) async {
    final vaults = RecoveryVaults();
    final pieces = await _vaultWithKit(vaults, 'forgotten');
    final scanner = FakeScanner();
    await _open(tester, vaults, overrides: [scanner.asOverride]);

    final scan = find.widgetWithText(FilledButton, t('recovery.collect.scan'));
    await tester.ensureVisible(scan);
    await tester.tap(scan);
    await tester.pumpAndSettle();
    await scanner.emitScan(tester, pieces[1]);
    await tester.pumpAndSettle();
    await scanner.emitScan(tester, pieces[0]);
    await tester.pumpAndSettle();

    expect(find.text(t('recovery.unlock.opened')), findsOneWidget);
    expect(scanner.isScanning, isFalse);
  });

  testWidgets('says so when the pieces belong to no vault here', (tester) async {
    final vaults = RecoveryVaults();
    await vaults.vaults.setupVault('pw');
    await _open(tester, vaults);

    await _addPiece(tester, makeKit(1, 1).pieces.single);

    expect(find.text(t('recovery.unlock.noVault')), findsOneWidget);
    // The collector starts over, ready for the right pieces
    expect(find.text(t('recovery.collect.start')), findsOneWidget);
    expect(find.text(t('recovery.collect.piece', {'index': 1, 'shares': 1})), findsNothing);
    expect(tester.widget<TextField>(_field).enabled, isTrue);
  });

  /// The first vault, and a Work vault, [listed] or hidden, whose one-piece kit is returned; the lock
  /// screen is on the first vault.
  Future<({String first, String work, List<String> pieces})> twoVaults(RecoveryVaults vaults, {bool listed = true}) async {
    await vaults.vaults.setupVault('first');
    final first = vaults.registry.active;
    final work = await vaults.vaults.createVault('Work', 'second', listed: listed);
    vaults.registry.active = work;
    final kit = makeKit(1, 1);
    await vaults.vaults.setRecoveryKey(
      await vaults.vaults.unlockVault('second'),
      RecoveryKey(kitId: kit.kitId, key: kit.key, threshold: 1, shares: 1, createdAt: isoString(testNow)),
    );
    vaults.registry.active = first;
    return (first: first, work: work, pieces: kit.pieces);
  }

  testWidgets('makes the vault the pieces open the active one, and keeps it so once its password is saved', (tester) async {
    final vaults = RecoveryVaults();
    final (:first, :work, :pieces) = await twoVaults(vaults);
    final results = await _open(tester, vaults);

    await _addPiece(tester, pieces.single);

    expect(find.text(t('recovery.unlock.opened')), findsOneWidget);
    expect(vaults.registry.active, work);
    await tester.enterText(_newPassword, 'brand new password');
    await tester.enterText(_confirm, 'brand new password');
    await tester.pump();
    await tester.ensureVisible(_save);
    await tester.tap(_save);
    await tester.pumpAndSettle();
    expect(results, [isA<VaultSession>()]);
    expect(vaults.registry.active, work);
    expect(first, isNot(work));
  });

  // The lock screen still shows the first vault: storage pointing at Work would offer and open Work's things there
  testWidgets('closed before the new password is saved, points storage back at the vault on screen', (tester) async {
    final vaults = RecoveryVaults();
    final (:first, :work, :pieces) = await twoVaults(vaults, listed: false);
    final results = await _open(tester, vaults);
    await _addPiece(tester, pieces.single);
    expect(vaults.registry.active, work);

    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await tester.pumpAndSettle();

    expect(results, [isNull]);
    expect(vaults.registry.active, first);
    // Nothing was saved: Work still opens with its password
    vaults.registry.active = work;
    await expectLater(vaults.vaults.unlockVault('second'), completion(isA<VaultSession>()));
  });

  testWidgets('keeps the new password from the phone’s password manager, and closing offers to save nothing', (tester) async {
    final vaults = RecoveryVaults();
    final results = await _openToNewPassword(tester, vaults);
    for (final field in [_newPassword, _confirm]) {
      // Null keeps it out of autofill, which the empty default doesn't
      expect(tester.widget<TextField>(field).autofillHints, isNull);
      expect(tester.widget<TextField>(field).enableIMEPersonalizedLearning, isFalse);
    }
    await tester.enterText(_newPassword, 'brand new password');
    await tester.enterText(_confirm, 'brand new password');
    tester.testTextInput.log.clear();

    // Closed without saving, as the back gesture does
    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await tester.pumpAndSettle();

    expect(results, [isNull]);
    final finished = tester.testTextInput.log.where((call) => call.method == 'TextInput.finishAutofillContext');
    expect(finished.map((call) => call.arguments), [false]);
  });

  testWidgets('asks for a new password of at least 12 characters', (tester) async {
    final vaults = RecoveryVaults();
    final results = await _openToNewPassword(tester, vaults);

    await tester.enterText(_newPassword, 'eleven-char');
    await tester.enterText(_confirm, 'eleven-char');
    await tester.pump();
    await tester.ensureVisible(_save);
    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(find.text(t('changePw.error.tooShort')), findsOneWidget);
    expect(results, isEmpty);
    await expectLater(vaults.vaults.unlockVault('forgotten'), completion(isA<VaultSession>()));
  });

  testWidgets('says when the passwords differ, and saves only when they match', (tester) async {
    final vaults = RecoveryVaults();
    final results = await _openToNewPassword(tester, vaults);
    expect(tester.widget<FilledButton>(_save).onPressed, isNull);

    await tester.enterText(_newPassword, 'brand new password');
    await tester.enterText(_confirm, 'brand new pass');
    await tester.pump();
    expect(find.text(t('changePw.field.mismatch')), findsOneWidget);
    expect(tester.widget<FilledButton>(_save).onPressed, isNull);

    await tester.enterText(_confirm, 'brand new password');
    await tester.pump();
    expect(find.text(t('changePw.field.mismatch')), findsNothing);

    // Done on the keyboard saves too
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(results, [isA<VaultSession>()]);
  });

  testWidgets('resolves to nothing when cancelled', (tester) async {
    final vaults = RecoveryVaults();
    await _vaultWithKit(vaults, 'pw');
    final results = await _open(tester, vaults);

    await tester.tap(find.text(t('changePw.cancel')));
    await tester.pumpAndSettle();

    expect(results, [isNull]);
    expect(find.text(t('recovery.unlock.title')), findsNothing);
  });

  // openspec: add-security-key-unlock, task 6.9
  testWidgets('says a vault with security keys will open with the new password alone, and removes its keys', (tester) async {
    final vaults = RecoveryVaults();
    final store = vaults.vaults;
    final session = await store.setupVault('forgotten');
    final kit = makeKit(1, 1);
    await store.setRecoveryKey(
      session,
      RecoveryKey(kitId: kit.kitId, key: kit.key, threshold: 1, shares: 1, createdAt: isoString(testNow)),
    );
    final proof = await store.enrolKey(
      session,
      await store.proveOwner(password: 'forgotten'),
      salt: store.keyChallenge().salt,
      credential: randomBytes(64),
      output: randomBytes(32),
      name: 'Example Key',
      pinBound: true,
    );
    await store.setUnlockMode(session, proof, UnlockMode.both);
    final results = await _open(tester, vaults);

    await _addPiece(tester, kit.pieces.single);
    expect(find.text(t('unlockMethod.recovery.keys')), findsOneWidget);
    await tester.enterText(_newPassword, 'brand new password');
    await tester.enterText(_confirm, 'brand new password');
    await tester.pump();
    await tester.ensureVisible(_save);
    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(results, [isA<VaultSession>()]);
    expect(store.unlockMode(), UnlockMode.password);
    expect(store.enrolledKeys(), isEmpty);
    await expectLater(store.unlockVault('brand new password'), completion(isA<VaultSession>()));
  });

  testWidgets('says nothing of keys for a vault without them', (tester) async {
    final vaults = RecoveryVaults();
    await _openToNewPassword(tester, vaults);
    expect(find.text(t('unlockMethod.recovery.keys')), findsNothing);
  });
}
