/// Android's UnifiedPush as the app's push port: [UnifiedPushTokens] is `PushTokens` over the plugin's channel. Both
/// builds use it (plan add-unifiedpush); parts_store and parts_free choose it on Android.
library;

import 'dart:async';

import 'package:kemlock_ports/kemlock_ports.dart';

import 'unified_push.dart';

/// Whether the server takes [url] as an endpoint: `https` on port 443 or 8443 (the default port of `https` is 443), no
/// whitespace, 512 characters at most. Anything else it refuses with a 400, so it is never sent.
bool usableEndpoint(String url) {
  if (url.isEmpty || url.length > 512 || url.contains(RegExp(r'\s'))) return false;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
  return uri.port == 443 || uri.port == 8443;
}

/// This phone's push on Android: the UnifiedPush endpoint is the token, of kind `unifiedpush`, and any message
/// the distributor delivers is a [PushNudge.sync], whatever it holds (the server sends none).
class UnifiedPushTokens implements PushTokens {
  UnifiedPushTokens({UnifiedPushChannel? channel}) : _push = channel ?? UnifiedPushChannel() {
    _heard = _push.events.listen(_onEvent);
  }

  final UnifiedPushChannel _push;
  late final StreamSubscription<UnifiedPushEvent> _heard;
  final _nudges = StreamController<PushNudge>.broadcast();
  final _changes = StreamController<void>.broadcast();

  void _onEvent(UnifiedPushEvent event) {
    switch (event) {
      case UnifiedPushMessage():
        _nudges.add(PushNudge.sync);
      case UnifiedPushEndpointChanged() || UnifiedPushUnregistered():
        _changes.add(null);
      case UnifiedPushRegistrationFailed():
        // The next sync run asks for the token again, which registers again
        break;
    }
  }

  @override
  bool get available => true;

  @override
  bool get choosesDistributor => true;

  @override
  Future<PushToken?> pushToken() async {
    final endpoint = await _push.endpoint();
    return endpoint == null || !usableEndpoint(endpoint) ? null : (kind: pushKindUnifiedPush, token: endpoint);
  }

  @override
  Stream<PushNudge> get onMessage => _nudges.stream;

  @override
  Stream<void> get onTokenChanged => _changes.stream;

  @override
  Future<PushDistributors> distributors() async {
    final got = await _push.distributors();
    final installed = [for (final one in got.installed) PushDistributor(id: one.id, name: one.name)];
    return PushDistributors(installed: installed, inUse: installed.where((one) => one.id == got.inUse).firstOrNull);
  }

  @override
  Future<bool> start() => _push.start();

  @override
  Future<bool> change() => _push.change();

  @override
  Future<void> stop() => _push.stop();

  /// Stops listening to the plugin and closes the streams. The app's push lives as long as the app does, so only a test
  /// ends it.
  Future<void> dispose() async {
    await _heard.cancel();
    await _nudges.close();
    await _changes.close();
  }
}
