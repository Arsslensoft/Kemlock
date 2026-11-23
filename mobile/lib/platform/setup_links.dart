import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// `otpauth://` and `otpauth-migration://` links other apps hand Kemlock:
/// a site's "set up an authenticator" link, a QR code the camera read, or
/// a Google Authenticator export (openspec: add-code-imports). On iOS
/// the app is listed under Settings › General › AutoFill & Passwords ›
/// Set Up Codes In for handling the scheme.
abstract interface class SetupLinks {
  /// The link the app was opened with, once; null when there was none.
  Future<String?> initial();

  /// Links that arrive while the app runs.
  Stream<String> get incoming;
}

/// Whether [link] is one the add-account sheet reads.
bool isSetupLink(String link) => _scheme.hasMatch(link);

final _scheme = RegExp(r'^otpauth(?:-migration)?://', caseSensitive: false);

/// [SetupLinks] over the app's method channel; a build without the native side gets none.
class ChannelSetupLinks implements SetupLinks {
  ChannelSetupLinks() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) _incoming.add(call.arguments as String);
    });
  }

  static const _channel = MethodChannel('com.kemlock.app/links');
  final _incoming = StreamController<String>.broadcast();

  @override
  Future<String?> initial() async {
    try {
      return await _channel.invokeMethod<String>('initial');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Stream<String> get incoming => _incoming.stream;
}

/// The phone's set-up links; tests put a fake in its place.
final setupLinksProvider = Provider<SetupLinks>((ref) => ChannelSetupLinks());

/// The last set-up link that arrived and hasn't been shown yet. It waits
/// here while the vault is locked; the open vault's shell takes it.
class PendingSetupLink extends Notifier<String?> {
  @override
  String? build() {
    final links = ref.watch(setupLinksProvider);
    final sub = links.incoming.listen(_arrived);
    ref.onDispose(sub.cancel);
    unawaited(links.initial().then((link) => link == null ? null : _arrived(link)));
    return null;
  }

  void _arrived(String link) {
    if (isSetupLink(link)) state = link;
  }

  /// The link, now shown, and forgotten.
  String? take() {
    final link = state;
    state = null;
    return link;
  }
}

final pendingSetupLinkProvider = NotifierProvider<PendingSetupLink, String?>(PendingSetupLink.new);
