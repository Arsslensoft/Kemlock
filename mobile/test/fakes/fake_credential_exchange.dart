import 'dart:async';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/features/export/credential_export.dart';
import 'package:kemlock/platform/credential_exchange.dart';

/// Stands in for Android's list of apps that can export (the build's [CredentialTransfer]): what it
/// answers, how often it was asked and for which credential types.
class FakeCredentialTransfer implements CredentialTransfer {
  FakeCredentialTransfer({this.available = true, this.answer, this.problem});

  /// Whether this phone and build can start a transfer.
  bool available;

  /// The CXF JSON the person's pick sends; null when they close the list.
  String? answer;

  /// The failure to throw instead of answering.
  Object? problem;

  /// The credential types of each time the list was opened.
  final List<Set<String>> asked = [];

  Override get asOverride => credentialTransferProvider.overrideWithValue(this);

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<String?> importCredentials(Set<String> types) async {
    asked.add(types);
    final failure = problem;
    if (failure != null) {
      throw failure;
    }
    return answer;
  }
}

/// Stands in for iOS's hand-off from another app: the token the app was opened with, those [send]
/// delivers while it runs, and the JSON [fetch] answers, with a note of every time it was asked.
class FakeIosCredentialExchange implements IosCredentialExchange {
  FakeIosCredentialExchange({this.opening, this.json = '', this.isSupported = true, this.fails = false});

  /// The token the app was opened with, handed over once.
  String? opening;

  /// What the system's data comes back as.
  String json;

  final bool isSupported;

  /// Whether the system refuses the token.
  bool fails;

  /// The token of each time the data was asked for.
  final List<String> fetches = [];

  final _incoming = StreamController<String>.broadcast();

  Override get asOverride => iosCredentialExchangeProvider.overrideWithValue(this);

  /// The system launches the app with [token] while it runs.
  void send(String token) => _incoming.add(token);

  @override
  Future<bool> supported() async => isSupported;

  @override
  Future<String?> initial() async {
    final token = opening;
    opening = null;
    return token;
  }

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Future<String> fetch(String token) async {
    fetches.add(token);
    if (fails) {
      throw const IosExchangeFailed();
    }
    return json;
  }

  /// What the person did in the system's sheet of apps when an export was handed over: null sends it,
  /// anything else is thrown instead.
  Object? exportOutcome;

  /// A system sheet the person has not gone on in yet: while it is set, [export] waits for it before it asks for the
  /// payload, as the system does for the person's choice of app.
  Completer<void>? sheet;

  /// How many times the system asked for the payload.
  int produced = 0;

  /// The CXF JSON of each export the system took.
  final List<String> exported = [];

  @override
  Future<void> export(Future<String> Function() json) async {
    final pending = sheet;
    if (pending != null) {
      await pending.future;
    }
    final outcome = exportOutcome;
    if (outcome != null) {
      throw outcome;
    }
    produced++;
    try {
      exported.add(await json());
    } on Object {
      // The channel tells the system a failure with no text
      throw const IosExchangeFailed();
    }
  }
}

/// Stands in for the other app an export goes to: what it asked for, what it was sent, and whether it
/// was told nothing is coming.
class FakeExportTarget implements CredentialExportTarget {
  FakeExportTarget({this.appName, this.appPackage, this.askedTypes, this.vaultId, this.outcome});

  @override
  final String? appName;

  @override
  final String? appPackage;

  @override
  final Set<String>? askedTypes;

  @override
  final String? vaultId;

  /// What [send] throws instead of taking the data.
  Object? outcome;

  /// The CXF JSON of each send.
  final List<String> sent = [];

  /// How many times the other app was told nothing is coming.
  int cancelled = 0;

  @override
  Future<void> send(Future<String> Function() json) async {
    final failure = outcome;
    if (failure != null) {
      throw failure;
    }
    sent.add(await json());
  }

  @override
  Future<void> cancel() async => cancelled++;
}

/// Stands in for Kemlock as an export source on Android (the build's [CredentialExport]): what was
/// registered, the request that was waiting, those [send] delivers, and what was answered or refused.
class FakeCredentialExport implements CredentialExport {
  FakeCredentialExport({this.waiting, this.answerProblem, this.clearProblem});

  /// The request that arrived before Dart was up, handed over once.
  ExportRequest? waiting;

  /// The problem [answerExport] throws instead of answering.
  CredentialExportProblem? answerProblem;

  /// The problem [clearExports] throws.
  CredentialExportProblem? clearProblem;

  /// The vaults of each registration, with the credential types it named.
  final List<({List<ExportVault> vaults, Set<String> types})> registrations = [];

  /// The id and JSON of each answer.
  final List<({String id, String json})> answers = [];

  /// The id of each refusal.
  final List<String> refused = [];

  /// How many times Dart asked to take Kemlock out of other apps' lists.
  int cleared = 0;

  /// How many times Dart asked for the waiting request.
  int asked = 0;

  final _incoming = StreamController<ExportRequest>.broadcast();

  Override get asOverride => credentialExportProvider.overrideWithValue(this);

  /// Another app's request arrives while the app runs.
  void send(ExportRequest request) => _incoming.add(request);

  @override
  Future<void> registerExports(List<ExportVault> vaults, Set<String> types) async {
    registrations.add((vaults: vaults, types: types));
  }

  @override
  Future<void> clearExports() async {
    cleared++;
    final problem = clearProblem;
    if (problem != null) {
      throw CredentialExportException(problem);
    }
  }

  @override
  Future<ExportRequest?> pendingExport() async {
    asked++;
    final request = waiting;
    waiting = null;
    return request;
  }

  @override
  Stream<ExportRequest> get exportRequests => _incoming.stream;

  @override
  Future<void> answerExport(String id, String json) async {
    final problem = answerProblem;
    if (problem != null) {
      throw CredentialExportException(problem);
    }
    answers.add((id: id, json: json));
  }

  @override
  Future<void> refuseExport(String id) async => refused.add(id);
}
