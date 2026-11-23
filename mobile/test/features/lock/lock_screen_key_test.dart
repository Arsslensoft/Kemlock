import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/lock/key_reader.dart';
import 'package:kemlock/features/lock/lock_screen.dart';
import 'package:kemlock/features/lock/unlock_attempts.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import '../../security_key/soft_key.dart';
import '../../vault/rotation_helpers.dart' show newKit;
import 'lock_phone.dart';

const KeyPrompts _prompts = (nfcMessage: 'Hold your key', nfcFailure: 'No key');

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// A phone for the key step: storage in memory, a software key, and the
/// app's own key reader over a fake phone that reaches keys as [reach] says.
class _KeyRig {
  _KeyRig({SecurityKeyCapabilities reach = FakeSecurityKeys.android, SoftKey? soft})
    : keys = FakeSecurityKeys(phone: reach),
      soft = soft ?? SoftKey(pin: '123456') {
    reader = CtapKeyReader(keys, now: keys.now);
    phone = LockPhone(extra: [keyReaderProvider.overrideWithValue(reader)]);
    key = FakeKey(productName: 'Example Key', ctap: this.soft);
  }

  final FakeSecurityKeys keys;
  final SoftKey soft;
  late final CtapKeyReader reader;
  late final LockPhone phone;
  late final FakeKey key;
  FakeDevice? device;

  /// The key is held to the phone.
  void present() => keys.arrive(device = key.device(kinds: {SecurityKeyLinkKind.nfc}));

  /// The key is taken away, and presented again.
  void presentAgain() {
    if (device case final held?) keys.remove(held);
    present();
  }

  /// The active vault, open in [session] with [password], gets a Recovery
  /// Kit and this key, and is set to open in [mode].
  Future<void> keyUp(WidgetTester tester, VaultSession session, UnlockMode mode, {required String password}) async {
    await tester.runAsync(() async {
      final store = phone.vaultStore;
      await store.setRecoveryKey(session, newKit());
      present();
      final challenge = store.keyChallenge();
      final enrolment = await reader.enrol(pin: _bytes('123456'), salt: challenge.salt, exclude: challenge.credentials, prompts: _prompts);
      final proof = await store.enrolKey(
        session,
        await store.proveOwner(password: password),
        salt: challenge.salt,
        credential: enrolment.credential,
        output: enrolment.output,
        name: 'Example Key',
        pinBound: enrolment.pinBound,
      );
      if (mode != UnlockMode.password) await store.setUnlockMode(session, proof, mode);
      keys.remove(device!);
      device = null;
    });
  }

  /// The first vault, "Personal", set up with the password "secret" and
  /// opening in [mode].
  Future<VaultSession> personal(WidgetTester tester, UnlockMode mode) async {
    final session = await phone.createVault(tester, 'secret');
    phone.vaultStore.renameVault(mainVault, 'Personal');
    await keyUp(tester, session, mode, password: 'secret');
    return session;
  }

  /// A hidden vault "Diary", password "diary", opening with password and key.
  Future<String> hiddenDiary(WidgetTester tester) async {
    final id = await phone.addVault(tester, 'Diary', 'diary', listed: false);
    final session = (await tester.runAsync(() => phone.vaultStore.unlockAnyVault('diary', mainVault)))!;
    await keyUp(tester, session, UnlockMode.both, password: 'diary');
    phone.vaults.active = mainVault;
    return id;
  }

  int count([String? slot = mainVault]) => phone.container.read(unlockAttemptsProvider).read(slot).count;
}

