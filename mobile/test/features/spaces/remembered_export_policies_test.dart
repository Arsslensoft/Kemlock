import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/spaces/remembered_export_policies.dart';
import 'package:kemlock/features/spaces/space_head_store.dart';
import 'package:kemlock/features/spaces/space_policies_provider.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/features/spaces/space_verify.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_unlock_keys.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import '../export/transfer_harness.dart';
import 'chain_kit.dart';
import 'policy_kit.dart';

// What the open vault remembers of each space's export policy (docs/plans/add-server-spaces.md, task 7.4): the chain a run
// or a read compared is left in the vault's anchors, comes back when the vault opens again, and is replaced by a chain read
// since, never relaxed by an older one.
void main() {
  final space = uuid(0x5a);
  final bob = Person(2);

  ChainAnchor anchor() => ChainAnchor(epoch: 1, links: [for (var i = 0; i < 5; i++) Uint8List(32)..fillRange(0, 32, i + 1)]);

  /// A chain of [space] where Bob is a confirmed Member and the Owner's `disableExport` was set to each of [flags] in turn.
  SpaceState chainWith(List<bool> flags, {bool confirmed = true}) {
    final chain = ChainBuilder(space)
      ..create(policyOwner, collection: uuid(0xe0 + 0x5a))
      ..invite(policyOwner, bob);
    if (confirmed) {
      chain.confirm(policyOwner, bob);
    }
    for (final flag in flags) {
      // A policies record that changes nothing is refused, so a flag the chain already has needs none
      if ((chain.state.policies['disableExport'] == true) != flag) {
        chain.policies(policyOwner, {'disableExport': flag});
      }
    }
    return chain.state;
  }

  late VaultStore vaultStore;
  late VaultSession session;
  late RecordingVault vault;
  late ProviderContainer container;
  late KeyValueStore keyValues;

  /// A container over the open vault, reading the anchors through [anchors].
  ProviderContainer containerOver(SyncedSpaceAnchorStore anchors) {
    final made = ProviderContainer(
      overrides: [
        ...testOverrides(store: keyValues),
        vault.asOverride,
        vaultStoreProvider.overrideWithValue(vaultStore),
        spaceAnchorStoreProvider.overrideWithValue(anchors),
      ],
    );
    addTearDown(made.dispose);
    return made;
  }

  setUp(() async {
    keyValues = KeyValueStore.memory();
    vaultStore = VaultStore(keyValues, VaultRegistry(keyValues), deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
    session = await vaultStore.setupVault('pw');
    // The space was met before: the anchor is what a remembered policy is kept with
    await SyncedSpaceAnchorStore(vaultStore, syncs: () => true).remember(space, anchor(), session, compared: true);
    vault = RecordingVault(session: session);
    container = containerOver(SyncedSpaceAnchorStore(vaultStore, syncs: () => true));
  });

  RememberedExportPoliciesNotifier notifier() => container.read(rememberedExportPoliciesProvider.notifier);
  Map<String, RememberedExportPolicy> remembered() => container.read(rememberedExportPoliciesProvider);

  void lock() => vault.change((state) => state.copyWith(phase: VaultPhase.locked, clearSession: true));
  void unlock() => vault.change((state) => state.copyWith(phase: VaultPhase.unlocked, session: session));

  group('the remembered export policy', () {
    test('drops a read that finishes after another vault opened', () async {
      final gate = Completer<void>();
      const stored = RememberedExportPolicy(disableExport: false, epoch: 1, seq: 3, at: 1);
      container = containerOver(_GatedStore(vaultStore, gate, space, anchor(), stored));
      notifier();

      vault.change((state) => state.copyWith(vault: const VaultInfo(id: 'other')));
      await notifier().ready;
      expect(remembered(), isEmpty, reason: 'the other vault has nothing remembered');
      gate.complete();
      await pumpEventQueue();

      expect(remembered(), isEmpty, reason: 'what the first vault held is not the other’s');
    });

    test('keeps a read that finishes while the vault is still the one it was made for', () async {
      final gate = Completer<void>();
      const stored = RememberedExportPolicy(disableExport: false, epoch: 1, seq: 3, at: 1);
      container = containerOver(_GatedStore(vaultStore, gate, space, anchor(), stored));
      final policies = notifier();

      gate.complete();
      await policies.ready;

      expect(remembered()[space], stored);
    });

    test('drops a chain that a run of another vault reports', () async {
      notifier().remember(space, bob.id, chainWith([true]), vault: 'someone-else');
      container.read(spacePoliciesProvider.notifier).reportCompared(space, bob.id, chainWith([true]), vault: 'someone-else');
      await notifier().ready;

      expect(remembered(), isEmpty);
      expect(container.read(spacePoliciesProvider).spaces, isEmpty);
      expect((await SpaceAnchorStore(vaultStore).load(session)).exportPolicyOf(space), isNull);

      container.read(spacePoliciesProvider.notifier).reportCompared(space, bob.id, chainWith([true]), vault: 'test');
      await notifier().ready;
      expect(remembered()[space]?.disableExport, isTrue, reason: 'a chain of the open vault goes through');
      expect(container.read(spacePoliciesProvider).known, {space});
    });

    test('keeps what a chain read for the open vault said, though the vault locked right after', () async {
      notifier().remember(space, bob.id, chainWith([true]));
      lock();
      expect(remembered(), isEmpty, reason: 'nothing is kept in memory while the vault is locked');
      await pumpEventQueue();
      unlock();
      await notifier().ready;

      expect(remembered()[space]?.disableExport, isTrue, reason: 'it was read for this vault while it was open');
    });

    test('is left in the vault by a compared chain, and read back when the vault locks and opens again', () async {
      await notifier().ready;
      expect(remembered(), isEmpty);

      notifier().remember(space, bob.id, chainWith([true]));
      await notifier().ready;
      expect(remembered()[space]?.disableExport, isTrue);
      expect(remembered()[space]?.seq, 3, reason: 'the fourth record: create, invite, confirm, policies');

      lock();
      expect(remembered(), isEmpty, reason: 'nothing is kept in memory while the vault is locked');
      unlock();
      await notifier().ready;

      expect(remembered()[space]?.disableExport, isTrue);
      expect((await SpaceAnchorStore(vaultStore).load(session)).exportPolicyOf(space)?.seq, 3);
    });

    test('is replaced by a chain read later, in either direction', () async {
      notifier().remember(space, bob.id, chainWith([false]));
      expect(remembered()[space]?.disableExport, isFalse);

      notifier().remember(space, bob.id, chainWith([false, true]));
      await notifier().ready;
      expect(remembered()[space]?.disableExport, isTrue);

      notifier().remember(space, bob.id, chainWith([false, true, false]));
      await notifier().ready;
      expect(remembered()[space]?.disableExport, isFalse);
      lock();
      unlock();
      await notifier().ready;
      expect(remembered()[space]?.disableExport, isFalse, reason: 'what the vault holds is the last chain read');
    });

    test('is not relaxed by a chain that is behind the one remembered', () async {
      notifier().remember(space, bob.id, chainWith([false, true]));
      notifier().remember(space, bob.id, chainWith([false]));
      await notifier().ready;

      expect(remembered()[space]?.disableExport, isTrue);
      lock();
      unlock();
      await notifier().ready;
      expect(remembered()[space]?.disableExport, isTrue);
    });

    test('forbids export for a chain that doesn’t show the account a confirmed member', () async {
      notifier().remember(space, bob.id, chainWith([false], confirmed: false));
      await notifier().ready;

      expect(remembered()[space]?.disableExport, isTrue);
    });

    test('is made by a compared chain and not by one that was only read', () async {
      final policies = container.read(spacePoliciesProvider.notifier);

      policies.report(space, bob.id, chainWith([false]));
      await notifier().ready;
      expect(remembered(), isEmpty);

      policies.reportCompared(space, bob.id, chainWith([false]));
      await notifier().ready;
      expect(remembered().keys, [space]);
      expect(container.read(spacePoliciesProvider).known, {space});
    });

    test('is none when the space has no anchor to keep it with, and still holds for this run of the vault', () async {
      final other = uuid(0x5b);
      final chain =
          (ChainBuilder(other)
                ..create(policyOwner, collection: uuid(0xe5))
                ..invite(policyOwner, bob)
                ..confirm(policyOwner, bob))
              .state;

      notifier().remember(other, bob.id, chain);
      await notifier().ready;

      expect(remembered()[other]?.disableExport, isFalse);
      expect((await SpaceAnchorStore(vaultStore).load(session)).exportPolicyOf(other), isNull);
    });
  });
}

/// A store whose first read of the anchors waits for [gate], as a slow disk or a busy sync does, and then holds [anchor] for
/// [space] with [policy] remembered; every other read finds nothing.
class _GatedStore extends SyncedSpaceAnchorStore {
  _GatedStore(super.store, this.gate, this.space, this.anchor, this.policy) : super(syncs: () => true);

  final Completer<void> gate;
  final String space;
  final ChainAnchor anchor;
  final RememberedExportPolicy policy;
  var _reads = 0;

  @override
  Future<SpaceAnchors> load(VaultSession session) async {
    if (_reads++ > 0) {
      return SpaceAnchors();
    }
    await gate.future;
    return SpaceAnchors({space: anchor}).rememberingExport(space, policy);
  }
}
