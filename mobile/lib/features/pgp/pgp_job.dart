/// One PGP action, text or file, run in a background isolate that Cancel
/// kills (openspec: add-pgp-messages). It is built like `KeyGeneration`: a
/// request that holds only bytes, strings and paths goes in; progress, then
/// a typed result or a typed error, comes back. A passphrase and an
/// unlocked key live in the job's isolate alone, whose memory is freed when
/// it ends.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../crypto/keys/pgp.dart' as pgp;

/// A vault key to sign or decrypt with, as the vault keeps it.
@immutable
class PgpJobKey {
  const PgpJobKey(this.secretKey, {this.passphrase, this.onCard = false});

  /// The binary transferable secret key.
  final Uint8List secretKey;

  /// Its passphrase, when it keeps one and the person just typed it.
  final String? passphrase;

  /// Whether its secret parts are on a security key's OpenPGP card, so
  /// that [secretKey] is GnuPG's stub and the job asks the app's
  /// [PgpCardBridge] for the private step (openspec: add-openpgp-card).
  final bool onCard;

  pgp.PgpSecretKey _secret(PgpCardBridge? card) => pgp.PgpSecretKey(
    secretKey,
    passphrase: passphrase,
    elsewhere: !onCard || card == null
        ? null
        : pgp.DelegatedSecret(
            sign: (key, digest) => card.sign(key.packet.encoded, digest),
            decipher: (key, input) => card.decipher(key.packet.encoded, input),
          ),
  );
}

/// Where a job's private step for a key on a card is done: on the UI
/// isolate, which reaches the security key (openspec: add-openpgp-card,
/// design decision 6). Each key is named by the bytes of its key packet.
/// Anything that stops the step (the person cancelled, the wrong card, a
/// signature that did not verify) throws [pgp.PgpProblem.cancelled], and the
/// job ends with nothing made; the bridge itself says why.
abstract interface class PgpCardBridge {
  /// The signature MPIs of the key over the SHA-512 [digest], checked.
  Future<Uint8List> sign(Uint8List keyPacket, Uint8List digest);

  /// The card's half of opening a session key to the key: from the RSA
  /// cryptogram or the ECDH point [input], the session key's encoding or
  /// the shared secret.
  Future<Uint8List> decipher(Uint8List keyPacket, Uint8List input);
}

/// What to do. Exactly one of the text and the path of a request is set.
sealed class PgpRequest {
  const PgpRequest({required this.now});

  /// The clock of the app when the work was asked for: the time a signature
  /// says it was made, and the time keys are judged expired at.
  final DateTime now;

  /// The file the work reads, whose size the progress is measured against;
  /// null when it works on text.
  String? get inputPath;
}

/// Encrypt [text] or the file at [inputPath] to [recipients] (binary
/// transferable public keys) or, with none, to [passphrase]. A file's
/// result is written to [outputPath]. [text] is armored unless [binary],
/// which the mail provider asks for when a mail app does.
final class EncryptRequest extends PgpRequest {
  const EncryptRequest({
    required super.now,
    this.text,
    this.inputPath,
    this.fileName = '',
    this.outputPath,
    this.recipients = const [],
    this.passphrase,
    this.signer,
    this.binary = false,
  });

  final Uint8List? text;
  @override
  final String? inputPath;
  final bool binary;
  final String fileName;
  final String? outputPath;
  final List<Uint8List> recipients;
  final String? passphrase;
  final PgpJobKey? signer;
}

/// Decrypt [text] or the file at [inputPath] with whichever of [keys] opens
/// it, else with [passphrase]. Content over [maxInMemory] is written into
/// [outputDirectory]; without one, as for the mail provider, which writes
/// nothing to storage, it is [pgp.PgpProblem.tooLarge].
final class DecryptRequest extends PgpRequest {
  const DecryptRequest({
    required super.now,
    this.text,
    this.inputPath,
    this.inputName,
    required this.outputDirectory,
    this.keys = const [],
    this.passphrase,
    this.verifiers = const [],
    this.maxInMemory = pgp.maxPgpTextLength,
  });

