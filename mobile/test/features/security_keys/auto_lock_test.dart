import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/security_keys/security_key_controller.dart';
import 'package:kemlock/features/settings/auto_lock.dart';
import 'package:kemlock/platform/security_keys.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_security_keys.dart';

const _nfc = {SecurityKeyLinkKind.nfc};
const _usb = {SecurityKeyLinkKind.usbHid};

/// The sheet's state on a fake phone, with the app's auto-lock watching:
/// "lock when hidden" is on, and the idle limit is one minute.
class _Rig {
  _Rig(SecurityKeyCapabilities capabilities) : phone = FakeSecurityKeys(phone: capabilities) {
    holds = AutoLockHolds(now: phone.now);
    autoLock = AutoLock(holds: holds, lock: () => locks++, now: phone.now)..update(active: true, minutes: 1, lockOnHide: true);
    controller = SecurityKeyController(keys: phone, holds: holds, now: phone.now)
      ..nfcMessage = 'Hold your key'
      ..nfcFailure = 'Try again';
  }

  final FakeSecurityKeys phone;
  late final AutoLockHolds holds;
  late final AutoLock autoLock;
  late final SecurityKeyController controller;
  int locks = 0;

  /// The system's sheet or question covers the app.
  void hide() => autoLock.lifecycleChanged(AppLifecycleState.hidden);

  /// The app is on screen again, the sheet or question gone.
  void show() {
    autoLock.lifecycleChanged(AppLifecycleState.inactive);
    autoLock.lifecycleChanged(AppLifecycleState.resumed);
  }

  void dispose() {
    autoLock.dispose();
    controller.dispose();
  }
}

void main() {
  late _Rig rig;

  Future<void> start(SecurityKeyCapabilities capabilities) async {
    rig = _Rig(capabilities);
    addTearDown(() => rig.dispose());
    await rig.controller.start();
    await pumpEventQueue();
  }

  group('while iPhone’s NFC sheet is up', () {
    test('hiding the app does not lock the vault, and the hold is released when the read succeeds', () async {
      await start(FakeSecurityKeys.iphone);
      rig.phone.arrive(FakeKey(ctap: FakeFidoKey()).device(kinds: _nfc));
      var hiddenUnderSheet = false;

      await rig.controller.run((session) async {
        hiddenUnderSheet = rig.phone.nfcSheetUp && rig.holds.isHeld;
        rig.hide();
      });

      expect(hiddenUnderSheet, isTrue);
      expect(rig.locks, 0);
      expect(rig.holds.isHeld, isFalse);
      rig.show();
      rig.hide();
      expect(rig.locks, 1, reason: 'with the sheet gone, hiding the app locks as before');
    });

    test('the hold is released when the read fails', () async {
      await start(FakeSecurityKeys.iphone);
      rig.phone.arrive(FakeKey(fido: false).device(kinds: _nfc));

      await expectLater(rig.controller.read(), throwsA(anything));

      expect(rig.holds.isHeld, isFalse);
      expect(rig.locks, 0);
    });

    test('the hold is released when the person closes the sheet', () async {
      await start(FakeSecurityKeys.iphone);
      rig.phone.cancelNextNfcSheet = true;

      await expectLater(rig.controller.read(), throwsA(isA<SecurityKeyCancelled>()));

      expect(rig.holds.isHeld, isFalse);
    });

    test('the hold is released when the session runs out', () async {
      await start(FakeSecurityKeys.iphone);

      final read = expectLater(rig.controller.read(), throwsA(isA<SecurityKeyTimeout>()));
      await pumpEventQueue();
      expect(rig.holds.isHeld, isTrue);
      rig.hide();
      expect(rig.locks, 0);
      rig.phone.expireNfcSession();
      await read;

      expect(rig.holds.isHeld, isFalse);
    });

    test('the hold is released when the app itself cancels the wait', () async {
      await start(FakeSecurityKeys.iphone);

      final read = expectLater(rig.controller.read(), throwsA(isA<SecurityKeyCancelled>()));
      await pumpEventQueue();
      await rig.controller.cancel();
      await read;

      expect(rig.holds.isHeld, isFalse);
    });
  });

  group('while Android’s USB question is up', () {
    Future<Completer<void>> ask() async {
      await start(FakeSecurityKeys.android);
      final answer = Completer<void>();
      rig.phone.permissionWaits = answer.future;
      rig.phone.arrive(FakeKey(productName: 'Example Key', ctap: FakeFidoKey()).device(kinds: _usb));
      await pumpEventQueue();
      expect(rig.holds.isHeld, isTrue);
      rig.hide();
      expect(rig.locks, 0, reason: 'the question hides the app; the vault stays open');
      return answer;
    }

    test('allowing it releases the hold', () async {
      final answer = await ask();

      answer.complete();
      await pumpEventQueue();

      expect(rig.holds.isHeld, isFalse);
      expect(rig.controller.key?.productName, 'Example Key');
    });

    test('refusing it releases the hold', () async {
      final answer = await ask();
      rig.phone.refusePermission = true;

      answer.complete();
      await pumpEventQueue();

      expect(rig.holds.isHeld, isFalse);
      expect(rig.controller.hub.denied, isNotNull);
    });

    test('dismissing it by pulling the key out releases the hold', () async {
      final answer = await ask();
      rig.phone.remove(rig.phone.here.single);

      answer.complete();
      await pumpEventQueue();

      expect(rig.holds.isHeld, isFalse);
      expect(rig.controller.key, isNull);
      expect(rig.controller.hub.denied, isNull);
    });
  });

  test('idle auto-lock still fires with the sheet open and a key connected', () async {
    await start(FakeSecurityKeys.android);
    rig.phone.arrive(FakeKey(ctap: FakeFidoKey()).device(kinds: _nfc));
    await pumpEventQueue();
    expect(rig.controller.connected, isTrue);
    expect(rig.holds.isHeld, isFalse, reason: 'a connected key holds nothing');

    rig.phone.elapse(const Duration(minutes: 2));
    rig.autoLock.lifecycleChanged(AppLifecycleState.resumed);

    expect(rig.locks, 1);
  });

  test('when the vault locks, the session with the key is closed and the PIN forgotten', () async {
    await start(FakeSecurityKeys.android);
    rig.phone.arrive(FakeKey(ctap: FakeFidoKey(pin: '123456')).device(kinds: _usb));
    await pumpEventQueue();
    rig.controller.rememberPin(Uint8List.fromList([0x31, 0x32, 0x33, 0x34]));
    final kept = rig.controller.pin!;

    await rig.controller.lock();

    expect(rig.phone.openLinks, isEmpty);
    expect(rig.controller.pin, isNull);
    expect(kept, [0, 0, 0, 0], reason: 'the bytes are wiped, not only let go');
    expect(rig.controller.key, isNull);
  });
}
