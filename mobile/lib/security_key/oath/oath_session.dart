/// A conversation with the OATH application of a security key: its
/// accounts, their codes and its password (openspec:
/// add-security-key-codes, decisions 1, 2 and 8).
///
/// ```dart
/// final codes = await runOnKey(keys, (connection) async {
///   final oath = await OathSession.open(connection);
///   if (oath.needsPassword) await oath.validate(oathAccessKey('password', oath.select.id));
///   return oath.calculateAll(oathChallenge(step));
/// });
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/bytes.dart';
import '../../crypto/pbkdf2.dart';
import '../apdu.dart';
import '../connection.dart';
import 'oath_messages.dart';

/// What proves a password to the key whose application id is [salt]:
/// PBKDF2-HMAC-SHA1, 1000 rounds, 16 bytes, as the protocol fixes it. It
/// opens this one key and is not the password.
Uint8List oathAccessKey(String password, List<int> salt) => pbkdf2Sha1(utf8.encode(password), salt, 1000, 16);

class OathSession {
  OathSession._(this._connection, this._card, this.select, this._challenge);

  final SecurityKeyConnection _connection;
  SmartCardSession _card;
  final Uint8List Function() _challenge;

  /// What the application said of itself when it was opened, or after the
  /// last [reset].
  OathSelect select;

  bool _proved = false;
  bool _untrusted = false;

  /// Opens the application on the connected key. Throws
  /// `SecurityKeyNoApplication` when the key has none, and [OathError]
  /// with [OathFailure.malformed] when what answers is not Yubico's OATH
  /// application. [challenge] gives this side's eight random bytes.
  static Future<OathSession> open(SecurityKeyConnection connection, {Uint8List Function()? challenge}) async {
    final card = await connection.selectApplication(oathAid);
    return OathSession._(connection, card, parseOathSelect(card.selectAnswer), challenge ?? () => randomBytes(8));
  }

  /// Whether the application has a password that was not proved yet.
  bool get needsPassword => select.hasPassword && !_proved;

  OathError _failure(ApduResponse response, {bool touch = false}) => OathError(switch (response.sw) {
    OathSw.noSpace => OathFailure.full,
    // After the password, the one thing still missing is the touch.
    OathSw.authRequired => touch && !needsPassword ? OathFailure.notTouched : OathFailure.passwordNeeded,
    OathSw.noSuchObject => OathFailure.noSuchAccount,
    OathSw.wrongSyntax => OathFailure.wrongSyntax,
    _ => OathFailure.refused,
  }, sw: response.sw);

  /// Sends [command]. Nothing but the proof is sent to a key that waits
  /// for its password, and nothing at all to one that failed its own proof.
  Future<Uint8List> _send(ApduCommand command, {bool open = false, bool touch = false}) async {
    if (_untrusted) throw const OathError(OathFailure.untrustedKey);
    if (!open && needsPassword) throw const OathError(OathFailure.passwordNeeded);
    final response = await _card.transmit(command, remainingIns: OathIns.sendRemaining);
    if (!response.ok) throw _failure(response, touch: touch);
    return response.data;
  }

  /// Proves the password with [accessKey] ([oathAccessKey]) and checks the
  /// key's own proof. Throws [OathError] with [OathFailure.wrongPassword]
  /// when the key refuses it, and with [OathFailure.untrustedKey] when the
  /// key's answer is not what a key that knows [accessKey] gives; nothing
  /// more is then sent to it.
  Future<void> validate(List<int> accessKey) async {
    final theirs = select.challenge;
    if (theirs == null || _proved) return;
    final mine = _challenge();
    final Uint8List answer;
    try {
      answer = await _send(oathValidateCommand(oathProof(accessKey, theirs), mine), open: true);
    } on OathError catch (error) {
      // "Wrong syntax" is how the application refuses a proof.
      if (error.failure == OathFailure.wrongSyntax) throw OathError(OathFailure.wrongPassword, sw: error.sw);
      rethrow;
    }
    final Uint8List proof;
    try {
      proof = parseOathValidate(answer);
    } on OathError {
      _untrusted = true;
      throw const OathError(OathFailure.untrustedKey);
    }
    if (!constantTimeEquals(proof, oathProof(accessKey, mine))) {
      _untrusted = true;
      throw const OathError(OathFailure.untrustedKey);
    }
    _proved = true;
  }

  /// Every account on the key: the whole list, or an error.
  Future<List<OathListed>> list() async => parseOathList(await _send(oathListCommand()));

  /// A code for every time-based account that needs no touch, over
  /// [challenge] ([oathChallenge] of a time step).
  Future<List<OathCalculated>> calculateAll(List<int> challenge) async =>
      parseOathCalculateAll(await _send(oathCalculateAllCommand(challenge)));

  /// The code of the account [name] over [challenge]; a counter-based
  /// account takes none and moves its counter on by one. Throws
  /// [OathError] with [OathFailure.notTouched] when the account waits for
  /// a touch that does not come.
  Future<OathCode> calculate(List<int> name, [List<int> challenge = const []]) async =>
      parseOathCalculate(await _send(oathCalculateCommand(name, challenge), touch: true));

  /// Writes an account, replacing one of the same name.
  Future<void> put({
    required List<int> name,
    required OathType type,
    required OathAlgorithm algorithm,
    required int digits,
    required List<int> secret,
    bool touch = false,
    int counter = 0,
  }) async {
    await _send(
      oathPutCommand(name: name, type: type, algorithm: algorithm, digits: digits, secret: secret, touch: touch, counter: counter),
    );
  }

  Future<void> delete(List<int> name) async {
    await _send(oathDeleteCommand(name));
  }

  /// Sets or changes the password: [accessKey] is [oathAccessKey] of the
  /// new one. The current password, if any, must have been proved.
  Future<void> setCode(List<int> accessKey) async {
    final mine = _challenge();
    await _send(oathSetCodeCommand(accessKey, mine, oathProof(accessKey, mine)));
    await _reselect();
  }

  /// Removes the password, which must have been proved.
  Future<void> clearCode() async {
    await _send(oathClearCodeCommand());
    await _reselect();
  }

  /// Erases every account and the password. The application has a new id
  /// afterwards, which [select] then carries.
  Future<void> reset() async {
    await _send(oathResetCommand(), open: true);
    await _reselect();
  }

  Future<void> _reselect() async {
    _card = await _connection.selectApplication(oathAid);
    select = parseOathSelect(_card.selectAnswer);
    _proved = false;
  }
}