  final Uint8List? text;
  @override
  final String? inputPath;
  final String? inputName;
  final String? outputDirectory;
  final int maxInMemory;
  final List<PgpJobKey> keys;
  final String? passphrase;
  final List<Uint8List> verifiers;
}

/// Sign: [text] as clear-signed text, or the file at [inputPath] with a
/// detached signature; or either in [form], as the mail provider asks.
final class SignRequest extends PgpRequest {
  const SignRequest({required super.now, this.text, this.inputPath, required this.signer, this.form});

  final Uint8List? text;
  @override
  final String? inputPath;
  final PgpJobKey signer;
  final pgp.PgpSignatureForm? form;
}

/// Verify [text] (clear-signed text or a signed message), or the file at
/// [inputPath] against the detached signature in [signature] or at
/// [signaturePath].
final class VerifyRequest extends PgpRequest {
  const VerifyRequest({required super.now, this.text, this.inputPath, this.signature, this.signaturePath, this.verifiers = const []});

  final Uint8List? text;
  @override
  final String? inputPath;
  final Uint8List? signature;
  final String? signaturePath;
  final List<Uint8List> verifiers;
}

/// How a job ended.
sealed class PgpOutcome {
  const PgpOutcome();
}

/// The armored message of a text (binary when the request said so), or
/// null when a file was written to the request's `outputPath`.
final class PgpEncryptedOutcome extends PgpOutcome {
  const PgpEncryptedOutcome(this.armored);

  final Uint8List? armored;
}

final class PgpDecryptedOutcome extends PgpOutcome {
  const PgpDecryptedOutcome(this.message);

  final pgp.PgpDecrypted message;
}

/// Clear-signed text, or a file's detached signature.
final class PgpSignedOutcome extends PgpOutcome {
  const PgpSignedOutcome(this.bytes);

  final Uint8List bytes;
}

final class PgpVerifiedOutcome extends PgpOutcome {
  const PgpVerifiedOutcome(this.verified);

  final pgp.PgpVerified verified;
}

/// The work could not be done; [error] says why.
final class PgpFailedOutcome extends PgpOutcome {
  const PgpFailedOutcome(this.error);

  final pgp.PgpException error;
}

/// Cancelled, or stopped because the vault locked: nothing was made.
final class PgpCancelledOutcome extends PgpOutcome {
  const PgpCancelledOutcome();
}

/// Does [request] on the calling isolate. [startPgpJob] runs this in the
/// background; tests and fakes call it directly. [onProgress] gets the
/// part of the input file read so far, from 0 to 1. [isCancelled] is asked
/// after each piece of a file: once it says yes the work stops, its files
/// are closed, and the outcome is [PgpCancelledOutcome].
Future<PgpOutcome> runPgpRequest(
  PgpRequest request, {
  void Function(double progress)? onProgress,
  bool Function()? isCancelled,
  PgpCardBridge? card,
}) async {
  final path = request.inputPath;
  final total = path == null ? 0 : File(path).lengthSync();
  void onRead(int read) {
    if (isCancelled?.call() ?? false) throw const pgp.PgpException(pgp.PgpProblem.cancelled);
    if (total > 0) onProgress?.call(read >= total ? 1 : read / total);
  }

  pgp.PgpData data(Uint8List? text) => path != null ? pgp.PgpData.file(path) : pgp.PgpData.bytes(text!);

  try {
    onProgress?.call(0);
    final PgpOutcome outcome;
    switch (request) {
      case EncryptRequest():
        outcome = PgpEncryptedOutcome(
          await pgp.encrypt(
            data: data(request.text),
            recipients: request.recipients,
            passphrase: request.passphrase,
            signer: request.signer?._secret(card),
            text: path == null && !request.binary,
            fileName: request.fileName,
            outputPath: request.outputPath,
            now: request.now,
            onRead: onRead,
          ),
        );
      case DecryptRequest():
        outcome = PgpDecryptedOutcome(
          await pgp.decrypt(
            data: data(request.text),
            keys: [for (final key in request.keys) key._secret(card)],
            passphrase: request.passphrase,
            verifiers: request.verifiers,
            outputDirectory: request.outputDirectory,
            inputName: request.inputName,
            maxInMemory: request.maxInMemory,
            now: request.now,
            onRead: onRead,
          ),
        );
      case SignRequest():
        outcome = PgpSignedOutcome(
          await pgp.sign(
            data: data(request.text),
            signer: request.signer._secret(card),
            form: request.form ?? (path == null ? pgp.PgpSignatureForm.cleartext : pgp.PgpSignatureForm.detached),
            now: request.now,
          ),
        );
      case VerifyRequest():
        final signature = request.signaturePath != null
            ? pgp.PgpData.file(request.signaturePath!)
            : request.signature == null
            ? null
            : pgp.PgpData.bytes(request.signature!);
        outcome = PgpVerifiedOutcome(
          signature == null
              ? await pgp.verify(signed: data(request.text), verifiers: request.verifiers, now: request.now, onRead: onRead)
              : await pgp.verify(
                  signed: signature,
                  data: data(request.text),
                  verifiers: request.verifiers,
                  now: request.now,
                  onRead: onRead,
                ),
        );
    }
    onProgress?.call(1);
    return outcome;
  } on pgp.PgpException catch (error) {
    return error.problem == pgp.PgpProblem.cancelled ? const PgpCancelledOutcome() : PgpFailedOutcome(error);
  }
}