void main() {
  late List<BuildContext> recoveries;

  Future<void> open(WidgetTester tester, _KeyRig rig) async {
    recoveries = [];
    usePhone(tester);
    await rig.phone.pump(
      tester,
      LockScreen(
        openRecovery: (context) async {
          recoveries.add(context);
          return null;
        },
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder passwordField() => fieldLabelled(t('unlock.field.password'));
  Finder pinField() => fieldLabelled(t('lock.key.pin'));

  Future<void> password(WidgetTester tester, String password) async {
    await tester.enterText(passwordField(), password);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
  }

  Future<void> pin(WidgetTester tester, String pin) async {
    await tester.enterText(pinField(), pin);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
  }

  Future<void> opening(WidgetTester tester) async {
    await tester.pump(openDelay);
    await tester.pumpAndSettle();
  }

  // openspec: add-security-key-unlock, task 5.1
  group('the key step', () {
    testWidgets('a vault with no name of its own is not named on the step', (tester) async {
      final rig = _KeyRig();
      final session = await rig.phone.createVault(tester, 'secret');
      await rig.keyUp(tester, session, UnlockMode.key, password: 'secret');
      await open(tester, rig);
      expect(find.text(t('lock.key.keyOnlyUnnamed')), findsOneWidget);
      expect(find.textContaining(t('vaults.defaultName')), findsNothing);
    });

    testWidgets('the right password of a vault needing both shows the step, and the vault is still locked', (tester) async {
      final rig = _KeyRig();
      await rig.personal(tester, UnlockMode.both);
      await open(tester, rig);
      expect(passwordField(), findsOneWidget);

      await password(tester, 'secret');

      expect(find.text(t('lock.key.titleAndroid')), findsOneWidget);
      expect(find.text(t('lock.key.both', {'name': 'Personal'})), findsOneWidget);
      expect(pinField(), findsOneWidget);
      expect(find.text(t('lock.key.pinNote')), findsOneWidget);
      expect(find.text(t('lock.key.lost')), findsOneWidget);
      expect(find.text(t('lock.key.another')), findsOneWidget);
      expect(passwordField(), findsNothing);
      expect(rig.phone.state.phase, VaultPhase.locked);
    });

    testWidgets('the key and its PIN open it', (tester) async {
      final rig = _KeyRig();
      final session = await rig.personal(tester, UnlockMode.both);
      await open(tester, rig);
      await password(tester, 'secret');

      rig.present();
      await pin(tester, '123456');
      await opening(tester);

      expect(rig.phone.state.phase, VaultPhase.unlocked);
      expect(rig.phone.state.session!.secretKey, session.secretKey);
      expect(rig.phone.vaults.active, mainVault);
    });

    testWidgets('a listed vault that opens with a key alone starts on the step, and opens with it', (tester) async {
      final rig = _KeyRig();
      await rig.personal(tester, UnlockMode.key);
      await open(tester, rig);

      expect(find.text(t('lock.key.titleAndroid')), findsOneWidget);
      expect(find.text(t('lock.key.keyOnly', {'name': 'Personal'})), findsOneWidget);
      expect(passwordField(), findsNothing);

      rig.present();
      await pin(tester, '123456');
      await opening(tester);
      expect(rig.phone.state.phase, VaultPhase.unlocked);
    });

    testWidgets('on an iPhone the title says to hold the key to the top of the phone', (tester) async {
      final rig = _KeyRig(reach: FakeSecurityKeys.iphone);
      await rig.personal(tester, UnlockMode.key);
      await open(tester, rig);

      expect(find.text(t('lock.key.title')), findsOneWidget);
    });

    testWidgets('"Open another vault" shows the password form with one vault on the phone, where a password is a wrong one', (
      tester,
    ) async {
      final rig = _KeyRig();
      await rig.personal(tester, UnlockMode.key);
      await open(tester, rig);

      await tapOn(tester, find.text(t('lock.key.another')));
      expect(passwordField(), findsOneWidget);
      expect(find.text(t('vaults.lock.choose')), findsNothing);
      await password(tester, 'secret');
      expect(find.text(t('unlock.error.incorrectPassword')), findsOneWidget);

      // And the way back to the key
      await tapOn(tester, find.text(t('lock.key.useKey')));
      expect(pinField(), findsOneWidget);
    });

    testWidgets('"Open another vault" shows the password form and the vault picker with several vaults', (tester) async {
      final rig = _KeyRig();
      await rig.personal(tester, UnlockMode.key);
      final work = await rig.phone.addVault(tester, 'Work', 'work password');
      rig.phone.vaults.active = mainVault;
      await open(tester, rig);
      expect(find.bySemanticsLabel(t('vaults.lock.choose')), findsNothing);

      await tapOn(tester, find.text(t('lock.key.another')));
      expect(find.bySemanticsLabel(t('vaults.lock.choose')), findsOneWidget);
      await tapOn(tester, find.text('Work'));
      await password(tester, 'work password');
      await opening(tester);

      expect(rig.phone.vaults.active, work);
      expect(rig.phone.state.phase, VaultPhase.unlocked);
    });

    testWidgets('the Recovery Kit button opens the recovery sheet', (tester) async {
      final rig = _KeyRig();
      await rig.personal(tester, UnlockMode.both);
      await open(tester, rig);
      await password(tester, 'secret');

      await tapOn(tester, find.text(t('lock.key.lost')));

      expect(recoveries, hasLength(1));
    });
  });

  // openspec: add-security-key-unlock, task 5.2
  group('the counts', () {
    testWidgets('a wrong password for a vault needing both counts and asks for no key', (tester) async {
      final rig = _KeyRig();
      await rig.personal(tester, UnlockMode.both);
      await open(tester, rig);

      await password(tester, 'wrong');

      expect(rig.count(), 1);
      expect(find.text(t('unlock.error.incorrectPassword')), findsOneWidget);
      expect(pinField(), findsNothing);
    });

    testWidgets('a right password followed by leaving the step puts the count back', (tester) async {
      final rig = _KeyRig();
      await rig.personal(tester, UnlockMode.both);
      await open(tester, rig);
      await password(tester, 'wrong');
      await password(tester, 'wrong again');
      expect(rig.count(), 2);

      await password(tester, 'secret');
      expect(rig.count(), 2);
      await tapOn(tester, find.text(t('lock.key.another')));

      expect(rig.count(), 2);
      expect(passwordField(), findsOneWidget);
    });

    testWidgets('an open resets it, and reports the wrong passwords before it', (tester) async {
      final rig = _KeyRig();
      await rig.personal(tester, UnlockMode.both);
      await open(tester, rig);
      await password(tester, 'wrong');
      await password(tester, 'secret');

      rig.present();
      await pin(tester, '123456');
      await opening(tester);

      expect(rig.phone.state.phase, VaultPhase.unlocked);
      expect(rig.count(), 0);
    });

    testWidgets('eight wrong PINs change no count and erase nothing, with the erase set to 10', (tester) async {
      final rig = _KeyRig();
      await rig.personal(tester, UnlockMode.both);
      writeUnlockErase(rig.phone.store, 10);
      await open(tester, rig);
      await password(tester, 'secret');
      rig.present();

      var sent = 0;
      while (rig.soft.retries > 0) {
        await pin(tester, '000000');
        if (find.text(t('lock.key.lastTry.title')).evaluate().isNotEmpty) {
          await tapOn(tester, find.text(t('lock.key.lastTry.confirm')));
        }
        sent++;
        // The key takes no more PINs after three wrong ones in a row until it is presented again
        if (find.textContaining(t('securityKeys.pin.locked')).evaluate().isNotEmpty) rig.presentAgain();
      }

      expect(sent, 8);
      expect(find.text(t('lock.key.blocked')), findsOneWidget);
      expect(rig.count(), 0);
      expect(rig.phone.vaultStore.isVaultSetup(), isTrue);
      expect(rig.phone.state.phase, VaultPhase.locked);
    });

    testWidgets('a key that is not the vault’s says so and counts nothing', (tester) async {
      final rig = _KeyRig();
      await rig.personal(tester, UnlockMode.both);
      await open(tester, rig);
      await password(tester, 'wrong');
      await password(tester, 'secret');

      // Another key, with its own PIN, that was never enrolled
      rig.keys.arrive(
        FakeKey(
          productName: 'Other Key',
          ctap: SoftKey(pin: '654321'),
        ).device(kinds: {SecurityKeyLinkKind.nfc}),
      );
      await pin(tester, '654321');

      expect(find.text(t('lock.key.notThisVault')), findsOneWidget);
      expect(rig.count(), 1);
      expect(rig.phone.state.phase, VaultPhase.locked);
      expect(pinField(), findsOneWidget);
    });
  });

  // openspec: add-security-key-unlock, task 5.3
  group('the PIN messages, with the software key', () {
    Future<_KeyRig> atStep(WidgetTester tester) async {
      final rig = _KeyRig();
      await rig.personal(tester, UnlockMode.key);
      await open(tester, rig);
      rig.present();
      return rig;
    }

    testWidgets('a wrong PIN says how many tries the key has left', (tester) async {
      final rig = await atStep(tester);

      await pin(tester, '000000');

      expect(find.text('${t('securityKeys.pin.wrong')} ${t('securityKeys.pin.triesLeft', {'count': 7})}'), findsOneWidget);
      expect(find.text(t('lock.key.pinNote')), findsNothing);
      expect(rig.soft.retries, 7);
    });

    testWidgets('at one try left it asks before sending the PIN', (tester) async {
      final rig = await atStep(tester);
      rig.soft.retries = 1;

      await pin(tester, '123456');
      expect(find.text(t('lock.key.lastTry.title')), findsOneWidget);
      await tapOn(tester, find.text(t('export.cancel')));
      expect(rig.soft.retries, 1);
      expect(rig.phone.state.phase, VaultPhase.locked);

      await pin(tester, '123456');
      await tapOn(tester, find.text(t('lock.key.lastTry.confirm')));
      await opening(tester);
      expect(rig.phone.state.phase, VaultPhase.unlocked);
      expect(rig.soft.retries, 8);
    });

    testWidgets('after three wrong PINs in a row it says to take the key away and present it again', (tester) async {
      final rig = await atStep(tester);
      for (var i = 0; i < 3; i++) {
        await pin(tester, '000000');
      }

      expect(find.text(t('securityKeys.pin.locked')), findsOneWidget);

      rig.presentAgain();
      await pin(tester, '123456');
      await opening(tester);
      expect(rig.phone.state.phase, VaultPhase.unlocked);
    });

    testWidgets('a PIN locked for good says the key opens nothing now, and offers another key or the kit', (tester) async {
      final rig = await atStep(tester);
      rig.soft.retries = 0;

      await pin(tester, '123456');

      expect(find.text(t('lock.key.blocked')), findsOneWidget);
      expect(find.text(t('lock.key.lost')), findsOneWidget);
      expect(pinField(), findsOneWidget);
    });
  });

  // openspec: add-security-key-unlock, task 5.4
  group('the step a password gave is dropped', () {
    Future<_KeyRig> atStep(WidgetTester tester, {SecurityKeyCapabilities reach = FakeSecurityKeys.android}) async {
      final rig = _KeyRig(reach: reach);
      await rig.personal(tester, UnlockMode.both);
      await open(tester, rig);
      await password(tester, 'secret');
      expect(pinField(), findsOneWidget);
      return rig;
    }

    Future<void> hide(WidgetTester tester) async {
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
    }

    Future<void> show(WidgetTester tester) async {
      for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
    }

    testWidgets('on leaving it', (tester) async {
      await atStep(tester);
      await tapOn(tester, find.text(t('lock.key.another')));

      expect(passwordField(), findsOneWidget);
      expect(pinField(), findsNothing);
    });

    testWidgets('when the app is hidden', (tester) async {
      final rig = await atStep(tester);
      await hide(tester);
      await show(tester);

      expect(passwordField(), findsOneWidget);
      expect(pinField(), findsNothing);
      expect(rig.phone.state.phase, VaultPhase.locked);
    });

    testWidgets('after two minutes, with a word on why', (tester) async {
      await atStep(tester);
      await tester.pump(keyStepTimeout - const Duration(seconds: 1));
      expect(pinField(), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(passwordField(), findsOneWidget);
      expect(find.text(t('lock.key.expired')), findsOneWidget);
    });

    testWidgets('but not under the system’s NFC sheet, which hides the app for the key', (tester) async {
      final rig = await atStep(tester, reach: FakeSecurityKeys.iphone);
      final covered = <bool>[];
      rig.soft.onRequest = (command, _) {
        if (command != 0x02 || covered.isNotEmpty) return;
        covered.add(rig.reader.coveredBySystem);
        for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      };
      rig.present();

      await pin(tester, '123456');
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await opening(tester);

      expect(covered, [isTrue]);
      expect(rig.phone.state.phase, VaultPhase.unlocked);
    });
  });

  // openspec: add-security-key-unlock, task 5.5
  group('hidden vaults', () {
    testWidgets(
      'a hidden vault needing both reaches the step after its password with no name, opens with its key and resets the listed slot',
      (tester) async {
        final rig = _KeyRig();
        await rig.phone.createVault(tester, 'secret');
        final diary = await rig.hiddenDiary(tester);
        await open(tester, rig);
        await password(tester, 'wrong');
        expect(rig.count(), 1);

        await password(tester, 'diary');
        expect(find.text(t('lock.key.bothHidden')), findsOneWidget);
        expect(find.textContaining('Diary'), findsNothing);
        expect(rig.phone.vaults.active, mainVault);

        rig.present();
        await pin(tester, '123456');
        await opening(tester);

        expect(rig.phone.vaults.active, diary);
        expect(rig.phone.state.phase, VaultPhase.unlocked);
        expect(rig.count(), 0);
        expect(rig.phone.store.storedKeys().where((key) => key.contains('unlock_failures') && key.contains(diary)), isEmpty);
      },
    );

    testWidgets('before any password the screen is the same with and without hidden vaults, whichever way the vault on screen opens', (
      tester,
    ) async {
      Future<List<String>> shown(UnlockMode mode, {required bool hidden}) async {
        final rig = _KeyRig();
        final session = await rig.phone.createVault(tester, 'secret');
        if (hidden) {
          await rig.hiddenDiary(tester);
          await rig.phone.addVault(tester, 'Journal', 'journal', listed: false);
          rig.phone.vaults.active = mainVault;
        }
        await rig.keyUp(tester, session, mode, password: 'secret');
        await open(tester, rig);
        final tree = [for (final widget in tester.allWidgets) widget.runtimeType.toString()];
        final texts = [for (final text in tester.widgetList<Text>(find.byType(Text))) text.data ?? text.textSpan?.toPlainText() ?? ''];
        await tester.pumpWidget(const SizedBox());
        return [...tree, ...texts];
      }

      for (final mode in UnlockMode.values) {
        expect(await shown(mode, hidden: true), await shown(mode, hidden: false), reason: mode.name);
      }
    });
  });
}
