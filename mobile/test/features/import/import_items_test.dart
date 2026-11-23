import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/attachment_format.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/contacts/contact_keys.dart';
import 'package:kemlock/features/contacts/contact_standing.dart';
import 'package:kemlock/features/import/import_merge.dart';
import 'package:kemlock/features/import/import_sheet.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/files.dart';
import 'package:kemlock/vault/attachment_store.dart';
import 'package:kemlock/vault/export_archive.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_export.dart';

import '../../fakes/fake_attachments.dart';
import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import '../contacts/contacts_kit.dart';
import '../export/transfer_harness.dart';
import '../keys/keys_kit.dart' show KeysApp;
import '../keys/pgp_kit.dart';

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
  late RecordingVault vault;
  late SecureNote note;
  late Uint8List scanKey;
  late Uint8List photoKey;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('import');
    attachments = FakeAttachmentStore();
    files = FakeFiles();
    vault = RecordingVault();
    scanKey = randomBytes(32);
    photoKey = randomBytes(32);
    note = SecureNote(
      id: 'n1',
      title: 'Passport',
      addedAt: 3,
      attachments: [
        NoteAttachment(id: 'f1', name: 'scan.pdf', size: _scan.length, key: b64(scanKey), addedAt: 3),
        NoteAttachment(id: 'f2', name: 'photo.jpg', size: _photo.length, key: b64(photoKey), addedAt: 3),
      ],
    );
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  /// An encrypted export archive of an account, a key, the note and a passkey.
  Future<Uint8List> archiveOf({bool withPhoto = true}) async {
    final json = await exportVault(
      const [_account],
      const [],
      'pw',
      keys: const [_key],
      notes: [note],
      passkeys: const [_passkey],
      deriveKey: fastKdf,
    );
    final path = '${scratch.path}/export.zip';
    await writeExportArchive(
      path,
      exportJson: json,
      files: [
        (id: 'f1', name: null, bytes: () async => kma1EncryptSync(_scan, scanKey)),
        if (withPhoto) (id: 'f2', name: null, bytes: () async => kma1EncryptSync(_photo, photoKey)),
      ],
    );
    return File(path).readAsBytesSync();
  }

  Future<void> open(WidgetTester tester) =>
      openSheet(tester, showImportSheet, vault: vault, files: files, overrides: [attachmentStoreProvider.overrideWithValue(attachments)]);

  Future<void> chooseAndOpen(WidgetTester tester, Uint8List bytes) async {
    files.nextPick = PickedFile(name: 'kemlock-export.zip', bytes: bytes, mimeType: 'application/zip');
    await tapOn(tester, find.text(t('import.browse')));
    await tester.enterText(fieldLabelled('import.field.password'), 'pw');
    await tester.pump();
    // The free build's sheet is taller, so the button can be below the fold
    await tester.ensureVisible(find.text(t('import.decrypt')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text(t('import.decrypt')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  Future<void> importIt(WidgetTester tester, String labelId, [Map<String, Object?> args = const {}]) async {
    await tester.ensureVisible(find.text(t(labelId, args)));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text(t(labelId, args)));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('previews and imports every kind from an archive, files and all', (tester) async {
    await open(tester);

    await chooseAndOpen(tester, (await tester.runAsync(archiveOf))!);

    expect(find.text(t('export.chip.keys', {'count': 1})), findsOneWidget);
    expect(find.text(t('export.chip.notes', {'count': 1})), findsOneWidget);
    expect(find.text(t('export.chip.files', {'count': 2})), findsOneWidget);
    expect(find.text(t('export.chip.passkeys', {'count': 1})), findsOneWidget);
    expect(find.text(t('import.info.items', {'newCount': 3, 'dupCount': 0})), findsOneWidget);
    expect(find.textContaining(t('import.missingFiles', {'count': 1, 'files': ''}).trim()), findsNothing);
    await importIt(tester, 'import.button.merge', {'count': 1});

    expect(vault.itemImports.single.keys, [_key]);
    expect(vault.itemImports.single.notes, [note]);
    expect(vault.passkeyImports.single, [_passkey]);
    // Each file is stored as it was in the archive, and opens with the note's key
    expect(kma1DecryptSync(attachments.files['test']!['f1']!.sealed, scanKey), _scan);
    expect(kma1DecryptSync(attachments.files['test']!['f2']!.sealed, photoKey), _photo);
  });

  testWidgets('importing the same export twice holds each item once', (tester) async {
    final bytes = (await tester.runAsync(archiveOf))!;
    await open(tester);
    await chooseAndOpen(tester, bytes);
    await importIt(tester, 'import.button.merge', {'count': 1});

    await tapOn(tester, find.text('Open'));
    await chooseAndOpen(tester, bytes);
    expect(find.text(t('import.info.items', {'newCount': 0, 'dupCount': 3})), findsOneWidget);
    await importIt(tester, 'import.button.merge', {'count': 1});

    expect(vault.itemImports.last.keys, isEmpty);
    expect(vault.itemImports.last.notes, isEmpty);
    expect(vault.passkeyImports.last, isEmpty);
    expect(vault.state.keys, hasLength(1));
    expect(vault.state.notes, hasLength(1));
    expect(vault.state.passkeys, hasLength(1));
  });

  // openspec: add-security-key-codes, task 8.3
  testWidgets('says how many accounts are on a key, and imports each of them once, by key and name', (tester) async {
    const onKey = [
      KeyAccount(id: 'ka1', device: '0102030405060708', keyName: 'YubiKey', name: 'Bank:ada', issuer: 'Bank', label: 'ada', addedAt: 1),
      KeyAccount(id: 'ka2', device: '0102030405060708', name: 'Registrar:ada', issuer: 'Registrar', label: 'ada', addedAt: 1),
    ];
    final json = (await tester.runAsync(() => exportVault(const [_account], const [], 'pw', keyAccounts: onKey, deriveKey: fastKdf)))!;
    Future<void> openJson() async {
      files.nextPick = PickedFile(name: 'kemlock-export.json', bytes: Uint8List.fromList(utf8.encode(json)), mimeType: 'application/json');
      await tapOn(tester, find.text(t('import.browse')));
      await tester.enterText(fieldLabelled('import.field.password'), 'pw');
      await tester.pump();
      // The free build's sheet is taller, so the button can be below the fold
      await tester.ensureVisible(find.text(t('import.decrypt')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text(t('import.decrypt')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
    }

    await open(tester);
    await openJson();
    expect(find.text(t('export.onKey', {'count': 2})), findsOneWidget);
    await importIt(tester, 'import.button.merge', {'count': 1});
    expect(vault.keyAccountImports.single, onKey);

    await tapOn(tester, find.text('Open'));
    await openJson();
    expect(find.text(t('export.onKey', {'count': 2})), findsOneWidget);
    // The test vault keeps no account it is handed, so the code account counts as new again.
    await importIt(tester, 'import.button.merge', {'count': 1});

    expect(vault.keyAccountImports.last, isEmpty);
    expect(vault.state.keyAccounts, onKey);
  });

  testWidgets('a file missing from the archive is named, and the rest comes in', (tester) async {
    await open(tester);

    await chooseAndOpen(tester, (await tester.runAsync(() => archiveOf(withPhoto: false)))!);

    expect(find.text(t('import.missingFiles', {'count': 1, 'files': 'Passport › photo.jpg'})), findsOneWidget);
    await importIt(tester, 'import.button.merge', {'count': 1});

    // The note keeps its record of the photo, which shows as missing; the scan is stored
    expect(vault.itemImports.single.notes.single.files.map((file) => file.name), ['scan.pdf', 'photo.jpg']);
    expect(attachments.files['test']!.keys, ['f1']);
  });

  testWidgets('a damaged file is left out, and the note still comes in', (tester) async {
    final bytes = (await tester.runAsync(archiveOf))!;
    // Put a file in the archive that its key doesn't open
    final json = readExportArchive(bytes).exportJson;
    final archive = Archive()
      ..addFile(ArchiveFile.noCompress('export.json', utf8.encode(json).length, utf8.encode(json)))
      ..addFile(ArchiveFile.noCompress('files/f1', 40, kma1EncryptSync(_scan, randomBytes(32))));
    await open(tester);

    await chooseAndOpen(tester, Uint8List.fromList(ZipEncoder().encodeBytes(archive)));
    await importIt(tester, 'import.button.merge', {'count': 1});

    expect(vault.itemImports.single.notes, hasLength(1));
    expect(attachments.files['test'] ?? const {}, isEmpty);
  });

  testWidgets('refuses an archive with an entry no export has, naming it', (tester) async {
    final archive = Archive()
      ..addFile(ArchiveFile.noCompress('export.json', 2, utf8.encode('{}')))
      ..addFile(ArchiveFile.noCompress('../evil.sh', 1, const [1]));
    await open(tester);

    files.nextPick = PickedFile(name: 'evil.zip', bytes: Uint8List.fromList(ZipEncoder().encodeBytes(archive)));
    await tapOn(tester, find.text(t('import.browse')));

    expect(find.text(t('import.error.archive.unexpectedEntry', {'entry': '../evil.sh'})), findsOneWidget);
    expect(find.text(t('import.decrypt')), findsNothing);
  });

  // openspec: add-pgp-key-editing, design decision 9
  group('a PGP key the vault holds another copy of', () {
    testWidgets('the import hands it over to be combined; the same copy, or another kind, is skipped', (tester) async {
      final held = (await tester.runAsync(() => pgpVaultKey(id: 'k-held')))!;
      final after = (await tester.runAsync(() => pgpVaultKey(path: 'gnupg/editing/signing-subkey.after.secret.asc', id: 'k-after')))!;
      vault = RecordingVault(keys: [held, _key]);
      Future<Uint8List> export(List<VaultKey> keys) async {
        final json = await exportVault(const [_account], const [], 'pw', keys: keys, deriveKey: fastKdf);
        final path = '${scratch.path}/keys-${keys.length}.zip';
        await writeExportArchive(path, exportJson: json, files: const []);
        return File(path).readAsBytesSync();
      }

      await open(tester);
      await chooseAndOpen(tester, (await tester.runAsync(() => export([after, held.copyWith(id: 'k-again'), _key])))!);
      await importIt(tester, 'import.button.merge', {'count': 1});

      expect(vault.itemImports.single.keys, [after]);
    });

    /// The app with a vault holding [key], named and noted.
    Future<(KeysApp, VaultController)> holding(WidgetTester tester, VaultKey key) async {
      final app = KeysApp(tester);
      await app.start();
      final controller = app.app.container.read(vaultControllerProvider.notifier);
      await tester.runAsync(() => controller.addKey(key.copyWith(name: 'Work key', note: 'Mine')));
      return (app, controller);
    }

    /// The key Kemlock changed: every packet of [key] and a new subkey.
    Future<VaultKey> grown(VaultKey key) async {
      final made = await crypto.makeKey(
        crypto.PgpChangeRequest(
          unb64(key.privateKey),
          const crypto.AddPgpSubkey(type: crypto.PgpKeyType.ed25519, use: crypto.PgpSubkeyUse.encrypt),
          now: DateTime.utc(2026, 11, 20, 12),
        ),
      );
      return key.withHalves(privateKey: b64(made.private), publicKey: b64(made.public!), protected: false);
    }

    testWidgets('an older copy leaves the newer one the vault holds as it was', (tester) async {
      final before = (await tester.runAsync(() => pgpVaultKey(id: 'k-before')))!;
      final after = (await tester.runAsync(() => grown(before.copyWith(id: 'k-after'))))!;
      final (app, controller) = await holding(tester, after);
      final kept = app.keys.single;

      await tester.runAsync(() => controller.imported(const [], const [], keys: [before]));

      expect(app.keys, [kept]);
    });

    testWidgets('a newer copy updates the held entry in place, its name and note kept', (tester) async {
      final before = (await tester.runAsync(() => pgpVaultKey(id: 'k-before')))!;
      final after = (await tester.runAsync(() => grown(before.copyWith(id: 'k-after', name: 'From the backup'))))!;
      final (app, controller) = await holding(tester, before);
      final held = app.keys.single;

      await tester.runAsync(() => controller.imported(const [], const [], keys: [after]));

      final updated = app.keys.single;
      expect((updated.id, updated.name, updated.note, updated.addedAt), (held.id, 'Work key', 'Mine', held.addedAt));
      expect((updated.privateKey, updated.publicKey), (after.privateKey, after.publicKey));
      expect(updated.updatedAt, isNotNull);
      // GnuPG's copy, which lacks the old self-signatures: both, read as GnuPG's
      final gnupg = (await tester.runAsync(() => pgpVaultKey(path: 'gnupg/editing/signing-subkey.after.secret.asc', id: 'k-gnupg')))!;
      await tester.runAsync(() => controller.imported(const [], const [], keys: [gnupg]));
      final both = crypto.readPgpKeyInfo(unb64(app.keys.single.privateKey));
      expect((app.keys.length, both.userIds.length, both.subkeys.length), (1, 2, 4));
    });

    testWidgets('a key of another kind is added, or skipped when held, as before', (tester) async {
      final (app, controller) = await holding(tester, (await tester.runAsync(() => pgpVaultKey(id: 'k-pgp')))!);

      await tester.runAsync(() => controller.imported(const [], const [], keys: [_key]));
      expect(app.keys.map((key) => key.id), ['k-pgp', _key.id]);
      await tester.runAsync(() => controller.imported(const [], const [], keys: [_key.copyWith(id: 'k-again')]));
      expect(app.keys.map((key) => key.id), ['k-pgp', _key.id]);
    });
  });

  // openspec: add-pgp-contacts, task 6.2
  group("other people's keys", () {
    final checkedAt = DateTime.utc(2026, 11, 3, 9).millisecondsSinceEpoch;

    /// The vault holding [held], and the import sheet open on an encrypted export of [inFile].
    Future<void> openExportOf(WidgetTester tester, List<Contact> inFile, {List<Contact> held = const []}) async {
      vault = RecordingVault(contacts: held);
      final json = (await tester.runAsync(() => exportVault(const [_account], const [], 'pw', contacts: inFile, deriveKey: fastKdf)))!;
      await openSheet(
        tester,
        showImportSheet,
        vault: vault,
        files: files,
        overrides: [
          attachmentStoreProvider.overrideWithValue(attachments),
          publicKeyReaderProvider.overrideWithValue(crypto.readPublicKeys),
        ],
      );
      files.nextPick = PickedFile(name: 'kemlock-export.json', bytes: Uint8List.fromList(utf8.encode(json)), mimeType: 'application/json');
      await tapOn(tester, find.text(t('import.browse')));
      await tester.enterText(fieldLabelled('import.field.password'), 'pw');
      await tester.pump();
      // The free build's sheet is taller, so the button can be below the fold
      await tester.ensureVisible(find.text(t('import.decrypt')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text(t('import.decrypt')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('the vault lacks are added, listed by name and fingerprint, and not checked', (tester) async {
      final inFile = [contactOf(grace1, checkedAt: checkedAt, note: 'Compared on a call'), contactOf(alan, id: 'c2', name: 'Alan Turing')];
      await openExportOf(tester, inFile);

      expect(find.text(t('export.chip.contacts', {'count': 2})), findsOneWidget);
      expect(find.text(t('import.info.contacts', {'newCount': 2, 'dupCount': 0})), findsOneWidget);
      // Each by its name and the last sixteen digits of its fingerprint, the one the file says was compared tagged so
      final list = find.byKey(const ValueKey('import-contact-list'));
      expect(find.descendant(of: list, matching: find.text('Grace Hopper')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.text('B405 E72A FBA2 3495')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.text('Alan Turing')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.text('A8CF F189 E65E 4BDC')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.text(t('import.chip.checked'))), findsOneWidget);
      // A file can say a key was checked when it never was: off unless the person turns it on
      expect(find.text(t('import.contacts.keepChecks.detail')), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await importIt(tester, 'import.button.merge', {'count': 1});

      expect(vault.contactImports.single, [for (final contact in inFile) contact.unchecked()]);
      expect(vault.state.contacts.first.note, 'Compared on a call');
      expect([for (final contact in vault.state.contacts) contactStanding(contact, contactsNow).checked], [false, false]);
    });

    testWidgets('keep the checks the file records when the person says so, for a backup of their own', (tester) async {
      final inFile = [contactOf(grace1, checkedAt: checkedAt), contactOf(alan, id: 'c2', name: 'Alan Turing')];
      await openExportOf(tester, inFile);

      await tapOn(tester, find.byType(Switch));
      await importIt(tester, 'import.button.merge', {'count': 1});

      expect(vault.contactImports.single, inFile);
      expect(contactStanding(vault.state.contacts.first, contactsNow).checked, isTrue);
      expect(vault.state.contacts.first.checkedAt, checkedAt);
      expect(contactStanding(vault.state.contacts.last, contactsNow).checked, isFalse);
    });

    testWidgets('asks nothing of a file that records no check, nor of one whose check is for another key', (tester) async {
      // Grace's mark names the fingerprint of another key: no check of the key it holds
      final markedForAnother = contactOf(grace1).copyWith(checkedAt: checkedAt, checkedFingerprint: alanFingerprint);
      await openExportOf(tester, [markedForAnother, contactOf(alan, id: 'c2', name: 'Alan Turing')]);

      expect(find.byKey(const ValueKey('import-contact-list')), findsOneWidget);
      expect(find.text(t('import.contacts.keepChecks')), findsNothing);
      expect(find.text(t('import.chip.checked')), findsNothing);
    });

    testWidgets('one the vault already holds, by fingerprint, is left as it is: checked here, not in the file', (tester) async {
      final here = contactOf(grace1, id: 'here', name: 'Grace', checkedAt: checkedAt);
      await openExportOf(
        tester,
        [contactOf(grace2, id: 'there'), contactOf(alan, id: 'c2', name: 'Alan Turing')],
        held: [here],
      );

      expect(find.text(t('import.info.contacts', {'newCount': 1, 'dupCount': 1})), findsOneWidget);
      await importIt(tester, 'import.button.merge', {'count': 1});

      expect(vault.contactImports.single.map((c) => c.name), ['Alan Turing']);
      expect(vault.state.contacts.first, here);
      expect(contactStanding(vault.state.contacts.first, contactsNow).checked, isTrue);
      expect(vault.state.contacts, hasLength(2));
    });

    testWidgets('one whose key fails its own checks is dropped, and the rest comes in', (tester) async {
      final altered = contactOf('contacts/grace-1.foreign-subkey.public.asc', id: 'bad', name: 'Altered', checkedAt: checkedAt);
      await openExportOf(tester, [altered, contactOf(alan, id: 'c2', name: 'Alan Turing')]);

      await importIt(tester, 'import.button.merge', {'count': 1});

      expect(vault.contactImports.single.map((c) => c.name), ['Alan Turing']);
      expect(vault.imports.single.accounts, [_account]);
    });

    testWidgets('one holding a key with packets its owner never signed comes in trimmed to what they did sign', (tester) async {
      final untrimmed = contactOf('contacts/rsa3072-certified-photo.public.asc', name: 'Certified');
      await openExportOf(tester, [untrimmed]);

      await importIt(tester, 'import.button.merge', {'count': 1});

      expect(vault.contactImports.single.single.publicKey, contactOf(rsa3072).publicKey);
      expect(vault.contactImports.single.single.publicKey.length, lessThan(untrimmed.publicKey.length));
    });

    testWidgets('replacing the codes still only adds contacts', (tester) async {
      final here = contactOf(grace1, id: 'here', name: 'Grace', checkedAt: checkedAt);
      await openExportOf(
        tester,
        [contactOf(alan, id: 'c2', name: 'Alan Turing')],
        held: [here],
      );

      await tapOn(tester, find.text(t('import.mode.replace')));
      expect(find.text(t('import.info.contacts', {'newCount': 1, 'dupCount': 0})), findsOneWidget);
      await importIt(tester, 'import.button.replace');

      expect(vault.contactImports.single.map((c) => c.name), ['Alan Turing']);
      expect(vault.state.contacts.map((c) => c.name), ['Grace', 'Alan Turing']);
    });

    test('are told apart by fingerprint, whatever their ids, each key once', () {
      final preview = ImportPreview(
        accounts: const [],
        backupServices: const [],
        contacts: [
          contactOf(grace2, id: 'x'),
          contactOf(alan, id: 'y'),
          contactOf(alan, id: 'z'),
          contactOf(alan, id: 'broken').copyWith(publicKey: 'AAAA'),
        ],
      );

      expect(newContacts(preview, [contactOf(grace1, id: 'c1')]).map((c) => c.id), ['y']);
      expect(newContacts(preview, const []).map((c) => c.id), ['x', 'y']);
    });
  });
}
