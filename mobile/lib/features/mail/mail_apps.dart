/// The mail apps the open vault allowed to use its PGP keys (openspec:
/// add-pgp-mail-provider, decision 5): one sealed value of the vault,
/// `backmycodes_mail_apps`, written once an app is approved and removed
/// with the last one, so a vault that never used the feature holds none.
/// It is in no export, backup, sync file or space: a package name and a
/// certificate mean something on one phone only. Being shaped like every
/// sealed value, a key-pair replacement seals it again with the rest.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/json.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_store.dart';

/// The storage key of the approvals, under the vault's own suffix.
const keyMailApps = 'backmycodes_mail_apps';

/// A mail app the vault approved: pinned to its package name and the
/// SHA-256 of the first certificate of its signing lineage.
@immutable
class MailApp {
  const MailApp({
    required this.package,
    required this.cert,
    required this.name,
    required this.allowedAt,
    this.keys = const [],
    this.unchecked = const [],
    this.extra = const {},
  });

  factory MailApp.fromJson(Map<String, Object?> json) => MailApp(
    package: asString(json['package']),
    cert: asString(json['cert']),
    name: asString(json['name']),
    allowedAt: asInt(json['allowedAt']) ?? 0,
    keys: [...?(json['keys'] as List<Object?>?)?.whereType<String>()],
    unchecked: [...?(json['unchecked'] as List<Object?>?)?.whereType<String>()],
    extra: extraKeys(json, _known),
  );

  static const _known = {'package', 'cert', 'name', 'allowedAt', 'keys', 'unchecked'};

  /// Its package name: `net.thunderbird.android`.
  final String package;

  /// The SHA-256 of the original certificate of its signing lineage, in
  /// hexadecimal.
  final String cert;

  /// Its label when it was approved, so Settings can name it without asking
  /// Android.
  final String name;

  /// Epoch ms it was allowed.
  final int allowedAt;

  /// The ids of the vault keys (`VaultKey.id`) it may sign and decrypt
  /// with: a key deleted from the vault drops out by itself.
  final List<String> keys;

  /// The fingerprints of unchecked keys it may encrypt to without asking,
  /// because the person chose to go on (decision 9).
  final List<String> unchecked;

  /// Fields a newer version wrote, kept as they were.
  final Map<String, Object?> extra;

  Map<String, Object?> toJson() => {
    'package': package,
    'cert': cert,
    'name': name,
    'allowedAt': allowedAt,
    'keys': keys,
    'unchecked': unchecked,
    ...extra,
  };

  MailApp copyWith({List<String>? keys, List<String>? unchecked}) => MailApp(
    package: package,
    cert: cert,
    name: name,
    allowedAt: allowedAt,
    keys: keys ?? this.keys,
    unchecked: unchecked ?? this.unchecked,
    extra: extra,
  );

  @override
  bool operator ==(Object other) => other is MailApp && const DeepCollectionEquality().equals(toJson(), other.toJson());

  @override
  int get hashCode => Object.hash(package, cert);

  @override
  String toString() => 'MailApp($package, $name, keys: $keys)';
}

/// Reads and writes the active vault's approvals.
class MailAppsStore {
  const MailAppsStore(this._store);

  final VaultStore _store;

  Future<List<MailApp>> load(VaultSession session) async {
    final stored = await _store.loadEncryptedValue(keyMailApps, session);
    if (stored is! List) return const [];
    return [for (final json in stored.whereType<Map<String, Object?>>()) MailApp.fromJson(json)];
  }

  /// Saves [apps], or removes the value when there are none.
  Future<void> save(List<MailApp> apps, VaultSession session) async {
    if (apps.isEmpty) {
      _store.removeEncryptedValue(keyMailApps);
      return;
    }
    await _store.saveEncryptedValue(keyMailApps, [for (final app in apps) app.toJson()], session);
  }
}

/// The open vault's approved mail apps, read when it opens and forgotten
/// when it locks. Empty while locked.
class MailApps extends Notifier<List<MailApp>> {
  Future<List<MailApp>>? _loading;
  VaultSession? _loadedFor;

  MailAppsStore get _apps => MailAppsStore(ref.read(vaultStoreProvider));

  @override
  List<MailApp> build() {
    ref.listen(vaultControllerProvider.select((state) => state.session), (_, session) {
      _loading = null;
      _loadedFor = null;
      state = const [];
      if (session != null) unawaited(current());
    });
    final session = ref.read(vaultControllerProvider).session;
    if (session != null) Future.microtask(current);
    return const [];
  }

  /// The list, once read for the open vault; empty while locked.
  Future<List<MailApp>> current() {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) return Future.value(const []);
    if (identical(_loadedFor, session) && _loading != null) return _loading!;
    _loadedFor = session;
    final loading = _loading = _apps.load(session).then((apps) {
      if (identical(_loadedFor, session) && ref.mounted) state = apps;
      return apps;
    });
    return loading;
  }

  /// The approval of [package], or null.
  Future<MailApp?> of(String package) async => (await current()).firstWhereOrNull((app) => app.package == package);

  /// Keeps [app], in place of any approval of its package.
  Future<void> put(MailApp app) async {
    final apps = await current();
    final index = apps.indexWhere((a) => a.package == app.package);
    await _save(index < 0 ? [...apps, app] : [for (final a in apps) a.package == app.package ? app : a]);
  }

  /// Lets the approved app [package] use the vault key [vaultKeyId] too.
  Future<void> allowKey(String package, String vaultKeyId) async {
    final app = await of(package);
    if (app == null || app.keys.contains(vaultKeyId)) return;
    await put(app.copyWith(keys: [...app.keys, vaultKeyId]));
  }

  /// Remembers that the person chose to encrypt from [package] to the
  /// unchecked keys with [fingerprints], without asking again.
  Future<void> goOn(String package, List<String> fingerprints) async {
    final app = await of(package);
    if (app == null) return;
    await put(app.copyWith(unchecked: {...app.unchecked, ...fingerprints}.toList()));
  }

  /// Forgets the approval of [package], its keys and what was remembered for it.
  Future<void> remove(String package) async {
    final apps = await current();
    await _save([...apps.where((a) => a.package != package)]);
  }

  Future<void> _save(List<MailApp> apps) async {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) throw StateError('the vault is locked');
    await _apps.save(apps, session);
    _loading = Future.value(apps);
    _loadedFor = session;
    state = apps;
  }
}

final mailAppsProvider = NotifierProvider<MailApps, List<MailApp>>(MailApps.new);
