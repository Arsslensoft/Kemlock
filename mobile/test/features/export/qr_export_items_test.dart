import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/export/qr_export_sheet.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';

import '../../helpers/test_app.dart';
import 'transfer_harness.dart';

const _account = OtpAccount(id: 'acc', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);
const _note = SecureNote(id: 'n1', title: 'Passport', addedAt: 0);
const _passkey = Passkey(
  id: 'p1',
  credentialId: 'AA',
  rpId: 'github.com',
  userHandle: 'AA',
  userName: 'me',
  privateKey: 'AA==',
  addedAt: 0,
);

void main() {
  testWidgets('says the notes and passkeys are not in a QR transfer, and where they go instead', (tester) async {
    await openSheet(
      tester,
      showQrExportSheet,
      vault: RecordingVault(accounts: const [_account], notes: const [_note, _note], passkeys: const [_passkey]),
    );

    final items = '${t('export.chip.notes', {'count': 2})}, ${t('export.chip.passkeys', {'count': 1})}';
    expect(find.text(t('qrExport.leftOut', {'items': items})), findsOneWidget);
    expect(t('qrExport.leftOut', {'items': items}), allOf(contains('2 notes, 1 passkey'), contains(t('app.menu.export'))));
  });

  testWidgets("says other people's keys are not in a QR transfer either", (tester) async {
    const contact = Contact(id: 'c1', name: 'Grace Hopper', publicKey: 'AAAA', source: ContactSource.qr, addedAt: 0);
    await openSheet(
      tester,
      showQrExportSheet,
      vault: RecordingVault(accounts: const [_account], notes: const [_note], contacts: const [contact, contact]),
    );

    final items = '${t('export.chip.notes', {'count': 1})}, ${t('export.chip.contacts', {'count': 2})}';
    expect(find.text(t('qrExport.leftOut', {'items': items})), findsOneWidget);
    expect(t('qrExport.leftOut', {'items': items}), contains('2 keys of other people'));
  });

  testWidgets("says so for a vault whose only other items are other people's keys", (tester) async {
    const contact = Contact(id: 'c1', name: 'Grace Hopper', publicKey: 'AAAA', source: ContactSource.qr, addedAt: 0);
    await openSheet(
      tester,
      showQrExportSheet,
      vault: RecordingVault(accounts: const [_account], contacts: const [contact]),
    );

    expect(
      find.text(
        t('qrExport.leftOut', {
          'items': t('export.chip.contacts', {'count': 1}),
        }),
      ),
      findsOneWidget,
    );
  });

  // openspec: add-passwords, task 7.6
  testWidgets('says the logins are not in a QR transfer either', (tester) async {
    const login = Login(id: 'l1', name: 'Larkspur Mail', password: 'hunter2', addedAt: 0);
    await openSheet(
      tester,
      showQrExportSheet,
      vault: RecordingVault(accounts: const [_account], passkeys: const [_passkey], logins: const [login, login, login]),
    );

    final items = '${t('export.chip.passkeys', {'count': 1})}, ${t('export.chip.logins', {'count': 3})}';
    expect(find.text(t('qrExport.leftOut', {'items': items})), findsOneWidget);
    expect(t('qrExport.leftOut', {'items': items}), contains('3 logins'));
  });

  testWidgets('says nothing of the kind for a vault of codes alone', (tester) async {
    await openSheet(tester, showQrExportSheet, vault: RecordingVault(accounts: const [_account]));

    expect(find.textContaining('QR codes carry the codes and backup codes alone'), findsNothing);
  });
}
