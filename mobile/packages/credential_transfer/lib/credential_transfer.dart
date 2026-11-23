/// The Dart side of the Android plugin: one method channel, and the codes its errors carry. The
/// port that parts_store implements over it, `CredentialTransfer` in `kemlock_ports`, turns those
/// codes into its own problems.
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// The channel the plugin's Kotlin class answers on.
const credentialTransferChannel = MethodChannel('com.kemlock.app/credential_transfer');

/// The `code` of the [PlatformException] that [CredentialTransferPlugin.importCredentials] throws.
/// The person closing the list is not an error: that returns null.
abstract final class TransferErrorCodes {
  /// No app that can export holds the kinds asked for, or the one picked refused.
  static const noExportOption = 'noExportOption';

  /// The phone can't do it: Android before 8, or no Play services, or an old one.
  static const unavailable = 'unavailable';

  /// The other app's answer wasn't valid JSON.
  static const invalidJson = 'invalidJson';

  /// Android's own failure while the data moved.
  static const system = 'system';

  /// The system couldn't tell who the exporter was.
  static const unknownCaller = 'unknownCaller';

  /// Anything else the library reported.
  static const unknown = 'unknown';

  /// An import is already running.
  static const busy = 'busy';

  /// No screen to show the list on.
  static const noActivity = 'noActivity';

  /// The request asked for nothing.
  static const badRequest = 'badRequest';

  /// Export: the system refused to list Kemlock as an exporter, or Play services isn't there.
  static const registerFailed = 'registerFailed';

  /// Export: the request being answered is closed, replaced, or gone with the process.
  static const gone = 'gone';
}

/// An export request that passed the exported activity's checks and waits for the person: the
/// importer, the vault it was sent to and the credential types it asked for. Never the entry's
/// secret id, which Dart doesn't see.
class ExportRequestInfo {
  const ExportRequestInfo({required this.id, required this.vaultId, required this.app, required this.package, required this.types});

  /// Made for this request; the answer carries it.
  final String id;
  final String vaultId;

  /// The importer's name as the phone shows it.
  final String app;
  final String package;
  final Set<String> types;

  static ExportRequestInfo? fromMap(Object? map) {
    if (map is! Map) {
      return null;
    }
    final id = map['id'];
    final vaultId = map['vaultId'];
    final app = map['app'];
    final package = map['package'];
    if (id is! String || vaultId is! String || app is! String || package is! String) {
      return null;
    }
    return ExportRequestInfo(
      id: id,
      vaultId: vaultId,
      app: app,
      package: package,
      types: {if (map['types'] case final List<Object?> types) ...types.whereType<String>()},
    );
  }

  @override
  String toString() => 'ExportRequestInfo($package)';
}

/// `ProviderEventsManager.importCredentials`, from Dart.
class CredentialTransferPlugin {
  CredentialTransferPlugin({this.channel = credentialTransferChannel});

  /// The channel it asks on; a test passes one of its own.
  final MethodChannel channel;

  /// Whether this phone can start an import: Android 8 (API 26) and later. Whether Play services
  /// answers is known only when the list is asked for.
  Future<bool> isAvailable() async {
    try {
      return await channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens the system's list of apps that can export [types], and returns the CXF JSON the one the
  /// person picked sent; null when they closed the list. Throws a [PlatformException] whose code is
  /// one of [TransferErrorCodes].
  Future<String?> importCredentials(Set<String> types) => channel.invokeMethod<String>('importCredentials', {'types': types.toList()});

  /// Lists Kemlock as an exporter in other apps' imports: one entry for each of [vaults], a vault id
  /// with the name to show it by (null for none), each naming the credential [types] Kemlock writes
  /// and nothing of what the vault holds. It replaces every entry registered before; an empty list
  /// clears them. The entries' secret ids are made and kept on the Kotlin side, never here. Throws a
  /// [PlatformException] whose code is one of [TransferErrorCodes].
  Future<void> registerExports(List<({String vaultId, String? name})> vaults, Set<String> types) =>
      channel.invokeMethod<void>('registerExports', {
        'entries': [
          for (final vault in vaults) {'vaultId': vault.vaultId, 'account': vault.name},
        ],
        'types': types.toList(),
      });

  /// Takes Kemlock out of other apps' lists.
  Future<void> clearExports() => channel.invokeMethod<void>('clearExports');

  /// Takes Kemlock out of other apps' lists only when an entry is registered, which is what a build with export
  /// switched off asks once at start: a release that had it on and is switched back off stops being offered, and
  /// a build that never had it on touches nothing. Throws a [PlatformException] whose code is one of [TransferErrorCodes].
  Future<void> clearRegisteredExports() => channel.invokeMethod<void>('clearRegisteredExports');

  /// The export request that arrived and waits for the person, or null. Asked once the app is up,
  /// since a request can start the app.
  Future<ExportRequestInfo?> pendingExport() async {
    try {
      return ExportRequestInfo.fromMap(await channel.invokeMethod<Object?>('pendingExport'));
    } on MissingPluginException {
      return null;
    }
  }

  /// Requests that arrive while the app runs.
  Stream<ExportRequestInfo> get exportRequests {
    final events = _events ??= StreamController<ExportRequestInfo>.broadcast();
    channel.setMethodCallHandler((call) async {
      if (call.method == 'exportRequested') {
        final request = ExportRequestInfo.fromMap(call.arguments);
        if (request != null) {
          events.add(request);
        }
      }
    });
    return events.stream;
  }

  StreamController<ExportRequestInfo>? _events;

  /// Gives the CXF [json] to the importer of request [id], and ends the request. Throws a
  /// [PlatformException] whose code is [TransferErrorCodes.gone] when the request is no longer there.
  Future<void> answerExport(String id, String json) => channel.invokeMethod<void>('answerExport', {'id': id, 'json': json});

  /// Tells the importer of request [id] that nothing is coming. False when the request is gone.
  Future<bool> refuseExport(String id) async => await channel.invokeMethod<bool>('refuseExport', {'id': id}) ?? false;
}
