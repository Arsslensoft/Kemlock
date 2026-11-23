import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/features/spaces/space_head_store.dart';
import 'package:kemlock/features/spaces/space_verify.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_unlock_keys.dart';
import '../../vault/fast_kdf.dart';
import 'chain_kit.dart';

/// An anchor of [seq] + 1 links, each filled with [fill] plus its position, at epoch [epoch].
ChainAnchor _anchor(int seq, int fill, {int epoch = 1}) =>
    ChainAnchor(epoch: epoch, links: [for (var i = 0; i <= seq; i++) Uint8List(32)..fillRange(0, 32, fill + i)]);

void main() {
  group('the anchors', () {
    test('read back as they were written, and an empty value is no heads', () {
      final heads = SpaceAnchors({uuid(1): _anchor(3, 1), uuid(2): _anchor(0, 2)});
      final read = SpaceAnchors.fromJson(heads.toJson());
      expect(read.of(uuid(1)), _anchor(3, 1));
      expect(read.of(uuid(2)), _anchor(0, 2));
      expect(read.of(uuid(3)), isNull);
      expect(SpaceAnchors.fromJson(null).length, 0);
    });

    test('keep the members they don’t know', () {
      final json = {
        ...SpaceAnchors({uuid(1): _anchor(3, 1)}).toJson(),
        'later': 7,
      };
      expect(SpaceAnchors.fromJson(json).toJson()['later'], 7);
    });

    test('never go back, and move on to a higher or the same sequence number', () {
      final heads = SpaceAnchors({uuid(1): _anchor(5, 1)});
      expect(heads.remembering(uuid(1), _anchor(4, 9)).of(uuid(1)), _anchor(5, 1));
      expect(heads.remembering(uuid(1), _anchor(6, 9)).of(uuid(1)), _anchor(6, 9));
      expect(heads.remembering(uuid(2), _anchor(0, 3)).length, 2);
      expect(heads.forgetting(uuid(1)).length, 0);
    });

    test('go back by a fence only: the anchor that replaced the records a fence dropped is kept', () {
      final anchors = SpaceAnchors({uuid(1): _anchor(12, 1)});
      final fenced = _anchor(10, 50, epoch: 2);
      expect(anchors.remembering(uuid(1), fenced).of(uuid(1)), _anchor(12, 1));
      expect(anchors.remembering(uuid(1), fenced, afterFence: true).of(uuid(1)), fenced);
    });

    test('hold the epoch and every link, and compare them whole', () {
      final anchor = _anchor(3, 1, epoch: 2);
      expect(anchor.seq, 3);
      expect(anchor.epoch, 2);
      expect(anchor.links, hasLength(4));
      expect(ChainAnchor.fromJson(anchor.toJson()), anchor);
      expect(_anchor(3, 1, epoch: 2) == _anchor(3, 2, epoch: 2), isFalse);
      expect(_anchor(3, 1, epoch: 2) == _anchor(3, 1, epoch: 3), isFalse);
    });

    test('read a version-1 value (a head, no links) as no anchors, so each space starts from first contact again', () {
      final v1 = {
        'v': 1,
        'heads': {
          uuid(1): {'seq': 4, 'hash': b64urlEncode(Uint8List(32))},
        },
      };
      expect(SpaceAnchors.fromJson(v1).length, 0);
      expect(SpaceAnchors.fromJson(v1).toJson()['v'], 2);
    });

    test('refuse a value that isn’t anchors, or that a newer version wrote, instead of reading it as empty', () {
      for (final bad in <Object?>[
        'text',
        {'v': 2},
        {'v': 2, 'anchors': []},
        {
          'v': 2,
          'anchors': {'not-a-uuid': {}},
        },
        {'v': 3, 'anchors': {}},
        {
          'v': 2,
          'anchors': {
            uuid(1): {'epoch': 1},
          },
        },
        {
          'v': 2,
          'anchors': {
            uuid(1): {'epoch': 0, 'links': b64urlEncode(Uint8List(32))},
          },
        },
        {
          'v': 2,
          'anchors': {
            uuid(1): {'epoch': 1, 'links': b64urlEncode(Uint8List(31))},
          },
        },
        {
          'v': 2,
          'anchors': {
            uuid(1): {'epoch': 1, 'links': ''},
          },
        },
      ]) {
        expect(() => SpaceAnchors.fromJson(bad), throwsA(isA<MalformedException>()), reason: '$bad');
      }
    });
  });

  group('in the vault', () {
    late KeyValueStore store;
    late VaultRegistry vaults;
    late VaultStore vault;

    setUp(() {
      store = KeyValueStore.memory();
      vaults = VaultRegistry(store);
      vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
    });

    test('is sealed, found by sealedValueKeys, and read back after the vault is opened again', () async {
      final session = await vault.setupVault('pw');
      final heads = SpaceAnchorStore(vault);
      expect((await heads.load(session)).length, 0);

      await heads.remember(uuid(1), _anchor(4, 7), session);
      expect(vault.sealedValueKeys(vaults.active), contains(vaults.vaultKey(keySpaceHeads, vaults.active)));
      expect(store.getItem(vaults.vaultKey(keySpaceHeads)), isNot(contains('"links"')), reason: 'only sealed bytes are stored');

      final reopened = await vault.unlockVault('pw');
      expect((await heads.load(reopened)).of(uuid(1)), _anchor(4, 7));
    });

    test('is not moved back by an older head', () async {
      final session = await vault.setupVault('pw');
      final heads = SpaceAnchorStore(vault);
      await heads.remember(uuid(1), _anchor(9, 1), session);
      final after = await heads.remember(uuid(1), _anchor(2, 2), session);
      expect(after.of(uuid(1)), _anchor(9, 1));
      expect((await heads.load(session)).of(uuid(1)), _anchor(9, 1));
    });

    test('is left alone, sealed as it was, when a newer version’s value sits beside it', () async {
      final session = await vault.setupVault('pw');
      await vault.saveEncryptedValue('backmycodes_future_thing', {'from': 'a newer version'}, session);
      await SpaceAnchorStore(vault).remember(uuid(1), _anchor(1, 1), session);
      expect(await vault.loadEncryptedValue('backmycodes_future_thing', session), {'from': 'a newer version'});
    });

    test('is deleted with its vault, and the other vault’s stays', () async {
      final session = await vault.setupVault('pw');
      await SpaceAnchorStore(vault).remember(uuid(1), _anchor(1, 1), session);
      final other = await vault.createVault('Work', 'work pw', listed: true);
      vaults.active = other;
      final otherSession = await vault.unlockVault('work pw');
      await SpaceAnchorStore(vault).remember(uuid(2), _anchor(2, 2), otherSession);

      vaults.removeVaultData(other);

      expect(store.getItem(vaults.vaultKey(keySpaceHeads, other)), isNull);
      expect(store.getItem(keySpaceHeads), isNotNull);
    });

    test('a value that can’t be opened throws, and is never read as empty', () async {
      final session = await vault.setupVault('pw');
      store.setItem(vaults.vaultKey(keySpaceHeads), '{"kemCT":"AA","nonce":"AA","ct":"AA"}');
      await expectLater(SpaceAnchorStore(vault).load(session), throwsA(anything));
    });
  });

  group('the record that a fingerprint was compared', () {
    test('is made only by a comparison: remembering a chain that was only read leaves the space uncompared', () {
      final read = SpaceAnchors().remembering(uuid(1), _anchor(3, 1));
      expect(read.of(uuid(1)), _anchor(3, 1));
      expect(read.hasCompared(uuid(1)), isFalse);
      expect(read.toJson()['anchors'], {uuid(1): _anchor(3, 1).toJson()}, reason: 'no record is written for it');

      final compared = read.remembering(uuid(1), _anchor(3, 1), compared: true);
      expect(compared.hasCompared(uuid(1)), isTrue);
      expect(compared.toJson()['anchors'], {
        uuid(1): {..._anchor(3, 1).toJson(), 'compared': true},
      });
    });

    test('stays with the space as its anchor moves on, also by a fence, and goes with it when it is forgotten', () {
      final compared = SpaceAnchors().remembering(uuid(1), _anchor(3, 1), compared: true);
      final moved = compared.remembering(uuid(1), _anchor(6, 1));
      expect(moved.of(uuid(1)), _anchor(6, 1));
      expect(moved.hasCompared(uuid(1)), isTrue, reason: 'reading on does not undo the comparison');
      expect(moved.remembering(uuid(1), _anchor(2, 9), afterFence: true).hasCompared(uuid(1)), isTrue);
      // An anchor that would go back is left out, and still takes the record of a comparison made now
      final read = SpaceAnchors().remembering(uuid(1), _anchor(6, 1));
      final behind = read.remembering(uuid(1), _anchor(4, 1), compared: true);
      expect(behind.of(uuid(1)), _anchor(6, 1));
      expect(behind.hasCompared(uuid(1)), isTrue);
      expect(compared.forgetting(uuid(1)).hasCompared(uuid(1)), isFalse);
      expect(compared.forgetting(uuid(1)).length, 0);
    });

    test('is read back as written, and an entry without it is an anchor nobody compared', () {
      final both = SpaceAnchors({uuid(1): _anchor(3, 1), uuid(2): _anchor(1, 2)}, const {}, {uuid(1)});
      final read = SpaceAnchors.fromJson(both.toJson());
      expect(read.hasCompared(uuid(1)), isTrue);
      expect(read.hasCompared(uuid(2)), isFalse);
      expect(read.of(uuid(2)), _anchor(1, 2));
      // What an earlier build of this branch wrote by anchoring everything it read
      final older = {
        'v': 2,
        'anchors': {uuid(3): _anchor(2, 3).toJson()},
      };
      expect(SpaceAnchors.fromJson(older).hasCompared(uuid(3)), isFalse);
      // Only `true` is a comparison
      final odd = {
        'v': 2,
        'anchors': {
          uuid(3): {..._anchor(2, 3).toJson(), 'compared': 'yes'},
        },
      };
      expect(SpaceAnchors.fromJson(odd).hasCompared(uuid(3)), isFalse);
      expect(SpaceAnchors.fromJson(odd).of(uuid(3)), _anchor(2, 3));
      // A record with no anchor to belong to means nothing
      expect(SpaceAnchors({uuid(1): _anchor(0, 1)}, const {}, {uuid(1), uuid(9)}).compared, {uuid(1)});
    });

    test('travels with the anchor to another device: a comparison on either counts for one chain, and the taken anchor’s own on two', () {
      final compared = SpaceAnchors({uuid(1): _anchor(5, 1), uuid(2): _anchor(2, 1)}, const {}, {uuid(1), uuid(2)});
      final read = SpaceAnchors({uuid(1): _anchor(3, 1), uuid(3): _anchor(0, 3)});

      final merged = read.mergedWith(compared).anchors;
      expect(merged.of(uuid(1)), _anchor(5, 1));
      expect(merged.hasCompared(uuid(1)), isTrue, reason: 'one chain, and the other device compared it');
      expect(merged.hasCompared(uuid(2)), isTrue, reason: 'a space only the other device holds keeps its record');
      expect(merged.hasCompared(uuid(3)), isFalse, reason: 'a space only this device read is still uncompared');
      expect(compared.mergedWith(read).anchors.hasCompared(uuid(1)), isTrue, reason: 'the same either way round');

      // Two chains: the anchor taken brings its own record, so a fence-moved chain nobody compared is not vouched for
      final here = SpaceAnchors({uuid(4): _anchor(3, 1)}, const {}, {uuid(4)});
      final fenced = SpaceAnchors({uuid(4): _anchor(2, 50, epoch: 2)});
      expect(here.mergedWith(fenced).anchors.of(uuid(4)), _anchor(2, 50, epoch: 2));
      expect(here.mergedWith(fenced).anchors.hasCompared(uuid(4)), isFalse);
      expect(fenced.mergedWith(here).anchors.hasCompared(uuid(4)), isFalse);
    });

    test('is carried by the stored values the vault’s sync merges', () {
      final theirs = SpaceAnchors({uuid(1): _anchor(4, 1)}, const {}, {uuid(1)}).toJson();
      final ours = SpaceAnchors({uuid(1): _anchor(1, 1)}).toJson();
      expect(SpaceAnchors.fromJson(SpaceAnchors.mergeValues(ours, theirs)).hasCompared(uuid(1)), isTrue);
      expect(SpaceAnchors.fromJson(SpaceAnchors.mergeValues(theirs, ours)).hasCompared(uuid(1)), isTrue);
    });

    test('is kept by the stores: a new phone of the account reads the space as compared', () async {
      final store = KeyValueStore.memory();
      final vaults = VaultRegistry(store);
      final vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
      final session = await vault.setupVault('pw');
      final anchors = SyncedSpaceAnchorStore(vault, syncs: () => true);
      await anchors.remember(uuid(1), _anchor(2, 1), session);
      await anchors.remember(uuid(2), _anchor(2, 2), session, compared: true);

      final carried = await vault.loadEncryptedValue(keySpaceAnchorsSynced, session);
      final fresh = KeyValueStore.memory();
      final freshVault = VaultStore(fresh, VaultRegistry(fresh), deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
      final freshSession = await freshVault.setupVault('pw');
      await freshVault.saveEncryptedValue(keySpaceAnchorsSynced, carried, freshSession);

      final onNewPhone = await SyncedSpaceAnchorStore(freshVault, syncs: () => true).load(freshSession);
      expect(onNewPhone.hasCompared(uuid(2)), isTrue, reason: 'compared on the first phone, so the second compares nothing');
      expect(onNewPhone.hasCompared(uuid(1)), isFalse, reason: 'anchored without a comparison: first contact still to do');
      expect((await SpaceAnchorStore(vault).load(session)).hasCompared(uuid(2)), isTrue);
    });
  });

  group('the anchors two devices of one account meet in the vault’s sync', () {
    test('keep a space only one of them holds, and take the longer chain when one is a prefix of the other', () {
      final phone = SpaceAnchors({uuid(1): _anchor(3, 1), uuid(2): _anchor(5, 2)});
      final other = SpaceAnchors({uuid(2): _anchor(2, 2), uuid(3): _anchor(0, 3)});
      final merged = phone.mergedWith(other);
      expect(merged.forked, isEmpty);
      expect(merged.anchors.of(uuid(1)), _anchor(3, 1));
      expect(merged.anchors.of(uuid(2)), _anchor(5, 2), reason: 'the other phone is behind on the same chain');
      expect(merged.anchors.of(uuid(3)), _anchor(0, 3));
      // The same either way round
      expect(other.mergedWith(phone).anchors.of(uuid(2)), _anchor(5, 2));
    });

    test('take the higher epoch when the chains differ, and name a fork when the epochs are equal', () {
      final behind = SpaceAnchors({uuid(1): _anchor(12, 1), uuid(2): _anchor(4, 1)});
      final fenced = SpaceAnchors({uuid(1): _anchor(10, 50, epoch: 2), uuid(2): _anchor(4, 90)});
      final merged = behind.mergedWith(fenced);
      expect(merged.anchors.of(uuid(1)), _anchor(10, 50, epoch: 2), reason: 'a fence moved the chain on');
      expect(merged.forked, {uuid(2)});
      expect(merged.anchors.of(uuid(2)), _anchor(4, 1), reason: 'a fork keeps this device’s own');
    });

    test('keep the members they don’t know, and merge two stored values, refusing one that can’t be read', () {
      final ours = {
        ...SpaceAnchors({uuid(1): _anchor(1, 1)}).toJson(),
        'later': 7,
      };
      final theirs = SpaceAnchors({uuid(1): _anchor(4, 1)}).toJson();
      final merged = SpaceAnchors.mergeValues(ours, theirs);
      expect(SpaceAnchors.fromJson(merged).of(uuid(1)), _anchor(4, 1));
      expect(merged['later'], 7);
      expect(() => SpaceAnchors.mergeValues(ours, {'v': 3, 'anchors': <String, Object?>{}}), throwsA(isA<MalformedException>()));
      expect(() => SpaceAnchors.mergeValues(ours, 'not an object'), throwsA(isA<MalformedException>()));
    });
  });

  group('the export policy remembered for a space', () {
    const allowed = RememberedExportPolicy(disableExport: false, epoch: 1, seq: 4, at: 1000);
    const forbidding = RememberedExportPolicy(disableExport: true, epoch: 1, seq: 6, at: 2000);

    test('is written in a top-level member, read back as written, and needs the anchor it was made for', () {
      final anchors = SpaceAnchors(
        {uuid(1): _anchor(4, 1), uuid(2): _anchor(1, 2)},
        const {},
        {uuid(1)},
      ).rememberingExport(uuid(1), allowed).rememberingExport(uuid(3), forbidding);

      final json = anchors.toJson();
      expect(json['exportPolicies'], {
        uuid(1): {'disableExport': false, 'epoch': 1, 'seq': 4, 'at': 1000},
      });
      expect(anchors.exportPolicyOf(uuid(3)), isNull, reason: 'a record means nothing without its anchor');
      expect(SpaceAnchors({uuid(1): _anchor(4, 1)}).toJson().containsKey('exportPolicies'), isFalse);

      final read = SpaceAnchors.fromJson(json);
      expect(read.exportPolicyOf(uuid(1)), allowed);
      expect(read.exportPolicyOf(uuid(2)), isNull);
      expect(read.of(uuid(1)), _anchor(4, 1));
      expect(read.hasCompared(uuid(1)), isTrue);
      expect(read.extra, isEmpty, reason: 'it is read as policies, not kept as a member this version doesn’t know');
    });

    test('leaves each space’s entry as an older build reads it, so the anchors still sync to one', () {
      final json = SpaceAnchors(
        {uuid(1): _anchor(4, 1), uuid(2): _anchor(1, 2)},
        const {},
        {uuid(1)},
      ).rememberingExport(uuid(1), allowed).rememberingExport(uuid(2), forbidding).toJson();

      // SpaceAnchors.fromJson as it was before the policies: it strips `compared` and reads the rest strictly, and keeps the
      // members of the value it doesn't know
      final entries = (json['anchors']! as Map<String, Object?>).cast<String, Map<String, Object?>>();
      for (final MapEntry(:key, :value) in entries.entries) {
        final fields = {...value}..remove('compared');
        expect(fields.keys.toSet(), {'epoch', 'links'}, reason: 'no field an older build would refuse: $key');
        expect(ChainAnchor.fromJson(fields), _anchor(key == uuid(1) ? 4 : 1, key == uuid(1) ? 1 : 2));
      }
      expect(json.keys.toSet().difference({'v', 'anchors'}), {'exportPolicies'}, reason: 'carried as a member it passes through');
    });

    test('is read as none when it can’t be understood, without refusing the anchors it rides in', () {
      final unreadable = <Object?>[
        'yes',
        7,
        <String, Object?>{},
        {'disableExport': 'yes', 'seq': 1, 'at': 1},
        {'disableExport': true, 'seq': -1, 'at': 1},
      ];
      for (final bad in unreadable) {
        final json = {
          'v': 2,
          'anchors': {uuid(1): _anchor(2, 1).toJson()},
          'exportPolicies': {uuid(1): bad},
        };
        final read = SpaceAnchors.fromJson(json);
        expect(read.exportPolicyOf(uuid(1)), isNull, reason: '$bad');
        expect(read.of(uuid(1)), _anchor(2, 1), reason: '$bad');
      }
      final notAnObject = SpaceAnchors.fromJson({
        'v': 2,
        'anchors': {uuid(1): _anchor(2, 1).toJson()},
        'exportPolicies': 'x',
      });
      expect(notAnObject.exportPolicies, isEmpty);
      expect(notAnObject.of(uuid(1)), _anchor(2, 1));
    });

    test('is replaced by a chain as far on or further, and never by an older one', () {
      final held = SpaceAnchors({uuid(1): _anchor(6, 1)}).rememberingExport(uuid(1), forbidding);

      expect(held.rememberingExport(uuid(1), allowed).exportPolicyOf(uuid(1)), forbidding, reason: 'seq 4 is behind seq 6');
      const same = RememberedExportPolicy(disableExport: false, epoch: 1, seq: 6, at: 3000);
      expect(held.rememberingExport(uuid(1), same).exportPolicyOf(uuid(1)), same, reason: 'the chain read last, as far on');
      const fenced = RememberedExportPolicy(disableExport: false, epoch: 2, seq: 2, at: 3000);
      expect(held.rememberingExport(uuid(1), fenced).exportPolicyOf(uuid(1)), fenced, reason: 'a fence moved the chain on');
    });

    test('goes with the space’s anchor: it stays when the anchor moves on and goes when the space does', () {
      final held = SpaceAnchors({uuid(1): _anchor(4, 1)}).rememberingExport(uuid(1), allowed);

      expect(held.remembering(uuid(1), _anchor(5, 1)).exportPolicyOf(uuid(1)), allowed);
      expect(held.remembering(uuid(1), _anchor(1, 9), afterFence: true).exportPolicyOf(uuid(1)), allowed);
      expect(held.forgetting(uuid(1)).exportPolicyOf(uuid(1)), isNull);
      expect(held.forgetting(uuid(1)).toJson()['anchors'], isEmpty);
    });

    test('is merged from two devices by the chain further on, and a tie goes to the one that forbids export', () {
      final here = SpaceAnchors({uuid(1): _anchor(4, 1), uuid(2): _anchor(2, 2), uuid(3): _anchor(6, 3)})
          .rememberingExport(uuid(1), allowed)
          .rememberingExport(uuid(2), const RememberedExportPolicy(disableExport: false, epoch: 1, seq: 6, at: 10));
      final there = SpaceAnchors({uuid(1): _anchor(6, 1), uuid(2): _anchor(3, 2), uuid(3): _anchor(6, 3)})
          .rememberingExport(uuid(1), forbidding)
          .rememberingExport(uuid(2), const RememberedExportPolicy(disableExport: true, epoch: 1, seq: 6, at: 5))
          .rememberingExport(uuid(3), allowed);

      for (final merged in [here.mergedWith(there).anchors, there.mergedWith(here).anchors]) {
        expect(merged.exportPolicyOf(uuid(1)), forbidding, reason: 'read from the chain further on');
        expect(merged.exportPolicyOf(uuid(2))?.disableExport, isTrue, reason: 'the same chain position: the stricter one');
        expect(merged.exportPolicyOf(uuid(3)), allowed, reason: 'only one device has it');
      }
    });

    test('travels in the carried value the vault’s sync merges', () {
      final theirs = SpaceAnchors({uuid(1): _anchor(4, 1)}).rememberingExport(uuid(1), forbidding).toJson();
      final ours = SpaceAnchors({uuid(1): _anchor(2, 1)}).toJson();

      expect(SpaceAnchors.fromJson(SpaceAnchors.mergeValues(ours, theirs)).exportPolicyOf(uuid(1)), forbidding);
      expect(SpaceAnchors.fromJson(SpaceAnchors.mergeValues(theirs, ours)).exportPolicyOf(uuid(1)), forbidding);
    });
  });

  group('the synced store', () {
    late KeyValueStore store;
    late VaultRegistry vaults;
    late VaultStore vault;

    setUp(() {
      store = KeyValueStore.memory();
      vaults = VaultRegistry(store);
      vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
    });

    test('keeps the anchors on the device only when the vault has no sync', () async {
      final session = await vault.setupVault('pw');
      final anchors = SyncedSpaceAnchorStore(vault, syncs: () => false);
      await anchors.remember(uuid(1), _anchor(2, 1), session);

      expect(store.getItem(vaults.vaultKey(keySpaceAnchorsSynced)), isNull);
      expect((await SpaceAnchorStore(vault).load(session)).of(uuid(1)), _anchor(2, 1));
      expect(await anchors.disagreements(session), isEmpty);
    });

    test('writes the value the vault’s sync carries, sealed, and a new phone reads what another phone confirmed', () async {
      final session = await vault.setupVault('pw');
      final anchors = SyncedSpaceAnchorStore(vault, syncs: () => true);
      await anchors.remember(uuid(1), _anchor(2, 1), session);
      expect(vault.sealedValueKeys(vaults.active), contains(vaults.vaultKey(keySpaceAnchorsSynced, vaults.active)));
      expect(store.getItem(vaults.vaultKey(keySpaceAnchorsSynced)), isNot(contains('"links"')), reason: 'only sealed bytes are stored');

      // A new phone has nothing of its own; the vault's sync brings the carried value
      final carried = await vault.loadEncryptedValue(keySpaceAnchorsSynced, session);
      final fresh = KeyValueStore.memory();
      final freshVault = VaultStore(fresh, VaultRegistry(fresh), deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
      final freshSession = await freshVault.setupVault('pw');
      await freshVault.saveEncryptedValue(keySpaceAnchorsSynced, carried, freshSession);

      final onNewPhone = await SyncedSpaceAnchorStore(freshVault, syncs: () => true).load(freshSession);
      expect(onNewPhone.of(uuid(1)), _anchor(2, 1), reason: 'the space is already anchored: no fingerprint to compare');
      final alone = await SyncedSpaceAnchorStore(freshVault, syncs: () => false).load(freshSession);
      expect(alone.of(uuid(1)), isNull, reason: 'a phone with no vault sync reads only its own');
    });

    test('a copy the sync brought that is further on is not moved back, and a fork is named', () async {
      final session = await vault.setupVault('pw');
      await vault.saveEncryptedValue(
        keySpaceAnchorsSynced,
        SpaceAnchors({uuid(1): _anchor(9, 1), uuid(2): _anchor(3, 70)}).toJson(),
        session,
      );
      final anchors = SyncedSpaceAnchorStore(vault, syncs: () => true);

      final after = await anchors.remember(uuid(1), _anchor(4, 1), session);
      expect(after.of(uuid(1)), _anchor(9, 1));

      await SpaceAnchorStore(vault).remember(uuid(2), _anchor(3, 5), session);
      expect(await anchors.disagreements(session), {uuid(2)});
    });

    test('keeps the export policy across a restart, and a save from a run that loaded earlier doesn’t lose it', () async {
      const forbidding = RememberedExportPolicy(disableExport: true, epoch: 1, seq: 4, at: 2000);
      final session = await vault.setupVault('pw');
      final anchors = SyncedSpaceAnchorStore(vault, syncs: () => true);
      await anchors.remember(uuid(1), _anchor(4, 1), session, compared: true);
      final loadedEarlier = await anchors.load(session);
      await anchors.rememberExport(uuid(1), forbidding, session);

      await anchors.save(loadedEarlier.remembering(uuid(1), _anchor(5, 1)), session);

      final restarted = VaultStore(store, VaultRegistry(store), deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
      final reopened = await restarted.unlockVault('pw');
      for (final read in [
        await SpaceAnchorStore(restarted).load(reopened),
        await SyncedSpaceAnchorStore(restarted, syncs: () => false).load(reopened),
        await SyncedSpaceAnchorStore(restarted, syncs: () => true).load(reopened),
      ]) {
        expect(read.exportPolicyOf(uuid(1)), forbidding);
        expect(read.of(uuid(1)), _anchor(5, 1));
      }
    });

    test('carries the export policy to a new phone of the account with the anchors', () async {
      const allowed = RememberedExportPolicy(disableExport: false, epoch: 1, seq: 4, at: 1000);
      final session = await vault.setupVault('pw');
      final anchors = SyncedSpaceAnchorStore(vault, syncs: () => true);
      await anchors.remember(uuid(1), _anchor(4, 1), session, compared: true);
      await anchors.rememberExport(uuid(1), allowed, session);

      final carried = await vault.loadEncryptedValue(keySpaceAnchorsSynced, session);
      final fresh = KeyValueStore.memory();
      final freshVault = VaultStore(fresh, VaultRegistry(fresh), deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
      final freshSession = await freshVault.setupVault('pw');
      await freshVault.saveEncryptedValue(keySpaceAnchorsSynced, carried, freshSession);

      final onNewPhone = await SyncedSpaceAnchorStore(freshVault, syncs: () => true).load(freshSession);
      expect(onNewPhone.exportPolicyOf(uuid(1)), allowed);
      expect((await SpaceAnchorStore(vault).load(session)).exportPolicyOf(uuid(1)), allowed);
      final alone = await SyncedSpaceAnchorStore(freshVault, syncs: () => false).load(freshSession);
      expect(alone.exportPolicyOf(uuid(1)), isNull, reason: 'a phone with no vault sync reads nothing the sync carried');
    });

    test('keeps both when an export policy write interleaves with anchor saves, through either store', () async {
      const forbidding = RememberedExportPolicy(disableExport: true, epoch: 1, seq: 4, at: 2000);
      final session = await vault.setupVault('pw');
      final anchors = SyncedSpaceAnchorStore(vault, syncs: () => true);
      await anchors.remember(uuid(1), _anchor(2, 1), session);

      // Each starts before the others finish: without one lock around each load-modify-save the last to save wins
      await Future.wait([
        anchors.rememberExport(uuid(1), forbidding, session),
        anchors.remember(uuid(1), _anchor(5, 1), session, compared: true),
        SpaceAnchorStore(vault).remember(uuid(2), _anchor(0, 2), session),
        SyncedSpaceAnchorStore(vault, syncs: () => true).remember(uuid(3), _anchor(1, 3), session, compared: true),
      ]);

      final read = await anchors.load(session);
      expect(read.of(uuid(1)), _anchor(5, 1), reason: 'the anchor moved on and wasn’t moved back');
      expect(read.hasCompared(uuid(1)), isTrue);
      expect(read.exportPolicyOf(uuid(1)), forbidding);
      expect(read.of(uuid(2)), _anchor(0, 2));
      expect(read.of(uuid(3)), _anchor(1, 3));
      expect(read.hasCompared(uuid(3)), isTrue);
    });

    test('goes on after a write that failed', () async {
      final session = await vault.setupVault('pw');
      await vault.saveEncryptedValue(keySpaceHeads, {'v': 3, 'anchors': <String, Object?>{}}, session);
      final anchors = SpaceAnchorStore(vault);
      await expectLater(anchors.remember(uuid(1), _anchor(1, 1), session), throwsA(isA<MalformedException>()));

      await vault.saveEncryptedValue(keySpaceHeads, SpaceAnchors().toJson(), session);
      await anchors.remember(uuid(1), _anchor(1, 1), session);
      expect((await anchors.load(session)).of(uuid(1)), _anchor(1, 1));
    });

    test('a carried value that can’t be read throws, and is never read as empty', () async {
      final session = await vault.setupVault('pw');
      await vault.saveEncryptedValue(keySpaceAnchorsSynced, {'v': 3, 'anchors': <String, Object?>{}}, session);
      await expectLater(SyncedSpaceAnchorStore(vault, syncs: () => true).load(session), throwsA(isA<MalformedException>()));
    });

    test('is deleted with its vault, and the other vault’s stays', () async {
      final session = await vault.setupVault('pw');
      await SyncedSpaceAnchorStore(vault, syncs: () => true).remember(uuid(1), _anchor(1, 1), session);
      final other = await vault.createVault('Work', 'work pw', listed: true);
      vaults.active = other;
      final otherSession = await vault.unlockVault('work pw');
      await SyncedSpaceAnchorStore(vault, syncs: () => true).remember(uuid(2), _anchor(2, 2), otherSession);

      vaults.removeVaultData(other);

      expect(store.getItem(vaults.vaultKey(keySpaceAnchorsSynced, other)), isNull);
      expect(store.getItem(keySpaceAnchorsSynced), isNotNull);
    });
  });
}
