/// The Dart side of the Android plugin: one method channel to the connector library, and what the
/// person's distributor tells the app. The port that parts_store and parts_free implement over it,
/// `PushTokens` in `kemlock_ports`, turns this into the push token and the nudges.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart';

/// The channel the plugin's Kotlin class answers on.
const unifiedPushChannel = MethodChannel('com.kemlock.app/unified_push');

/// An app that delivers pushes (ntfy, NextPush, Sunup, ...): its package id and the name the phone shows.
@immutable
class UnifiedPushDistributor {
  const UnifiedPushDistributor({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) => other is UnifiedPushDistributor && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// The distributors installed, and the one this app uses, if it has chosen.
@immutable
class UnifiedPushDistributors {
  const UnifiedPushDistributors({this.installed = const [], this.inUse});

  final List<UnifiedPushDistributor> installed;

  /// The package id of the one in use, or null before a choice or when it was uninstalled.
  final String? inUse;
}

/// What the service heard from the distributor, while the app runs.
sealed class UnifiedPushEvent {
  const UnifiedPushEvent();
}

/// A new endpoint, or the same one again: ask [UnifiedPushChannel.endpoint] for it.
class UnifiedPushEndpointChanged extends UnifiedPushEvent {
  const UnifiedPushEndpointChanged();
}

/// The distributor ended the registration (or was uninstalled): there is no endpoint now.
class UnifiedPushUnregistered extends UnifiedPushEvent {
  const UnifiedPushUnregistered();
}

/// The distributor could not register this app: `INTERNAL_ERROR`, `NETWORK`, `ACTION_REQUIRED` or `VAPID_REQUIRED`.
class UnifiedPushRegistrationFailed extends UnifiedPushEvent {
  const UnifiedPushRegistrationFailed(this.reason);

  final String reason;
}

/// A push message arrived. Its content is never read: the server sends none, and any message means "sync now".
class UnifiedPushMessage extends UnifiedPushEvent {
  const UnifiedPushMessage();
}

/// Android's UnifiedPush connector, behind [channel]. Tests give their own.
class UnifiedPushChannel {
  UnifiedPushChannel({MethodChannel? channel}) : _channel = channel ?? unifiedPushChannel {
    _channel.setMethodCallHandler(_called);
  }

  final MethodChannel _channel;
  final _events = StreamController<UnifiedPushEvent>.broadcast();

  Future<Object?> _called(MethodCall call) async {
    final event = switch (call.method) {
      'endpoint' => const UnifiedPushEndpointChanged(),
      'unregistered' => const UnifiedPushUnregistered(),
      'failed' => UnifiedPushRegistrationFailed(call.arguments is String ? call.arguments as String : 'INTERNAL_ERROR'),
      'message' => const UnifiedPushMessage(),
      _ => throw MissingPluginException(),
    };
    _events.add(event);
    return null;
  }

  /// What the service hears, as it arrives.
  Stream<UnifiedPushEvent> get events => _events.stream;

  /// The distributors installed and the one in use. None where the plugin is missing or fails.
  Future<UnifiedPushDistributors> distributors() async {
    try {
      final answer = await _channel.invokeMapMethod<String, Object?>('distributors');
      final list = answer?['installed'];
      return UnifiedPushDistributors(
        installed: [
          if (list is List)
            for (final item in list)
              if (item is Map && item['id'] is String)
                UnifiedPushDistributor(id: item['id'] as String, name: item['name'] is String ? item['name'] as String : item['id'] as String),
        ],
        inUse: answer?['inUse'] is String ? answer!['inUse'] as String : null,
      );
    } on MissingPluginException {
      return const UnifiedPushDistributors();
    } on PlatformException {
      return const UnifiedPushDistributors();
    }
  }

  /// The endpoint the distributor gave this app, or null when there is none yet. With a distributor chosen
  /// and no endpoint, it asks the distributor again.
  Future<String?> endpoint() async {
    try {
      final url = await _channel.invokeMethod<String>('endpoint');
      return url == null || url.isEmpty ? null : url;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Registers with the distributor in use, or with the system's default, which the system asks the person to
  /// pick when there are several and none is the default. False when none is installed or the person went back.
  Future<bool> start() => _choose('start');

  /// Lets the person pick another distributor on the system's screen, then registers with it. False when none
  /// could be picked.
  Future<bool> change() => _choose('change');

  Future<bool> _choose(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Ends the registration with the distributor and forgets the endpoint.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No plugin, no registration
    } on PlatformException {
      // Nothing more to end
    }
  }
}
