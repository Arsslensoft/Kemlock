/// Runs the PGP sheets' work, one job at a time (openspec:
/// add-pgp-messages): it starts the job, holds off the inactivity lock
/// while the person waits for it, keeps track of the temporary files, and
/// stops and clears everything when the vault locks.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../vault/vault_controller.dart';
import '../settings/auto_lock.dart';
import 'pgp_files.dart';
import 'pgp_job.dart';

/// Starts a job; tests replace it with one that needs no isolate.
final pgpJobStarterProvider = Provider<PgpJob Function(PgpRequest request, {Directory? directory})>((ref) => startPgpJob);

/// Starts a job whose keys may be on a security key's card, with the
/// bridge their private step goes through (openspec: add-openpgp-card);
/// tests replace it as they replace [pgpJobStarterProvider].
final pgpCardJobStarterProvider = Provider<PgpJob Function(PgpRequest request, {Directory? directory, required PgpCardBridge card})>(
  (ref) =>
      (request, {directory, required card}) => startPgpJob(request, directory: directory, card: card),
);

/// A job under way: how far it has got, and whether it works on a file
/// (a progress bar) or on text (a spinner).
@immutable
class PgpJobStatus {
  const PgpJobStatus({required this.progress, required this.onFile});

  /// From 0 to 1.
  final double progress;
  final bool onFile;
}

/// The running job, or null when none is.
class PgpJobController extends Notifier<PgpJobStatus?> {
  PgpJob? _job;
  final _directories = <Directory>[];
  final _pickedCopies = <String>{};

  @override
  PgpJobStatus? build() {
    // A vault that locks takes the work, its files and its input with it
    ref.listen(vaultControllerProvider.select((state) => state.session), (_, session) {
      if (session == null) unawaited(discard());
    });
    ref.onDispose(() => _job?.cancel());
    return null;
  }

  bool get isRunning => _job != null;

  /// A new directory for what a job writes. It is deleted by [discard],
  /// and at once when its job fails or is cancelled.
  Future<Directory> newDirectory() async {
    final directory = await createPgpJobDirectory(await ref.read(pgpTempRootProvider)());
    _directories.add(directory);
    return directory;
  }

  /// Takes charge of the copy a picker left at [path]: it is deleted by
  /// [forget], by [discard], and when a job given it as its `pickedCopy`
  /// succeeds or is cancelled.
  void adopt(String path) => _pickedCopies.add(path);

  /// Deletes the picker's copy at [path], when the person removes the
  /// file from the sheet.
  Future<void> forget(String path) async {
    if (_pickedCopies.remove(path)) await deletePgpFile(path);
  }

  /// Runs [request] and gives its outcome. The inactivity lock is held
  /// off until it ends; [card] does the private step of a key on a card.
  /// [directory], where the job writes, is deleted
  /// unless it succeeds; [pickedCopy], a file a picker left for the job to
  /// read, is deleted unless it fails, so that a wrong passphrase can be
  /// tried again on the same file.
  ///
  /// Throws a [StateError] while another job runs.
  Future<PgpOutcome> run(PgpRequest request, {Directory? directory, String? pickedCopy, PgpCardBridge? card}) async {
    if (_job != null) throw StateError('a PGP job is already running');
    final release = ref.read(autoLockHoldsProvider).hold();
    final job = card == null
        ? ref.read(pgpJobStarterProvider)(request, directory: directory)
        : ref.read(pgpCardJobStarterProvider)(request, directory: directory, card: card);
    final onFile = request.inputPath != null;
    _job = job;
    state = PgpJobStatus(progress: 0, onFile: onFile);
    void onProgress() {
      if (identical(_job, job)) state = PgpJobStatus(progress: job.progress.value, onFile: onFile);
    }

    job.progress.addListener(onProgress);
    try {
      final outcome = await job.result;
      if (outcome is PgpFailedOutcome || outcome is PgpCancelledOutcome) {
        if (directory != null && _directories.remove(directory)) await deletePgpDirectory(directory);
      }
      if (pickedCopy != null && outcome is! PgpFailedOutcome) await forget(pickedCopy);
      return outcome;
    } finally {
      job.progress.removeListener(onProgress);
      release();
      if (identical(_job, job)) {
        _job = null;
        if (ref.mounted) state = null;
      }
    }
  }

  /// Stops the running job, whose [run] then gives [PgpCancelledOutcome].
  void cancel() => _job?.cancel();

  /// Stops the running job and deletes every file the sheets' work left:
  /// when a sheet closes, and when the vault locks.
  Future<void> discard() async {
    _job?.cancel();
    final directories = [..._directories];
    final copies = [..._pickedCopies];
    _directories.clear();
    _pickedCopies.clear();
    for (final directory in directories) {
      await deletePgpDirectory(directory);
    }
    for (final path in copies) {
      await deletePgpFile(path);
    }
  }
}

final pgpJobControllerProvider = NotifierProvider<PgpJobController, PgpJobStatus?>(PgpJobController.new);

/// The id of the vault key last chosen under "Sign as", so that the next
/// sheet offers it again. It is held in memory only and forgotten when the
/// vault locks: a stored default would name a hidden vault's key where a
/// locked phone can be read.
class PgpLastSigner extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(vaultControllerProvider.select((state) => state.session), (_, session) {
      if (session == null) state = null;
    });
    return null;
  }

  void choose(String keyId) => state = keyId;
}

final pgpLastSignerProvider = NotifierProvider<PgpLastSigner, String?>(PgpLastSigner.new);
