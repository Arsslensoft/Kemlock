import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/vault/attachment_store.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_attachments.dart';
import '../fakes/fake_unlock_keys.dart';
import 'fast_kdf.dart';

class _NoBiometrics implements Biometrics {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

void main() {
  late MessageCatalog catalog;
  late KeyValueStore store;
  late VaultRegistry vaults;
  late VaultStore vaultStore;
  late FakeAttachmentStore files;
  late ProviderContainer container;
  var now = DateTime.utc(2026, 11, 15, 12);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await MessageCatalog.load();
  });

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    vaultStore = VaultStore(store, vaults, deriveKey: fastKdf);
    files = FakeAttachmentStore();
    now = DateTime.utc(2026, 11, 15, 12);
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        messageCatalogProvider.overrideWithValue(catalog),
        vaultRegistryProvider.overrideWithValue(vaults),
        vaultStoreProvider.overrideWithValue(vaultStore),
        biometricsProvider.overrideWithValue(_NoBiometrics()),
        // No biometrics the hardware key could use, without the native side
        FakeUnlockKeys(available: false).asOverride,
        attachmentStoreProvider.overrideWithValue(files),
        clockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(container.dispose);
  });

  VaultController controller() => container.read(vaultControllerProvider.notifier);
  VaultState state() => container.read(vaultControllerProvider);
  final scan = Uint8List.fromList(utf8.encode('passport scan'));

  /// Stores a file and returns its record, as attaching does.
  Future<NoteAttachment> attach(String vaultId, String id, {required DateTime at}) async {
    final key = randomBytes(32);
    files.now = at;
    await files.write(vaultId, id, scan, key);
    return NoteAttachment(id: id, name: '$id.pdf', size: scan.length, key: b64(key), addedAt: at.millisecondsSinceEpoch);
  }

  test('a deleted note comes back with Undo, and its file still opens', () async {
    final session = await vaultStore.setupVault('pw');
    await controller().open(session);
    final file = await attach('main', 'f1', at: now);
    await controller().addNote(SecureNote(id: 'n1', title: 'Passport', addedAt: 0, attachments: [file]));

    await controller().deleteNote(state().notes.single);
    container.read(toastsProvider)!.onAction!();
    await pumpEventQueue();

    expect(state().notes.single.files.single.id, 'f1');
    expect(await files.read('main', 'f1', unb64(file.key)), scan);
  });

  test('the sweep at unlock deletes old files no note names, and spares the rest', () async {
    final session = await vaultStore.setupVault('pw');
    await controller().open(session);
    final kept = await attach('main', 'kept', at: now.subtract(const Duration(days: 30)));
    await attach('main', 'removed', at: now.subtract(const Duration(days: 2)));
    await attach('main', 'fresh', at: now.subtract(const Duration(hours: 2)));
    await controller().addNote(SecureNote(id: 'n1', title: 'Passport', addedAt: 0, attachments: [kept]));
    controller().lock();

    await controller().open(session);
    await pumpEventQueue();

    // The removed one was a day old and named by no note; the fresh one may
    // still be Undone or saved, and the kept one is named
    expect(files.files['main']!.keys.toList()..sort(), ['fresh', 'kept']);
  });

  test("the sweep leaves other vaults' files alone", () async {
    final session = await vaultStore.setupVault('pw');
    await attach('a1b2c3d4e5f6', 'theirs', at: now.subtract(const Duration(days: 9)));

    await controller().open(session);
    await pumpEventQueue();

    expect(files.files['a1b2c3d4e5f6']!.keys, ['theirs']);
  });

  test('deleting a vault deletes its files, and only its files', () async {
    await vaultStore.setupVault('first');
    await attach('main', 'mine', at: now);
    final second = await vaultStore.createVault('Work', 'second', listed: true);
    controller().switchVault(second);
    await controller().open(await vaultStore.unlockVault('second'));
    await attach(second, 'work', at: now);

    controller().deleteVault();
    await pumpEventQueue();

    expect(files.files.containsKey(second), isFalse);
    expect(files.files['main']!.keys, ['mine']);
  });

  test('wiping every vault deletes every file', () async {
    await vaultStore.setupVault('pw');
    await attach('main', 'f1', at: now);
    await attach('a1b2c3d4e5f6', 'f2', at: now);

    vaultStore.wipeVault();
    controller().wiped();
    await pumpEventQueue();

    expect(files.files, isEmpty);
  });
}
