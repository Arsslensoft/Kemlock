/// Asking an address's own domain for its key: the Web Key Directory of
/// draft-koch-openpgp-webkey-service (openspec: add-key-lookup, decisions 1
/// to 3). What counts as an address, the two addresses a key is fetched
/// from, and the search over them.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;
import 'package:http/http.dart' as http;

import '../../../crypto/zbase32.dart';
import '../../../platform/network.dart';
import 'lookup_http.dart';

/// The longest address a search takes, in characters.
const maxLookupAddressLength = 254;

/// Why text is not an address a key can be looked up for.
enum AddressProblem {
  /// Nothing typed yet.
  empty,
  noAt,
  severalAt,
  emptyLocalPart,

  /// A space or a control character before the @.
  badLocalPart,

  /// Something other than ASCII letters, digits, hyphens and dots, or an
  /// empty label, after the @.
  badDomain,
  noDot,

  /// A domain written with letters outside ASCII, which would need IDNA to
  /// be asked (decision 2).
  internationalDomain,

  /// Over [maxLookupAddressLength] characters.
  tooLong,
}

/// One email address to look a key up for: the part before the @ as it was
/// typed, and the domain in lower case.
class LookupAddress {
  const LookupAddress._(this.localPart, this.domain);

  /// The part before the @, as typed.
  final String localPart;

  /// The domain, in lower case.
  final String domain;

  /// The address searched: [localPart] and [domain].
  String get address => '$localPart@$domain';

  @override
  bool operator ==(Object other) => other is LookupAddress && other.localPart == localPart && other.domain == domain;

  @override
  int get hashCode => Object.hash(localPart, domain);

  @override
  String toString() => address;
}

/// Reads [text] as one address (decision 2): trimmed, exactly one @, a
/// part before it with no space or control character, and a domain of
/// ASCII letters, digits, hyphens and dots with at least one dot, at most
/// [maxLookupAddressLength] characters in all.
({LookupAddress? address, AddressProblem? problem}) readLookupAddress(String text) {
  ({LookupAddress? address, AddressProblem? problem}) refuse(AddressProblem problem) => (address: null, problem: problem);
  final trimmed = text.trim();
  if (trimmed.isEmpty) return refuse(AddressProblem.empty);
  if (trimmed.length > maxLookupAddressLength) return refuse(AddressProblem.tooLong);
  final parts = trimmed.split('@');
  if (parts.length == 1) return refuse(AddressProblem.noAt);
  if (parts.length > 2) return refuse(AddressProblem.severalAt);
  final [local, domain] = parts;
  if (local.isEmpty) return refuse(AddressProblem.emptyLocalPart);
  if (RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(local)) return refuse(AddressProblem.badLocalPart);
  if (domain.codeUnits.any((unit) => unit > 0x7f)) return refuse(AddressProblem.internationalDomain);
  if (!RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(domain)) return refuse(AddressProblem.badDomain);
  if (!domain.contains('.')) return refuse(AddressProblem.noDot);
  if (domain.split('.').any((label) => label.isEmpty)) return refuse(AddressProblem.badDomain);
  return (address: LookupAddress._(local, asciiLowerCase(domain)), problem: null);
}

/// [text] with the ASCII capitals made lower case, and nothing else changed.
String asciiLowerCase(String text) => String.fromCharCodes(text.codeUnits.map((unit) => unit >= 0x41 && unit <= 0x5a ? unit + 0x20 : unit));

/// The name a directory files the key of [address] under: the SHA-1 of the
/// part before the @, its ASCII capitals made lower case, in z-base-32.
String wkdHash(LookupAddress address) => zBase32(hash.sha1.convert(utf8.encode(asciiLowerCase(address.localPart))).bytes);

/// The query that carries the part before the @ as typed, percent-encoded.
String _query(LookupAddress address) => 'l=${Uri.encodeQueryComponent(address.localPart)}';

/// Where the advanced method fetches the key of [address]: on the
/// directory host `openpgpkey.<domain>`.
Uri wkdAdvancedUri(LookupAddress address) =>
    Uri.parse('https://openpgpkey.${address.domain}/.well-known/openpgpkey/${address.domain}/hu/${wkdHash(address)}?${_query(address)}');

/// Where the direct method fetches it: on the domain itself.
Uri wkdDirectUri(LookupAddress address) =>
    Uri.parse('https://${address.domain}/.well-known/openpgpkey/hu/${wkdHash(address)}?${_query(address)}');

/// What a directory answer is fetched as.
const wkdAccept = 'application/octet-stream';

/// Asks the domain of [address] for its key (decision 3). The directory
/// host `openpgpkey.<domain>` is resolved first: when it has an address,
/// only the advanced address is fetched; only when it has none is the
/// direct address fetched, and when the domain has none either, the domain
/// could not be reached. A 200 is the answer; every other status, a
/// redirect that is not followed included, is no key; a failed connection
/// is unreachable. No other party is asked.
Future<LookupOutcome> searchWkd(
  LookupAddress address, {
  required http.Client client,
  required HostResolver resolve,
  Future<void>? abandon,
}) async {
  Future<LookupOutcome> fetch(Uri url) async {
    try {
      final response = await lookupGet(client, url, accept: wkdAccept, redirects: maxLookupRedirects, abandon: abandon);
      return response.status == 200 ? LookupAnswered(response.body!) : const LookupNoKey();
    } on LookupException catch (error) {
      return failedLookup(error.failure);
    }
  }

  try {
    final advanced = wkdAdvancedUri(address);
    if (await resolve(advanced.host)) return await fetch(advanced);
    final direct = wkdDirectUri(address);
    // A phone with no connection resolves nothing, which must not read as "no key"
    if (!await resolve(direct.host)) return const LookupUnreachable();
    return await fetch(direct);
  } on OfflineException {
    return const LookupPaused();
  }
}