/// A PGP action under way. [result] completes with its outcome, or with
/// [PgpCancelledOutcome] once [cancel] has stopped it; it never completes
/// with an error.
abstract interface class PgpJob {
  /// The part of the input read so far, from 0 to 1.
  ValueListenable<double> get progress;

  Future<PgpOutcome> get result;

  /// Stops the work; does nothing once it has finished.
  void cancel();
}

/// Starts [request] in a background isolate. [directory] is the job's
/// own, where its request writes: it is deleted, with whatever partial
/// output it holds, when the job is cancelled or fails. With [card], a key
/// of the request that is on a card has its private step done by it, on
/// this isolate.
PgpJob startPgpJob(PgpRequest request, {Directory? directory, PgpCardBridge? card}) => _IsolatePgpJob(request, directory, card);

/// What a job's isolate asks of the card bridge, and its answer.
const _cardSign = 'card sign';
const _cardDecipher = 'card decipher';

/// How long a job asked to stop is given to close its files and go,
/// before its isolate is killed.
const _stopGrace = Duration(seconds: 2);

class _IsolatePgpJob implements PgpJob {
  _IsolatePgpJob(PgpRequest request, this._directory, this._card) {
    unawaited(_start(request));
  }

  final Directory? _directory;
  final PgpCardBridge? _card;
  final _done = Completer<PgpOutcome>();
  final _progress = ValueNotifier<double>(0);
  Isolate? _isolate;
  RawReceivePort? _port;
  Timer? _kill;
  var _cancelled = false;
  var _finishing = false;

  /// A file in the job's directory whose appearing tells the isolate to
  /// stop. An isolate deep in a file hears nothing else, and one that is
  /// killed leaves its files open, which on some systems keeps them from
  /// being deleted; asked this way, it closes them and goes.
  File? get _stopFile => _directory == null ? null : File('${_directory.path}${Platform.pathSeparator}.stop');

  @override
  ValueListenable<double> get progress => _progress;

  @override
  Future<PgpOutcome> get result => _done.future;

  @override
  void cancel() {
    if (_done.isCompleted || _cancelled) return;
    _cancelled = true;
    final stopFile = _stopFile;
    var asked = false;
    if (stopFile != null) {
      try {
        stopFile.createSync();
        asked = true;
      } on FileSystemException {
        // No directory to leave the note in: the isolate is killed instead
      }
    }
    if (asked) {
      _kill = Timer(_stopGrace, () => _isolate?.kill(priority: Isolate.immediate));
    } else {
      _isolate?.kill(priority: Isolate.immediate);
    }
  }

