import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/export/export_sheet.dart';
import 'package:kemlock/features/export/qr_export_sheet.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/payment_card.dart';

import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import 'transfer_harness.dart';

const _account = OtpAccount(id: 'acc', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);
const _card = PaymentCard(id: 'c1', name: 'Everyday Visa', number: '4111111111111111', addedAt: 0);
const _identity = Identity(
  id: 'i1',
  name: 'Me',
  documents: [IdentityDocument(id: 'd1', type: 'passport', number: '123456789')],
  addedAt: 0,
);

// the add-cards-identities-and-websites plan, task 3.4
void main() {
  testWidgets('the export sheet counts cards and identities, and says older versions leave them out', (tester) async {
    await openSheet(
      tester,
      showExportSheet,
      files: FakeFiles(),
      vault: RecordingVault(accounts: const [_account], cards: const [_card, _card], identities: const [_identity]),
    );

    expect(find.text(t('export.chip.cards', {'count': 2})), findsOneWidget);
    expect(find.text(t('export.chip.identities', {'count': 1})), findsOneWidget);
    expect(t('export.chip.cards', {'count': 2}), '2 cards');
    expect(t('export.chip.identities', {'count': 1}), '1 identity');
    expect(find.text(t('export.cards.older')), findsOneWidget);
    expect(find.text(t('export.plaintext.warning.cards')), findsNothing, reason: 'an encrypted export hides them');
  });

  testWidgets('a plain export warns that card and document numbers are readable', (tester) async {
    await openSheet(
      tester,
      showExportSheet,
      files: FakeFiles(),
      vault: RecordingVault(accounts: const [_account], cards: const [_card], identities: const [_identity]),
    );

    await tapOn(tester, find.text(t('export.mode.plaintext')));

    expect(find.text(t('export.plaintext.warning.cards')), findsOneWidget);
  });

  testWidgets('a vault without them shows neither the chips nor the lines', (tester) async {
    await openSheet(
      tester,
      showExportSheet,
      files: FakeFiles(),
      vault: RecordingVault(accounts: const [_account]),
    );

    expect(find.text(t('export.cards.older')), findsNothing);
    expect(find.text(t('export.chip.cards', {'count': 0})), findsNothing);
  });

  testWidgets('the QR transfer sheet lists cards and identities among what is not included', (tester) async {
    await openSheet(
      tester,
      showQrExportSheet,
      vault: RecordingVault(accounts: const [_account], cards: const [_card], identities: const [_identity]),
    );

    final items = '${t('export.chip.cards', {'count': 1})}, ${t('export.chip.identities', {'count': 1})}';
    expect(find.text(t('qrExport.leftOut', {'items': items})), findsOneWidget);
    expect(items, '1 card, 1 identity');
  });
}
