import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/models/otp_account.dart';

import '../../helpers/test_app.dart';
import 'sync_screen_kit.dart';

/// Sync while the vault's key pair is replaced (openspec:
/// replace-vault-key-pair, task 6.1, decision 6).
void main() {
  testWidgets('a sync due during the replacement waits for it, and runs once after with the new key pair', (tester) async {
    final kit = SyncSheetKit();
    await kit.pump(tester, showSyncSheet, syncHost: true);
    await kit.open(tester);
    await kit.vault.applySynced(
      Lists(
        accounts: [OtpAccount(id: 'phone', issuer: 'GitHub', label: '', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1)],
      ),
    );
    await kit.fillDav(tester);
    await tester.enterText(field(t('sync.field.passphrase')), 'shared secret phrase');
    await tester.pump();
    await tapButton(tester, t('sync.connect'));
    // The first sync, once turned on, is over
    await tester.pumpAndSettle();
    expect(kit.container.read(syncProvider).running, isFalse);
    final duringReplacement = <bool>[];
    kit.server.respond = (request) async {
      duringReplacement.add(kit.vaultState.replacingKey);
      return kit.server.handle(request);
    };
    final before = kit.server.requests.length;

    final replacing = kit.vault.replaceKey('pw');
    // Sync now, while it runs
    kit.sync.requestSync();
    await tester.pumpAndSettle();
    final next = await replacing;
    await tester.pumpAndSettle();

    expect(kit.vaultState.session, same(next));
    expect(duringReplacement, isNotEmpty);
    expect(duringReplacement, everyElement(isFalse));
    expect(kit.server.requests.length, greaterThan(before));
    // What the run kept is sealed to the new key pair
    expect(await kit.vaultStore.loadEncryptedValue('backmycodes_sync_state', next), isNotNull);
    expect(kit.container.read(syncProvider).status[personalScope]?.problem, isNull);
  });
}
