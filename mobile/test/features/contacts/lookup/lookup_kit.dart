import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/features/contacts/lookup/lookup_http.dart';
import 'package:kemlock/features/contacts/lookup/wkd.dart';
import 'package:kemlock/platform/network.dart';

// What a Web Key Directory and keys.openpgp.org answer in the lookup tests: test/fixtures/keys/lookup (its README
// has the commands), made from the keys of test/fixtures/keys/contacts and never regenerated.

/// Grace Hopper's key, one binary key.
const wkdGrace = 'wkd-grace.bin';

/// Grace's key revoked, then another key for her address, binary, one after the other.
const wkdRevokedThenOther = 'wkd-grace-revoked-then-other.bin';

/// Alan Turing's key, binary: an answer for Grace's address that names another one.
const wkdAlan = 'wkd-alan.bin';

/// Grace's key with a second user ID, the bare address [graceLabAddress].
const wkdTwoAddresses = 'wkd-grace-two-addresses.bin';
const graceLabAddress = 'hopper@lab.example.org';

/// Alan's key as keys.openpgp.org answers, armored.
const vksAlan = 'vks-alan.asc';

/// The bytes of the answer [name] under `test/fixtures/keys/lookup`.
Uint8List lookupAnswer(String name) => File('test/fixtures/keys/lookup/$name').readAsBytesSync();

/// [text] read as an address; it must be one.
LookupAddress addressOf(String text) => readLookupAddress(text).address!;

/// The Web Key Directories and keys.openpgp.org of the lookup tests, behind a [MockClient] and a fake name
/// resolver: which hosts have an address, what each address answers (404 when nothing is set), and every request
/// and resolution, in order. [overrides] put both under the app's gated client and resolver.
class FakeKeyServices {
  /// The hosts that resolve.
  final hosts = <String>{};

  /// What a request is answered with, by its host and path.
  final answers = <String, Future<http.Response> Function(http.Request request)>{};

  /// Hosts whose every request fails to connect.
  final unreachable = <String>{};

  /// Every request the client was sent, and every host the resolver was asked for.
  final requests = <Uri>[];
  final resolved = <String>[];

  late final http.Client client = MockClient((request) async {
    requests.add(request.url);
    if (unreachable.contains(request.url.host)) throw const SocketException('Connection refused');
    final answer = answers['${request.url.host}${request.url.path}'];
    return answer == null ? http.Response('', 404) : answer(request);
  });

  Future<bool> resolve(String host) async {
    resolved.add(host);
    return hosts.contains(host);
  }

  /// Answers [url] with [status] and [body].
  void answer(Uri url, int status, [List<int> body = const []]) =>
      answers['${url.host}${url.path}'] = (_) async => http.Response.bytes(body, status);

  /// The domain of [address] publishes [body] for it in its directory, by the advanced method, or by the direct
  /// one when [advanced] is false.
  void directory(String address, List<int> body, {bool advanced = true}) {
    final at = addressOf(address);
    final url = advanced ? wkdAdvancedUri(at) : wkdDirectUri(at);
    hosts.add(url.host);
    answer(url, 200, body);
  }

  /// The domain of [address] has a directory host that holds nothing for it.
  void emptyDirectory(String address) => hosts.add(wkdAdvancedUri(addressOf(address)).host);

  /// keys.openpgp.org answers [status] and [body] for [address].
  void keyServer(String address, int status, [List<int> body = const []]) =>
      answer(Uri.parse('https://keys.openpgp.org/vks/v1/by-email/${Uri.encodeComponent(address)}'), status, body);

  /// The requests made to keys.openpgp.org.
  List<Uri> get keyServerRequests => [
    for (final url in requests)
      if (url.host == 'keys.openpgp.org') url,
  ];

  List<Override> get overrides => [
    plainClientProvider.overrideWithValue(() => client),
    plainHostResolverProvider.overrideWithValue(resolve),
  ];
}
