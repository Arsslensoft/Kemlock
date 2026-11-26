import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/custom_field.dart';
import '../sync/kemlock/km_custom_fields.dart';
import '../sync/sync_store.dart';

/// The last answer of the server, kept in memory for as long as the app runs and for one account: what the editor offers
/// while the phone is offline, or the server can't be reached.
class _LastDefinitions {
  String? _account;
  KmCustomFields? _answer;

  KmCustomFields? of(String account) => _account == account ? _answer : null;

  void keep(String account, KmCustomFields answer) {
    _account = account;
    _answer = answer;
  }
}

final _lastDefinitionsProvider = Provider<_LastDefinitions>((ref) => _LastDefinitions());

/// The custom fields the admin of the vault's Kemlock Server account offers (`GET /kem/v1/custom-fields`), read when the
/// vault syncs with that account and again after each run. It is null when there is no Kemlock Server account, or none
/// was ever read on this run and the server can't be asked (offline mode, a locked vault, no network): the editor then
/// offers nothing from an admin, lets the person add their own, and leaves the admin fields an item holds as they are.
/// A server that can't be reached after an earlier answer gives that answer.
final kmCustomFieldsProvider = FutureProvider<KmCustomFields?>((ref) async {
  final host = ref.watch(kemlockHostProvider);
  final target = ref.watch(syncProvider.select((sync) => sync.settings?.kemlock));
  // A run in progress changes nothing here, and the one after it asks again
  final running = ref.watch(syncProvider.select((sync) => sync.running));
  final last = ref.read(_lastDefinitionsProvider);
  if (target == null) {
    return null;
  }
  final account = target.accountId;
  if (host == null || running) {
    return last.of(account);
  }
  try {
    final answer = await host.withAccount(target, (connection, _) => fetchKmCustomFields(connection));
    last.keep(account, answer);
    return answer;
  } on Object {
    return last.of(account);
  }
});

/// Whether [field] is the admin's: it was made from a definition [definitions] still has. A field whose definition is not
/// known (it was deleted, or the answer was never read) is the person's own, in the editor and in the view alike.
bool isAdminField(CustomField field, KmCustomFields? definitions) {
  final id = field.adminField;
  return id != null && definitions?.definition(id) != null;
}
