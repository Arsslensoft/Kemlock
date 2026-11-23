import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../platform/device_keys.dart';
import '../../vault/attachment_store.dart';
import '../../vault/vault_store.dart';
import '../duplicates/duplicate_normalise.dart' show SiteResolver;
import '../spaces/space_head_store.dart';
import 'kemlock/km_api.dart';
import 'kemlock/km_auth_api.dart' show KmPushToken;
import 'kemlock/km_dedup_api.dart' show KmHints;
import 'kemlock/km_dpop.dart';
import 'kemlock/km_failover.dart' show KmAway;
import 'kemlock/km_files.dart';
import 'kemlock/km_host.dart';
import 'kemlock/km_models.dart' show KemlockTarget;
import 'kemlock/km_session.dart';
import 'kemlock/km_sync.dart' show KmAnchors;

/// The open vault's sealed values, as [KmHost] reads and writes them: the session, the account and the cache.
class VaultKmValues implements KmVaultValues {
  VaultKmValues(this.vault, this.session);

  final VaultStore vault;
  final VaultSession session;

  @override
  Future<Object?> load(String key) => vault.loadEncryptedValue(key, session);

  @override
  Future<void> save(String key, Object? value) => vault.saveEncryptedValue(key, value, session);

  @override
  void remove(String key) => vault.removeEncryptedValue(key);
}

/// The proofs a session's device key signs, found again by its reference (a hardware key's tag, or the software key
/// sealed with the session). Null when the phone lost the key.
Future<KmProofs?> kmProofsFor(DeviceKeys keys, KmSession session) async {
  final choice = await openDeviceKey(keys, session.deviceKey);
  return choice == null ? null : KmDpop(choice.key);
}

/// Makes the Kemlock Server sync of the open vault: the host the scheduler runs and "Turn off" signs out through.
KmHost makeKmHost({
  required VaultStore vault,
  required VaultSession session,
  required http.Client Function(String? pin) clientFor,
  required DeviceKeys deviceKeys,
  KmFileStore? files,
  KmAnchors? anchors,
  DateTime Function() clock = DateTime.now,
  void Function(KmAway? away)? onAway,
  Future<KmPushToken?> Function()? pushToken,
  void Function(KemlockTarget next)? onList,
  Future<SiteResolver> Function()? dedupSites,
  void Function(KmHints hints)? onHints,
  void Function(bool enabled)? onMatching,
}) => KmHost(
  values: VaultKmValues(vault, session),
  clientFor: clientFor,
  proofsFor: (stored) => kmProofsFor(deviceKeys, stored),
  fileStore: files,
  anchors: anchors,
  clock: clock,
  onAway: onAway,
  pushToken: pushToken,
  onList: onList,
  dedupSites: dedupSites,
  onHints: onHints,
  onMatching: onMatching,
);

/// [KmFileStore] over the app's attachment store, for one vault.
class VaultKmFiles implements KmFileStore {
  VaultKmFiles(this.store, this.vaultId);

  final AttachmentStore store;
  final String vaultId;

  @override
  Future<bool> exists(String id) => store.exists(vaultId, id);

  @override
  Future<Uint8List?> readSealed(String id) => store.readSealed(vaultId, id);

  @override
  Future<void> writeSealed(String id, Uint8List sealed) => store.writeSealed(vaultId, id, sealed);
}

/// The anchors of the account's server spaces in [store], as a Kemlock Server run carries them: none when the vault
/// holds none, so a run with nothing to carry writes nothing.
KmAnchors kmAnchorsOf(SpaceAnchorStorage store, VaultSession session) => KmAnchors(
  load: () async {
    final anchors = await store.load(session);
    return anchors.length == 0 && anchors.extra.isEmpty ? null : anchors.toJson();
  },
  save: (anchors) => store.save(SpaceAnchors.fromJson(anchors), session),
);
