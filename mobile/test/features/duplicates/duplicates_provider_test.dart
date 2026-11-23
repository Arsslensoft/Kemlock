import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/public_suffixes.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/duplicates/dedup_store.dart';
import 'package:kemlock/features/duplicates/dedup_tagger.dart';
import 'package:kemlock/features/duplicates/duplicate_matcher.dart';
import 'package:kemlock/features/duplicates/duplicate_merge.dart';
import 'package:kemlock/features/duplicates/duplicates_provider.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_unlock_keys.dart';
import '../../vault/fast_kdf.dart';

class _NoBiometrics implements Biometrics {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

SecureNote _note(String id, String text) => SecureNote(id: id, title: 'Note $id', text: text, addedAt: 0);

Login _login(String id, String password) =>
    Login(id: id, name: 'Login $id', username: 'sam', password: password, websites: const ['proton.me'], addedAt: 0);

// The plan's task 6.2: "Not duplicates", pruning past 30 days, and an undo that reaches another phone
void main() {
  late MessageCatalog catalog;
  late KeyValueStore store;
  late VaultRegistry vaults;
  late VaultStore vaultStore;
  late ProviderContainer container;
  var now = DateTime.utc(2026, 11, 21, 12);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await MessageCatalog.load();
  });

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    vaultStore = VaultStore(store, vaults, deriveKey: fastKdf);
    now = DateTime.utc(2026, 11, 21, 12);
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        messageCatalogProvider.overrideWithValue(catalog),
        vaultRegistryProvider.overrideWithValue(vaults),
        vaultStoreProvider.overrideWithValue(vaultStore),
        biometricsProvider.overrideWithValue(_NoBiometrics()),
        FakeUnlockKeys(available: false).asOverride,
        clockProvider.overrideWithValue(() => now),
        // The asset bundle can't be read here: every host stands for itself
        publicSuffixListProvider.overrideWith((ref) async => null),
        suffixListHashProvider.overrideWith((ref) async => 'none'),
      ],
    );
    addTearDown(container.dispose);
  });

  VaultController controller() => container.read(vaultControllerProvider.notifier);
  VaultState state() => container.read(vaultControllerProvider);
  DuplicatesController duplicates() => container.read(duplicatesProvider.notifier);
  DuplicatesState found() => container.read(duplicatesProvider);
  void later(Duration by) => now = now.add(by);

  Future<void> openNew() async {
    await controller().open(await vaultStore.setupVault('pw'));
    // The first check starts as the provider is built
    container.read(duplicatesProvider);
    await pumpEventQueue();
  }

  group('Not duplicates', () {
    test('hides the group on Check again, and it returns when a third item joins', () async {
      await openNew();
      await controller().addNote(_note('n1', 'same text'));
      await controller().addNote(_note('n2', 'same text'));
      await duplicates().check();
      expect(found().groups, hasLength(1));

      expect(await duplicates().dismiss(found().groups.single), isTrue);
      expect(found().groups, isEmpty);

      await duplicates().check();
      expect(found().groups, isEmpty);

      await controller().addNote(_note('n3', 'same text'));
      await duplicates().check();
      expect(found().groups.single.items.map((item) => item.id), unorderedEquals(['n1', 'n2', 'n3']));
    });

    test('is remembered by the vault: another open of it still hides the group', () async {
      await openNew();
      await controller().addNote(_note('n1', 'same text'));
      await controller().addNote(_note('n2', 'same text'));
      await duplicates().check();
      await duplicates().dismiss(found().groups.single);

      final answers = await DedupStore(vaultStore).loadAnswers(state().session!);

      expect(answers.dismissed, hasLength(1));
      expect(withoutDismissed(found().groups, answers.dismissed), isEmpty);
    });
  });

  group('merge records', () {
    test('past 30 days are gone at the next check, and fresher ones stay', () async {
      await openNew();
      await controller().addLogin(_login('a', 'old'));
      later(const Duration(minutes: 1));
      await controller().addLogin(_login('b', 'new'));
      await controller().mergeDuplicates(MergeChoices(dedupItems(logins: state().logins)));
      later(const Duration(days: 20));
      await controller().addLogin(_login('c', 'x'));
      await controller().addLogin(_login('d', 'y'));
      await controller().mergeDuplicates(
        MergeChoices(
          dedupItems(
            logins: [
              for (final login in state().logins)
                if (login.id == 'c' || login.id == 'd') login,
            ],
          ),
        ),
      );
      await duplicates().check();
      expect(found().records, hasLength(2));

      later(const Duration(days: 11));
      await duplicates().check();

      expect(found().records, hasLength(1));
      final stored = await DedupStore(vaultStore).loadAnswers(state().session!);
      expect(stored.mergeRecords, hasLength(1));
      expect(stored.mergeRecords.single.undoable(now.millisecondsSinceEpoch), isTrue);
    });

    test('are counted by the notifier for the health card', () async {
      await openNew();
      await controller().addLogin(_login('a', 'old'));
      later(const Duration(minutes: 1));
      await controller().addLogin(_login('b', 'new'));
      await controller().mergeDuplicates(MergeChoices(dedupItems(logins: state().logins)));
      await duplicates().check();

      expect(found().merges, 1);
      expect(found().records.single.label, 'Login b');
      expect(found().groups, isEmpty);
    });
  });

  test('an undo reaches the other phone after a sync: the restored items outlive the removal both shared', () async {
    await openNew();
    await controller().addLogin(_login('a', 'old'));
    later(const Duration(minutes: 1));
    await controller().addLogin(_login('b', 'new'));
    final phoneB = state().lists;
    final held = phoneB.ids.toList();
    await controller().mergeDuplicates(MergeChoices(dedupItems(logins: state().logins)));

    // Phone A syncs the merge, and phone B takes it: the removed login goes there too
    final merged = mergeScope(state().lists, held, null, now: now.millisecondsSinceEpoch);
    final afterMerge = mergeScope(phoneB, held, merged.doc, now: now.millisecondsSinceEpoch);
    expect(afterMerge.doc.logins.map((login) => login.id), ['b']);

    // Six days later phone A undoes the merge and syncs again
    later(const Duration(days: 6));
    final id = (await DedupStore(vaultStore).loadAnswers(state().session!)).mergeRecords.single.id;
    expect(await controller().undoMerge(id), isTrue);
    final undone = mergeScope(state().lists, merged.known, merged.doc, now: now.millisecondsSinceEpoch);
    final onPhoneB = mergeScope(afterMerge.doc, afterMerge.known, undone.doc, now: now.millisecondsSinceEpoch);

    expect(onPhoneB.doc.logins.map((login) => login.id), unorderedEquals(['a', 'b']));
    expect(onPhoneB.doc.logins.firstWhere((login) => login.id == 'a').password, 'old');
  });
}
