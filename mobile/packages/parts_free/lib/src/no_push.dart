import 'package:kemlock_ports/kemlock_ports.dart';

/// The free build's push, which is none (add-kemlock-server-sync, design 13): no token, no nudges, and nothing
/// that talks to a push service. Changes and requests from other devices arrive while the app is open, through
/// the live socket and the schedule.
class NoPushTokens implements PushTokens {
  const NoPushTokens();

  @override
  bool get available => false;

  @override
  Future<String?> token() async => null;

  @override
  Stream<PushNudge> get onMessage => const Stream.empty();
}
