import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:kemlock_ports/kemlock_ports.dart';
import 'package:unified_push/unified_push_tokens.dart';

/// The free build's push (plan add-unifiedpush): UnifiedPush on Android, through the distributor the person installs
/// (ntfy, NextPush, ...; free software, no Google service), and none anywhere else. [platform] is where the build
/// runs; tests give it.
PushTokens makePushTokens({TargetPlatform? platform}) =>
    (platform ?? defaultTargetPlatform) == TargetPlatform.android ? UnifiedPushTokens() : const NoPushTokens();

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
