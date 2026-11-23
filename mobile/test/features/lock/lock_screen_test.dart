import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/storage/preferences_backend.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/features/lock/key_reader.dart';
import 'package:kemlock/features/lock/lock_screen.dart';
import 'package:kemlock/features/lock/unlock_attempts.dart';
import 'package:kemlock/features/mail/mail_grants.dart';
import 'package:kemlock/features/mail/mail_handler.dart';
import 'package:kemlock/features/settings/auto_lock.dart';
import 'package:kemlock/features/share/shared_item_waiting.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/platform/shared_items.dart';
import 'package:kemlock/platform/unlock_keys.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_security_keys.dart';
import '../../fakes/fake_shared_items.dart';
import '../../fakes/fake_unlock_keys.dart';
import '../../flows/flow_kit.dart' show pumpUntil, submitPassword;
import '../../helpers/old_biometric_entry.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import '../../vault/rotation_helpers.dart' show newKit;
import '../mail/mail_app_kit.dart';
import 'key_phone.dart' show SoftKey, pinBytes, testKeyPrompts;
import 'lock_phone.dart';

void main() {
  /// Shows the lock screen on [phone], with [recovery] as the Recovery Kit sheet.
  Future<void> open(WidgetTester tester, LockPhone phone, {Future<VaultSession?> Function(BuildContext context)? recovery}) async {
    usePhone(tester);
    await phone.pump(tester, LockScreen(openRecovery: recovery ?? (_) async => null));
    await tester.pumpAndSettle();
  }

  Finder passwordField() => fieldLabelled(t('unlock.field.password'));
  TextField field(WidgetTester tester) => tester.widget<TextField>(passwordField());

  /// Types [password] and presses the keyboard's Go key.
  Future<void> submit(WidgetTester tester, String password) async {
    await tester.enterText(passwordField(), password);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
  }

  /// Lets the vault's opening play out.
  Future<void> opening(WidgetTester tester) async {
    await tester.pump(openDelay);
    await tester.pumpAndSettle();
  }

  group('the master password', () {
    testWidgets('asks for the password straight away when no quick unlock is set up', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);

      expect(find.text(t('lock.title.locked')), findsOneWidget);
      expect(find.text(t('lock.sub.locked')), findsOneWidget);
      expect(field(tester).focusNode!.hasFocus, isTrue);
      expect(find.text(t('unlock.passkey.useBiometric')), findsNothing);
      expect(phone.biometrics.prompts, isEmpty);
    });

    testWidgets('unlocks with the master password', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);

      await tester.enterText(passwordField(), 'secret');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel(t('unlock.button')));
      await tester.pump();
      expect(find.text(t('lock.title.verifying')), findsOneWidget);
      expect(find.text(t('unlock.loading')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump();
      expect(find.text(t('lock.title.open')), findsOneWidget);
      // The opening plays before the app takes over
      expect(phone.state.phase, VaultPhase.locked);

      await opening(tester);
      expect(phone.state.phase, VaultPhase.unlocked);
      expect(phone.state.session, isNotNull);
      expect(phone.vaults.active, mainVault);
    });

    testWidgets('submits on Enter', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);

      await submit(tester, 'secret');
      await opening(tester);

      expect(phone.state.phase, VaultPhase.unlocked);
    });

    testWidgets('keeps the unlock button disabled until something is typed', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);

      expect(tester.getSemantics(find.bySemanticsLabel(t('unlock.button'))), isSemantics(isButton: true, isEnabled: false));

      await tester.enterText(passwordField(), 's');
      await tester.pump();
      expect(tester.getSemantics(find.bySemanticsLabel(t('unlock.button'))), isSemantics(isButton: true, isEnabled: true));
    });

    testWidgets('can reveal the password', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);
      expect(field(tester).obscureText, isTrue);

      await tapOn(tester, find.bySemanticsLabel(t('lock.showPassword')));

      expect(field(tester).obscureText, isFalse);
    });

    testWidgets('keeps the password from the phone’s password manager and the keyboard’s learning', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);

      // Null keeps it out of autofill, which the empty default doesn't
      expect(field(tester).autofillHints, isNull);
      expect(field(tester).enableIMEPersonalizedLearning, isFalse);
    });

    testWidgets('forgets a password typed and not sent, and covers it again, when the app is hidden', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);
      await tester.enterText(passwordField(), 'half typ');
      await tapOn(tester, find.bySemanticsLabel(t('lock.showPassword')));
      expect(field(tester).obscureText, isFalse);

      // The notification shade or the app switcher leaves it as it is
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(field(tester).controller!.text, 'half typ');

      for (final state in [AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();

      expect(field(tester).controller!.text, isEmpty);
      expect(field(tester).obscureText, isTrue);
      expect(phone.state.phase, VaultPhase.locked);
    });

    testWidgets('reports a wrong password, clears the field and focuses it again', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);

      await submit(tester, 'wrong');
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(t('unlock.error.incorrectPassword')), findsOneWidget);
      expect(field(tester).controller!.text, isEmpty);
      expect(field(tester).focusNode!.hasFocus, isTrue);
      expect(find.text(t('lock.title.locked')), findsOneWidget);
      expect(phone.state.phase, VaultPhase.locked);
    });

    testWidgets('offers a vault reset by itself after three failed attempts', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);

      for (var i = 0; i < 2; i++) {
        await submit(tester, 'wrong');
        expect(find.text(t('unlock.error.incorrectPassword')), findsOneWidget);
      }
      expect(find.text(t('unlock.error.resetLink')), findsNothing);

      await submit(tester, 'wrong');
      await tapOn(tester, buttonLabelled(t('unlock.error.resetLink')));
      expect(find.text(t('unlock.wipe.title')), findsOneWidget);
      expect(find.text(t('unlock.wipe.body')), findsOneWidget);
      await tapOn(tester, buttonLabelled(t('unlock.wipe.confirm')));

      expect(phone.vaultStore.isVaultSetup(), isFalse);
      expect(phone.state.phase, VaultPhase.setup);
    });

    testWidgets('does not wipe when the reset is cancelled', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);
      for (var i = 0; i < 3; i++) {
        await submit(tester, 'wrong');
      }

      await tapOn(tester, buttonLabelled(t('unlock.error.resetLink')));
      await tapOn(tester, buttonLabelled(t('unlock.wipe.cancel')));

      expect(find.text(t('unlock.wipe.title')), findsNothing);
      expect(phone.vaultStore.isVaultSetup(), isTrue);
      expect(phone.state.phase, VaultPhase.locked);
    });

    testWidgets('offers the Recovery Kit when the password is forgotten', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      var asked = 0;
      await open(
        tester,
        phone,
        recovery: (_) async {
          asked++;
          return null;
        },
      );

      await tapOn(tester, buttonLabelled(t('unlock.error.forgotPassword')));
      expect(buttonLabelled(t('unlock.error.resetLink')), findsOneWidget);
      // The link gives way to the box
      expect(find.text(t('unlock.error.forgotPassword')), findsOneWidget);
      await tapOn(tester, buttonLabelled(t('recovery.unlock.open')));

      expect(asked, 1);
      expect(phone.state.phase, VaultPhase.locked);
    });

    testWidgets('opens the Recovery Kit sheet to collect its pieces', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      usePhone(tester);
      await phone.pump(tester, const LockScreen());
      await tester.pumpAndSettle();

      await tapOn(tester, buttonLabelled(t('unlock.error.forgotPassword')));
      await tapOn(tester, buttonLabelled(t('recovery.unlock.open')));

      expect(find.bySemanticsLabel(t('recovery.unlock.title')), findsWidgets);
      expect(fieldLabelled(t('recovery.collect.field')), findsOneWidget);
    });

    testWidgets('opens the vault the Recovery Kit unlocked', (tester) async {
      final phone = LockPhone();
      final session = await phone.createVault(tester, 'secret');
      await open(tester, phone, recovery: (_) async => session);

      await tapOn(tester, buttonLabelled(t('unlock.error.forgotPassword')));
      await tapOn(tester, buttonLabelled(t('recovery.unlock.open')));
      expect(find.text(t('lock.title.open')), findsOneWidget);
      await opening(tester);

      expect(phone.state.phase, VaultPhase.unlocked);
      expect(phone.state.session, same(session));
    });
  });

  group('wrong passwords', () {
    /// What the screen says after [count] wrong passwords, the last one now.
    String counted(int count, {bool phone = false}) => t(
      phone ? 'lock.failures.phone' : 'lock.failures',
      failuresArgs(
        UnlockFailures(count: count, last: testNow.millisecondsSinceEpoch),
        now: testNow,
        locale: 'en',
      ),
    );

    testWidgets('says nothing while there are none', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);

      expect(find.textContaining('wrong password'), findsNothing);
      expect(find.text(t('lock.failures.limit')), findsNothing);
    });

    testWidgets('counts each one, says when the last was and what the count doesn’t stop', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);

      await submit(tester, 'wrong');
      expect(find.text(counted(1)), findsOneWidget);
      await submit(tester, 'wrong again');

      expect(find.text(counted(2)), findsOneWidget);
      expect(counted(2), '2 wrong passwords since this vault last opened, the last at ${DateFormat.Hm('en').format(testNow.toLocal())}');
      expect(find.text(t('lock.failures.limit')), findsOneWidget);
      expect(jsonDecode(phone.store.getItem('backmycodes_unlock_failures')!), {'count': 2, 'last': testNow.millisecondsSinceEpoch});
    });

    testWidgets('still shows them on a lock screen built again on the same phone', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);
      for (var i = 0; i < 2; i++) {
        await submit(tester, 'wrong');
      }

      await open(tester, phone);

      expect(find.text(counted(2)), findsOneWidget);
      expect(find.text(t('unlock.error.incorrectPassword')), findsNothing);
    });

    testWidgets('keeps each listed vault’s own count when switching', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'main-pw');
      await phone.addVault(tester, 'Work', 'work-pw');
      await open(tester, phone);
      for (var i = 0; i < 2; i++) {
        await submit(tester, 'wrong');
      }

      await tapOn(tester, find.bySemanticsLabel('Work'));
      expect(find.textContaining('wrong password'), findsNothing);
      await submit(tester, 'wrong');
      expect(find.text(counted(1)), findsOneWidget);

      await tapOn(tester, find.bySemanticsLabel(t('vaults.defaultName')));
      expect(find.text(counted(2)), findsOneWidget);
    });

    testWidgets('counts for the phone when every vault is hidden', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'main-pw');
      await phone.addVault(tester, 'Secret', 'hidden-pw', listed: false);
      phone.vaults.setListed(mainVault, false);
      await open(tester, phone);

      await submit(tester, 'wrong');

      expect(find.text(counted(1, phone: true)), findsOneWidget);
      expect(phone.store.getItem('backmycodes_unlock_failures_device'), isNotNull);
      expect(phone.store.storedKeys().where((key) => key.startsWith('backmycodes_unlock_failures::')), isEmpty);
    });

    testWidgets('counts nothing for a biometric prompt that was cancelled or failed', (tester) async {
      final phone = LockPhone(biometrics: PromptBiometrics());
      final session = await phone.createVault(tester, 'secret');
      await phone.enableBiometrics(tester, session);
      phone.unlockKeys.cancelNext();
      await open(tester, phone);

      phone.unlockKeys.failNext('Face not recognised');
      await tapOn(tester, find.bySemanticsLabel(t('unlock.passkey.useBiometric')));

      expect(phone.unlockKeys.prompts, hasLength(2));
      expect(find.textContaining('wrong password'), findsNothing);
      expect(phone.store.getItem('backmycodes_unlock_failures'), isNull);
    });

    testWidgets('offers the Recovery Kit and the reset after three, even after a restart', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);
      for (var i = 0; i < 3; i++) {
        await submit(tester, 'wrong');
      }
      expect(buttonLabelled(t('unlock.error.resetLink')), findsOneWidget);

      await open(tester, phone);

      expect(buttonLabelled(t('unlock.error.resetLink')), findsOneWidget);
      expect(buttonLabelled(t('recovery.unlock.open')), findsOneWidget);
      expect(find.text(counted(3)), findsOneWidget);
    });
  });

  group('opening after wrong passwords', () {
    String report(int count) => t(
      'vault.failures.report',
      failuresArgs(
        UnlockFailures(count: count, last: testNow.millisecondsSinceEpoch),
        now: testNow,
        locale: 'en',
      ),
    );
    String? toast(LockPhone phone) => phone.container.read(toastsProvider)?.message;

    /// The vault on [phone], [wrong] passwords typed on its lock screen.
    Future<VaultSession> afterWrong(
      WidgetTester tester,
      LockPhone phone,
      int wrong, {
      Future<VaultSession?> Function(BuildContext)? recovery,
    }) async {
      final session = await phone.createVault(tester, 'secret');
      await open(tester, phone, recovery: recovery);
      for (var i = 0; i < wrong; i++) {
        await submit(tester, 'wrong');
      }
      return session;
    }

    testWidgets('by password, says once how many there were and sets the count back to zero', (tester) async {
      final phone = LockPhone();
      await afterWrong(tester, phone, 3);

      await submit(tester, 'secret');
      await opening(tester);

      expect(phone.state.phase, VaultPhase.unlocked);
      expect(toast(phone), report(3));
      expect(
        report(3),
        '3 wrong passwords were typed since this vault last opened, the last at ${DateFormat.Hm('en').format(testNow.toLocal())}',
      );
      expect(jsonDecode(phone.store.getItem('backmycodes_unlock_failures')!), {'count': 0});

      phone.controller.lock();
      await open(tester, phone);
      expect(find.textContaining('wrong password'), findsNothing);
    });

    testWidgets('by biometrics', (tester) async {
      final phone = LockPhone(biometrics: PromptBiometrics());
      final session = await phone.createVault(tester, 'secret');
      await phone.enableBiometrics(tester, session);
      phone.unlockKeys.cancelNext();
      await open(tester, phone);
      await tapOn(tester, buttonLabelled(t('unlock.usePassword')));
      for (var i = 0; i < 2; i++) {
        await submit(tester, 'wrong');
      }

      await tapOn(tester, buttonLabelled(t('unlock.passkey.useBiometric')));
      await tapOn(tester, find.bySemanticsLabel(t('unlock.passkey.useBiometric')));
      await opening(tester);

      expect(phone.state.phase, VaultPhase.unlocked);
      expect(toast(phone), report(2));
      expect(phone.vaultStore.hasBiometricUnlock(), isTrue);
      expect(UnlockFailures.parse(phone.store.getItem('backmycodes_unlock_failures')), UnlockFailures.none);
    });

    testWidgets('by Recovery Kit', (tester) async {
      final phone = LockPhone();
      late VaultSession session;
      session = await afterWrong(tester, phone, 4, recovery: (_) async => session);

      await tapOn(tester, buttonLabelled(t('recovery.unlock.open')));
      await opening(tester);

      expect(phone.state.phase, VaultPhase.unlocked);
      expect(toast(phone), report(4));
      expect(UnlockFailures.parse(phone.store.getItem('backmycodes_unlock_failures')), UnlockFailures.none);
    });

    testWidgets('says nothing when there were none', (tester) async {
      final phone = LockPhone();
      await afterWrong(tester, phone, 0);

      await submit(tester, 'secret');
      await opening(tester);

      expect(phone.state.phase, VaultPhase.unlocked);
      expect(toast(phone), isNull);
      // The try that opened was written down before it was checked, and set back after
      expect(jsonDecode(phone.store.getItem('backmycodes_unlock_failures')!), {'count': 0});
    });
  });

  group('erasing after wrong passwords', () {
    /// A phone with Personal and a hidden vault, its biometric key, and the erase set to [after].
    Future<LockPhone> phoneErasingAfter(WidgetTester tester, int? after) async {
      final phone = LockPhone(biometrics: PromptBiometrics());
      final session = await phone.createVault(tester, 'secret');
      await phone.enableBiometrics(tester, session);
      await phone.addVault(tester, 'Diary', 'diary-pw', listed: false);
      phone.store.setItem('backmycodes_locale', 'en');
      if (after != null) phone.store.setItem('backmycodes_unlock_erase', jsonEncode({'after': after}));
      phone.unlockKeys.cancelNext();
      return phone;
    }

    Future<void> wrong(WidgetTester tester, int times) async {
      for (var i = 0; i < times; i++) {
        await submit(tester, 'wrong');
      }
    }

    testWidgets('warns from three tries left', (tester) async {
      final phone = await phoneErasingAfter(tester, 10);
      await open(tester, phone);
      await tapOn(tester, buttonLabelled(t('unlock.usePassword')));

      await wrong(tester, 6);
      expect(find.textContaining('will erase every vault'), findsNothing);
      await wrong(tester, 1);
      expect(find.text(t('lock.erase.warning', {'left': 3})), findsOneWidget);
      expect(t('lock.erase.warning', {'left': 3}), '3 more wrong passwords will erase every vault on this phone.');
      await wrong(tester, 2);
      expect(find.text(t('lock.erase.warning', {'left': 1})), findsOneWidget);
      expect(phone.vaultStore.isVaultSetup(), isTrue);
    });

    testWidgets('erases every vault, its keys and the counts on the tenth', (tester) async {
      final phone = await phoneErasingAfter(tester, 10);
      await open(tester, phone);
      await tapOn(tester, buttonLabelled(t('unlock.usePassword')));

      await wrong(tester, 9);
      expect(phone.vaultStore.isVaultSetup(), isTrue);
      await wrong(tester, 1);

      expect(phone.vaultStore.isVaultSetup(), isFalse);
      expect(phone.state.phase, VaultPhase.setup);
      expect(phone.unlockKeys.calls, contains('deleteAll'));
      expect(phone.unlockKeys.keys, isEmpty);
      expect(phone.store.storedKeys().toSet(), {'backmycodes_locale', 'backmycodes_erased'});
      expect(jsonDecode(phone.store.getItem('backmycodes_erased')!), {'at': testNow.millisecondsSinceEpoch, 'after': 10});
    });

    testWidgets('erases at once when a count already reached it, as after the app was killed during the last check', (tester) async {
      final phone = await phoneErasingAfter(tester, 15);
      phone.store.setItem('backmycodes_unlock_failures', jsonEncode({'count': 15, 'last': testNow.millisecondsSinceEpoch}));

      await open(tester, phone);

      expect(phone.vaultStore.isVaultSetup(), isFalse);
      expect(phone.state.phase, VaultPhase.setup);
      expect(phone.unlockKeys.prompts, isEmpty);
      expect(jsonDecode(phone.store.getItem('backmycodes_erased')!), containsPair('after', 15));
    });

    testWidgets('does not count, and never erases on, a failure that is no wrong password', (tester) async {
      final phone = await phoneErasingAfter(tester, 3);
      // The hidden vault's config can no longer be read, so checking a password against it throws
      final hidden = phone.vaults.hiddenVaultIds().single;
      phone.store.setItem(phone.vaults.vaultKey(keyConfig, hidden), '{}');
      await open(tester, phone);
      await tapOn(tester, buttonLabelled(t('unlock.usePassword')));

      await wrong(tester, 5);

      expect(phone.vaultStore.isVaultSetup(), isTrue);
      expect(phone.state.phase, VaultPhase.locked);
      expect(phone.store.getItem('backmycodes_erased'), isNull);
      expect(find.text(t('unlock.error.failed')), findsOneWidget);
      expect(find.text(t('unlock.error.incorrectPassword')), findsNothing);
      expect(phone.container.read(unlockAttemptsProvider).read(mainVault).count, 0);

      // The listed vault still opens with its own password
      await submit(tester, 'secret');
      await opening(tester);
      expect(phone.state.phase, VaultPhase.unlocked);
    });

    testWidgets('erases nothing while it is off, and counts on', (tester) async {
      final phone = await phoneErasingAfter(tester, null);
      await open(tester, phone);
      await tapOn(tester, buttonLabelled(t('unlock.usePassword')));

      await wrong(tester, 50);

      expect(phone.vaultStore.isVaultSetup(), isTrue);
      expect(phone.vaults.allVaultIds(), hasLength(2));
      expect(phone.state.phase, VaultPhase.locked);
      expect(find.textContaining('50 wrong passwords since this vault last opened'), findsOneWidget);
      expect(find.textContaining('will erase every vault'), findsNothing);
      expect(phone.store.getItem('backmycodes_erased'), isNull);
    });
  });

  group('a hidden vault', () {
    /// What a phone with Personal listed and a hidden vault shows and keeps
    /// after two wrong passwords and then [password]: the counts in storage,
    /// the report, and every text of the next lock screen.
    Future<({Map<String, String?> counts, String? report, List<String?> texts})> run(WidgetTester tester, String password) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'personal-pw');
      await phone.addVault(tester, 'Diary', 'diary-pw', listed: false);
      await open(tester, phone);
      for (var i = 0; i < 2; i++) {
        await submit(tester, 'wrong');
      }

      await submit(tester, password);
      await opening(tester);
      expect(phone.state.phase, VaultPhase.unlocked);
      final report = phone.container.read(toastsProvider)?.message;
      phone.controller.lock();
      await open(tester, phone);

      return (
        counts: {
          for (final key in phone.store.storedKeys())
            if (key.contains('unlock_failures')) key: phone.store.getItem(key),
        },
        report: report,
        texts: [for (final text in tester.widgetList<Text>(find.byType(Text))) text.data ?? text.textSpan?.toPlainText()],
      );
    }

    testWidgets('opening leaves what the listed vault opening leaves', (tester) async {
      final listed = await run(tester, 'personal-pw');
      final hidden = await run(tester, 'diary-pw');

      expect(hidden.counts, listed.counts);
      expect(hidden.counts, {'backmycodes_unlock_failures': '{"count":0}'});
      expect(hidden.report, listed.report);
      expect(hidden.report, startsWith('2 wrong passwords were typed'));
      expect(hidden.texts, listed.texts);
      expect(hidden.texts, isNot(contains(contains('wrong password'))));
    });
  });

  testWidgets('counts a try whose check never finished, once the app starts again', (tester) async {
    usePhone(tester);
    final backend = MemoryPreferences();
    final before = (await tester.runAsync(() => KeyValueStore.open(backend)))!;
    await tester.runAsync(() async {
      await VaultStore(before, VaultRegistry(before), deriveKey: fastKdf).setupVault('secret');
      await before.flush();
    });
    // The app is killed while scrypt runs: the check never comes back
    final killed = LockPhone(
      store: before,
      vaultStore: (store, vaults) => VaultStore(store, vaults, deriveKey: (_, _) => Completer<Uint8List>().future),
    );
    await killed.pump(tester, const LockScreen());
    await tester.pumpAndSettle();
    await tester.enterText(passwordField(), 'wrong');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text(t('lock.title.verifying')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    // The phone's storage, read again by a new app
    final after = (await tester.runAsync(() => KeyValueStore.open(backend)))!;
    final restarted = LockPhone(store: after);
    await restarted.pump(tester, const LockScreen());
    await tester.pumpAndSettle();

    expect(
      find.text(
        t(
          'lock.failures',
          failuresArgs(
            UnlockFailures(count: 1, last: testNow.millisecondsSinceEpoch),
            now: testNow,
            locale: 'en',
          ),
        ),
      ),
      findsOneWidget,
    );
  });

  group('several vaults', () {
    Future<(LockPhone, String)> twoVaults(WidgetTester tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'main-pw');
      final work = await phone.addVault(tester, 'Work', 'work-pw');
      return (phone, work);
    }

    Finder picker() => find.bySemanticsLabel(t('vaults.lock.choose'));
    Finder radio(String name) => find.descendant(of: picker(), matching: find.bySemanticsLabel(name));

    testWidgets('lets the user pick a listed vault and unlocks that one', (tester) async {
      final (phone, work) = await twoVaults(tester);
      await open(tester, phone);

      expect(picker(), findsOneWidget);
      expect(tester.getSemantics(radio(t('vaults.defaultName'))), isSemantics(isInMutuallyExclusiveGroup: true, isChecked: true));
      expect(tester.getSemantics(radio('Work')), isSemantics(isInMutuallyExclusiveGroup: true, isChecked: false));

      await tapOn(tester, radio('Work'));
      expect(tester.getSemantics(radio('Work')), isSemantics(isChecked: true));
      await submit(tester, 'work-pw');
      await opening(tester);

      expect(phone.state.phase, VaultPhase.unlocked);
      expect(phone.vaults.active, work);
    });

    testWidgets('opens only the chosen vault among the listed ones', (tester) async {
      final (phone, _) = await twoVaults(tester);
      await open(tester, phone);

      await tapOn(tester, radio('Work'));
      await submit(tester, 'main-pw');

      expect(find.text(t('unlock.error.incorrectPassword')), findsOneWidget);
      expect(phone.state.phase, VaultPhase.locked);
    });

    testWidgets('starts on the vault opened last', (tester) async {
      final (phone, work) = await twoVaults(tester);
      phone.vaults.rememberVault(work);
      await open(tester, phone);

      expect(tester.getSemantics(radio('Work')), isSemantics(isChecked: true));
      expect(tester.getSemantics(radio(t('vaults.defaultName'))), isSemantics(isChecked: false));
    });

    testWidgets('shows no vault names when every vault is hidden', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'main-pw');
      final hidden = await phone.addVault(tester, 'Secret', 'hidden-pw', listed: false);
      phone.vaults.setListed(mainVault, false);
      await open(tester, phone);

      expect(picker(), findsNothing);
      expect(find.text('Secret'), findsNothing);
      // With nothing chosen, the password alone decides which hidden vault opens
      await submit(tester, 'hidden-pw');
      await opening(tester);

      expect(phone.state.phase, VaultPhase.unlocked);
      expect(phone.vaults.active, hidden);
    });
  });

  group('biometric unlock', () {
    /// A vault with biometric unlock on, whose automatic prompt [first] answers: cancelled unless said.
    Future<LockPhone> withBiometric(WidgetTester tester, {UnlockKeyError? first = const UnlockKeyCancelled()}) async {
      final phone = LockPhone(biometrics: PromptBiometrics());
      final session = await phone.createVault(tester, 'secret');
      await phone.enableBiometrics(tester, session);
      phone.unlockKeys.nextError = first;
      return phone;
    }

    Finder quickButton() => find.bySemanticsLabel(t('unlock.passkey.useBiometric'));

    testWidgets('leads with the biometric button and keeps the password one tap away', (tester) async {
      final phone = await withBiometric(tester);
      await open(tester, phone);

      expect(tester.getSemantics(quickButton()), isSemantics(isButton: true, isEnabled: true));
      expect(passwordField(), findsNothing);

      await tapOn(tester, buttonLabelled(t('unlock.usePassword')));
      expect(field(tester).enabled, isTrue);

      await tapOn(tester, buttonLabelled(t('unlock.passkey.useBiometric')));
      expect(passwordField(), findsNothing);
    });

    testWidgets('unlocks with biometrics, through the hardware key', (tester) async {
      final phone = await withBiometric(tester);
      await open(tester, phone);

      await tester.tap(quickButton());
      await tester.pump();
      expect(find.text(t('lock.title.open')), findsOneWidget);
      await opening(tester);

      expect(phone.state.phase, VaultPhase.unlocked);
      expect(phone.unlockKeys.prompts, [t('unlock.passkey.useBiometric'), t('unlock.passkey.useBiometric')]);
      expect(phone.unlockKeys.calls, ['open main', 'open main']);
      // local_auth's prompt holds no key, so it isn't the one shown
      expect(phone.biometrics.prompts, isEmpty);
    });

    testWidgets('shows biometric errors and keeps password unlock available', (tester) async {
      final phone = await withBiometric(tester, first: const UnlockKeyPromptFailed('Too many attempts. Try again later.'));
      await open(tester, phone);
      // The prompt shown straight away failed quietly
      expect(find.text('Too many attempts. Try again later.'), findsNothing);
      expect(find.text(t('lock.title.locked')), findsOneWidget);

      phone.unlockKeys.failPromptNext('Too many attempts. Try again later.');
      await tapOn(tester, quickButton());
      expect(find.text('Too many attempts. Try again later.'), findsOneWidget);
      expect(phone.vaultStore.hasBiometricUnlock(), isTrue);

      await tapOn(tester, buttonLabelled(t('unlock.usePassword')));
      expect(field(tester).enabled, isTrue);

      await tapOn(tester, find.bySemanticsLabel(t('passkey.close')));
      expect(find.text('Too many attempts. Try again later.'), findsNothing);
    });

    testWidgets('goes back to the buttons quietly when the prompt is cancelled', (tester) async {
      final phone = await withBiometric(tester);
      await open(tester, phone);

      phone.unlockKeys.cancelNext();
      await tapOn(tester, quickButton());

      expect(find.text(t('lock.title.locked')), findsOneWidget);
      expect(find.byType(AppAlert), findsNothing);
      expect(tester.getSemantics(quickButton()), isSemantics(isButton: true, isEnabled: true));
      expect(buttonLabelled(t('unlock.usePassword')), findsOneWidget);
      expect(phone.state.phase, VaultPhase.locked);
      expect(phone.vaultStore.hasBiometricUnlock(), isTrue);
    });

    testWidgets('prompts for a registered biometric automatically', (tester) async {
      final phone = await withBiometric(tester, first: null);
      await open(tester, phone);
      await opening(tester);

      expect(phone.state.phase, VaultPhase.unlocked);
      expect(phone.unlockKeys.prompts, hasLength(1));
    });

    testWidgets('says biometric unlock went off when biometrics changed, and asks for the password', (tester) async {
      final phone = await withBiometric(tester, first: null);
      phone.unlockKeys.invalidate(mainVault);
      await open(tester, phone);

      expect(find.text(t('unlock.biometric.invalidated')), findsOneWidget);
      expect(field(tester).focusNode!.hasFocus, isTrue);
      expect(buttonLabelled(t('unlock.passkey.useBiometric')), findsNothing);
      expect(phone.vaultStore.hasBiometricUnlock(), isFalse);
      expect(phone.unlockKeys.keys, isEmpty);
      expect(phone.biometrics.prompts, isEmpty);

      await submit(tester, 'secret');
      await opening(tester);
      expect(phone.state.phase, VaultPhase.unlocked);
    });

    testWidgets('opens a vault whose entry an earlier version wrote, moving it to the hardware', (tester) async {
      final phone = LockPhone(biometrics: PromptBiometrics());
      final session = await phone.createVault(tester, 'secret');
      await tester.runAsync(() => writeOldBiometricEntry(phone.store, phone.vaults, session));
      await open(tester, phone);
      await opening(tester);

      expect(phone.state.phase, VaultPhase.unlocked);
      expect(phone.state.session!.secretKey, session.secretKey);
      expect(phone.unlockKeys.calls, ['seal main']);
      expect(phone.biometrics.prompts, isEmpty);
      expect(phone.store.getItem('backmycodes_hardware_bio'), isNotNull);
      expect(phone.store.getItem('backmycodes_native_bio'), isNotNull);
    });

    testWidgets('says once why biometric unlock went away on a phone whose biometrics the key can’t use', (tester) async {
      // An entry an earlier version wrote, on a phone with only a weak face unlock
      final phone = LockPhone(biometrics: PromptBiometrics(), unlockKeys: FakeUnlockKeys(available: false));
      final session = await phone.createVault(tester, 'secret');
      await tester.runAsync(() => writeOldBiometricEntry(phone.store, phone.vaults, session));
      await open(tester, phone);

      expect(find.text(t('unlock.biometric.unsupported')), findsOneWidget);
      expect(field(tester).focusNode!.hasFocus, isTrue);
      expect(buttonLabelled(t('unlock.passkey.useBiometric')), findsNothing);
      expect(phone.store.getItem('backmycodes_native_bio'), isNull);
      expect(phone.vaultStore.hasBiometricUnlock(), isFalse);
      expect([...phone.unlockKeys.prompts, ...phone.biometrics.prompts], isEmpty);

      // The next lock screen asks for the password and says nothing more
      await open(tester, phone);
      expect(find.text(t('unlock.biometric.unsupported')), findsNothing);
      expect(passwordField(), findsOneWidget);
      expect(find.byType(AppAlert), findsNothing);
    });

    testWidgets('asks for the password of a vault without it', (tester) async {
      final phone = await withBiometric(tester);
      await phone.addVault(tester, 'Work', 'work-pw');
      await open(tester, phone);
      expect(passwordField(), findsNothing);

      await tapOn(tester, find.bySemanticsLabel('Work'));

      expect(passwordField(), findsOneWidget);
      expect(buttonLabelled(t('unlock.passkey.useBiometric')), findsNothing);
    });
  });

  // openspec: replace-vault-key-pair, task 5.4
  testWidgets('shows an exposed vault, listed or hidden, as it shows one that isn’t', (tester) async {
    /// What the lock screen shows on a phone with a listed and a hidden vault, exposed or not.
    Future<List<String>> shown({required bool exposed}) async {
      final phone = LockPhone();
      final personal = await phone.createVault(tester, 'pw');
      final diary = await phone.addVault(tester, 'Diary', 'diary', listed: false);
      if (exposed) {
        await tester.runAsync(() async {
          await phone.vaultStore.saveEncryptedValue(keyKeyInfo, {'exposed': true, 'asked': false}, personal);
          phone.vaults.active = diary;
          final hidden = await phone.vaultStore.unlockAnyVault('diary', mainVault);
          await phone.vaultStore.saveEncryptedValue(keyKeyInfo, {'exposed': true, 'asked': false}, hidden);
          phone.vaults.active = mainVault;
        });
      }
      await open(tester, phone);
      return [for (final text in tester.widgetList<Text>(find.byType(Text))) text.data ?? text.textSpan?.toPlainText() ?? ''];
    }

    final unexposed = await shown(exposed: false);
    final exposed = await shown(exposed: true);

    expect(exposed, unexposed);
    expect(exposed.join(' '), isNot(contains(t('replaceKey.exposed'))));
  });
  // openspec: add-pgp-mail-provider, task 6.1
  group('a mail request in front', () {
    testWidgets('names the app and its package, and Cancel cancels it and leaves the vault locked', (tester) async {
      final mail = MailScreensApp(tester);
      await mail.start(unlock: false);
      final call = mail.call(OpenPgp.decryptVerify);
      await mail.bringUp(call);
      expect(find.text(t('mail.lock.request', {'app': 'Thunderbird'})), findsOneWidget);
      expect(find.text('net.thunderbird.android'), findsOneWidget);

      await tapOn(tester, find.text(t('mail.lock.cancel')));
      expect(mail.finished, [(call.requestId, false)]);
      expect(mail.app.state.isUnlocked, isFalse);
      expect(find.byKey(const ValueKey('mail-request-line')), findsNothing);
      expect(find.text(t('lock.title.locked')), findsOneWidget);
    });

    testWidgets('with no request the lock screen carries no line', (tester) async {
      final mail = MailScreensApp(tester);
      await mail.start(unlock: false);
      expect(find.text(t('lock.title.locked')), findsOneWidget);
      expect(find.byKey(const ValueKey('mail-request-line')), findsNothing);
    });

    testWidgets("a hidden vault's password opens it, and the request goes on there", (tester) async {
      final mail = MailScreensApp(tester);
      await mail.start(unlock: false, beforeStart: () => mail.app.vaultStore.createVault('Hidden', 'hidden pw', listed: false));
      final call = mail.call(OpenPgp.checkPermission);
      await mail.bringUp(call);
      await submitPassword(tester, 'hidden pw');
      await pumpUntil(tester, find.text(t('mail.approve.title', {'app': 'Thunderbird'})));
      expect(mail.app.state.vault.hidden, isTrue);
      expect(find.byKey(const ValueKey('mail-hidden-vault')), findsOneWidget);
      expect(mail.finished, isEmpty);
    });

    // With add-security-key-unlock and add-share-extension, merged beside it
    testWidgets('a vault that opens with its key shows the key step under the app and a waiting share, and its grant holds the lock', (
      tester,
    ) async {
      final phone = FakeSecurityKeys(phone: FakeSecurityKeys.android);
      final soft = SoftKey(pin: '123456');
      FakeDevice hold() {
        final device = FakeKey(productName: 'Example Key', ctap: soft).device(kinds: {SecurityKeyLinkKind.nfc});
        phone.arrive(device);
        return device;
      }

      final shared = FakeSharedItems();
      final root = Directory.systemTemp.createTempSync('share-mail-lock');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final mail = MailScreensApp(tester);
      await mail.start(
        unlock: false,
        overrides: [
          // The app's own reader, with the app's holds, over a phone that reaches keys
          keyReaderProvider.overrideWith((ref) => CtapKeyReader(phone, hold: ref.watch(autoLockHoldsProvider).hold, now: phone.now)),
          securityKeysProvider.overrideWithValue(phone),
          shared.asOverride,
          shareTempRootProvider.overrideWithValue(() async => root),
        ],
        beforeStart: () async {
          await tester.runAsync(() async {
            final store = mail.app.vaultStore;
            final session = await store.unlockAnyVault('pw', mainVault);
            await store.setRecoveryKey(session, newKit());
            final device = hold();
            final challenge = store.keyChallenge();
            final enrolment = await CtapKeyReader(
              phone,
              now: phone.now,
            ).enrol(pin: pinBytes('123456'), salt: challenge.salt, exclude: challenge.credentials, prompts: testKeyPrompts);
            final proof = await store.enrolKey(
              session,
              await store.proveOwner(password: 'pw'),
              salt: challenge.salt,
              credential: enrolment.credential,
              output: enrolment.output,
              name: 'Example Key',
              pinBound: enrolment.pinBound,
            );
            await store.setUnlockMode(session, proof, UnlockMode.key);
            phone.remove(device);
          });
        },
      );
      final call = mail.call(OpenPgp.checkPermission);
      await mail.bringUp(call);
      shared.send(const SharedText('Meet me at nine.'));
      await mail.settle();

      // The app's name, then the waiting share, then the key step's PIN
      final pinField = fieldLabelled(t('lock.key.pin'));
      expect(find.text(t('lock.key.titleAndroid')), findsOneWidget);
      expect(find.text(t('mail.lock.request', {'app': 'Thunderbird'})), findsOneWidget);
      expect(find.text(t('share.lock.waiting')), findsOneWidget);
      expect(pinField, findsOneWidget);
      final line = tester.getTopLeft(find.byKey(const ValueKey('mail-request-line'))).dy;
      expect(line, lessThan(tester.getTopLeft(find.byType(SharedItemWaiting)).dy));
      expect(tester.getTopLeft(find.byType(SharedItemWaiting)).dy, lessThan(tester.getTopLeft(pinField).dy));

      // The key opens the vault, and the request goes on to the approval
      hold();
      await tester.enterText(pinField, '123456');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await pumpUntil(tester, find.text(t('mail.approve.title', {'app': 'Thunderbird'})));
      expect(mail.app.state.isUnlocked, isTrue);
      final holds = mail.app.container.read(autoLockHoldsProvider);
      expect(holds.isHeld, isFalse, reason: 'the read let go of its hold');

      await tapOn(tester, find.text(t('mail.approve.allow')));
      await mail.settle();
      expect(mail.finished, [(call.requestId, true)]);
      expect(holds.isHeld, isTrue, reason: 'the grant holds the lock until the mail app sends again');
      // The share waited behind the request, and is offered now
      expect(find.text(t('share.encrypt')), findsOneWidget);

      mail.app.container.read(mailGrantsProvider).end(call.requestId);
      expect(holds.isHeld, isFalse);
      expect(mail.app.state.isUnlocked, isTrue);
    });
  });

  group('a shared item waiting (openspec: add-share-extension)', () {
    late Directory root;
    late FakeSharedItems shared;

    setUp(() {
      root = Directory.systemTemp.createTempSync('share-lock');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      shared = FakeSharedItems();
    });

    LockPhone sharingPhone() => LockPhone(extra: [shared.asOverride, shareTempRootProvider.overrideWithValue(() async => root)]);

    /// A file the native side copied for the app, as another app shared it.
    SharedFile sharedFile(String name) {
      final file = File('${root.path}${Platform.pathSeparator}ab12${Platform.pathSeparator}$name')
        ..createSync(recursive: true)
        ..writeAsStringSync('the signed contract');
      return SharedFile(path: file.path, name: name, size: file.lengthSync(), type: 'application/pdf');
    }

    Future<void> share(WidgetTester tester, SharedArrival arrival) async {
      shared.send(arrival);
      await tester.pumpAndSettle();
    }

    /// Every text the screen shows or says, in its texts, fields and semantics.
    String everything(WidgetTester tester) => [
      for (final widget in tester.allWidgets)
        switch (widget) {
          Text(:final data, :final textSpan) => data ?? textSpan?.toPlainText() ?? '',
          RichText(:final text) => text.toPlainText(),
          EditableText(:final controller) => controller.text,
          Semantics(:final properties) => '${properties.label ?? ''} ${properties.value ?? ''} ${properties.hint ?? ''}',
          _ => '',
        },
    ].join('\n');

    /// What the screen is made of, by kind, in order.
    List<Type> shape(WidgetTester tester) => [for (final widget in tester.allWidgets) widget.runtimeType];

    /// Drops what still waits, whose timer would outlive the test.
    void done(LockPhone phone) => phone.container.read(pendingShareProvider.notifier).drop();

    testWidgets('says something was shared, and never what: not a file name, nor a text', (tester) async {
      final phone = sharingPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);

      await share(tester, sharedFile('contract.pdf'));
      expect(find.text(t('share.lock.waiting')), findsOneWidget);
      expect(find.text(t('share.lock.notNow')), findsOneWidget);
      expect(everything(tester), isNot(contains('contract')));
      expect(everything(tester), isNot(contains(t('notes.file.bytes', {'count': 19}))));

      await share(tester, const SharedText('Meet me at the usual place at nine.'));
      expect(find.text(t('share.lock.waiting')), findsOneWidget);
      expect(everything(tester), isNot(contains('usual place')));
      // The line stands above the password field
      expect(tester.getTopLeft(find.byType(SharedItemWaiting)).dy, lessThan(tester.getTopLeft(passwordField()).dy));
      done(phone);
    });

    testWidgets('"Not now" takes the line away and forgets the item and its file', (tester) async {
      final phone = sharingPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);
      final item = sharedFile('contract.pdf');
      await share(tester, item);

      await tester.tap(find.text(t('share.lock.notNow')));
      await tester.pumpAndSettle();

      expect(find.byType(SharedItemWaiting), findsNothing);
      expect(phone.container.read(pendingShareProvider), isNull);
      expect(File(item.path).existsSync(), isFalse);
      // Unlocking afterwards opens the vault with nothing waiting
      await submit(tester, 'secret');
      await opening(tester);
      expect(phone.state.phase, VaultPhase.unlocked);
      expect(phone.container.read(pendingShareProvider), isNull);
    });

    testWidgets('with nothing waiting, the screen is what it was', (tester) async {
      final phone = sharingPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);
      final before = shape(tester);
      expect(find.byType(SharedItemWaiting), findsNothing);
      expect(find.text(t('share.lock.waiting')), findsNothing);

      await share(tester, const SharedText('Meet me at nine.'));
      expect(shape(tester), isNot(before));
      await tester.tap(find.text(t('share.lock.notNow')));
      await tester.pumpAndSettle();
      expect(shape(tester), before);
    });

    testWidgets('the line is the same with a hidden vault on the phone', (tester) async {
      Future<String> line({required bool hidden}) async {
        shared = FakeSharedItems();
        final phone = sharingPhone();
        await phone.createVault(tester, 'personal-pw');
        if (hidden) await phone.addVault(tester, 'Diary', 'diary-pw', listed: false);
        await open(tester, phone);
        await share(tester, const SharedText('Meet me at nine.'));
        expect(find.byType(SharedItemWaiting), findsOneWidget);
        final said = [
          for (final text in tester.widgetList<Text>(find.descendant(of: find.byType(SharedItemWaiting), matching: find.byType(Text))))
            text.data ?? '',
        ].join(' | ');
        done(phone);
        return said;
      }

      final without = await line(hidden: false);
      final withHidden = await line(hidden: true);
      expect(withHidden, without);
      expect(withHidden, '${t('share.lock.waiting')} | ${t('share.lock.notNow')}');
    });
  });

  // openspec: add-security-key-unlock, task 1.3: what the key step must keep
  group('the counts and the time a password takes', () {
    /// A phone whose key derivations are counted in [derivations].
    LockPhone counting(List<String> derivations) => LockPhone(
      vaultStore: (store, vaults) => VaultStore(
        store,
        vaults,
        deriveKey: (password, salt) {
          derivations.add(password);
          return fastKdf(password, salt);
        },
        unlockKeys: FakeUnlockKeys(available: false),
      ),
    );

    testWidgets('a wrong password counts against the vault on screen', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await open(tester, phone);

      await submit(tester, 'wrong');
      await submit(tester, 'wrong again');

      expect(phone.container.read(unlockAttemptsProvider).read(mainVault).count, 2);
      expect(phone.state.phase, VaultPhase.locked);
    });

    testWidgets('a hidden vault’s password sets the count of the vault on screen back to zero', (tester) async {
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      final diary = await phone.addVault(tester, 'Diary', 'diary', listed: false);
      await open(tester, phone);
      await submit(tester, 'wrong');
      expect(phone.container.read(unlockAttemptsProvider).read(mainVault).count, 1);

      await submit(tester, 'diary');
      await opening(tester);

      expect(phone.vaults.active, diary);
      expect(phone.container.read(unlockAttemptsProvider).read(mainVault).count, 0);
      expect(phone.store.storedKeys().where((key) => key.contains('unlock_failures') && key.contains(diary)), isEmpty);
    });

    testWidgets('a wrong password takes one key derivation, with and without a hidden vault', (tester) async {
      Future<int> derivationsOfAWrongPassword({required bool hidden}) async {
        final derivations = <String>[];
        final phone = counting(derivations);
        await phone.createVault(tester, 'secret');
        if (hidden) await phone.addVault(tester, 'Diary', 'diary', listed: false);
        await open(tester, phone);
        derivations.clear();
        await submit(tester, 'wrong');
        expect(find.text(t('unlock.error.incorrectPassword')), findsOneWidget);
        return derivations.length;
      }

      expect(await derivationsOfAWrongPassword(hidden: false), 1);
      expect(await derivationsOfAWrongPassword(hidden: true), 1);
    });
  });
}
