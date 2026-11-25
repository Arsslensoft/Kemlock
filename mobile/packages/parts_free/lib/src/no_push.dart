import 'package:kemlock_ports/kemlock_ports.dart';

/// No push at all: no token, no nudges, and nothing that talks to a push service. Changes and requests from other
/// devices arrive while the app is open, through the live socket and the schedule.
class NoPushTokens implements PushTokens {
  const NoPushTokens();

  @override
  bool get available => false;

  @override
  bool get choosesDistributor => false;

  @override
  Future<PushToken?> pushToken() async => null;

  @override
  Stream<PushNudge> get onMessage => const Stream.empty();

  @override
  Stream<void> get onTokenChanged => const Stream.empty();

  @override
  Future<PushDistributors> distributors() async => PushDistributors.none;

  @override
  Future<bool> start() async => false;

  @override
  Future<bool> change() async => false;

  @override
  Future<void> stop() async {}
}
