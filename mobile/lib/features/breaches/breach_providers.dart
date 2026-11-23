import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../platform/network.dart';
import '../../vault/vault_controller.dart';
import 'breach_list.dart';
import 'breach_refresh.dart';
import 'breach_scan.dart';

Future<BreachList>? _bundled;

/// The copy of the breach list that ships with the app, read from [bundle] (the app's own
/// by default) the first time it is needed: at ~77 kB it would only slow down every start.
Future<BreachList> loadBundledBreaches({AssetBundle? bundle}) async {
  if (bundle != null) return _read(bundle);
  try {
    return await (_bundled ??= _read(rootBundle));
  } catch (_) {
    _bundled = null;
    rethrow;
  }
}

Future<BreachList> _read(AssetBundle bundle) async =>
    BreachList.fromJson(jsonDecode(await bundle.loadString(BreachList.asset, cache: false)) as Map<String, Object?>);

/// The copy of the breach list that ships with the app. Tests put a small list in its place.
final bundledBreachListProvider = FutureProvider<BreachList>((ref) => loadBundledBreaches());

/// The breach list in use: the copy that ships with the app, or the one the online update
/// stored if that is later. Loaded on first watch, and again when an update stores a list.
final breachListProvider = FutureProvider<BreachList>((ref) async {
  final refresh = ref.watch(breachRefreshProvider);
  watchKeys(ref, [keyBreachList]);
  return refresh.inUse(await ref.watch(bundledBreachListProvider.future));
});

/// Runs the online update for the open vault, if it has that turned on and the last
/// check is a day old. The list in use follows by itself when a newer one is stored.
/// While offline mode is on it does nothing, before anything else, so the time of
/// the last check stays as it was (openspec: add-offline-mode, decision 4).
Future<void> updateBreachList(WidgetRef ref) async {
  if (ref.read(offlineProvider)) return;
  final refresh = ref.read(breachRefreshProvider);
  final BreachList current;
  try {
    current = await ref.read(breachListProvider.future);
  } catch (_) {
    return;
  }
  await refresh.run(current);
}

/// The breaches of the open vault's accounts and backup-code lists; none while the vault
/// is locked or the list is still loading.
final breachFindingsProvider = Provider<BreachFindings>((ref) {
  final list = ref.watch(breachListProvider).value;
  final (unlocked, accounts, services) = ref.watch(
    vaultControllerProvider.select((vault) => (vault.isUnlocked, vault.accounts, vault.backupServices)),
  );
  if (list == null || !unlocked) return BreachFindings.none;
  return scanBreaches(accounts, services, list);
});
