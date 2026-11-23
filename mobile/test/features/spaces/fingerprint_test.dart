import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/bundle.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/features/spaces/account_security_sheet.dart';
import 'package:kemlock/features/spaces/fingerprint.dart';
import 'package:kemlock/features/spaces/fingerprint_view.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../crypto/account/server_vectors.dart';
import '../../crypto/vectors.dart';
import '../../helpers/test_app.dart';

void main() {
  // The server's bundle vectors give each fingerprint and its digits, so what a screen shows is held to them
  final cases = [
    for (final c in readServerCases('bundle.json'))
      (
        name: c['name']! as String,
        fingerprint: fromHex(c['fingerprint']! as String),
        groups: (c['fingerprint_groups']! as List<Object?>).cast<String>(),
        bundle: KeyBundle.parse(fromHex(c['bundle']! as String)),
      ),
  ];

  group('the rows of a fingerprint', () {
    for (final c in cases) {
      test('${c.name}: 12 groups of 5 digits in three rows of four', () {
        final rows = fingerprintRows(c.fingerprint);
        expect(rows, hasLength(3));
        expect(rows.every((row) => row.length == 4), isTrue);
        expect([for (final row in rows) ...row], c.groups);
      });
    }
  });

  group('the text of its QR code', () {
    final fingerprint = cases.first.fingerprint;
    final bundle = cases.first.bundle;

    test('is the 64 bytes as base64url, and reads back as them', () {
      final text = fingerprintQrText(fingerprint);
      expect(text, hasLength(86));
      expect(text, isNot(contains('=')));
      expect(readFingerprintQr(text), fingerprint);
      expect(readFingerprintQr(' $text\n'), fingerprint);
    });

    test('is refused when it is not 64 bytes of base64url without padding', () {
      expect(readFingerprintQr(''), isNull);
      expect(readFingerprintQr('bmc-space:abc'), isNull);
      expect(readFingerprintQr(b64urlEncode(List.filled(63, 1))), isNull);
      expect(readFingerprintQr(b64urlEncode(List.filled(65, 1))), isNull);
      expect(readFingerprintQr('${fingerprintQrText(fingerprint)}='), isNull);
    });

    test('a scan of the bundle’s own fingerprint matches', () {
      expect(checkScannedFingerprint(fingerprintQrText(bundle.fingerprint), bundle), FingerprintCheck.match);
    });

    test('a scan of another fingerprint is a mismatch, and anything else is unreadable', () {
      final other = List<int>.of(bundle.fingerprint)..[63] ^= 1;
      expect(checkScannedFingerprint(fingerprintQrText(other), bundle), FingerprintCheck.mismatch);
      expect(checkScannedFingerprint('otpauth://totp/x?secret=ABC', bundle), FingerprintCheck.unreadable);
    });
  });

  for (final locale in [AppLocale.en, AppLocale.fr]) {
    group('FingerprintView in ${locale.name}', () {
      for (final c in cases) {
        testWidgets('${c.name}: shows the 12 groups in three rows of four, and the QR code', (tester) async {
          await pumpScreen(
            tester,
            Scaffold(
              body: SingleChildScrollView(child: FingerprintView(fingerprint: c.fingerprint)),
            ),
            locale: locale,
          );

          for (var i = 0; i < 12; i++) {
            expect((tester.widget(find.byKey(fingerprintGroupKey(i))) as Text).data, c.groups[i]);
          }
          // Four groups share a row: same height, left to right
          for (var row = 0; row < 3; row++) {
            final tops = {
              for (var column = 0; column < 4; column++) tester.getTopLeft(find.byKey(fingerprintGroupKey(row * 4 + column))).dy,
            };
            expect(tops, hasLength(1));
          }
          expect(find.byType(QrImageView), findsOneWidget);
          expect(find.text(testCatalog.of(locale).t('fingerprint.qr')), findsOneWidget);
        });
      }

      testWidgets('leaves the QR code out when asked', (tester) async {
        await pumpScreen(
          tester,
          Scaffold(body: FingerprintView(fingerprint: cases.first.fingerprint, showQr: false)),
          locale: locale,
        );

        expect(find.byType(QrImageView), findsNothing);
        expect(find.byKey(fingerprintGroupKey(11)), findsOneWidget);
      });

      testWidgets('the Account security sheet shows the account’s fingerprint and key version', (tester) async {
        final bundle = cases.first.bundle;
        await pumpScreen(
          tester,
          Scaffold(body: AccountSecuritySheet(load: () async => bundle)),
          locale: locale,
        );
        await tester.pump();

        final messages = testCatalog.of(locale);
        expect(find.text(messages.t('accountSecurity.title')), findsOneWidget);
        expect(find.text(messages.t('accountSecurity.version', {'version': bundle.keyVersion})), findsOneWidget);
        expect((tester.widget(find.byKey(fingerprintGroupKey(0))) as Text).data, bundle.fingerprintDigits.split(' ').first);
        expect(find.byType(QrImageView), findsOneWidget);
      });

      testWidgets('the Account security sheet says so when the vault holds no account', (tester) async {
        await pumpScreen(
          tester,
          Scaffold(body: AccountSecuritySheet(load: () async => null)),
          locale: locale,
        );
        await tester.pump();

        expect(find.text(testCatalog.of(locale).t('accountSecurity.missing')), findsOneWidget);
        expect(find.byType(QrImageView), findsNothing);
      });
    });
  }
}
