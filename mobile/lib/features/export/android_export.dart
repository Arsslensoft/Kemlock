/// Another app's request for Kemlock's items on Android (openspec: plan add-credential-exchange,
/// task 8.4): Kemlock listed as an export source, the request the exported activity passes on once
/// it has checked the caller and the entry, and the line the lock screen shows while one waits for a
/// vault. The request carries no secret and no item: Dart reads nothing of the vault until the
/// vault is open and the person has passed the owner check in the sheet, and then answers through
/// the build's [CredentialExport].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/credential_exchange.dart';
import '../../ui/ui.dart';
import '../../vault/vault_providers.dart';
import '../import/credential_exchange.dart' show credentialTypesKept;
import 'credential_export.dart';

/// Sends to the app that asked, through the system's transfer. It answers once, or tells the app
/// nothing is coming. [onSettled] is told the request's id when it has done either, which is when the request's
/// five minutes ([PendingExportRequest]) stop running.
class AndroidExportTarget implements CredentialExportTarget {
  AndroidExportTarget(this._export, this.request, {this.onSettled});

  final CredentialExport _export;
  final ExportRequest request;
  final void Function(String id)? onSettled;

  @override
  String? get appName => request.app;

  @override
  String? get appPackage => request.package;

  @override
  Set<String>? get askedTypes => request.types;

  @override
  String? get vaultId => request.vaultId;

  @override
  Future<void> send(Future<String> Function() json) async {
    try {
      await _export.answerExport(request.id, await json());
    } on CredentialExportException {
      // The request is gone or the write failed; the problem is not worth more than that
      throw const CredentialExportFailed();
    } on NotInThisBuild {
      throw const CredentialExportFailed();
    } finally {
      // Sent, or failed: the request is over either way
      onSettled?.call(request.id);
    }
  }

  @override
  Future<void> cancel() async {
    onSettled?.call(request.id);
    await _export.refuseExport(request.id);
  }
}

/// Lists each vault the lock screen offers as an export source in other apps' imports, while export
/// is switched on, in the store build on Android. A failed registration is not shown: there is
/// nothing the person can do about it, and the entries stay as they were.
///
/// While export is switched off it asks once to take Kemlock out of the lists if any entry is registered (the plugin
/// answers that from the ids it keeps), so that a release that had export on and is switched back off is no longer
/// offered by the selector. A build that never had it on has no entry, and nothing is touched. It runs once per start,
/// and once it has cleared, the entries are gone and later starts touch nothing.
final credentialExportRegistrationProvider = FutureProvider<void>((ref) async {
  if (!ref.watch(credentialExportEnabledProvider)) {
    try {
      await ref.read(credentialExportProvider).clearExports();
    } on CredentialExportException {
      // Left as it was; the next start asks again
    } on NotInThisBuild {
      // The free build lists nothing
    }
    return;
  }
  final registry = ref.watch(vaultRegistryProvider);
  final vaults = [for (final id in registry.listedVaultIds()) ExportVault(vaultId: id, name: registry.vaultName(id))];
  try {
    await ref.read(credentialExportProvider).registerExports(vaults, credentialTypesKept);
  } on CredentialExportException {
    // Left as it was
  } on NotInThisBuild {
    // The free build lists nothing
  }
});

/// How long a request waits for a vault to be opened. The importer's screen waits on it, so it is
/// the short wait a shared item has, not the long one an iOS token has.
const exportRequestLife = Duration(minutes: 5);

/// The request another app made, kept in memory until a vault is open: the lock screen shows that
/// one waits, and the open vault's shell takes it and opens the export sheet on it. It is forgotten,
/// and its app told nothing is coming, when it is dropped ("Cancel it"), [exportRequestLife] after
/// it arrived, and when a newer one replaces it; [take] hands it to the sheet, which owns it from
/// then. The five minutes run on while the sheet has it, through the owner check and until the person sends
/// ([settled]): the importer's screen waits on it all that time, and a sheet left open must not hold it
/// for ever. Nothing is listened for while export is switched off.
class PendingExportRequest extends Notifier<ExportRequest?> {
  Timer? _timer;

  /// The request the sheet has taken and not yet settled, whose time is still running.
  ExportRequest? _taken;

  @override
  ExportRequest? build() {
    if (!ref.watch(credentialExportEnabledProvider)) {
      return null;
    }
    final export = ref.watch(credentialExportProvider);
    final sub = export.exportRequests.listen(_arrived);
    ref.onDispose(() {
      unawaited(sub.cancel());
      _timer?.cancel();
    });
    unawaited(
      export
          .pendingExport()
          .then((request) {
            if (request != null) {
              _arrived(request);
            }
          })
          .catchError((Object _) {}),
    );
    return null;
  }

  void _arrived(ExportRequest request) {
    final before = state;
    if (before != null && before.id != request.id) {
      // Replaced by a newer one, which the system has already cancelled the older for
      unawaited(ref.read(credentialExportProvider).refuseExport(before.id));
    }
    // A request the sheet holds is gone too, the system having cancelled it for the newer one
    _taken = null;
    state = request;
    _timer?.cancel();
    _timer = Timer(exportRequestLife, _expired);
  }

  /// The time ran out: the request, waiting or in the sheet, is dropped and its app told nothing is coming. A sheet
  /// still open finds the request gone when it sends.
  void _expired() {
    final request = state ?? _taken;
    state = null;
    _taken = null;
    if (request != null) {
      unawaited(ref.read(credentialExportProvider).refuseExport(request.id));
    }
  }

  /// The request, now the sheet's, and forgotten here. Its time keeps running until [settled].
  ExportRequest? take() {
    final request = state;
    state = null;
    if (request != null) {
      _taken = request;
    }
    return request;
  }

  /// The sheet is done with request [id]: it sent, or told the app nothing is coming. Its time stops.
  void settled(String id) {
    if (_taken?.id == id) {
      _taken = null;
      _timer?.cancel();
    }
  }

  /// Forgets the request and tells its app nothing is coming.
  void cancel() {
    final request = take();
    _taken = null;
    _timer?.cancel();
    if (request != null) {
      unawaited(ref.read(credentialExportProvider).refuseExport(request.id));
    }
  }
}

final pendingExportRequestProvider = NotifierProvider<PendingExportRequest, ExportRequest?>(PendingExportRequest.new);

/// Whether an export request waits for a vault to be opened, for the lock screen to show
/// [ExportRequestWaiting].
bool exportRequestWaits(WidgetRef ref) => ref.watch(pendingExportRequestProvider) != null;

/// The lock screen's line while a request waits. It says that an export waits and never to which
/// app or what it asks for, since the lock screen can be seen by whoever the phone was handed to.
/// "Cancel it" tells the app nothing is coming.
class ExportRequestWaiting extends ConsumerWidget {
  const ExportRequestWaiting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AppAlert(
    severity: AlertSeverity.info,
    child: Row(
      children: [
        Expanded(child: Text(context.t('export.cxf.lock.waiting'))),
        const SizedBox(width: 8),
        TextButton(
          style: smallButtonStyle,
          onPressed: () => ref.read(pendingExportRequestProvider.notifier).cancel(),
          child: Text(context.t('export.cxf.lock.notNow')),
        ),
      ],
    ),
  );
}
