import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'app/app_closed_lock.dart';
import 'app/scratch_sweep.dart';
import 'core/providers.dart';
import 'core/storage/key_value_store.dart';
import 'core/storage/preferences_backend.dart';
import 'features/mail/mail_service.dart';
import 'features/pgp/pgp_files.dart';
import 'i18n/messages.dart';
import 'platform/network.dart';
import 'platform/scratch.dart';
import 'vault/vault_controller.dart';
import 'vault/vault_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));

  // A decrypted file that a killed app left waiting to be saved is gone before the lock screen shows.
  await sweepPgpTempAtStart();
  // So are the plain copies that picking, sharing or exporting a file left in the cache of a killed app.
  await sweepPhoneScratch();

  // The vault is read synchronously, so native storage is loaded before the first frame, as persist.ts did.
  final store = await KeyValueStore.open(CapacitorPreferences.forPlatform() ?? MemoryPreferences());
  final catalog = await MessageCatalog.load();
  final container = ProviderContainer(
    overrides: [keyValueStoreProvider.overrideWithValue(store), messageCatalogProvider.overrideWithValue(catalog)],
  );
  // The backstop of offline mode: while it is on, no dart:io HTTP client can be made, by this code or a
  // package's (openspec: add-offline-mode, decision 3). Here only, because flutter_test installs its own.
  HttpOverrides.global = GatedHttpOverrides(container.read(networkGateProvider));
  // An erase of every vault the app was killed in the middle of is finished, with what it does beside
  // storage, before anything reads a vault: what it left would open, perhaps with the erase setting gone.
  if (container.read(vaultRegistryProvider).finishCutShortErase()) container.read(vaultControllerProvider.notifier).wiped();
  // Locks when Android's main screen is closed for good, which no longer ends the engine (openspec:
  // add-pgp-mail-provider, decision 2).
  container.read(appClosedLockProvider);
  // Sweeps those copies again whenever a vault locks, is deleted or is erased.
  container.read(scratchSweeperProvider);
  // Answers Android mail apps' OpenPGP requests from launch, locked or not (add-pgp-mail-provider).
  container.read(mailServiceProvider);

  runApp(UncontrolledProviderScope(container: container, child: const KemlockApp()));
}
