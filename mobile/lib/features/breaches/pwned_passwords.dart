/// Whether a password is among those known from data breaches, asked of Have I Been
/// Pwned's Pwned Passwords without the password leaving the phone (openspec:
/// password-leak-check).
///
/// The service is asked for every leaked password whose SHA-1 hash starts with the same
/// five characters as this one's, and the answer is searched here. It learns those five
/// characters, 20 of the hash's 160 bits, and nothing else.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../platform/network.dart' show AnswerTooLarge, readAnswer;
import 'hibp.dart';

/// The password couldn't be checked: no answer in time, or one that can't be read. It
/// says nothing about the password either way.
class LeakCheckError implements Exception {
  const LeakCheckError(this.reason);

  final String reason;

  @override
  String toString() => 'LeakCheckError: $reason';
}

/// Asks Pwned Passwords through [client], which tests replace with a `MockClient`.
class PwnedPasswords {
  PwnedPasswords(this.client, {required this.userAgent, this.timeout = const Duration(seconds: 10)});

  final http.Client client;

  /// The `User-Agent`, which the service refuses a request without.
  final Future<String> Function() userAgent;

  /// How long to wait for the answer.
  final Duration timeout;

  static const _range = 'https://api.pwnedpasswords.com/range/';

  /// A padded answer is under 40 kB; anything far past that isn't one.
  static const _maxBytes = 1 << 20;

  /// How many times [password] appears in the breaches Pwned Passwords knows, 0 when it
  /// isn't among them. Throws a [LeakCheckError] when it can't tell.
  Future<int> timesLeaked(String password) async {
    // Of the password as typed: the service hashes the UTF-8 bytes of each leaked one
    final hash = sha1.convert(utf8.encode(password)).toString().toUpperCase();
    final suffix = hash.substring(5);
    Future<http.Response> ask() async {
      final request = http.Request('GET', Uri.parse('$_range${hash.substring(0, 5)}'))
        ..headers.addAll({
          'User-Agent': await userAgent(),
          // Pads the answer to 800-1,000 lines, so its size says nothing of the prefix
          'Add-Padding': 'true',
        });
      // Dropped once it passes the limit, not read whole first
      return readAnswer(await client.send(request), _maxBytes);
    }

    final http.Response response;
    try {
      // The wait covers reading the app's version for the user agent too
      response = await ask().timeout(timeout);
    } on TimeoutException {
      throw const LeakCheckError('no answer in time');
    } on AnswerTooLarge {
      throw const LeakCheckError('answer too large');
    } catch (error) {
      throw LeakCheckError('no answer: $error');
    }
    if (response.statusCode != 200) throw LeakCheckError('status ${response.statusCode}');

    // Lines of SUFFIX:COUNT; the padding's have a count of 0
    for (final line in const LineSplitter().convert(response.body)) {
      final colon = line.indexOf(':');
      if (colon < 0 || line.substring(0, colon).trim().toUpperCase() != suffix) continue;
      final count = int.tryParse(line.substring(colon + 1).trim());
      if (count != null) return count < 0 ? 0 : count;
    }
    return 0;
  }
}

/// The leak check, through the client and user agent every Have I Been Pwned request uses.
final pwnedPasswordsProvider = Provider<PwnedPasswords>(
  (ref) => PwnedPasswords(ref.watch(hibpClientProvider), userAgent: () => ref.read(hibpUserAgentProvider.future)),
);
