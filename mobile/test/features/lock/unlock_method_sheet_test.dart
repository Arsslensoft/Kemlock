import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/lock/unlock_method_sheet.dart';
import 'package:kemlock/features/security_keys/security_key_sheet.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_security_keys.dart';
import '../../helpers/test_app.dart';
import '../../vault/rotation_helpers.dart' show newKit;
import 'key_phone.dart';
import 'lock_phone.dart';

void main() {
  /// Sets the first vault up with "secret" and, unless [kit] is false, a
  /// Recovery Kit, enrols [keys] and sets [mode], opens it, and opens the
  /// sheet over a page.
  Future<VaultSession> open(
    WidgetTester tester,
    KeyPhone rig, {
    List<SoftKey> keys = const [],
    UnlockMode mode = UnlockMode.password,
    bool kit = true,
    bool hidden = false,
  }) async {
    usePhone(tester);
    final session = await rig.phone.createVault(tester, 'secret');
    if (keys.isNotEmpty) {
      await rig.keyUp(tester, session, password: 'secret', keys: keys, mode: mode, kit: kit);
    } else if (kit) {
      await tester.runAsync(() => rig.phone.vaultStore.setRecoveryKey(session, newKit()));
    }
    if (hidden) rig.phone.vaults.setListed(mainVault, false);
    await rig.phone.pump(tester, const SheetOpener(showUnlockMethodSheet));
    await rig.phone.controller.open(session);
    await tapOn(tester, find.text('Open'));
    return session;
  }

  VaultStore store(KeyPhone rig) => rig.phone.vaultStore;
  Finder mode(UnlockMode mode) => find.text(t('unlockMethod.mode.${mode.name}'));
  bool marked(WidgetTester tester, UnlockMode m) =>
      tester.getSemantics(mode(m)).getSemanticsData().flagsCollection.isChecked == CheckedState.isTrue;
  Finder continueButton() => find.text(t('unlockMethod.continue.key'));
  bool canContinue(WidgetTester tester) => tester.widget<ButtonStyleButton>(buttonLabelled(t('unlockMethod.continue.key'))).enabled;

  /// Whether the field labelled [id] is kept from the phone's password manager, by null hints rather than the
  /// empty default, and from the keyboard's learning.
  void expectNoAutofill(WidgetTester tester, String id) {
    final field = tester.widget<TextField>(fieldLabelled(t(id)));
    expect(field.autofillHints, isNull, reason: id);
    expect(field.enableIMEPersonalizedLearning, isFalse, reason: id);
  }

  /// Types the vault's password in the proof's sheet.
  Future<void> givePassword(WidgetTester tester, String password) async {
    expect(find.text(t('unlockMethod.prove.password.title')), findsOneWidget);
    expectNoAutofill(tester, 'unlock.field.password');
    await typeInto(tester, t('unlock.field.password'), password);
    await tapOn(tester, buttonLabelled(t('unlockMethod.continue')));
  }

  /// Holds [soft] to the phone and gives its PIN in the key's sheet.
  Future<void> giveKey(WidgetTester tester, KeyPhone rig, SoftKey soft, {String? pin}) async {
    rig.hold(soft);
    await typeInto(tester, t('lock.key.pin'), pin ?? soft.pin!);
    await tapOn(tester, buttonLabelled(t('lock.key.read')));
  }

  String madeOn(VaultStore store) {
    final made = DateTime.parse(store.recoveryKitInfo()!.createdAt).toLocal();
    return t('unlockMethod.kit.made', {'date': '${_month(made.month)} ${made.day}'});
  }

  // openspec: add-security-key-unlock, task 6.1
  group('the sheet', () {
    testWidgets('a vault with a kit and no key shows password marked, the kit’s date, no second key, and Continue', (tester) async {
      final rig = KeyPhone();
      await open(tester, rig);

      expect(find.text(t('unlockMethod.title')), findsOneWidget);
      for (final m in UnlockMode.values) {
        expect(mode(m), findsOneWidget);
        expect(find.text(t('unlockMethod.mode.${m.name}.detail')), findsOneWidget);
      }
      expect(marked(tester, UnlockMode.password), isTrue);
      expect(marked(tester, UnlockMode.both), isFalse);
      expect(find.text(t('unlockMethod.lose').toUpperCase()), findsOneWidget);
      expect(find.text(madeOn(store(rig))), findsOneWidget);
      expect(find.text(t('unlockMethod.second')), findsOneWidget);
      expect(find.text(t('unlockMethod.second.none')), findsOneWidget);
      expect(find.text(t('unlockMethod.add')), findsOneWidget);
      expect(find.text(t('unlockMethod.note')), findsOneWidget);
      expect(find.text(t('unlockMethod.keys').toUpperCase()), findsNothing);
      // Nothing to continue to until another way is chosen
      expect(canContinue(tester), isFalse);
      await tapOn(tester, mode(UnlockMode.both));
      expect(marked(tester, UnlockMode.both), isTrue);
      expect(canContinue(tester), isTrue);
      // An Android phone: no iPhone line
      expect(find.text(t('unlockMethod.iphone')), findsNothing);
    });

    testWidgets('the kit row opens the kit sheet', (tester) async {
      final rig = KeyPhone();
      await open(tester, rig);

      await tapOn(tester, find.text(t('recovery.kit.title')));

      expect(find.text(t('recovery.kit.replace')), findsOneWidget);
    });

    testWidgets('says the key is read over NFC only on an iPhone', (tester) async {
      final rig = KeyPhone(reach: FakeSecurityKeys.iphone, iPhoneProven: true);
      await open(tester, rig);
      expect(find.text(t('unlockMethod.iphone')), findsOneWidget);
    });

    testWidgets('a key mode is turned on with two keys', (tester) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      await open(
        tester,
        rig,
        keys: [
          blue,
          SoftKey(pin: '654321'),
        ],
        kit: false,
      );

      await tapOn(tester, mode(UnlockMode.both));
      await tapOn(tester, continueButton());
      await givePassword(tester, 'secret');
      await giveKey(tester, rig, blue);

      expect(store(rig).unlockMode(), UnlockMode.both);
    });
  });

  // openspec: add-security-key-unlock, task 6.2
  group('the steps', () {
    testWidgets('password to both with a kit: the password, then the key, then the offer of a new key pair', (tester) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      final session = await open(tester, rig);

      await tapOn(tester, mode(UnlockMode.both));
      await tapOn(tester, continueButton());
      await givePassword(tester, 'secret');
      expect(find.text(t('unlockMethod.enrol.title')), findsOneWidget);
      await giveKey(tester, rig, blue);

      expect(find.text(t('unlockMethod.done.both')), findsOneWidget);
      expect(find.text(t('unlockMethod.replace.body')), findsOneWidget);
      expect(store(rig).unlockMode(), UnlockMode.both);
      expect(store(rig).enrolledKeys(), hasLength(1));
      // The credential and two reads of its secret
      expect(blue.makeRequests, hasLength(1));
      expect(blue.assertRequests, hasLength(2));
      await tester.runAsync(() async {
        final step = await store(rig).beginUnlock('secret', mainVault);
        expect(step, isA<UnlockNeedsKey>());
      });
      expect(rig.phone.state.session!.secretKey, session.secretKey);
    });

    testWidgets('password to key with no kit stops after the first key, says what is missing, and finishes with a second', (tester) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      final green = SoftKey(pin: '654321');
      await open(tester, rig, kit: false);

      await tapOn(tester, mode(UnlockMode.key));
      await tapOn(tester, continueButton());
      await givePassword(tester, 'secret');
      await giveKey(tester, rig, blue);

      expect(find.text(t('unlockMethod.missing')), findsOneWidget);
      expect(store(rig).unlockMode(), UnlockMode.password);
      expect(store(rig).enrolledKeys(), hasLength(1));
      final blueReads = blue.assertRequests.length;

      await tapOn(tester, find.text(t('unlockMethod.add')));
      // No password and no read of the first key: the sheet kept what they gave
      expect(find.text(t('unlockMethod.prove.password.title')), findsNothing);
      await giveKey(tester, rig, green);

      expect(find.text(t('unlockMethod.done.key')), findsOneWidget);
      expect(store(rig).unlockMode(), UnlockMode.key);
      expect(store(rig).enrolledKeys(), hasLength(2));
      expect(blue.assertRequests, hasLength(blueReads));
    });

    testWidgets('both to password asks for the password and a key', (tester) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      await open(tester, rig, keys: [blue], mode: UnlockMode.both);
      final reads = blue.assertRequests.length;

      await tapOn(tester, mode(UnlockMode.password));
      await tapOn(tester, continueButton());
      await givePassword(tester, 'secret');
      expect(find.text(t('unlockMethod.prove.key.title')), findsOneWidget);
      await giveKey(tester, rig, blue);

      expect(find.text(t('unlockMethod.done.password')), findsOneWidget);
      expect(store(rig).unlockMode(), UnlockMode.password);
      expect(blue.assertRequests, hasLength(reads + 1));
    });

    testWidgets('key to password asks for the key, then a new password twice', (tester) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      final session = await open(tester, rig, keys: [blue], mode: UnlockMode.key);

      await tapOn(tester, mode(UnlockMode.password));
      await tapOn(tester, continueButton());
      expect(find.text(t('unlockMethod.prove.password.title')), findsNothing);
      await giveKey(tester, rig, blue);
      expect(find.text(t('unlockMethod.newPassword.title')), findsOneWidget);
      expectNoAutofill(tester, 'changePw.field.new');
      expectNoAutofill(tester, 'changePw.field.confirm');
      await typeInto(tester, t('changePw.field.new'), 'eleven-char');
      await typeInto(tester, t('changePw.field.confirm'), 'eleven-char');
      await tapOn(tester, buttonLabelled(t('unlockMethod.continue')));
      expect(find.text(t('changePw.error.tooShort')), findsOneWidget);
      await typeInto(tester, t('changePw.field.new'), 'a new password');
      await typeInto(tester, t('changePw.field.confirm'), 'a new password');
      await tapOn(tester, buttonLabelled(t('unlockMethod.continue')));

      expect(find.text(t('unlockMethod.done.password')), findsOneWidget);
      final opened = await tester.runAsync(() => store(rig).unlockAnyVault('a new password', mainVault));
      expect(opened!.secretKey, session.secretKey);
    });

    testWidgets('closing the sheet at any step leaves the vault as it was', (tester) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      await open(tester, rig);
      final stored = rig.phone.store.getItem(keyConfig);

      // At the password
      await tapOn(tester, mode(UnlockMode.both));
      await tapOn(tester, continueButton());
      await tapOn(tester, buttonLabelled(t('export.cancel')));
      expect(rig.phone.store.getItem(keyConfig), stored);

      // At the key
      await tapOn(tester, continueButton());
      await givePassword(tester, 'secret');
      rig.hold(blue);
      await tapOn(tester, buttonLabelled(t('export.cancel')));
      expect(rig.phone.store.getItem(keyConfig), stored);
      expect(blue.made, isEmpty);

      // The sheet itself
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(rig.phone.store.getItem(keyConfig), stored);
      expect(store(rig).unlockMode(), UnlockMode.password);
    });
  });

  // openspec: add-security-key-unlock, task 6.3
  group('the keys that open the vault', () {
    Future<void> act(WidgetTester tester, String keyName, String action) async {
      await tapOn(tester, find.byTooltip(t('unlockMethod.keys.actions', {'name': keyName})));
      await tapOn(tester, find.text(t('unlockMethod.keys.$action')));
    }

    testWidgets('each key is listed with its date, and Check says whether a key opens the vault', (tester) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      await open(tester, rig, keys: [blue]);
      final stored = rig.phone.store.getItem(keyConfig);

      expect(find.text(t('unlockMethod.keys').toUpperCase()), findsOneWidget);
      expect(find.text('Key 1'), findsOneWidget);

      await act(tester, 'Key 1', 'check');
      await giveKey(tester, rig, blue);
      expect(find.text(t('unlockMethod.check.opens', {'name': 'Key 1'})), findsOneWidget);

      // A key that is not the vault's: the sheet says so and stays for another key
      await act(tester, 'Key 1', 'check');
      await giveKey(tester, rig, SoftKey(pin: '000000'), pin: '000000');
      expect(find.text(t('lock.key.notThisVault')), findsOneWidget);
      await tapOn(tester, buttonLabelled(t('export.cancel')));
      expect(rig.phone.store.getItem(keyConfig), stored);
    });

    testWidgets('removing the second key of a vault that needs one, with no kit, is refused with the reason', (tester) async {
      final rig = KeyPhone();
      await open(
        tester,
        rig,
        keys: [
          SoftKey(pin: '123456'),
          SoftKey(pin: '654321'),
        ],
        mode: UnlockMode.both,
        kit: false,
      );
      final stored = rig.phone.store.getItem(keyConfig);

      await act(tester, 'Key 2', 'remove');

      expect(find.text(t('unlockMethod.refusal.safetyNet')), findsOneWidget);
      expect(find.text(t('unlockMethod.remove.title')), findsNothing);
      expect(rig.phone.store.getItem(keyConfig), stored);
    });

    testWidgets('a key is renamed and removed with what opens the vault, and the lost key is not needed', (tester) async {
      final rig = KeyPhone();
      await open(tester, rig, keys: [SoftKey(pin: '123456')]);

      await act(tester, 'Key 1', 'rename');
      await tester.enterText(find.byType(TextField).last, 'Blue key');
      await tapOn(tester, find.text(t('unlockMethod.rename.save')));
      await givePassword(tester, 'secret');
      expect(find.text('Blue key'), findsOneWidget);

      await act(tester, 'Blue key', 'remove');
      await tapOn(tester, find.text(t('unlockMethod.remove.confirm')));
      expect(find.text(t('unlockMethod.removed', {'name': 'Blue key'})), findsOneWidget);
      expect(store(rig).enrolledKeys(), isEmpty);
    });

    testWidgets('a key removed while another stays says what it still opens, and every key can go so the rest share a new secret', (
      tester,
    ) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      await open(
        tester,
        rig,
        keys: [
          blue,
          SoftKey(pin: '654321'),
        ],
        mode: UnlockMode.both,
      );
      final salt = store(rig).keyChallenge().salt;

      await act(tester, 'Key 2', 'remove');
      expect(find.text(t('unlockMethod.remove.body', {'name': 'Key 2'})), findsOneWidget);
      await tapOn(tester, find.text(t('unlockMethod.remove.confirm')));
      await givePassword(tester, 'secret');
      await giveKey(tester, rig, blue);
      expect(find.text(t('unlockMethod.removed.shared', {'name': 'Key 2'})), findsOneWidget);
      expect(store(rig).enrolledKeys(), hasLength(1));

      await tapOn(tester, buttonLabelled(t('unlockMethod.restart')));
      expect(find.text(t('unlockMethod.restart.body')), findsOneWidget);
      await tapOn(tester, buttonLabelled(t('unlockMethod.restart.confirm')).last);

      expect(find.text(t('unlockMethod.restart.done.mode')), findsOneWidget);
      expect(find.text(t('unlockMethod.replace.button')), findsOneWidget);
      expect(store(rig).enrolledKeys(), isEmpty);
      expect(store(rig).unlockMode(), UnlockMode.password);

      // Continue turns both on again with the key at hand, under a secret of its own
      await tapOn(tester, continueButton());
      await giveKey(tester, rig, blue);
      expect(store(rig).unlockMode(), UnlockMode.both);
      expect(store(rig).enrolledKeys(), hasLength(1));
      expect(store(rig).keyChallenge().salt, isNot(salt));
    });

    testWidgets('the last key removed says no more than that it no longer opens the vault', (tester) async {
      final rig = KeyPhone();
      await open(tester, rig, keys: [SoftKey(pin: '123456')]);

      await act(tester, 'Key 1', 'remove');
      await tapOn(tester, find.text(t('unlockMethod.remove.confirm')));
      await givePassword(tester, 'secret');

      expect(find.text(t('unlockMethod.removed', {'name': 'Key 1'})), findsOneWidget);
      expect(find.text(t('unlockMethod.restart')), findsNothing);
    });

    testWidgets('the same key twice is refused, and the vault keeps one key', (tester) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      await open(tester, rig, keys: [blue]);

      await tapOn(tester, find.text(t('unlockMethod.add')));
      await givePassword(tester, 'secret');
      // The key secret a further key is wrapped with comes from an enrolled key
      expect(find.text(t('unlockMethod.prove.key.title')), findsOneWidget);
      await giveKey(tester, rig, blue);
      expect(find.text(t('unlockMethod.enrol.title')), findsOneWidget);
      await giveKey(tester, rig, blue);

      expect(find.text(t('unlockMethod.key.already')), findsOneWidget);
      expect(store(rig).enrolledKeys(), hasLength(1));
    });
  });

  // openspec: add-security-key-unlock, task 6.4
  group('what the sheet says', () {
    testWidgets('the biometric line shows only with biometric unlock on and a way that needs the key chosen', (tester) async {
      final rig = KeyPhone(biometrics: PromptBiometrics());
      final session = await open(tester, rig);
      expect(find.text(t('unlockMethod.biometric')), findsNothing);
      await rig.phone.enableBiometrics(tester, session);
      await tapOn(tester, mode(UnlockMode.both));
      expect(find.text(t('unlockMethod.biometric')), findsOneWidget);
      await tapOn(tester, mode(UnlockMode.password));
      expect(find.text(t('unlockMethod.biometric')), findsNothing);
    });

    testWidgets('the AutoFill line shows only with AutoFill on and a way that needs the key chosen', (tester) async {
      final rig = KeyPhone();
      await open(tester, rig);
      await tapOn(tester, mode(UnlockMode.both));
      expect(find.text(t('unlockMethod.autofill')), findsNothing);

      rig.phone.container.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(autofill: true));
      await tester.pumpAndSettle();
      expect(find.text(t('unlockMethod.autofill')), findsOneWidget);
      await tapOn(tester, mode(UnlockMode.password));
      expect(find.text(t('unlockMethod.autofill')), findsNothing);
    });

    testWidgets('a key that is not tied to its PIN is refused for "security key", and both is offered instead', (tester) async {
      final rig = KeyPhone();
      final old = SoftKey.ctap20(pin: '123456');
      await open(tester, rig, keys: [old]);

      await tapOn(tester, mode(UnlockMode.key));
      await tapOn(tester, continueButton());
      await givePassword(tester, 'secret');
      await giveKey(tester, rig, old);

      expect(find.text(t('unlockMethod.notPinBound')), findsOneWidget);
      expect(store(rig).unlockMode(), UnlockMode.password);
      await tapOn(tester, find.text(t('unlockMethod.useBoth')));
      expect(marked(tester, UnlockMode.both), isTrue);
      await tapOn(tester, continueButton());
      expect(find.text(t('unlockMethod.done.both')), findsOneWidget);
    });

    testWidgets('a key with no PIN is asked to get one, through the Security key sheet', (tester) async {
      final rig = KeyPhone();
      await open(tester, rig);
      await tapOn(tester, mode(UnlockMode.both));
      await tapOn(tester, continueButton());
      await givePassword(tester, 'secret');

      await giveKey(tester, rig, SoftKey(), pin: '123456');
      expect(find.text(t('unlockMethod.key.noPin')), findsOneWidget);
      await tapOn(tester, find.text(t('securityKeys.pin.set')));

      expect(find.byType(SecurityKeySheet), findsOneWidget);
    });

    testWidgets('declining the new key pair leaves the way of opening on; accepting opens the replacement', (tester) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      await open(tester, rig);
      await tapOn(tester, mode(UnlockMode.both));
      await tapOn(tester, continueButton());
      await givePassword(tester, 'secret');
      await giveKey(tester, rig, blue);

      await tapOn(tester, find.text(t('unlockMethod.replace.button')));
      expect(find.text(t('replaceKey.title')), findsOneWidget);
      await tapOn(tester, buttonLabelled(t('changePw.cancel')));

      expect(store(rig).unlockMode(), UnlockMode.both);
    });

    testWidgets('"Not now" leaves the vault needing both and its key pair as it was', (tester) async {
      final rig = KeyPhone();
      final session = await open(tester, rig);
      await tapOn(tester, mode(UnlockMode.both));
      await tapOn(tester, continueButton());
      await givePassword(tester, 'secret');
      await giveKey(tester, rig, SoftKey(pin: '123456'));

      await tapOn(tester, find.text(t('replaceKey.notNow')));

      expect(find.text(t('unlockMethod.title')), findsNothing);
      expect(store(rig).unlockMode(), UnlockMode.both);
      expect(rig.phone.state.session!.publicKey, session.publicKey);
    });
  });

  // openspec: add-security-key-unlock, task 6.5
  group('where no key can open a vault', () {
    Future<void> expectUnavailable(WidgetTester tester, KeyPhone rig, String reason) async {
      await open(tester, rig);
      expect(find.text(reason), findsOneWidget);
      for (final m in [UnlockMode.key, UnlockMode.both]) {
        await tapOn(tester, mode(m));
        expect(marked(tester, m), isFalse);
      }
      expect(marked(tester, UnlockMode.password), isTrue);
    }

    testWidgets('an iPad', (tester) async {
      await expectUnavailable(tester, KeyPhone(reach: FakeSecurityKeys.ipad), t('unlockMethod.unavailable.ipad'));
    });

    testWidgets('an iPhone before the prototype’s verdict', (tester) async {
      await expectUnavailable(tester, KeyPhone(reach: FakeSecurityKeys.iphone), t('unlockMethod.unavailable.iphone'));
    });

    testWidgets('an Android phone with neither NFC nor USB hosting', (tester) async {
      await expectUnavailable(tester, KeyPhone(reach: const SecurityKeyCapabilities()), t('securityKeys.wait.none'));
    });
  });

  // openspec: add-security-key-unlock, task 6.8
  testWidgets('a hidden vault cannot be set to open with a key alone, and says why', (tester) async {
    final rig = KeyPhone();
    await open(tester, rig, hidden: true);

    expect(find.text(t('unlockMethod.hiddenKeyOnly')), findsOneWidget);
    await tapOn(tester, mode(UnlockMode.key));
    expect(marked(tester, UnlockMode.key), isFalse);
    await tapOn(tester, mode(UnlockMode.both));
    expect(marked(tester, UnlockMode.both), isTrue);
  });
}

String _month(int month) => const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][month - 1];
