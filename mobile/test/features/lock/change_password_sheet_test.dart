import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/features/lock/change_password_sheet.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/features/spaces/space_policies_provider.dart';
import 'package:kemlock/platform/network.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../helpers/test_app.dart';
import '../breaches/leak_kit.dart';
import '../spaces/chain_kit.dart';
import '../spaces/policy_kit.dart';
import 'key_phone.dart';
import 'lock_phone.dart';

void main() {
  /// Opens the vault on [phone], with `old-password`, and the sheet over a page.
  Future<VaultSession> open(WidgetTester tester, LockPhone phone) async {
    usePhone(tester);
    final session = await phone.createVault(tester, 'old-password');
    await phone.pump(tester, const SheetOpener(showChangePasswordSheet));
    await phone.controller.open(session);
    await tapOn(tester, find.text('Open'));
    return session;
  }

  Future<void> fill(WidgetTester tester, {required String current, required String next, required String confirm}) async {
    await typeInto(tester, t('changePw.field.current'), current);
    await typeInto(tester, t('changePw.field.new'), next);
    await typeInto(tester, t('changePw.field.confirm'), confirm);
  }

  bool canChange(WidgetTester tester) => isEnabled(tester, t('changePw.button'));

  testWidgets('keeps the button off until all three are filled, and flags a mismatch', (tester) async {
    await open(tester, LockPhone());
    expect(find.text(t('changePw.title')), findsOneWidget);
    expect(find.text(t('changePw.body')), findsOneWidget);
    expect(canChange(tester), isFalse);

    await fill(tester, current: 'old-password', next: 'new-password', confirm: 'new-passwor');
    expect(find.text(t('changePw.field.mismatch')), findsOneWidget);
    expect(canChange(tester), isFalse);

    await typeInto(tester, t('changePw.field.confirm'), 'new-password');
    expect(find.text(t('changePw.field.mismatch')), findsNothing);
    expect(canChange(tester), isTrue);
  });

  testWidgets('keeps the three fields from the phone’s password manager and the keyboard’s learning', (tester) async {
    await open(tester, LockPhone());

    for (final id in ['changePw.field.current', 'changePw.field.new', 'changePw.field.confirm']) {
      final field = tester.widget<TextField>(fieldLabelled(t(id)));
      // Null keeps it out of autofill, which the empty default doesn't
      expect(field.autofillHints, isNull, reason: id);
      expect(field.enableIMEPersonalizedLearning, isFalse, reason: id);
    }
  });

  testWidgets('refuses a new password under 12 characters', (tester) async {
    final phone = LockPhone();
    await open(tester, phone);

    await fill(tester, current: 'old-password', next: 'eleven-char', confirm: 'eleven-char');
    await tapOn(tester, buttonLabelled(t('changePw.button')));

    expect(find.text(t('changePw.error.tooShort')), findsOneWidget);
    await expectLater(phone.vaultStore.unlockVault('old-password'), completes);
  });

  testWidgets('refuses a 12-character password in a space that requires 14, naming the space, and takes one of 14', (tester) async {
    final phone = LockPhone();
    await open(tester, phone);
    final member = Person(2);
    phone.container.read(spacePoliciesProvider.notifier)
      ..report(uuid(0x5a), member.id, spaceWithPolicies(0x5a, member, {'masterPassword': masterPasswordOf(14)}))
      ..name(uuid(0x5a), 'Example Co');

    await fill(tester, current: 'old-password', next: 'twelve-chars', confirm: 'twelve-chars');
    await tapOn(tester, buttonLabelled(t('changePw.button')));

    expect(find.text(t('changePw.error.space', {'space': 'Example Co', 'length': 14})), findsOneWidget);
    expect(find.text(t('changePw.error.tooShort')), findsNothing, reason: 'the vault’s own 12 is met');
    await expectLater(phone.vaultStore.unlockVault('old-password'), completes);

    await typeInto(tester, t('changePw.field.new'), 'fourteen-chars');
    await typeInto(tester, t('changePw.field.confirm'), 'fourteen-chars');
    await tapOn(tester, buttonLabelled(t('changePw.button')));

    await expectLater(phone.vaultStore.unlockVault('fourteen-chars'), completes);
  });

  testWidgets('keeps the spaces’ policies when a password change installs a new session, and drops them on lock', (tester) async {
    final phone = LockPhone();
    await open(tester, phone);
    final member = Person(2);
    phone.container
        .read(spacePoliciesProvider.notifier)
        .report(uuid(0x5a), member.id, spaceWithPolicies(0x5a, member, {'masterPassword': masterPasswordOf(14)}));

    final next = await phone.vaultStore.unlockVault('old-password');
    phone.controller.passwordChanged(next);
    await tester.pump();

    expect(phone.state.session, same(next), reason: 'the vault goes on with a new session');
    expect(phone.container.read(spacePoliciesProvider).spaces.keys, [uuid(0x5a)], reason: 'what was read since the vault opened stays');
    expect(phone.container.read(spacePoliciesProvider).shortfallsOf('twelve-chars'), hasLength(1));

    phone.controller.lock();
    await tester.pump();

    expect(phone.container.read(spacePoliciesProvider).spaces, isEmpty);
  });

  testWidgets('says when the current password is wrong', (tester) async {
    final phone = LockPhone();
    await open(tester, phone);

    await fill(tester, current: 'guess', next: 'new-password', confirm: 'new-password');
    await tapOn(tester, buttonLabelled(t('changePw.button')));

    expect(find.text(t('changePw.error.incorrect')), findsOneWidget);
    expect(canChange(tester), isTrue);
    await expectLater(phone.vaultStore.unlockVault('new-password'), throwsA(isA<AesGcmAuthError>()));
  });

  testWidgets('changes the password and keeps the vault’s keys', (tester) async {
    final phone = LockPhone();
    final session = await open(tester, phone);

    await fill(tester, current: 'old-password', next: 'new-password', confirm: 'new-password');
    await tapOn(tester, buttonLabelled(t('changePw.button')));

    expect(find.text(t('changePw.body')), findsNothing);
    expect(phone.container.read(toastsProvider)?.message, t('app.snack.passwordChanged'));
    expect(phone.state.session, same(session));
    expect((await phone.vaultStore.unlockVault('new-password')).secretKey, session.secretKey);
    await expectLater(phone.vaultStore.unlockVault('old-password'), throwsA(isA<AesGcmAuthError>()));
  });

  testWidgets('changes it from the keyboard', (tester) async {
    final phone = LockPhone();
    await open(tester, phone);

    await fill(tester, current: 'old-password', next: 'new-password', confirm: 'new-password');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await expectLater(phone.vaultStore.unlockVault('new-password'), completes);
  });

  testWidgets('can be cancelled', (tester) async {
    final phone = LockPhone();
    await open(tester, phone);

    await fill(tester, current: 'old-password', next: 'new-password', confirm: 'new-password');
    await tapOn(tester, buttonLabelled(t('changePw.cancel')));

    expect(find.text(t('changePw.body')), findsNothing);
    await expectLater(phone.vaultStore.unlockVault('old-password'), completes);
  });

  testWidgets('can reveal the passwords', (tester) async {
    await open(tester, LockPhone());
    for (final id in ['changePw.field.current', 'changePw.field.new', 'changePw.field.confirm']) {
      expect(isObscured(tester, t(id)), isTrue);
    }

    await tapOn(tester, find.bySemanticsLabel(t('lock.showPassword')));

    for (final id in ['changePw.field.current', 'changePw.field.new', 'changePw.field.confirm']) {
      expect(isObscured(tester, t(id)), isFalse);
    }
  });

  group('the password leak check', () {
    const leaked = 'leaked-password';

    /// A phone whose vault has the check on or off, with [pwned] for Pwned Passwords.
    LockPhone phoneWith(FakePwnedPasswords pwned, {required bool on}) {
      final phone = LockPhone(extra: pwned.overrides);
      if (on) phone.store.setItem(prefsKey, '{"leakCheck":true}');
      return phone;
    }

    bool box(WidgetTester tester) => tester.widget<Checkbox>(find.byType(Checkbox)).value!;

    testWidgets('makes no request when the vault has it off', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 9});
      final phone = phoneWith(pwned, on: false);
      await open(tester, phone);
      expect(box(tester), isFalse);
      expect(find.text(t('leakCheck.option.hint')), findsOneWidget);

      await fill(tester, current: 'old-password', next: leaked, confirm: leaked);
      await tapOn(tester, buttonLabelled(t('changePw.button')));

      expect(pwned.requests, isEmpty);
      await expectLater(phone.vaultStore.unlockVault(leaked), completes);
    });

    testWidgets('checks the new password, and only that one, when the vault has it on', (tester) async {
      final pwned = FakePwnedPasswords();
      final phone = phoneWith(pwned, on: true);
      await open(tester, phone);
      expect(box(tester), isTrue);

      await fill(tester, current: 'old-password', next: 'new-password', confirm: 'new-password');
      expect(pwned.requests, isEmpty);
      await tapOn(tester, buttonLabelled(t('changePw.button')));

      expect(pwned.asked, [FakePwnedPasswords.prefixOf('new-password')]);
      expect(find.text(t('changePw.body')), findsNothing);
      await expectLater(phone.vaultStore.unlockVault('new-password'), completes);
    });

    testWidgets('does not change to a leaked password, and says how often it appeared', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 1204});
      final phone = phoneWith(pwned, on: true);
      await open(tester, phone);

      await fill(tester, current: 'old-password', next: leaked, confirm: leaked);
      await tapOn(tester, buttonLabelled(t('changePw.button')));

      expect(find.text(t('leakCheck.leaked', {'count': 1204})), findsOneWidget);
      expect(find.text(t('changePw.body')), findsOneWidget);
      await expectLater(phone.vaultStore.unlockVault('old-password'), completes);
      await expectLater(phone.vaultStore.unlockVault(leaked), throwsA(isA<AesGcmAuthError>()));
    });

    testWidgets('keeps a leaked password when told to, without asking again', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 1204});
      final phone = phoneWith(pwned, on: true);
      await open(tester, phone);
      await fill(tester, current: 'old-password', next: leaked, confirm: leaked);
      await tapOn(tester, buttonLabelled(t('changePw.button')));

      await tapOn(tester, find.text(t('leakCheck.useAnyway')));

      expect(pwned.requests, hasLength(1));
      expect(find.text(t('changePw.body')), findsNothing);
      await expectLater(phone.vaultStore.unlockVault(leaked), completes);
    });

    testWidgets('takes the message away when the new password is edited', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 1204});
      await open(tester, phoneWith(pwned, on: true));
      await fill(tester, current: 'old-password', next: leaked, confirm: leaked);
      await tapOn(tester, buttonLabelled(t('changePw.button')));

      await typeInto(tester, t('changePw.field.new'), 'another-password');

      expect(find.text(t('leakCheck.useAnyway')), findsNothing);
      expect(pwned.requests, hasLength(1));
    });

    // openspec: add-offline-mode, "Breach checks are paused"
    testWidgets('while offline mode is on the new password is not checked, and the sheet says so', (tester) async {
      final pwned = FakePwnedPasswords(leaked: {leaked: 1204});
      final phone = phoneWith(pwned, on: true);
      await open(tester, phone);
      phone.container.read(offlineProvider.notifier).set(true);
      await tester.pumpAndSettle();

      expect(box(tester), isTrue, reason: 'the setting keeps its value');
      expect(find.text(t('leakCheck.offline')), findsOneWidget);
      expect(find.text(t('leakCheck.retry')), findsNothing);
      expect(find.text(t('leakCheck.useAnyway')), findsNothing);

      await fill(tester, current: 'old-password', next: leaked, confirm: leaked);
      await tapOn(tester, buttonLabelled(t('changePw.button')));

      expect(pwned.requests, isEmpty);
      await expectLater(phone.vaultStore.unlockVault(leaked), completes);
      expect(phone.container.read(prefsProvider).leakCheck, isTrue);
    });

    testWidgets('says when the check cannot be made, and goes on without it when told to', (tester) async {
      final pwned = FakePwnedPasswords(down: true);
      final phone = phoneWith(pwned, on: true);
      await open(tester, phone);
      await fill(tester, current: 'old-password', next: 'new-password', confirm: 'new-password');

      await tapOn(tester, buttonLabelled(t('changePw.button')));
      expect(find.text(t('leakCheck.failed')), findsOneWidget);
      expect(find.text(t('leakCheck.retry')), findsOneWidget);
      await expectLater(phone.vaultStore.unlockVault('old-password'), completes);

      await tapOn(tester, find.text(t('leakCheck.continue')));

      expect(pwned.requests, hasLength(1));
      await expectLater(phone.vaultStore.unlockVault('new-password'), completes);
      expect(phone.container.read(prefsProvider).leakCheck, isTrue);
    });

    testWidgets('still says when the current password is wrong, after the check', (tester) async {
      final pwned = FakePwnedPasswords();
      final phone = phoneWith(pwned, on: true);
      await open(tester, phone);

      await fill(tester, current: 'guess', next: 'new-password', confirm: 'new-password');
      await tapOn(tester, buttonLabelled(t('changePw.button')));

      expect(find.text(t('changePw.error.incorrect')), findsOneWidget);
      await expectLater(phone.vaultStore.unlockVault('old-password'), completes);
    });

    testWidgets('makes no request for a new password that is too short', (tester) async {
      final pwned = FakePwnedPasswords();
      await open(tester, phoneWith(pwned, on: true));

      await fill(tester, current: 'old-password', next: 'short', confirm: 'short');
      await tapOn(tester, buttonLabelled(t('changePw.button')));

      expect(find.text(t('changePw.error.tooShort')), findsOneWidget);
      expect(pwned.requests, isEmpty);
    });

    testWidgets('the checkbox is the vault\'s setting: ticking it turns the check on for the vault', (tester) async {
      final pwned = FakePwnedPasswords();
      final phone = phoneWith(pwned, on: false);
      await open(tester, phone);

      await tapOn(tester, find.text(t('leakCheck.option')));
      expect(phone.container.read(prefsProvider).leakCheck, isTrue);

      await tapOn(tester, find.text(t('leakCheck.option')));
      expect(phone.container.read(prefsProvider).leakCheck, isFalse);
      expect(phone.store.getItem(prefsKey), isNot(contains('leakCheck')));
    });
  });

  // openspec: add-security-key-unlock, task 6.7
  group('with security keys', () {
    Future<VaultSession> openKeyed(WidgetTester tester, KeyPhone rig, List<SoftKey> keys, UnlockMode mode) async {
      usePhone(tester);
      final session = await rig.phone.createVault(tester, 'old-password');
      await rig.keyUp(tester, session, password: 'old-password', keys: keys, mode: mode);
      await rig.phone.pump(tester, const SheetOpener(showChangePasswordSheet));
      await rig.phone.controller.open(session);
      await tapOn(tester, find.text('Open'));
      return session;
    }

    testWidgets('a vault that needs both is asked for its password and its key, and keeps its key', (tester) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      await openKeyed(tester, rig, [blue], UnlockMode.both);

      await fill(tester, current: 'old-password', next: 'new-password', confirm: 'new-password');
      await tapOn(tester, buttonLabelled(t('changePw.button')));
      expect(find.text(t('unlockMethod.prove.key.title')), findsOneWidget);
      rig.hold(blue);
      await typeInto(tester, t('lock.key.pin'), '123456');
      await tapOn(tester, buttonLabelled(t('lock.key.read')));

      expect(find.text(t('changePw.title')), findsNothing);
      final store = rig.phone.vaultStore;
      expect(store.unlockMode(), UnlockMode.both);
      expect(store.enrolledKeys(), hasLength(1));
      await tester.runAsync(() async {
        expect(await store.beginUnlock('new-password', mainVault), isA<UnlockNeedsKey>());
        await expectLater(store.beginUnlock('old-password', mainVault), throwsA(isA<IncorrectPasswordError>()));
      });
    });

    testWidgets('closing the key’s sheet changes nothing', (tester) async {
      final rig = KeyPhone();
      await openKeyed(tester, rig, [SoftKey(pin: '123456')], UnlockMode.both);
      final stored = rig.phone.store.getItem(keyConfig);

      await fill(tester, current: 'old-password', next: 'new-password', confirm: 'new-password');
      await tapOn(tester, buttonLabelled(t('changePw.button')));
      await tapOn(tester, buttonLabelled(t('export.cancel')).last);

      expect(rig.phone.store.getItem(keyConfig), stored);
      expect(find.text(t('changePw.title')), findsOneWidget);
    });

    testWidgets('a vault that opens with its password and has a key is asked for no key, and keeps the key', (tester) async {
      final rig = KeyPhone();
      await openKeyed(tester, rig, [SoftKey(pin: '123456')], UnlockMode.password);

      await fill(tester, current: 'old-password', next: 'new-password', confirm: 'new-password');
      await tapOn(tester, buttonLabelled(t('changePw.button')));

      expect(find.text(t('unlockMethod.prove.key.title')), findsNothing);
      expect(find.text(t('changePw.title')), findsNothing);
      expect(rig.phone.vaultStore.enrolledKeys(), hasLength(1));
      await expectLater(tester.runAsync(() => rig.phone.vaultStore.unlockVault('new-password')), completes);
    });
  });
}
