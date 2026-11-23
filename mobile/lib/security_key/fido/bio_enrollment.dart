/// The fingerprints on a key with a reader (`authenticatorBioEnrollment`,
/// CTAP 2.1 section 6.7): the list, adding one touch by touch, renaming
/// and removing. The standard command (`0x09`) and the preview one
/// (`0x40`) share one implementation, given the command byte.
library;

import 'dart:typed_data';

import '../cbor.dart';
import '../connection.dart';
import 'client_pin.dart';
import 'ctap.dart';

/// What `fingerprint` is called in the command's `modality` member.
const _fingerprint = 1;

/// A fingerprint enrolled on a key.
class KeyFingerprint {
  const KeyFingerprint(this.id, this.name);

  final Uint8List id;

  /// The name it was given, if any.
  final String? name;
}

/// What a key says of its reader.
class FingerprintSensor {
  const FingerprintSensor({required this.maxSamples, this.maxNameBytes});

  /// How many good touches the key asks for to enrol a fingerprint, at most.
  final int maxSamples;

  /// The longest name the key keeps, in bytes, when it says.
  final int? maxNameBytes;
}

/// What the key made of one touch of the reader.
enum FingerprintSample {
  good,
  tooHigh,
  tooLow,
  tooLeft,
  tooRight,
  tooFast,
  tooSlow,
  poorQuality,
  tooSkewed,
  tooShort,
  mergeFailure,
  alreadyEnrolled,
  noActivity,
  other;

  static FingerprintSample fromStatus(Object? status) => switch (status) {
    0 => good,
    1 => tooHigh,
    2 => tooLow,
    3 => tooLeft,
    4 => tooRight,
    5 => tooFast,
    6 => tooSlow,
    7 => poorQuality,
    8 => tooSkewed,
    9 => tooShort,
    10 => mergeFailure,
    11 => alreadyEnrolled,
    13 || 14 => noActivity,
    _ => other,
  };
}

/// Where an enrolment stands after a touch.
class EnrollStep {
  const EnrollStep({required this.templateId, required this.sample, required this.remaining});

  /// Names the fingerprint being added, for the next touch and for naming it.
  final Uint8List templateId;

  /// What the key made of the touch.
  final FingerprintSample sample;

  /// How many more good touches the key asks for; 0 when it is done.
  final int remaining;

  bool get done => remaining == 0;
}

/// The fingerprint commands of one key.
class BioEnrollment {
  BioEnrollment(this.session, this.command, this.token);

  final CtapSession session;

  /// [CtapCommand.bioEnrollment] or [CtapCommand.bioEnrollmentPreview].
  final int command;

  /// A token with [PinPermission.bioEnrollment].
  final PinToken token;

  Future<Map<int, Object?>> _signed(int subCommand, [Map<int, Object?>? parameters]) => session.request(command, {
    1: _fingerprint,
    2: subCommand,
    3: ?parameters,
    4: token.protocol.number,
    5: token.authenticate([_fingerprint, subCommand, if (parameters != null) ...cborEncode(parameters)]),
  });

  /// What the key says of its reader.
  Future<FingerprintSensor> sensor() async {
    final answer = await session.request(command, {1: _fingerprint, 2: 7});
    final samples = answer[3];
    final name = answer[8];
    return FingerprintSensor(maxSamples: samples is int ? samples : 0, maxNameBytes: name is int ? name : null);
  }

  /// The fingerprints on the key.
  Future<List<KeyFingerprint>> list() async {
    final Map<int, Object?> answer;
    try {
      answer = await _signed(4);
    } on CtapError catch (error) {
      // A key with none says the option is invalid.
      if (error.status == CtapStatus.invalidOption) return const [];
      rethrow;
    }
    final infos = answer[7];
    return [
      if (infos is List)
        for (final info in infos.map(cborIntMap))
          if (info[1] case final Uint8List id) KeyFingerprint(id, info[2] is String ? info[2]! as String : null),
    ];
  }

  EnrollStep _step(Map<int, Object?> answer, Uint8List? known) {
    final id = answer[4] ?? known;
    final remaining = answer[6];
    if (id is! Uint8List || remaining is! int) throw const CtapError(CtapStatus.invalidParameter);
    return EnrollStep(templateId: id, sample: FingerprintSample.fromStatus(answer[5]), remaining: remaining);
  }

  /// Starts adding a fingerprint: the key waits for the first touch.
  /// Throws a [CtapError] with [CtapStatus.fingerprintDatabaseFull] when
  /// the key has no room.
  Future<EnrollStep> begin() async => _step(await _signed(1), null);

  /// Waits for the next touch of the fingerprint [templateId].
  Future<EnrollStep> next(Uint8List templateId) async => _step(await _signed(2, {1: templateId}), templateId);

  /// Tells the key to drop the unfinished fingerprint.
  Future<void> cancel() async {
    await session.request(command, {1: _fingerprint, 2: 3});
  }

  /// Names the fingerprint [id].
  Future<void> rename(Uint8List id, String name) async {
    await _signed(5, {1: id, 2: name});
  }

  /// Removes the fingerprint [id] from the key.
  Future<void> remove(Uint8List id) async {
    await _signed(6, {1: id});
  }
}
