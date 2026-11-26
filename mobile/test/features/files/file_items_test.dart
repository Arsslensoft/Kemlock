import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/crypto/attachment_format.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/files/file_added.dart';
import 'package:kemlock/features/files/file_sheet.dart';
import 'package:kemlock/features/vault/add_to_vault_sheet.dart';
import 'package:kemlock/features/vault/vault_items.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_file.dart';
import 'package:kemlock/platform/files.dart';
import 'package:kemlock/vault/attachment_seal.dart';
import 'package:kemlock/vault/attachment_sealer.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_files.dart';
import '../../fakes/fake_sealer.dart';
import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

PickedFile _pdf({int size = 2048, String name = 'lease.pdf'}) =>
    PickedFile(name: name, bytes: Uint8List.fromList([for (var i = 0; i < size; i++) i & 0xff]), mimeType: 'application/pdf');

void main() {
  late FakeFiles files;

  Future<TestApp> open(WidgetTester tester, {List<Override> overrides = const []}) async {
    files = FakeFiles();
    final app = TestApp();
    await startApp(tester, app, overrides: [files.asOverride, sealsOnTheSpot, ...overrides]);
    await createVault(tester);
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    return app;
  }

  List<VaultFile> items(TestApp app) => app.container.read(vaultControllerProvider).files;
  Finder addButton() => find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault')));

  /// Picks the next file from the add menu. Past the saved toast, which covers the sheet's buttons, unless [pastToast] is false:
  /// a toast that says why nothing was added is what the test then looks for.
  Future<void> addFile(WidgetTester tester, {bool pastToast = true}) async {
    await tapOn(tester, addButton());
    await tapOn(tester, find.text(t('files.add')));
    if (pastToast) {
      await tester.pump(const Duration(seconds: 10));
    }
  }

  testWidgets('New file picks a file, seals and stores it, and saves an item named after it', (tester) async {
    final app = await open(tester);
    files.nextPick = _pdf();

    await addFile(tester);

    expect(find.byType(AddToVaultSheet), findsNothing);
    final item = items(app).single;
    expect((item.name, item.file.name, item.file.size, item.file.type), ('lease.pdf', 'lease.pdf', 2048, 'application/pdf'));
    // Sealed like a note's attachment, with the file's SHA-256, and stored under its own id
    expect(item.file.sha256, sha256Hex(_pdf().bytes));
    final vaultId = app.container.read(vaultControllerProvider).vault.id;
    final stored = app.attachments.files[vaultId]![item.file.id]!.sealed;
    expect(stored.sublist(0, 4), kma1Magic);
    expect(kma1DecryptSync(stored, unb64(item.file.key)), _pdf().bytes);
    expect(storedText(app), isNot(contains('lease.pdf')));
  });

  testWidgets('a cancelled pick adds nothing, and a file over the limit is refused with the notes message', (tester) async {
    final app = await open(tester);

    await addFile(tester);
    expect(items(app), isEmpty);

    files.nextPick = _pdf(size: attachmentSizeLimit + 1, name: 'huge.bin');
    await addFile(tester, pastToast: false);
    expect(find.text(t('notes.attach.tooLarge', {'size': 50})), findsOneWidget);
    expect(items(app), isEmpty);
    expect(app.attachments.files.values.expand((vault) => vault.keys), isEmpty);
  });

  testWidgets('a file the sealer refuses for another reason than its size is not called too large', (tester) async {
    final app = await open(
      tester,
      overrides: [
        attachmentSealerProvider.overrideWithValue((plain, {required name, type, required now}) => throw ArgumentError.value(name, 'name')),
      ],
    );
    files.nextPick = _pdf();

    await addFile(tester, pastToast: false);

    expect(find.text(t('files.add.failed')), findsOneWidget);
    expect(find.text(t('notes.attach.tooLarge', {'size': 50})), findsNothing);
    expect(items(app), isEmpty);
  });

  testWidgets('a failed write adds nothing and says so', (tester) async {
    final app = await open(tester);
    app.attachments.failWrites = true;
    files.nextPick = _pdf();

    await addFile(tester, pastToast: false);

    expect(find.text(t('files.add.failed')), findsOneWidget);
    expect(items(app), isEmpty);
  });

  testWidgets('the Vault tab lists the file under Files, and its sheet shows the details and shares a copy', (tester) async {
    final app = await open(tester);
    files.nextPick = _pdf();
    await addFile(tester);

    await tapOn(tester, find.text(t('files.filter')));
    expect(find.text('lease.pdf'), findsWidgets);
    await tapOn(tester, find.text('lease.pdf').first);

    expect(find.byType(FileSheet), findsOneWidget);
    expect(find.text('application/pdf'), findsOneWidget);
    expect(find.text(t('notes.file.kb', {'size': 2.0})), findsWidgets);

    // Sharing says first that the copy isn't encrypted
    await tapOn(tester, find.text(t('notes.copy.share')));
    expect(find.text(t('notes.copy.title')), findsOneWidget);
    await tapOn(tester, find.widgetWithText(FilledButton, t('notes.copy.share')));
    expect(files.saved.single.name, 'lease.pdf');
    expect(files.saved.single.bytes, _pdf().bytes);
    expect(files.saved.single.shared, isTrue);
    expect(items(app), hasLength(1));
  });

  testWidgets('Delete asks, removes the item and offers Undo; the stored file stays for the sweep', (tester) async {
    final app = await open(tester);
    files.nextPick = _pdf();
    await addFile(tester);
    final id = items(app).single.file.id;
    await tapOn(tester, find.text(t('files.filter')));
    await tapOn(tester, find.text('lease.pdf').first);

    await tapOn(tester, find.text(t('files.delete')));
    await tapOn(tester, find.widgetWithText(FilledButton, t('files.delete.confirm')));

    expect(items(app), isEmpty);
    expect(find.byType(FileSheet), findsNothing);
    final vaultId = app.container.read(vaultControllerProvider).vault.id;
    expect(app.attachments.files[vaultId]!.containsKey(id), isTrue);

    await tapOn(tester, find.text(t('app.undo')));
    expect(items(app).single.file.id, id);
  });

  testWidgets("the sweep at unlock keeps a File item's file and drops one no item names", (tester) async {
    final app = await open(tester);
    files.nextPick = _pdf();
    await addFile(tester);
    final vaultId = app.container.read(vaultControllerProvider).vault.id;
    final named = items(app).single.file.id;
    // Both are older than the sweep's cutoff, so only being named keeps the first
    final stored = app.attachments.files[vaultId]![named]!;
    app.attachments.files[vaultId]![named] = (sealed: stored.sealed, modified: DateTime.utc(2020));
    app.attachments.files[vaultId]!['orphan'] = (sealed: Uint8List(4), modified: DateTime.utc(2020));

    await app.container.read(vaultControllerProvider.notifier).sweepAttachments();

    expect(app.attachments.files[vaultId]!.keys, [named]);
  });

  group('the Vault tab list', () {
    const entry = NoteAttachment(id: 'a1', name: 'scan-0042.pdf', size: 10, type: 'application/pdf', key: 'AA==', addedAt: 2);
    const state = VaultState(
      phase: VaultPhase.unlocked,
      files: [
        VaultFile(id: 'f1', name: 'Lease', file: entry, notes: 'signed copy', addedAt: 2),
        VaultFile(id: 'f2', name: 'Apple receipt', file: entry, favorite: true, addedAt: 1),
      ],
      notes: [SecureNote(id: 'n1', title: 'wi-fi', text: 'hunter2', addedAt: 3)],
      vault: VaultInfo(id: 'main'),
    );

    test('a File item the web vault made with no date takes the day its file was attached', () {
      const web = VaultFile(id: 'f3', name: 'Web made', file: entry, addedAt: 0);
      const withDate = VaultFile(id: 'f1', name: 'Lease', file: entry, addedAt: 7);

      expect(fileAddedAt(web), 2);
      expect(fileAddedAt(withDate), 7);
      expect(VaultListItem.file(web).addedAt, 2);
    });

    test('lists File items under All and under the Files filter alone, a favourite first', () {
      final all = vaultListItems(state);
      expect(all.total, 3);
      expect([for (final item in all.pinned) item.title], ['Apple receipt']);

      final filtered = vaultListItems(state, filter: VaultFilter.files);
      expect([for (final item in [...filtered.pinned, ...filtered.rest]) item.title], ['Apple receipt', 'Lease']);
      expect(VaultFilter.values.indexOf(VaultFilter.files), VaultFilter.values.indexOf(VaultFilter.notes) + 1);
    });

    test("finds a File item by its name, notes, and its file's name and type", () {
      for (final query in ['lease', 'signed', 'scan-0042', 'application/pdf']) {
        final found = vaultListItems(state, query: query);
        expect([for (final item in [...found.pinned, ...found.rest]) item.kind], contains(VaultItemKind.file), reason: query);
      }
      final none = vaultListItems(state, query: 'wi-fi', filter: VaultFilter.files);
      expect([...none.pinned, ...none.rest], isEmpty);
    });
  });
}
