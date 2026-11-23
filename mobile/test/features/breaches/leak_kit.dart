import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/features/breaches/hibp.dart';

/// Stands in for Pwned Passwords: knows the [leaked] passwords and how often each
/// appeared, answers as the service does, and keeps what it was asked.
class FakePwnedPasswords {
  FakePwnedPasswords({this.leaked = const {}, this.down = false});

  final Map<String, int> leaked;

  /// Answers with an error, as when the service or the connection is down.
  bool down;

  final requests = <http.Request>[];

  /// The hash prefixes asked for, in order.
  List<String> get asked => [for (final request in requests) request.url.pathSegments.last];

  late final client = MockClient((request) async {
    requests.add(request);
    if (down) return http.Response('Service Unavailable', 503);
    final prefix = request.url.pathSegments.last.toUpperCase();
    return http.Response(
      [
        for (final MapEntry(key: password, value: count) in leaked.entries)
          if (hashOf(password).startsWith(prefix)) '${hashOf(password).substring(5)}:$count',
        // What the padding looks like
        '${'0' * 35}:0',
      ].join('\r\n'),
      200,
    );
  });

  /// This service in place of the real one, and a user agent that needs no plugin.
  List<Override> get overrides => [
    hibpClientProvider.overrideWithValue(client),
    hibpUserAgentProvider.overrideWith((ref) async => 'Kemlock/1.1.0'),
  ];

  /// The upper-case SHA-1 of [password], as the service files it.
  static String hashOf(String password) => sha1.convert(utf8.encode(password)).toString().toUpperCase();

  /// The five characters the app may send for [password].
  static String prefixOf(String password) => hashOf(password).substring(0, 5);
}
