import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/attachment_format.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/export/export_sheet.dart';
import 'package:kemlock/models/json.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/files.dart';
import 'package:kemlock/vault/attachment_store.dart';
import 'package:kemlock/vault/export_archive.dart';
import 'package:kemlock/vault/vault_export.dart';

import '../../fakes/fake_attachments.dart';
import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import '../../vault/contacts_fixture_inputs.dart';
import '../../vault/fast_kdf.dart';
import 'transfer_harness.dart';

const _account = OtpAccount(id: 'acc', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);
const _key = VaultKey(
  id: 'k1',
  name: 'laptop',
  kind: KeyKind.ssh,
  algorithm: 'ed25519',
  privateKey: 'MC4CAQAwBQYDK2VwBCIEIA==',
  publicKey: 'MCowBQYDK2VwAyEA',
  origin: KeyOrigin.generated,
  addedAt: 1,
);
const _passkey = Passkey(
  id: 'p1',
  credentialId: 'AAECAwQFBgcICQoLDA0ODw',
  rpId: 'github.com',
  userHandle: 'dXNlcg',
  userName: 'octocat',
  privateKey: 'MIGHAgEAMBMGByqGSM49AgEG',
  addedAt: 2,
);

final _scan = Uint8List.fromList(utf8.encode('%PDF passport scan'));
final _photo = Uint8List.fromList(utf8.encode('jpeg bytes'));

