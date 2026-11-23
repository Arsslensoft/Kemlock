/// The one kind of request a key lookup makes (openspec: add-key-lookup,
/// decision 6): an HTTPS `GET` that carries the app's name and what it
/// accepts and nothing else, waits ten seconds at most, reads 1 MB at most,
/// and follows a redirect only by hand, to another HTTPS address, and only
/// as often as the caller allows. Its client and the name resolver both
/// pass offline mode's gate (decision 5).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../crypto/keys/keys.dart' show maxKeyInputLength;
import '../../../platform/network.dart';

/// The `User-Agent` of a lookup: the app's name, without its version,
/// which nothing here needs.
const lookupUserAgent = 'Kemlock';

/// How long one request may take, from asking to the last byte.
const lookupTimeout = Duration(seconds: 10);

/// How many redirects in a row a directory may send.
const maxLookupRedirects = 3;

const _redirects = {301, 302, 303, 307, 308};

/// Why a lookup request came back with nothing to judge.
enum LookupFailure {
  /// The connection failed, the certificate did not verify, or the wait ran out.
  unreachable,

  /// The answer was larger than a key may be.
  tooLarge,

  /// Offline mode stopped the request before it was made.
  offline,
}

/// What [lookupGet] throws in place of an answer.
class LookupException implements Exception {
  const LookupException(this.failure);

  final LookupFailure failure;

  @override
  String toString() => 'LookupException(${failure.name})';
}

/// What a lookup request came back with: the last [status], from [url],
/// and the [body] of a 200, at most [maxKeyInputLength] bytes. A redirect
/// that was not followed is its own status, with no body.
class LookupResponse {
  const LookupResponse(this.status, this.url, [this.body]);

  final int status;
  final Uri url;
  final Uint8List? body;
}

/// A `GET` of [url] that accepts [accept], following at most [redirects]
/// redirects, each to an `https` address. Each request gives up after
/// [timeout]; once [abandon] completes, the one under way is dropped.
///
/// Throws a [LookupException]: [LookupFailure.offline] when the gate
/// refuses it, [LookupFailure.tooLarge] for a body over
/// [maxKeyInputLength], and [LookupFailure.unreachable] for anything else
/// that keeps an answer from arriving.
Future<LookupResponse> lookupGet(
  http.Client client,
  Uri url, {
  required String accept,
  int redirects = 0,
  Duration timeout = lookupTimeout,
  Future<void>? abandon,
}) async {
  var at = url;
  for (var followed = 0; ; followed++) {
    if (at.scheme != 'https') throw const LookupException(LookupFailure.unreachable);
    final (status, location, body) = await _once(client, at, accept, timeout, abandon);
    final next = location == null ? null : at.resolve(location);
    if (!_redirects.contains(status) || next == null || next.scheme != 'https' || followed >= redirects) {
      return LookupResponse(status, at, body);
    }
    at = next;
  }
}

/// One request: its status, its `Location`, and the body of a 200.
Future<(int, String?, Uint8List?)> _once(http.Client client, Uri url, String accept, Duration timeout, Future<void>? abandon) async {
  final abort = Completer<void>();
  void stop() {
    if (!abort.isCompleted) abort.complete();
  }

  unawaited(abandon?.whenComplete(stop));
  final request = http.AbortableRequest('GET', url, abortTrigger: abort.future)
    ..followRedirects = false
    ..headers['User-Agent'] = lookupUserAgent
    ..headers['Accept'] = accept;
  try {
    return await _read(client, request).timeout(timeout);
  } on LookupException {
    stop();
    rethrow;
  } on OfflineException {
    throw const LookupException(LookupFailure.offline);
  } on TimeoutException {
    stop();
    throw const LookupException(LookupFailure.unreachable);
  } on http.ClientException {
    stop();
    throw const LookupException(LookupFailure.unreachable);
  } on IOException {
    // A socket that failed, an answer that broke off, or a certificate that did not verify
    stop();
    throw const LookupException(LookupFailure.unreachable);
  }
}

Future<(int, String?, Uint8List?)> _read(http.Client client, http.BaseRequest request) async {
  final response = await client.send(request);
  final status = response.statusCode;
  if (status != 200) {
    // Nothing of it is read; listening and leaving closes the connection
    unawaited(response.stream.listen(null, onError: (Object _) {}).cancel());
    return (status, response.headers['location'], null);
  }
  if ((response.contentLength ?? 0) > maxKeyInputLength) {
    unawaited(response.stream.listen(null, onError: (Object _) {}).cancel());
    throw const LookupException(LookupFailure.tooLarge);
  }
  final body = BytesBuilder(copy: false);
  await for (final chunk in response.stream) {
    if (body.length + chunk.length > maxKeyInputLength) throw const LookupException(LookupFailure.tooLarge);
    body.add(chunk);
  }
  return (status, null, body.toBytes());
}

/// The client both services are asked through: offline mode's gated
/// client, so a request made while it is on fails before a socket opens.
final keyLookupClientProvider = Provider<http.Client>((ref) => ref.watch(gatedClientProvider));

/// Whether [host] has an address: what tells a domain with a directory
/// host from one without (decision 3).
typedef HostResolver = Future<bool> Function(String host);

/// Asks the phone's resolver for [host]. A name with no address, and a
/// resolver that can't be reached or doesn't answer in time, are both
/// false: a phone with no connection resolves nothing.
Future<bool> resolvesHost(String host) async {
  try {
    return (await InternetAddress.lookup(host).timeout(lookupTimeout)).isNotEmpty;
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  }
}

/// The resolver [hostResolverProvider] puts behind the gate. Tests override
/// it with a fake.
final plainHostResolverProvider = Provider<HostResolver>((ref) => resolvesHost);

/// The resolver a lookup asks. Offline mode's gate covers HTTP clients,
/// and a name resolution leaves the phone too, so this one passes the same
/// gate: while offline mode is on it throws an [OfflineException] without
/// asking anyone.
final hostResolverProvider = Provider<HostResolver>((ref) {
  final gate = ref.watch(networkGateProvider);
  final resolve = ref.watch(plainHostResolverProvider);
  return (host) async {
    gate.check(Uri(scheme: 'https', host: host));
    return resolve(host);
  };
});

/// What asking one service for the key of an address came to.
sealed class LookupOutcome {
  const LookupOutcome();
}

/// The service answered with [bytes], which may hold keys.
final class LookupAnswered extends LookupOutcome {
  const LookupAnswered(this.bytes);

  final Uint8List bytes;
}

/// The service holds no key for the address, or none it could hand over.
final class LookupNoKey extends LookupOutcome {
  const LookupNoKey();
}

/// The service could not be reached, so whether it holds a key is not known.
final class LookupUnreachable extends LookupOutcome {
  const LookupUnreachable();
}

/// The service asked to be asked less often.
final class LookupSlowDown extends LookupOutcome {
  const LookupSlowDown();
}

/// Offline mode stopped the lookup before anything was sent.
final class LookupPaused extends LookupOutcome {
  const LookupPaused();
}

/// The outcome of a request that ended in [failure]: an answer too large
/// to be a key is no key.
LookupOutcome failedLookup(LookupFailure failure) => switch (failure) {
  LookupFailure.unreachable => const LookupUnreachable(),
  LookupFailure.tooLarge => const LookupNoKey(),
  LookupFailure.offline => const LookupPaused(),
};
