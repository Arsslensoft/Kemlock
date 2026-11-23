/// Finding a key by email, from the address typed to the keys the review
/// shows (openspec: add-key-lookup, decisions 3 to 5, 7 and 10): the
/// address's own domain first, keys.openpgp.org only on the person's second
/// answer and for that one search, and offline mode asked before each step.
/// Nothing calls it but the search sheet's buttons, and nothing of it is
/// kept once the sheet closes.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../crypto/keys/keys.dart' as crypto;
import '../../../models/contact.dart';
import '../../../platform/network.dart';
import 'keys_for_address.dart';
import 'lookup_http.dart';
import 'vks.dart';
import 'wkd.dart';

/// The two steps of a search.
enum KeySearchStep {
  /// The Web Key Directory of the address's domain.
  domain,

  /// keys.openpgp.org.
  server,
}

/// Where a search stands.
sealed class KeySearchState {
  const KeySearchState();
}

/// Nothing asked yet.
final class SearchIdle extends KeySearchState {
  const SearchIdle();
}

/// A step of a search for [address] under way, or ended.
sealed class SearchOf extends KeySearchState {
  const SearchOf(this.address);

  final LookupAddress address;
}

/// The domain is being asked.
final class SearchAskingDomain extends SearchOf {
  const SearchAskingDomain(super.address);
}

/// The domain or the key server gave [keys] for the address, in the order
/// to review them, found as [source], one of `ContactSource`.
final class SearchFound extends SearchOf {
  const SearchFound(super.address, this.keys, this.source);

  final List<crypto.PgpPublicKey> keys;
  final String source;
}

/// The domain publishes no key for the address: the key server may be
/// offered.
final class SearchDomainHasNone extends SearchOf {
  const SearchDomainHasNone(super.address);
}

/// keys.openpgp.org is being asked, as the person accepted.
final class SearchAskingServer extends SearchOf {
  const SearchAskingServer(super.address);
}

/// Neither the domain nor the key server has a key for the address.
final class SearchNowhere extends SearchOf {
  const SearchNowhere(super.address);
}

/// The service of [step] could not be reached.
final class SearchCouldNotAsk extends SearchOf {
  const SearchCouldNotAsk(super.address, this.step);

  final KeySearchStep step;
}

/// keys.openpgp.org asked to slow down.
final class SearchSlowDown extends SearchOf {
  const SearchSlowDown(super.address);
}

/// Offline mode stopped [step] before anything was sent.
final class SearchPaused extends SearchOf {
  const SearchPaused(super.address, this.step);

  final KeySearchStep step;
}

/// Reads an answer and keeps the keys that name an address, at a time.
typedef KeyLookupReader = Future<List<crypto.PgpPublicKey>> Function(Uint8List answer, String address, DateTime now);

/// The keys of [answer] for [address], as [keysForAddress] gives them. A
/// key that fails its own checks is left out and the others are kept; none
/// when the answer holds no sound key.
Future<List<crypto.PgpPublicKey>> readKeysForAddress(Uint8List answer, String address, DateTime now) async {
  try {
    return await keysForAddress(await crypto.readPublicKeys(answer, skipUnsound: true), address, now);
  } on crypto.KeyFormatException {
    return const [];
  }
}

/// Reads answers off the UI isolate: checking an RSA key's signatures takes
/// a moment. Tests replace it with one that needs no isolate.
final keyLookupReaderProvider = Provider<KeyLookupReader>(
  (ref) =>
      (answer, address, now) => Isolate.run(() => readKeysForAddress(answer, address, now), debugName: 'readKeysForAddress'),
);

/// One search sheet's search: [search] asks the domain of an address, and
/// [askKeyServer], once the domain gave no key, asks keys.openpgp.org.
/// [value] is where it stands. Once disposed, a request under way is
/// dropped and its answer never read.
class KeySearch extends ValueNotifier<KeySearchState> {
  KeySearch({required this._gate, required this._client, required this._resolve, required this._read, required this._now})
    : super(const SearchIdle());

  final NetworkGate _gate;
  final http.Client _client;
  final HostResolver _resolve;
  final KeyLookupReader _read;
  final DateTime Function() _now;
  final _abandon = Completer<void>();
  var _closed = false;

  /// Whether a step is under way.
  bool get busy => value is SearchAskingDomain || value is SearchAskingServer;

  /// Whether [askKeyServer] would ask now: the domain gave no key, or the
  /// key server could not be asked, asked to slow down, or was paused.
  bool get canAskKeyServer => switch (value) {
    SearchDomainHasNone() || SearchSlowDown() => true,
    SearchCouldNotAsk(step: KeySearchStep.server) || SearchPaused(step: KeySearchStep.server) => true,
    _ => false,
  };

  /// Starts a search for [address] by asking its domain. Whatever an earlier
  /// search reached, its key server offer included, is gone.
  Future<void> search(LookupAddress address) async {
    if (busy || _closed) return;
    if (_gate.offline) return _set(SearchPaused(address, KeySearchStep.domain));
    _set(SearchAskingDomain(address));
    final outcome = await searchWkd(address, client: _client, resolve: _resolve, abandon: _abandon.future);
    await _judge(address, outcome, KeySearchStep.domain);
  }

  /// Asks keys.openpgp.org, the person's second answer; nothing unless
  /// [canAskKeyServer].
  Future<void> askKeyServer() async {
    final state = value;
    if (!canAskKeyServer || _closed || state is! SearchOf) return;
    final address = state.address;
    if (_gate.offline) return _set(SearchPaused(address, KeySearchStep.server));
    _set(SearchAskingServer(address));
    final outcome = await searchVks(address, client: _client, abandon: _abandon.future);
    await _judge(address, outcome, KeySearchStep.server);
  }

  /// Asks again the service that could not be asked, and only that one.
  Future<void> retry() => switch (value) {
    SearchCouldNotAsk(step: KeySearchStep.domain, :final address) ||
    SearchPaused(step: KeySearchStep.domain, :final address) => search(address),
    SearchCouldNotAsk(step: KeySearchStep.server) || SearchSlowDown() || SearchPaused(step: KeySearchStep.server) => askKeyServer(),
    _ => Future.value(),
  };

  /// Goes back to nothing asked, as when the address is changed.
  void reset() {
    if (!busy) _set(const SearchIdle());
  }

  Future<void> _judge(LookupAddress address, LookupOutcome outcome, KeySearchStep step) async {
    if (_closed) return;
    final none = step == KeySearchStep.domain ? SearchDomainHasNone(address) : SearchNowhere(address);
    switch (outcome) {
      case LookupAnswered(:final bytes):
        List<crypto.PgpPublicKey> keys;
        try {
          keys = await _read(bytes, address.address, _now());
        } on Object {
          // An answer that can't be read holds no key this app takes
          keys = const [];
        }
        _set(keys.isEmpty ? none : SearchFound(address, keys, step == KeySearchStep.domain ? ContactSource.wkd : ContactSource.keyserver));
      case LookupNoKey():
        _set(none);
      case LookupUnreachable():
        _set(SearchCouldNotAsk(address, step));
      case LookupSlowDown():
        _set(SearchSlowDown(address));
      case LookupPaused():
        _set(SearchPaused(address, step));
    }
  }

  void _set(KeySearchState state) {
    if (!_closed) value = state;
  }

  @override
  void dispose() {
    _closed = true;
    if (!_abandon.isCompleted) _abandon.complete();
    super.dispose();
  }
}