void main() {
  late Directory scratch;
  late FakeAttachmentStore attachments;
  late FakeFiles files;
  late SecureNote note;

  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('export');
    attachments = FakeAttachmentStore();
    files = FakeFiles();
    final scanKey = randomBytes(32);
    final photoKey = randomBytes(32);
    await attachments.write('test', 'f1', _scan, scanKey);
    await attachments.write('test', 'f2', _photo, photoKey);
    note = SecureNote(
      id: 'n1',
      title: 'Passport',
      text: 'In the drawer',
      addedAt: 3,
      attachments: [
        NoteAttachment(id: 'f1', name: 'scan.pdf', size: _scan.length, type: 'application/pdf', key: b64(scanKey), addedAt: 3),
        NoteAttachment(id: 'f2', name: 'photo.jpg', size: _photo.length, type: 'image/jpeg', key: b64(photoKey), addedAt: 3),
      ],
    );
  });
  tearDown(() async {
    // The sheet deletes its archive as it closes, without waiting for it; Windows
    // won't remove the folder while that delete is still under way
    for (var tries = 1; ; tries++) {
      try {
        return scratch.deleteSync(recursive: true);
      } on FileSystemException {
        if (tries == 40) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<void> open(WidgetTester tester, {List<SecureNote>? notes}) => openSheet(
    tester,
    showExportSheet,
    files: files,
    vault: RecordingVault(accounts: const [_account], keys: const [_key], notes: notes ?? [note], passkeys: const [_passkey]),
    overrides: [attachmentStoreProvider.overrideWithValue(attachments), exportScratchProvider.overrideWithValue(() async => scratch)],
  );

  Future<void> exportEncrypted(WidgetTester tester) async {
    await tester.enterText(fieldLabelled('export.field.password'), 'export password');
    await tester.enterText(fieldLabelled('export.field.confirm'), 'export password');
    await tester.pump();
    await tester.ensureVisible(find.text(t('export.button')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final before = files.saved.length;
      await tester.tap(find.text(t('export.button')));
      // The export encrypts and writes real files: wait for its save, as a set time runs out under load
      for (var waited = 0; files.saved.length == before && waited < 10000; waited += 50) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> verify(WidgetTester tester) async {
    await tester.enterText(fieldLabelled('export.verify.field'), 'export password');
    await tester.pump();
    await tester.ensureVisible(find.text(t('export.verify.button')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text(t('export.verify.button')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('counts each kind on the sheet, and says what older versions read', (tester) async {
    await open(tester);

    for (final (id, count) in [
      ('export.chip.accounts', 1),
      ('export.chip.keys', 1),
      ('export.chip.notes', 1),
      ('export.chip.files', 2),
      ('export.chip.passkeys', 1),
    ]) {
      expect(find.text(t(id, {'count': count})), findsOneWidget, reason: id);
    }
    expect(find.text(t('export.items.archive')), findsOneWidget);
  });

  testWidgets('exports a vault with attached files as a zip, from a path, with every item', (tester) async {
    await open(tester);

    await exportEncrypted(tester);

    final saved = files.saved.single;
    expect(saved.name, endsWith('.zip'));
    expect(saved.mimeType, 'application/zip');
    expect(files.fromPath, [saved.name]);
    final archive = readExportArchive(saved.bytes);
    // The files are the KMA1 files as the phone keeps them
    expect(archive.files['f1']!(), attachments.files['test']!['f1']!.sealed);
    expect(archive.files['f2']!(), attachments.files['test']!['f2']!.sealed);
    final payload = await importVault(archive.exportJson, 'export password', deriveKey: fastKdf);
    expect((payload.accounts.length, payload.keys.single, payload.notes.single, payload.passkeys.single), (1, _key, note, _passkey));
  });

  testWidgets('exports a vault without attached files as JSON, from bytes', (tester) async {
    await open(tester, notes: [note.copyWith(attachments: unset)]);

    expect(find.text(t('export.items.older')), findsOneWidget);
    await exportEncrypted(tester);

    final saved = files.saved.single;
    expect(saved.name, endsWith('.json'));
    expect(files.fromPath, isEmpty);
    final payload = await importVault(utf8.decode(saved.bytes), 'export password', deriveKey: fastKdf);
    expect(payload.notes.single.title, 'Passport');
  });

  testWidgets('the check counts every kind and every file', (tester) async {
    await open(tester);
    await exportEncrypted(tester);

    await verify(tester);

    final ok = t('export.verify.ok', {'accounts': 1, 'services': 0});
    final items = t('export.verify.items', {'keys': 1, 'notes': 1, 'files': 2, 'passkeys': 1});
    expect(find.text('$ok $items'), findsOneWidget);
  });

  testWidgets('the check fails, by name, for a file missing from the archive', (tester) async {
    await attachments.delete('test', 'f2');
    await open(tester);
    await exportEncrypted(tester);

    await verify(tester);

    expect(find.text(t('export.verify.missingFile', {'note': 'Passport', 'file': 'photo.jpg'})), findsOneWidget);
  });

  testWidgets('a plain export warns about private keys, passkeys and files, and holds the files decrypted', (tester) async {
    await open(tester);
    await tapOn(tester, find.text(t('export.mode.plaintext')));

    expect(find.text(t('export.plaintext.warning.items', {'keys': 1, 'passkeys': 1, 'files': 2})), findsOneWidget);
    expect(t('export.plaintext.warning.items', {'keys': 1, 'passkeys': 1, 'files': 2}), contains('1 private key'));
    expect(files.saved, isEmpty);
    await tester.ensureVisible(find.text(t('export.plaintext.button')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text(t('export.plaintext.button')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    final saved = files.saved.single;
    final names = [for (final entry in ZipDecoder().decodeBytes(saved.bytes)) entry.name];
    expect(names, ['export.json', 'files/f1/scan.pdf', 'files/f2/photo.jpg']);
    final archive = readExportArchive(saved.bytes);
    expect(archive.files['f1']!(), _scan);
    expect(importVaultPlaintext(archive.exportJson).keys.single.privateKey, _key.privateKey);
    // The archive is the plain file; nothing there is KMA1
    expect(archive.files['f2']!().take(4), isNot(kma1Magic));
    // Saved, it leaves no plain copy of every secret in the cache
    expect(scratch.listSync(), isEmpty);
  });

  group('the archive built in the cache', () {
    /// Taps the button labelled [id] and lets the export work on real
    /// files until the sheet is done with it: its button enabled again, or
    /// gone once the export was saved.
    Future<void> tapExport(WidgetTester tester, String id) async {
      final label = find.text(t(id));
      await tester.ensureVisible(label);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(label);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      final button = find.ancestor(of: label, matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
      bool busy() => button.evaluate().isNotEmpty && !tester.widget<ButtonStyleButton>(button).enabled;
      for (var tries = 0; tries < 4 || busy(); tries++) {
        if (tries == 200) throw TestFailure('The export never finished');
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    testWidgets('is gone when the save is cancelled, and a second try builds one again', (tester) async {
      await open(tester);
      await tapOn(tester, find.text(t('export.mode.plaintext')));

      files.nextSave = const SaveCancelled();
      await tapExport(tester, 'export.plaintext.button');
      expect(files.saved, isEmpty);
      expect(scratch.listSync(), isEmpty);

      await tapExport(tester, 'export.plaintext.button');
      expect(files.saved.single.name, endsWith('.zip'));
      expect(scratch.listSync(), isEmpty);
    });

    testWidgets('is gone when an encrypted save is cancelled', (tester) async {
      await open(tester);
      files.nextSave = const SaveCancelled();
      await tester.enterText(fieldLabelled('export.field.password'), 'export password');
      await tester.enterText(fieldLabelled('export.field.confirm'), 'export password');
      await tester.pump();

      await tapExport(tester, 'export.button');

      expect(files.saved, isEmpty);
      expect(scratch.listSync(), isEmpty);
    });

    testWidgets('stays, encrypted, for the check that it opens', (tester) async {
      await open(tester);
      await exportEncrypted(tester);

      expect(scratch.listSync(), hasLength(1));
      await verify(tester);
      expect(find.text(t('export.verify.missingFile', {'note': 'Passport', 'file': 'photo.jpg'})), findsNothing);
    });
  });

  // openspec: add-pgp-contacts, task 6.3
  group("other people's keys", () {
    final contacts = fixtureContacts();

    Future<void> openWith(WidgetTester tester) => openSheet(
      tester,
      showExportSheet,
      files: files,
      vault: RecordingVault(accounts: const [_account], contacts: contacts),
      overrides: [attachmentStoreProvider.overrideWithValue(attachments), exportScratchProvider.overrideWithValue(() async => scratch)],
    );

    testWidgets('are counted on the sheet', (tester) async {
      await openWith(tester);

      expect(find.text(t('export.chip.contacts', {'count': 2})), findsOneWidget);
    });

    testWidgets('are in the encrypted file, and the check that it opens counts them', (tester) async {
      await openWith(tester);
      await exportEncrypted(tester);

      final payload = await tester.runAsync(() => importVault(files.lastSavedText, 'export password', deriveKey: fastKdf));
      expect(payload!.contacts, contacts);
      await verify(tester);

      final ok = t('export.verify.ok', {'accounts': 1, 'services': 0});
      expect(find.text('$ok ${t('export.verify.contacts', {'count': 2})}'), findsOneWidget);
    });

    testWidgets('are in the plain file', (tester) async {
      await openWith(tester);
      await tapOn(tester, find.text(t('export.mode.plaintext')));
      await tester.ensureVisible(find.text(t('export.plaintext.button')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text(t('export.plaintext.button')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      expect(importVaultPlaintext(files.lastSavedText).contacts, contacts);
    });

    testWidgets('a vault without any shows no count of them, and its file has no such list', (tester) async {
      await openSheet(
        tester,
        showExportSheet,
        files: files,
        vault: RecordingVault(accounts: const [_account], keys: const [_key]),
      );

      expect(find.text(t('export.chip.contacts', {'count': 0})), findsNothing);
      await tapOn(tester, find.text(t('export.mode.plaintext')));
      await tester.ensureVisible(find.text(t('export.plaintext.button')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text(t('export.plaintext.button')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      expect((jsonDecode(files.lastSavedText) as Map<String, Object?>).keys, isNot(contains('contacts')));
    });
  });

  testWidgets('a vault of codes alone shows no items and exports as before', (tester) async {
    await openSheet(
      tester,
      showExportSheet,
      files: files,
      vault: RecordingVault(accounts: const [_account]),
    );

    expect(find.text(t('export.items.older')), findsNothing);
    expect(find.text(t('export.chip.keys', {'count': 0})), findsNothing);
    expect(find.text(t('export.logins.older')), findsNothing);
    await tapOn(tester, find.text(t('export.mode.plaintext')));
    expect(find.text(t('export.plaintext.warning')), findsOneWidget);
  });

  // openspec: add-passwords, task 7.6
  testWidgets('counts the logins, says older versions leave them out, and exports them', (tester) async {
    const login = Login(id: 'l1', name: 'Larkspur Mail', username: 'ada', password: 'hunter2', addedAt: 0);
    await openSheet(
      tester,
      showExportSheet,
      files: files,
      vault: RecordingVault(
        accounts: const [_account],
        logins: const [
          login,
          Login(id: 'l2', name: 'Bank', password: '1234', addedAt: 0),
        ],
      ),
    );

    expect(find.text(t('export.chip.logins', {'count': 2})), findsOneWidget);
    expect(find.text(t('export.logins.older')), findsOneWidget);
    await exportEncrypted(tester);

    final payload = await importVault(utf8.decode(files.saved.single.bytes), 'export password', deriveKey: fastKdf);
    expect(payload.logins.map((login) => login.id), ['l1', 'l2']);
  });
}
