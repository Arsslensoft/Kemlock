/// The offer to move a vault from Vaultwarden to Kemlock Server (add-kemlock-server-sync, task 12.2): a Vaultwarden
/// server that also speaks Kemlock's own API says so in its `/api/config`, under `kemlock`
/// (`{"api": "https://host/kem/v1", "versions": ["v1"]}`). The Vaultwarden sheet shows "This server also speaks
/// Kemlock's own API" with Move and Not now, at most once a day, and changes nothing on its own.
///
/// Move hands off to the move of `move-off-vaultwarden-sync` through [moveOffVaultwardenProvider], which takes the
/// sheet's context, the Vaultwarden target and what the server offered. Its default opens Kemlock Server's sign-in
/// at the server's address with the account's email filled in; the move's own sheet follows it.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../kemlock_setup.dart' show showKemlockSignInForMove;
import 'vw_api.dart' show jsonKey;
import 'vw_models.dart';

/// What a Vaultwarden server's `/api/config` says about Kemlock's own API.
class KemlockOffer {
  const KemlockOffer({required this.api, required this.versions});

  /// The address of the API, `https://host/kem/v1`.
  final String api;
  final List<String> versions;

  /// The offer in [config], or null when the server has none: no `kemlock` member, no `v1` among its versions, or
  /// an address that isn't https.
  static KemlockOffer? fromConfig(Map<String, Object?> config) {
    final member = jsonKey(config, 'kemlock');
    if (member is! Map<String, Object?>) {
      return null;
    }
    final versions = jsonKey(member, 'versions');
    final api = jsonKey(member, 'api');
    if (versions is! List || !versions.contains('v1') || api is! String || Uri.tryParse(api)?.scheme != 'https') {
      return null;
    }
    return KemlockOffer(api: api, versions: [for (final version in versions) ?(version is String ? version : null)]);
  }
}

/// The day [now] is in, as the offer counts days: the phone's own calendar day, `yyyy-mm-dd`.
String offerDay(DateTime now) {
  final day = now.toLocal();
  return '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
}

/// Whether the offer may be read and shown on [now]: not already on that day.
bool offerDue(VaultwardenTarget target, DateTime now) => target.kemlockOfferDay != offerDay(now);

/// The seam of `move-off-vaultwarden-sync`: starts the move for [target], offered [offer]: the sign-in to the
/// server's Kemlock API, then the move's sheet, which asks before anything is written. Tests override it to see
/// what was handed over.
typedef MoveOffVaultwardenSheet = Future<void> Function(BuildContext context, VaultwardenTarget target, KemlockOffer offer);

final moveOffVaultwardenProvider = Provider<MoveOffVaultwardenSheet>(
  (ref) =>
      (context, target, offer) => showKemlockSignInForMove(context, address: target.server, email: target.email),
);
