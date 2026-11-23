/// Asking keys.openpgp.org for the key of an address, through its VKS
/// interface (openspec: add-key-lookup, decision 4). Only on the person's
/// second answer, which the search sheet asks for; the host is fixed.
library;

import 'package:http/http.dart' as http;

import 'lookup_http.dart';
import 'wkd.dart';

/// The key server, the only one asked.
const vksHost = 'keys.openpgp.org';

/// What a key-server answer is fetched as.
const vksAccept = 'application/pgp-keys';

/// Where keys.openpgp.org answers for [address]: its by-email lookup, the
/// address percent-encoded.
Uri vksUri(LookupAddress address) => Uri.parse('https://$vksHost/vks/v1/by-email/${Uri.encodeComponent(address.address)}');

/// Asks keys.openpgp.org for the key of [address]. A 200 is the answer, 404
/// is no key, 429 is a request to slow down, and anything else, a redirect
/// included, which is never followed, is unreachable, as is a failed
/// connection.
Future<LookupOutcome> searchVks(LookupAddress address, {required http.Client client, Future<void>? abandon}) async {
  try {
    final response = await lookupGet(client, vksUri(address), accept: vksAccept, abandon: abandon);
    return switch (response.status) {
      200 => LookupAnswered(response.body!),
      404 => const LookupNoKey(),
      429 => const LookupSlowDown(),
      _ => const LookupUnreachable(),
    };
  } on LookupException catch (error) {
    return failedLookup(error.failure);
  }
}
