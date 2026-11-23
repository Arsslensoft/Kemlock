import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/security_keys/key_fingerprints_sheet.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/cbor.dart';

import '../fakes/fake_fido_key.dart';
import '../fakes/fake_security_keys.dart';
import '../features/security_keys/key_sheet_harness.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders the Security key sheet and the sheets it opens, in dark and
/// light, on a fake phone with a fake key (`SecurityKey.dc.html` and
/// `Passkeys.dc.html`, without the sections later changes add):
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/security_key_test.dart
void main() {
  /// The mockup's key: a PIN, seven passkeys, room for a hundred, no reader.
  FakeFidoKey mockupKey() => FakeFidoKey(pin: '123456', firmwareVersion: 58)
    ..addPasskey('github.com', 'adalovelace')
    ..addPasskey('google.com', 'ada@example.org')
    ..addPasskey('microsoft.com', 'ada@example.org')
    ..addPasskey('cloudflare.com', 'ada@example.org')
    ..addPasskey('example.org', 'ada')
    ..addPasskey('example.net', 'ada')
    ..addPasskey('example.com', 'ada');

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    Future<KeySheetRig> open(WidgetTester tester, {SecurityKeyCapabilities capabilities = FakeSecurityKeys.android}) {
      usePhoneScreen(tester);
      return openKeySheet(tester, capabilities: capabilities, brightness: brightness, tall: false);
    }

    testScreenshot('security key: waiting on Android, $name', (tester) async {
      await open(tester);
      await takeScreenshot(tester, 'security_key_waiting_android_$name');
    });

    testScreenshot('security key: waiting on iPhone, $name', (tester) async {
      await open(tester, capabilities: FakeSecurityKeys.iphone);
      await takeScreenshot(tester, 'security_key_waiting_iphone_$name');
    });

    testScreenshot('security key: a connected key with a PIN and no reader, $name', (tester) async {
      final rig = await open(tester);
      await rig.present(FakeKey(ctap: mockupKey()), nfc);
      await rig.tapRow('securityKeys.passkeys.row');
      await rig.typePin('123456');
      await rig.close();
      await takeScreenshot(tester, 'security_key_connected_$name');
    });

    testScreenshot('security key: a U2F-only key, $name', (tester) async {
      final rig = await open(tester);
      await rig.present(FakeKey(productName: 'Example U2F Key'), usb);
      await takeScreenshot(tester, 'security_key_u2f_only_$name');
    });

    testScreenshot('security key: the PIN prompt after a wrong PIN, $name', (tester) async {
      final rig = await open(tester);
      await rig.present(FakeKey(productName: 'Example Key 5C NFC', ctap: mockupKey()..retries = 4), usb);
      await rig.tapRow('securityKeys.passkeys.row');
      await rig.typePin('000000');
      await takeScreenshot(tester, 'security_key_pin_wrong_$name');
    });

    testScreenshot('security key: passkeys on the key, $name', (tester) async {
      final rig = await open(tester);
      await rig.present(FakeKey(productName: 'Example Key 5C NFC', ctap: mockupKey()), usb);
      await rig.tapRow('securityKeys.passkeys.row');
      await rig.typePin('123456');
      await takeScreenshot(tester, 'security_key_passkeys_$name');
    });

    testScreenshot('security key: a key that cannot list its passkeys, $name', (tester) async {
      final rig = await open(tester);
      await rig.present(
        FakeKey(
          productName: 'Example Older Key',
          ctap: FakeFidoKey(pin: '123456', credentialManagement: FakeSupport.none),
        ),
        usb,
      );
      await takeScreenshot(tester, 'security_key_cannot_list_$name');
    });

    testScreenshot('security key: fingerprints, $name', (tester) async {
      final fido = FakeFidoKey(pin: '123456', fingerprintReader: FakeSupport.standard)
        ..addFingerprint('Right thumb')
        ..addFingerprint('Left index')
        ..addFingerprint();
      final rig = await open(tester);
      await rig.present(FakeKey(productName: 'Example Bio Key', ctap: fido), usb);
      await rig.tapRow('securityKeys.fingerprints.row');
      await rig.typePin('123456');
      await takeScreenshot(tester, 'security_key_fingerprints_$name');
    });

    testScreenshot('security key: adding a fingerprint, $name', (tester) async {
      final fido = FakeFidoKey(pin: '123456', fingerprintReader: FakeSupport.standard)..addFingerprint('Right thumb');
      final rig = await open(tester);
      // The key waits for the second touch for as long as the picture takes.
      rig.phone.yieldOnRead = true;
      final key = FakeKey(
        productName: 'Example Bio Key',
        ctap: _WaitsForSecondTouch(fido),
        keepaliveEvery: const Duration(milliseconds: 1),
      );
      rig.phone.arrive(key.device(kinds: usb));
      Future<void> until(Finder finder) async {
        for (var i = 0; i < 400 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 2));
        }
      }

      await until(find.text(t('securityKeys.connected').toUpperCase()));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(keyRow('securityKeys.fingerprints.row'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '123456');
      await tester.pump();
      await tester.tap(find.text(t('securityKeys.pin.continue')));
      await until(find.byType(KeyFingerprintsSheet));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('securityKeys.fingerprints.add')));
      await until(find.text(t('securityKeys.fingerprints.remaining', {'count': 3})));

      await takeScreenshot(tester, 'security_key_fingerprint_add_$name');

      await tester.tap(find.widgetWithText(TextButton, t('export.cancel')).last);
      await until(find.text(t('securityKeys.fingerprints.add')));
      await tester.pump(const Duration(milliseconds: 100));
    });

    testScreenshot('security key: the reset confirmation, $name', (tester) async {
      final rig = await open(tester);
      await rig.present(FakeKey(productName: 'Example Key 5C NFC', ctap: mockupKey()), usb);
      await rig.tap('securityKeys.reset.button');
      await takeScreenshot(tester, 'security_key_reset_confirm_$name');
    });

    testScreenshot('security key: reset, unplug the key, $name', (tester) async {
      final rig = await open(tester);
      await rig.present(FakeKey(productName: 'Example Key 5C NFC', ctap: mockupKey()), usb);
      await rig.tap('securityKeys.reset.button');
      await tester.tap(find.widgetWithText(FilledButton, t('securityKeys.reset.confirm')));
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'security_key_reset_unplug_$name');
    });
  }
}

/// A key with a reader that is touched once, then waits.
class _WaitsForSecondTouch extends FakeCtapAuthenticator {
  _WaitsForSecondTouch(this.inner);

  final FakeFidoKey inner;

  @override
  FakeCtapReply handle(int command, Uint8List parameters, SecurityKeyLinkKind kind) {
    final sub = command == 0x09 && parameters.isNotEmpty ? cborIntMap(cborDecode(parameters))[2] : null;
    return sub == 2 ? FakeCtapReply.hang(2) : inner.handle(command, parameters, kind);
  }

  @override
  void poweredUp(DateTime Function() now) => inner.poweredUp(now);
}
