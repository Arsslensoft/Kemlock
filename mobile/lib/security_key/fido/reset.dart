/// Erasing a key's FIDO2 side (`authenticatorReset`, CTAP 2.1 section
/// 6.6): every passkey, the PIN and the fingerprints. A key accepts it
/// only within ten seconds of getting power and after a touch. That rule
/// is the key's: this code sends the command and explains a refusal.
library;

import '../connection.dart';
import 'ctap.dart';

/// Why a key did not reset.
enum ResetRefusal {
  /// Too long after the key got power, or not over this connection.
  notAllowed,

  /// The key waited for a touch and none came.
  noTouch,

  /// The key said no.
  denied,

  /// A refusal the standard does not name for a reset.
  other,
}

/// The key answered the reset with a refusal.
class ResetRefused implements Exception {
  const ResetRefused(this.refusal, this.status);

  final ResetRefusal refusal;
  final int status;

  @override
  String toString() => 'ResetRefused(${refusal.name})';
}

/// Sends the reset. It needs no PIN. Throws [ResetRefused] when the key
/// does not do it.
Future<void> resetKey(CtapSession session) async {
  final answer = await session.send(CtapCommand.reset);
  if (answer.status == CtapStatus.ok) return;
  throw ResetRefused(switch (answer.status) {
    CtapStatus.notAllowed => ResetRefusal.notAllowed,
    CtapStatus.userActionTimeout => ResetRefusal.noTouch,
    CtapStatus.operationDenied => ResetRefusal.denied,
    _ => ResetRefusal.other,
  }, answer.status);
}
