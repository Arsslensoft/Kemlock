import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kemlock_parts/kemlock_parts.dart' as parts;
import 'package:kemlock_ports/kemlock_ports.dart' show CredentialExport, CredentialTransfer;

export 'package:kemlock_ports/kemlock_ports.dart'
    show
        CredentialExport,
        CredentialExportException,
        CredentialExportProblem,
        CredentialTransfer,
        CredentialTransferException,
        CredentialTransferProblem,
        ExportRequest,
        ExportVault,
        NotInThisBuild;

/// The system's list of apps that can export to Kemlock, on Android in the store build (openspec:
/// plan add-credential-exchange, design decision 8). Tests put a fake in its place.
final credentialTransferProvider = Provider<CredentialTransfer>((ref) => parts.makeCredentialTransfer());

/// Kemlock as a source other apps' imports list, on Android in the store build; the free build's does
/// nothing. Switched off with the rest of export until plan add-credential-exchange, task 8.6, passes.
/// Tests put a fake in its place.
final credentialExportProvider = Provider<CredentialExport>((ref) => parts.makeCredentialExport());

/// Another app's export on iOS 26 and later (design decision 7): the other app starts it, the system
/// launches Kemlock with a token, and Kemlock reads the data only once a vault is open.
abstract interface class IosCredentialExchange {
  /// Whether this phone takes part: iOS 26 and later.
  Future<bool> supported();

  /// The token the app was opened with, once; null when there was none.
  Future<String?> initial();

  /// Tokens that arrive while the app runs.
  Stream<String> get incoming;

  /// Reads the export behind [token] and answers its CXF JSON. Throws [IosExchangeFailed].
  Future<String> fetch(String token);

  /// Hands CXF JSON to another app (`ASCredentialExportManager`, plan task 8.3). The system's sheet opens first
  /// and asks the person which app; only once they have chosen and gone on is [json] called for the payload, so no
  /// plaintext waits in memory while they decide, and it is never called if they close the sheet. [json] is called
  /// at most once, and whatever it throws is told to the system as a failure with no text. Throws
  /// [IosExportCancelled] when the person closes the system's sheet, and [IosExchangeFailed] for any other end.
  Future<void> export(Future<String> Function() json);
}

/// The person closed the system's list of apps without choosing one.
class IosExportCancelled implements Exception {
  const IosExportCancelled();

  @override
  String toString() => 'IosExportCancelled';
}

/// The export behind a token could not be read: the system refused the token, or its data could not
/// be written as JSON. It carries nothing of the data.
class IosExchangeFailed implements Exception {
  const IosExchangeFailed();

  @override
  String toString() => 'IosExchangeFailed';
}

/// [IosCredentialExchange] over the app's method channel (ios/Runner/CredentialExchangeChannel.swift).
class ChannelIosCredentialExchange implements IosCredentialExchange {
  ChannelIosCredentialExchange() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'token' && call.arguments is String) {
        _incoming.add(call.arguments as String);
      } else if (call.method == 'exportJson') {
        // The system's sheet is done and the person went on: this is the one time the payload is made
        final produce = _producer;
        _producer = null;
        if (produce == null) {
          throw PlatformException(code: 'gone');
        }
        try {
          return await produce();
        } on Object {
          // Never the error: it could hold what was being written
          throw PlatformException(code: 'failed');
        }
      }
      return null;
    });
  }

  static const _channel = MethodChannel('com.kemlock.app/credential_exchange');
  final _incoming = StreamController<String>.broadcast();

  /// What makes the payload of the export under way, held until the system asks for it, once.
  Future<String> Function()? _producer;

  @override
  Future<bool> supported() async {
    try {
      return await _channel.invokeMethod<bool>('supported') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<String?> initial() async {
    try {
      return await _channel.invokeMethod<String>('initial');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Future<String> fetch(String token) async {
    try {
      return await _channel.invokeMethod<String>('fetch', {'token': token}) ?? (throw const IosExchangeFailed());
    } on PlatformException {
      throw const IosExchangeFailed();
    } on MissingPluginException {
      throw const IosExchangeFailed();
    }
  }

  @override
  Future<void> export(Future<String> Function() json) async {
    // Native asks for the payload over this channel once the person has chosen an app: no JSON goes with the call
    _producer = json;
    try {
      await _channel.invokeMethod<void>('export');
    } on PlatformException catch (error) {
      // The code only: an error never carries the data
      throw error.code == 'cancelled' ? const IosExportCancelled() : const IosExchangeFailed();
    } on MissingPluginException {
      throw const IosExchangeFailed();
    } finally {
      _producer = null;
    }
  }
}

/// What every phone but an iPhone has: no hand-off to answer.
class NoIosCredentialExchange implements IosCredentialExchange {
  const NoIosCredentialExchange();

  @override
  Future<bool> supported() async => false;

  @override
  Future<String?> initial() async => null;

  @override
  Stream<String> get incoming => const Stream.empty();

  @override
  Future<String> fetch(String token) async => throw const IosExchangeFailed();

  @override
  Future<void> export(Future<String> Function() json) async => throw const IosExchangeFailed();
}

/// The phone's hand-off from another app on iOS; tests put a fake in its place.
final iosCredentialExchangeProvider = Provider<IosCredentialExchange>(
  (ref) => defaultTargetPlatform == TargetPlatform.iOS ? ChannelIosCredentialExchange() : const NoIosCredentialExchange(),
);
