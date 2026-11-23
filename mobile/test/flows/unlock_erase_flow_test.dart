import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:kemlock/features/lock/setup_screen.dart';

import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';
import 'flow_kit.dart';

/// Erasing after wrong passwords, through the real router (openspec:
/// harden-unlock-and-clipboard): a phone with two listed vaults and a
/// hidden one, biometric unlock on for the first, and the erase at 10.
void main() {
  testWidgets('ten wrong passwords on one vault erase every vault, and setup says why', (tester) async {
    final app = TestApp(biometrics: FakeBiometrics());
    await tester.runAsync(() async {
      final personal = await app.createVault(masterPassword);
      await app.vaultStore.enableBiometricUnlock(personal, 'Turn it on');
      await app.vaultStore.createVault('Work', 'Work-Horse-9', listed: true);
      await app.vaultStore.createVault('Diary', 'Diary-Horse-9', listed: false);
    });
    app.store.setItem('backmycodes_locale', 'en');
    app.store.setItem('backmycodes_theme', 'dark');
    app.store.setItem('backmycodes_unlock_erase', jsonEncode({'after': 10}));
    // The automatic Face ID prompt is cancelled, as someone without the owner's face would
    app.unlockKeys.cancelNext();
    await startApp(tester, app);
    await tapOn(tester, find.text(t('unlock.usePassword')));

    for (var i = 1; i < 10; i++) {
      await submitPassword(tester, 'not-it-$i');
      await tester.pumpAndSettle();
      expect(passwordField, findsOneWidget, reason: 'try $i');
    }
    expect(find.text(t('lock.erase.warning', {'left': 1})), findsOneWidget);
    expect(app.vaults.allVaultIds(), hasLength(3));

    await submitPassword(tester, 'not-it-10');
    await pumpUntil(tester, find.byType(SetupScreen));

    expect(location(app), '/setup');
    final note = t('setup.erased', {
      'count': 10,
      'date': DateFormat.yMMMd('en').format(testNow.toLocal()),
      'time': DateFormat.Hm('en').format(testNow.toLocal()),
    });
    expect(find.text(note), findsOneWidget);
    // Only the language, the look and the note are left, and no hardware key
    expect(
      {for (final key in app.store.storedKeys()) key: app.store.getItem(key)},
      {
        'backmycodes_locale': 'en',
        'backmycodes_theme': 'dark',
        'backmycodes_erased': jsonEncode({'at': testNow.millisecondsSinceEpoch, 'after': 10}),
      },
    );
    expect(app.unlockKeys.calls, contains('deleteAll'));
    expect(app.unlockKeys.keys, isEmpty);
    expect(app.autofill.calls, contains('removeAll'));
    expect(app.attachments.files, isEmpty);

    // A vault made now starts afresh, and the note goes
    await createVault(tester);
    expect(app.store.getItem('backmycodes_erased'), isNull);
    expect(app.vaults.allVaultIds(), hasLength(1));
  });
}
