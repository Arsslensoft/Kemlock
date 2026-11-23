import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:kemlock_ports/kemlock_ports.dart';

/// The store build's push (add-kemlock-server-sync, design 13): APNs on iOS, behind a small channel with no Dart
/// plugin. The Swift side answers `token`, and calls `nudge` with the type of each nudge and nothing else.
///
/// Android has none: the owner decided that Kemlock has no Firebase, so there the store build is as the free one,
/// [available] is false, [token] is null, nothing asks the channel, and changes and requests arrive through the live
/// socket and the schedule while the app is open. [platform] is where the build runs; tests give it.
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
  Future<String?> token() async {
    if (!_apns) {
      return null;
    }
    try {
      final token = await _channel.invokeMethod<String>('token');
      return token == null || token.isEmpty ? null : token;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Stream<PushNudge> get onMessage => _apns ? _nudges.stream : const Stream.empty();
}