  Future<void> _finish(PgpOutcome outcome) async {
    if (_finishing) return;
    _finishing = true;
    _kill?.cancel();
    _port?.close();
    final result = _cancelled ? const PgpCancelledOutcome() : outcome;
    final directory = _directory;
    if (directory != null && (result is PgpFailedOutcome || result is PgpCancelledOutcome)) await _deleteDirectory(directory);
    try {
      final stopFile = _stopFile;
      if (stopFile != null && stopFile.existsSync()) stopFile.deleteSync();
    } on FileSystemException {
      // Gone with its directory
    }
    if (!_done.isCompleted) _done.complete(result);
  }

  Future<void> _start(PgpRequest request) async {
    final port = _port = RawReceivePort();
    port.handler = (Object? message) {
      switch (message) {
        case double():
          if (!_done.isCompleted && !_cancelled) _progress.value = message;
        case PgpOutcome():
          unawaited(_finish(message));
        case [final String ask, final Uint8List key, final Uint8List input, final SendPort reply]
            when ask == _cardSign || ask == _cardDecipher:
          unawaited(_answerCard(ask, key, input, reply));
        case [final Object? error, _]:
          // Nothing but a PgpException should leave the message code
          unawaited(_finish(PgpFailedOutcome(pgp.PgpException(pgp.PgpProblem.damaged, detail: '$error'))));
        default:
          // The isolate went without a word: killed
          unawaited(_finish(const PgpFailedOutcome(pgp.PgpException(pgp.PgpProblem.damaged, detail: 'the job stopped without a result'))));
      }
    };
    try {
      final isolate = await Isolate.spawn(
        _run,
        (port.sendPort, request, _stopFile?.path, _card != null),
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      _isolate = isolate;
      // Cancelled while the isolate was starting, with nowhere to say so
      if (_cancelled && _kill == null) isolate.kill(priority: Isolate.immediate);
    } on Object catch (error) {
      unawaited(_finish(PgpFailedOutcome(pgp.PgpException(pgp.PgpProblem.damaged, detail: '$error'))));
    }
  }
}

extension on _IsolatePgpJob {
  /// Does what the job's isolate asked of the card, and sends the answer
  /// back: the bytes, or null when the step was stopped.
  Future<void> _answerCard(String ask, Uint8List key, Uint8List input, SendPort reply) async {
    final card = _card;
    try {
      if (card == null || _cancelled) throw const pgp.PgpException(pgp.PgpProblem.cancelled);
      reply.send(ask == _cardSign ? await card.sign(key, input) : await card.decipher(key, input));
    } on Object {
      reply.send(null);
    }
  }
}

/// The card bridge as the job's isolate sees it: each step is asked of
/// the UI isolate over [_port] and waited for.
class _PortCardBridge implements PgpCardBridge {
  _PortCardBridge(this._port);

  final SendPort _port;

  Future<Uint8List> _ask(String what, Uint8List key, Uint8List input) async {
    final answer = ReceivePort();
    try {
      _port.send([what, key, input, answer.sendPort]);
      final reply = await answer.first;
      if (reply is Uint8List) return reply;
      throw const pgp.PgpException(pgp.PgpProblem.cancelled);
    } finally {
      answer.close();
    }
  }

  @override
  Future<Uint8List> sign(Uint8List keyPacket, Uint8List digest) => _ask(_cardSign, keyPacket, digest);

  @override
  Future<Uint8List> decipher(Uint8List keyPacket, Uint8List input) => _ask(_cardDecipher, keyPacket, input);
}

Future<void> _deleteDirectory(Directory directory) async {
  // A file the isolate had open may take a moment to be let go of
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

Future<void> _run((SendPort, PgpRequest, String?, bool) message) async {
  final (port, request, stopPath, card) = message;
  final stopFile = stopPath == null ? null : File(stopPath);
  var sent = -1.0;
  final outcome = await runPgpRequest(
    request,
    isCancelled: stopFile?.existsSync,
    card: card ? _PortCardBridge(port) : null,
    onProgress: (progress) {
      // A message for each hundredth is plenty for a progress bar
      if (progress < 1 && progress - sent < 0.01) return;
      sent = progress;
      port.send(progress);
    },
  );
  Isolate.exit(port, outcome);
}
