import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:kemlock_ports/kemlock_ports.dart';
import 'package:unified_push/unified_push_tokens.dart';

/// The store build's push (add-kemlock-server-sync, design 13; plan add-unifiedpush): APNs on iOS and UnifiedPush on
/// Android, which both builds have. [platform] is where the build runs; tests give it.
PushTokens makePushTokens({TargetPlatform? platform}) {
  final where = platform ?? defaultTargetPlatform;
  return where == TargetPlatform.android ? UnifiedPushTokens() : ChannelPushTokens(platform: where);
}

/// The store build's APNs push, on iOS, behind a small channel with no Dart plugin. The Swift side answers `token`, and
/// calls `nudge` with the type of each nudge and nothing else.
///
/// Nothing else has APNs: on any other platform [available] is false, [pushToken] is null and nothing asks the channel.
/// Android's push is UnifiedPush (`UnifiedPushTokens`), which [makePushTokens] chooses there. [platform] is where the
/// build runs; tests give it.
class ChannelPushTokens implements PushTokens {
  ChannelPushTokens({TargetPlatform? platform}) : _apns = (platform ?? defaultTargetPlatform) == TargetPlatform.iOS {
    if (_apns) {
      _channel.setMethodCallHandler(_called);
    }
  }

  static const _channel = MethodChannel('com.kemlock.app/push');

  final bool _apns;
  final _nudges = StreamController<PushNudge>.broadcast();

  Future<Object?> _called(MethodCall call) async {
    if (call.method != 'nudge') throw MissingPluginException();
    final nudge = PushNudge.parse(call.arguments is Map ? (call.arguments as Map)['type'] : call.arguments);
    if (nudge != null) {
      _nudges.add(nudge);
    }
    return null;
  }

  @override
  bool get available => _apns;

  @override
  bool get choosesDistributor => false;

  @override
  Future<PushToken?> pushToken() async {
    if (!_apns) {
      return null;
    }
    try {
      final token = await _channel.invokeMethod<String>('token');
      return token == null || token.isEmpty ? null : (kind: pushKindApns, token: token);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Stream<PushNudge> get onMessage => _apns ? _nudges.stream : const Stream.empty();

  @override
  Stream<void> get onTokenChanged => const Stream.empty();

  @override
  Future<PushDistributors> distributors() async => PushDistributors.none;

  @override
  Future<bool> start() async => _apns;

  @override
  Future<bool> change() async => false;

  @override
  Future<void> stop() async {}
}
