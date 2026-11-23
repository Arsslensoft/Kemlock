import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/time.dart';
import 'package:kemlock/features/lock/replace_key_sheet.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import '../recovery/recovery_harness.dart';
import 'key_phone.dart';
import 'lock_phone.dart';

/// Vaults whose key derivations can be held, from the [heldFrom]th on, until
/// [release]: the sheet checks the password with one, and the replacement
/// derives again, so holding the second keeps the replacement running.
class _HeldVaults extends RecoveryVaults {
  int heldFrom = 1 << 30;
  var derivations = 0;
  final _held = Completer<void>();

  void release() => _held.complete();

  @override
  VaultStore get vaults => _store;

  late final VaultStore _store = VaultStore(
    store,
    registry,
    deriveKey: (password, salt) async {
      if (++derivations >= heldFrom) await _held.future;
      return fastKdf(password, salt);
    },
    unlockKeys: unlockKeys,
  );
}

void main() {
  late _HeldVaults vaults;
  late ProviderContainer container;
  late VaultSession session;

  /// The sheet over an open vault; [kit] gives the vault a Recovery Kit of that shape first.
  Future<void> open(WidgetTester tester, {({int threshold, int shares})? kit, bool exposed = false}) async {
    vaults = _HeldVaults();
    session = await vaults.vaults.setupVault('pw');
    if (kit != null) {
      await vaults.vaults.setRecoveryKey(
        session,
        RecoveryKey(
          kitId: 'OLDKT',
          key: Uint8List(32),
          threshold: kit.threshold,
          shares: kit.shares,
          createdAt: isoString(DateTime.utc(2026)),
        ),
      );
    }
    container = await pumpLauncher(
      tester,
      vaults,
      (context) => showReplaceKeySheet(context, exposed: exposed),
      before: (container) => container.read(vaultControllerProvider.notifier).open(session),
    );
  }

  Map<String, String?> snapshot() => {for (final key in vaults.store.storedKeys()) key: vaults.store.getItem(key)};

  String publicKey() => (jsonDecode(vaults.store.getItem(keyConfig)!) as Map<String, Object?>)['publicKey']! as String;

  Finder button(String id) => find.ancestor(of: find.text(t(id)), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> typePassword(WidgetTester tester, String password) async {
    await tester.enterText(find.byType(TextField), password);
    await tester.pump();
  }

  testWidgets('keeps the password from the phone’s password manager and the keyboard’s learning', (tester) async {
    await open(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    // Null keeps it out of autofill, which the empty default doesn't
    expect(field.autofillHints, isNull);
    expect(field.enableIMEPersonalizedLearning, isFalse);
  });

  testWidgets('says the password is wrong and changes nothing', (tester) async {
    await open(tester);
    final before = snapshot();

    await typePassword(tester, 'not it');
    await tap(tester, button('replaceKey.button'));

    expect(find.text(t('replaceKey.error.incorrect')), findsOneWidget);
    expect(find.text(t('replaceKey.title')), findsOneWidget);
    expect(snapshot(), before);
  });

  testWidgets('replaces the key of a vault without a kit, with no kit step', (tester) async {
    await open(tester);
    final before = publicKey();

    expect(find.text(t('replaceKey.kitNote')), findsNothing);
    await typePassword(tester, 'pw');
    await tap(tester, button('replaceKey.button'));

    expect(find.text(t('replaceKey.done.title')), findsOneWidget);
    expect(find.text(t('replaceKey.kit.title')), findsNothing);
    expect(publicKey(), isNot(before));
    expect(container.read(vaultControllerProvider).session!.publicKey, isNot(session.publicKey));
    expect(vaults.store.getItem(keyKeyRotation), isNull);
    expect(vaults.vaults.recoveryKitInfo(), isNull);
  });

  testWidgets('has a vault with a kit make a new one of the same shape', (tester) async {
    await open(tester, kit: (threshold: 2, shares: 3));

    expect(find.text(t('replaceKey.kitNote')), findsOneWidget);
    await typePassword(tester, 'pw');
    await tap(tester, button('replaceKey.continue'));
    expect(find.text(t('replaceKey.kit.body')), findsOneWidget);
    await tap(tester, button('replaceKey.kit.make'));
    // The kit sheet, with the old kit's shape
    expect(find.text(t('recovery.kit.pieces.people', {'needed': 2, 'total': 3})), findsOneWidget);
    await tap(tester, find.text(t('recovery.kit.replacement.saved')));
    await tap(tester, button('recovery.kit.replacement.use'));

    expect(find.text(t('replaceKey.done.title')), findsOneWidget);
    final info = vaults.vaults.recoveryKitInfo()!;
    expect((info.threshold, info.shares), (2, 3));
    expect(info.kitId, isNot('OLDKT'));
    await expectLater(vaults.vaults.unlockWithRecoveryKey('OLDKT', Uint8List(32)), throwsA(isA<KitNotFoundError>()));
  });

  testWidgets('goes on without a kit when asked, leaving the vault with none', (tester) async {
    await open(tester, kit: (threshold: 1, shares: 1));

    await typePassword(tester, 'pw');
    await tap(tester, button('replaceKey.continue'));
    await tap(tester, button('replaceKey.kit.skip'));

    expect(find.text(t('replaceKey.done.title')), findsOneWidget);
    expect(vaults.vaults.recoveryKitInfo(), isNull);
  });

  testWidgets('a kit sheet put away makes nothing, and the kit step waits', (tester) async {
    await open(tester, kit: (threshold: 1, shares: 1));
    final before = publicKey();

    await typePassword(tester, 'pw');
    await tap(tester, button('replaceKey.continue'));
    await tap(tester, button('replaceKey.kit.make'));
    await tap(tester, button('changePw.cancel'));

    expect(find.text(t('replaceKey.kit.body')), findsOneWidget);
    expect(publicKey(), before);
  });

  testWidgets('can’t be closed while the key is being replaced', (tester) async {
    await open(tester);
    // The sheet's check passes; the replacement's own derivation waits
    vaults.heldFrom = 3;

    await typePassword(tester, 'pw');
    await tester.tap(button('replaceKey.button'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(t('replaceKey.working')), findsOneWidget);
    expect(container.read(vaultControllerProvider).replacingKey, isTrue);

    await tester.binding.handlePopRoute();
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(t('replaceKey.working')), findsOneWidget);

    vaults.release();
    await tester.pumpAndSettle();
    expect(find.text(t('replaceKey.done.title')), findsOneWidget);
    expect(container.read(vaultControllerProvider).replacingKey, isFalse);
  });

  testWidgets('says so in a vault known to be exposed, and can be put off', (tester) async {
    await open(tester, exposed: true);
    final before = snapshot();

    expect(find.text(t('replaceKey.exposed')), findsOneWidget);
    await tap(tester, button('replaceKey.notNow'));

    expect(find.text(t('replaceKey.title')), findsNothing);
    expect(snapshot(), before);
  });

  // openspec: add-security-key-unlock, task 6.7
  group('with security keys', () {
    Future<VaultSession> openKeyed(WidgetTester tester, KeyPhone rig, List<SoftKey> keys, UnlockMode mode) async {
      usePhone(tester);
      final opened = await rig.phone.createVault(tester, 'pw');
      // Two keys and no kit: the replacement asks for no new kit
      await rig.keyUp(tester, opened, password: 'pw', keys: keys, mode: mode, kit: false);
      await rig.phone.pump(tester, const SheetOpener(showReplaceKeySheet));
      await rig.phone.controller.open(opened);
      await tapOn(tester, find.text('Open'));
      return opened;
    }

    Future<void> giveKey(WidgetTester tester, KeyPhone rig, SoftKey soft) async {
      expect(find.text(t('unlockMethod.prove.key.title')), findsOneWidget);
      rig.hold(soft);
      await typeInto(tester, t('lock.key.pin'), soft.pin!);
      await tapOn(tester, buttonLabelled(t('lock.key.read')));
    }

    testWidgets('a vault that needs both is asked for its password and its key, and every key opens it afterwards', (tester) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      final green = SoftKey(pin: '654321');
      final before = await openKeyed(tester, rig, [blue, green], UnlockMode.both);

      expect(fieldLabelled(t('unlock.field.password')), findsOneWidget);
      await typeInto(tester, t('unlock.field.password'), 'pw');
      await tapOn(tester, buttonLabelled(t('replaceKey.button')));
      await giveKey(tester, rig, blue);

      expect(find.text(t('replaceKey.done.title')), findsOneWidget);
      final next = rig.phone.state.session!;
      expect(next.publicKey, isNot(before.publicKey));
      final store = rig.phone.vaultStore;
      expect(store.unlockMode(), UnlockMode.both);
      expect(store.enrolledKeys(), hasLength(2));
      for (final soft in [blue, green]) {
        await tester.runAsync(() async {
          rig.hold(soft);
          final challenge = store.keyChallenge();
          final output = await rig.reader.read(
            pin: pinBytes(soft.pin!),
            salt: challenge.salt,
            allow: challenge.credentials,
            prompts: testKeyPrompts,
          );
          final step = await store.beginUnlock('pw', mainVault) as UnlockNeedsKey;
          final opened = await store.unlockWithSecurityKey(mainVault, (
            credential: output.credential,
            output: output.output,
          ), pending: step.pending);
          expect(opened.secretKey, next.secretKey);
        });
      }
    });

    testWidgets('a vault that opens with its key alone is asked for the key and no password', (tester) async {
      final rig = KeyPhone();
      final blue = SoftKey(pin: '123456');
      final before = await openKeyed(tester, rig, [blue, SoftKey(pin: '654321')], UnlockMode.key);

      expect(fieldLabelled(t('unlock.field.password')), findsNothing);
      await tapOn(tester, buttonLabelled(t('replaceKey.button')));
      await giveKey(tester, rig, blue);

      expect(find.text(t('replaceKey.done.title')), findsOneWidget);
      expect(rig.phone.state.session!.publicKey, isNot(before.publicKey));
      expect(rig.phone.vaultStore.unlockMode(), UnlockMode.key);
    });
  });
}
