import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:kemlock/features/breaches/leak_check.dart';
import 'package:kemlock/features/lock/master_password.dart';
import 'package:kemlock/features/lock/setup_screen.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/platform/network.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import '../breaches/leak_kit.dart';
import 'lock_phone.dart';

const _strong = 'Correct-Horse-9';

/// A store whose vault can't be made: it throws [error].
class _FailingStore extends VaultStore {
  _FailingStore(super.store, super.vaults, this.error) : super(deriveKey: fastKdf);

  final Object error;

  @override
  Future<VaultSession> setupVault(String password, {String? id, String? name, Uint8List? salt}) async => throw error;
}

void main() {
  Future<LockPhone> open(WidgetTester tester, {Object? failWith, FakePwnedPasswords? pwned}) async {
    usePhone(tester);
    final phone = LockPhone(
      vaultStore: failWith == null ? null : (store, vaults) => _FailingStore(store, vaults, failWith),
      extra: [...?pwned?.overrides],
    );
    await phone.pump(tester, const SetupScreen());
    await tester.pumpAndSettle();
    return phone;
  }

  Future<void> fill(WidgetTester tester, String password, String confirm) async {
    await typeInto(tester, t('setup.field.password'), password);
    await typeInto(tester, t('setup.field.confirm'), confirm);
  }

  Finder chip(String id) =>
      find.ancestor(of: find.text(t(id)), matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.checked != null));

  group('after every vault was erased for wrong passwords', () {
    final erasedAt = DateTime.utc(2026, 10, 15, 21, 30);

    Future<LockPhone> openErased(WidgetTester tester) async {
      usePhone(tester);
      final phone = LockPhone();
      phone.store.setItem('backmycodes_erased', jsonEncode({'at': erasedAt.millisecondsSinceEpoch, 'after': 10}));
      await phone.pump(tester, const SetupScreen());
      await tester.pumpAndSettle();
      return phone;
    }

    String note() => t('setup.erased', {
      'count': 10,
      'date': DateFormat.yMMMd('en').format(erasedAt.toLocal()),
      'time': DateFormat.Hm('en').format(erasedAt.toLocal()),
    });

    testWidgets('says when and after how many', (tester) async {
      await openErased(tester);

      expect(find.text(note()), findsOneWidget);
      expect(note(), startsWith('Every vault on this phone was erased on Oct 15, 2026 at '));
      expect(note(), contains('after 10 wrong passwords in a row'));
    });

    testWidgets('says it until a vault is made, and no more once one is', (tester) async {
      final phone = await openErased(tester);
      await phone.pump(tester, const SetupScreen());
      await tester.pumpAndSettle();
      expect(find.text(note()), findsOneWidget);

      await fill(tester, _strong, _strong);
      await tester.ensureVisible(buttonLabelled(t('setup.button')));
      await tester.tap(buttonLabelled(t('setup.button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 3 * 280 + 650));
      await tester.pump();

      expect(phone.vaultStore.isVaultSetup(), isTrue);
      expect(phone.state.phase, VaultPhase.unlocked);
      expect(phone.store.getItem('backmycodes_erased'), isNull);
      await phone.pump(tester, const SetupScreen());
      await tester.pumpAndSettle();
      expect(find.textContaining('was erased'), findsNothing);
    });

    testWidgets('says nothing on a phone that never erased', (tester) async {
      await open(tester);

      expect(find.textContaining('was erased'), findsNothing);
    });
  });

  test('rates a password by the checks it passes', () {
    expect(passwordScore('').score, 0);
    expect(passwordScore('abc').score, 1);
    expect(passwordScore('abc').passed, [false, false, true, false, false]);
    expect(passwordScore(_strong).score, 5);
    expect(passwordScore('ABCDEFGHIJKL').passed, [true, true, false, false, false]);
    expect(passwordScore('1234 !').passed, [false, false, false, true, true]);
  });

  test('a master password is twelve characters or more', () {
    expect(masterPasswordMinLength, 12);
    expect(masterPasswordLongEnough(''), isFalse);
    expect(masterPasswordLongEnough('Abcdefgh1!x'), isFalse);
    expect(masterPasswordLongEnough('Abcdefgh1!xy'), isTrue);
    // Characters, not the units they take in memory
    expect(masterPasswordLongEnough('😀😀😀😀😀😀'), isFalse);
  });

  test('the meter never says more than "fair" of a password under twelve characters', () {
    // Four of the five checks, and guessed in no time
    expect(passwordStrength('Aa1!'), (level: 2, bars: 2));
    expect(passwordStrength('Abcdefgh1!x'), (level: 2, bars: 2));
    expect(passwordStrength('abc'), (level: 1, bars: 1));
    expect(passwordStrength(''), (level: 0, bars: 0));
    // From twelve on it is rated by its checks, as before
    expect(passwordStrength('abcdefghijkl'), (level: 2, bars: 2));
    expect(passwordStrength('Abcdefghijkl'), (level: 3, bars: 3));
    expect(passwordStrength('Abcdefgh1!xy'), (level: 4, bars: 5));
  });

  testWidgets('keeps both fields from the phone’s password manager and the keyboard’s learning', (tester) async {
    await open(tester);

    for (final label in [t('setup.field.password'), t('setup.field.confirm')]) {
      final field = tester.widget<TextField>(fieldLabelled(label));
      // Null keeps it out of autofill, which the empty default doesn't
      expect(field.autofillHints, isNull, reason: label);
      expect(field.enableIMEPersonalizedLearning, isFalse, reason: label);
    }
  });

  testWidgets('is disabled until a password is entered', (tester) async {
    await open(tester);

    expect(find.text(t('setup.title')), findsOneWidget);
    expect(find.text(t('setup.stepOf', {'step': 1, 'total': 2})), findsOneWidget);
    expect(isEnabled(tester, t('setup.button')), isFalse);
  });

  testWidgets('rates password strength as the user types', (tester) async {
    await open(tester);

    await typeInto(tester, t('setup.field.password'), 'abc');
    expect(find.text(t('setup.strength.weak')), findsOneWidget);

    // Passing all five checks is the top level, not an out-of-range index
    await typeInto(tester, t('setup.field.password'), _strong);
    expect(find.text(t('setup.strength.veryStrong')), findsOneWidget);
  });

  testWidgets('ticks off each requirement as it is met', (tester) async {
    await open(tester);

    await typeInto(tester, t('setup.field.password'), 'abc');

    expect(find.descendant(of: chip('setup.check.lowercase'), matching: find.byIcon(Icons.check_rounded)), findsOneWidget);
    expect(find.descendant(of: chip('setup.check.uppercase'), matching: find.byIcon(Icons.check_rounded)), findsNothing);
    expect(tester.getSemantics(find.text(t('setup.check.lowercase'))), isSemantics(hasCheckedState: true, isChecked: true));
    expect(tester.getSemantics(find.text(t('setup.check.uppercase'))), isSemantics(hasCheckedState: true, isChecked: false));
  });

  testWidgets('refuses weak passwords even when they match', (tester) async {
    await open(tester);

    await fill(tester, 'password', 'password');

    expect(isEnabled(tester, t('setup.button')), isFalse);
  });

  testWidgets('refuses a password under twelve characters, whatever else it has, and never calls it strong', (tester) async {
    await open(tester);

    // Upper case, lower case, a digit and a symbol: four checks of five, in eleven characters
    await fill(tester, 'Abcdefgh1!x', 'Abcdefgh1!x');

    expect(isEnabled(tester, t('setup.button')), isFalse);
    expect(find.text(t('setup.strength.fair')), findsOneWidget);
    expect(find.text(t('setup.strength.strong')), findsNothing);
    expect(find.text(t('setup.strength.veryStrong')), findsNothing);

    await fill(tester, 'Abcdefgh1!xy', 'Abcdefgh1!xy');

    expect(isEnabled(tester, t('setup.button')), isTrue);
    expect(find.text(t('setup.strength.veryStrong')), findsOneWidget);
  });

  testWidgets('flags mismatched confirmation', (tester) async {
    await open(tester);

    await fill(tester, _strong, '${_strong}x');

    expect(find.text(t('setup.field.mismatch')), findsOneWidget);
    expect(isEnabled(tester, t('setup.button')), isFalse);
  });

  testWidgets('confirms a matching password', (tester) async {
    await open(tester);

    await fill(tester, _strong, _strong);

    expect(tester.getSemantics(find.bySemanticsLabel(t('setup.field.match'))), isSemantics(isImage: true));
    expect(isEnabled(tester, t('setup.button')), isTrue);
  });

  testWidgets('creates the vault with the chosen password, showing each step', (tester) async {
    final phone = await open(tester);
    await fill(tester, _strong, _strong);

    await tester.ensureVisible(buttonLabelled(t('setup.button')));
    await tester.tap(buttonLabelled(t('setup.button')));
    await tester.pump();

    expect(find.text(t('setup.forging.title')), findsOneWidget);
    expect(find.text(t('setup.step.derive')), findsOneWidget);
    expect(phone.vaultStore.isVaultSetup(), isFalse);

    await tester.pump(const Duration(milliseconds: 350));
    expect(phone.vaultStore.isVaultSetup(), isTrue);

    await tester.pump(const Duration(milliseconds: 3 * 280));
    expect(find.text(t('setup.ready.title')), findsOneWidget);
    expect(phone.state.phase, VaultPhase.setup);

    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump();
    expect(phone.state.phase, VaultPhase.unlocked);
    expect(phone.state.session, isNotNull);
    // The vault opens with the password chosen
    await expectLater(phone.vaultStore.unlockVault(_strong), completes);
  });

  testWidgets('creates the vault from the keyboard', (tester) async {
    final phone = await open(tester);
    await fill(tester, _strong, _strong);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(phone.vaultStore.isVaultSetup(), isTrue);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('shows the error and lets the user retry if vault creation fails', (tester) async {
    final phone = await open(
      tester,
      failWith: PlatformException(code: 'storage', message: 'Storage is full'),
    );
    await fill(tester, _strong, _strong);

    await tapOn(tester, buttonLabelled(t('setup.button')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('Storage is full'), findsOneWidget);
    expect(phone.state.phase, VaultPhase.setup);
    expect(isEnabled(tester, t('setup.button')), isTrue);
  });

  testWidgets('says the vault could not be made when the error has no message', (tester) async {
    await open(tester, failWith: StateError('isolate died'));
    await fill(tester, _strong, _strong);

    await tapOn(tester, buttonLabelled(t('setup.button')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text(t('setup.error.failed')), findsOneWidget);
  });

  testWidgets('can reveal the password', (tester) async {
    await open(tester);
    expect(isObscured(tester, t('setup.field.password')), isTrue);

    await tapOn(tester, find.bySemanticsLabel(t('lock.showPassword')));

    expect(isObscured(tester, t('setup.field.password')), isFalse);
    expect(isObscured(tester, t('setup.field.confirm')), isFalse);
    expect(find.bySemanticsLabel(t('lock.hidePassword')), findsOneWidget);
  });

  group('the password leak check', () {
    const leaked = 'Password-12345';

    /// Presses the button that makes the vault, and waits for what comes of it.
    Future<void> submit(WidgetTester tester) async {
      await tapOn(tester, buttonLabelled(t('setup.button')));
    }

    /// Lets the vault be made and opened, once the form was submitted.
    Future<void> finish(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    }

    bool leakCheckOf(LockPhone phone) => phone.container.read(prefsProvider).leakCheck;

    testWidgets('is offered off, and says what is sent and to whom', (tester) async {
      await open(tester, pwned: FakePwnedPasswords());

      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(find.text(t('leakCheck.option')), findsOneWidget);
      expect(find.text(t('leakCheck.option.hint')), findsOneWidget);
      expect(t('leakCheck.option.hint'), allOf(contains('5 characters'), contains('Have I Been Pwned'), contains('stays on this phone')));
    });

    testWidgets('makes no request when it is left off, and the new vault has it off', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 1204});
      final phone = await open(tester, pwned: pwned);
      await fill(tester, leaked, leaked);

      await submit(tester);
      await finish(tester);

      expect(pwned.requests, isEmpty);
      expect(phone.state.phase, VaultPhase.unlocked);
      expect(leakCheckOf(phone), isFalse);
    });

    testWidgets('makes no request while the password is typed, only when it is submitted', (tester) async {
      final pwned = FakePwnedPasswords();
      await open(tester, pwned: pwned);
      await tapOn(tester, find.text(t('leakCheck.option')));

      for (var length = 1; length <= _strong.length; length++) {
        await typeInto(tester, t('setup.field.password'), _strong.substring(0, length));
      }
      await typeInto(tester, t('setup.field.confirm'), _strong);
      expect(pwned.requests, isEmpty);

      await submit(tester);
      expect(pwned.asked, [FakePwnedPasswords.prefixOf(_strong)]);
      await finish(tester);
    });

    testWidgets('makes no request for a password that is too weak or typed differently twice', (tester) async {
      final pwned = FakePwnedPasswords();
      final phone = await open(tester, pwned: pwned);
      await tapOn(tester, find.text(t('leakCheck.option')));

      await fill(tester, 'abc', 'abc');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await fill(tester, _strong, '$_strong!');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(pwned.requests, isEmpty);
      expect(phone.vaultStore.isVaultSetup(), isFalse);
    });

    testWidgets('sends five characters of the hash, and nothing else of the password', (tester) async {
      final pwned = FakePwnedPasswords();
      await open(tester, pwned: pwned);
      await tapOn(tester, find.text(t('leakCheck.option')));
      await fill(tester, _strong, _strong);

      await submit(tester);

      final request = pwned.requests.single;
      final hash = FakePwnedPasswords.hashOf(_strong);
      expect(request.url.toString(), 'https://api.pwnedpasswords.com/range/${hash.substring(0, 5)}');
      expect(request.headers['Add-Padding'], 'true');
      expect(request.headers['User-Agent'], startsWith('Kemlock'));
      final sent = '${request.url.path} ${request.headers} ${request.body}';
      expect(sent, isNot(contains(_strong)));
      expect(sent.toUpperCase(), isNot(contains(hash.substring(5))));
      await finish(tester);
    });

    // openspec: add-offline-mode, "Breach checks are paused"
    testWidgets('while offline mode is on the password is not checked, the screen says so, and the vault is made', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 1204});
      final phone = await open(tester, pwned: pwned);
      phone.container.read(offlineProvider.notifier).set(true);
      await tapOn(tester, find.text(t('leakCheck.option')));

      expect(find.text(t('leakCheck.offline')), findsOneWidget);
      expect(find.descendant(of: find.byType(LeakFindingNotice), matching: find.byType(TextButton)), findsNothing);

      await fill(tester, leaked, leaked);
      await submit(tester);
      await finish(tester);

      expect(pwned.requests, isEmpty);
      expect(phone.state.phase, VaultPhase.unlocked);
      expect(leakCheckOf(phone), isTrue, reason: 'the setting is kept for when offline mode is off');
      await expectLater(phone.vaultStore.unlockVault(leaked), completes);
    });

    testWidgets('while offline mode is on and the check is off, the screen says nothing of it', (tester) async {
      final phone = await open(tester, pwned: FakePwnedPasswords());
      phone.container.read(offlineProvider.notifier).set(true);
      await tester.pumpAndSettle();

      expect(find.text(t('leakCheck.offline')), findsNothing);
    });

    testWidgets('a clean password goes straight on, and the new vault has the check on', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 1204});
      final phone = await open(tester, pwned: pwned);
      await tapOn(tester, find.text(t('leakCheck.option')));
      await fill(tester, _strong, _strong);

      await submit(tester);
      await finish(tester);

      expect(pwned.requests, hasLength(1));
      expect(phone.state.phase, VaultPhase.unlocked);
      expect(leakCheckOf(phone), isTrue);
      await expectLater(phone.vaultStore.unlockVault(_strong), completes);
    });

    testWidgets('a leaked password is not used: the screen says how often it appeared', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 1204});
      final phone = await open(tester, pwned: pwned);
      await tapOn(tester, find.text(t('leakCheck.option')));
      await fill(tester, leaked, leaked);

      await submit(tester);
      await tester.pump(const Duration(seconds: 3));

      expect(find.text('This password appeared 1,204 times in data breaches. Choose another one.'), findsOneWidget);
      expect(find.text(t('leakCheck.useAnyway')), findsOneWidget);
      expect(phone.vaultStore.isVaultSetup(), isFalse);
      expect(phone.state.phase, VaultPhase.setup);
      expect(find.text(t('setup.title')), findsOneWidget);
    });

    testWidgets('choosing another password takes the message away, and the new one is checked when submitted', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 1204});
      final phone = await open(tester, pwned: pwned);
      await tapOn(tester, find.text(t('leakCheck.option')));
      await fill(tester, leaked, leaked);
      await submit(tester);
      expect(find.text(t('leakCheck.useAnyway')), findsOneWidget);

      await typeInto(tester, t('setup.field.password'), _strong);
      expect(find.text(t('leakCheck.useAnyway')), findsNothing);
      expect(pwned.requests, hasLength(1));

      await typeInto(tester, t('setup.field.confirm'), _strong);
      await submit(tester);
      await finish(tester);

      expect(pwned.asked, [FakePwnedPasswords.prefixOf(leaked), FakePwnedPasswords.prefixOf(_strong)]);
      expect(phone.state.phase, VaultPhase.unlocked);
    });

    testWidgets('"Use it anyway" makes the vault with the leaked password, without asking again', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 1204});
      final phone = await open(tester, pwned: pwned);
      await tapOn(tester, find.text(t('leakCheck.option')));
      await fill(tester, leaked, leaked);
      await submit(tester);

      await tapOn(tester, find.text(t('leakCheck.useAnyway')));
      await finish(tester);

      expect(pwned.requests, hasLength(1));
      expect(phone.state.phase, VaultPhase.unlocked);
      expect(leakCheckOf(phone), isTrue);
      await expectLater(phone.vaultStore.unlockVault(leaked), completes);
    });

    testWidgets('a check that cannot be made says so, and neither calls the password leaked nor safe', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 1204}, down: true);
      final phone = await open(tester, pwned: pwned);
      await tapOn(tester, find.text(t('leakCheck.option')));
      await fill(tester, leaked, leaked);

      await submit(tester);

      expect(find.text(t('leakCheck.failed')), findsOneWidget);
      expect(find.text(t('leakCheck.retry')), findsOneWidget);
      expect(find.text(t('leakCheck.continue')), findsOneWidget);
      expect(find.textContaining('appeared'), findsNothing);
      expect(phone.vaultStore.isVaultSetup(), isFalse);
    });

    testWidgets('"Try again" asks again, and reports what the service then says', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 1204}, down: true);
      await open(tester, pwned: pwned);
      await tapOn(tester, find.text(t('leakCheck.option')));
      await fill(tester, leaked, leaked);
      await submit(tester);

      pwned.down = false;
      await tapOn(tester, find.text(t('leakCheck.retry')));

      expect(pwned.requests, hasLength(2));
      expect(find.text(t('leakCheck.failed')), findsNothing);
      expect(find.text(t('leakCheck.useAnyway')), findsOneWidget);
    });

    testWidgets('"Continue without checking" makes the vault, and its check stays on', (tester) async {
      final pwned = FakePwnedPasswords(down: true);
      final phone = await open(tester, pwned: pwned);
      await tapOn(tester, find.text(t('leakCheck.option')));
      await fill(tester, _strong, _strong);
      await submit(tester);

      await tapOn(tester, find.text(t('leakCheck.continue')));
      await finish(tester);

      expect(pwned.requests, hasLength(1));
      expect(phone.state.phase, VaultPhase.unlocked);
      expect(leakCheckOf(phone), isTrue);
    });
  });
}
