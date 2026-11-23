import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../sync/sync_store.dart';
import 'sends_recipient.dart';
import 'sends_service.dart';

/// Opens Sends from links, over the app's gated client with no pin (`kemlockClientFactoryProvider`): offline mode
/// refuses it. It needs no account. Tests override it with a fake server's client.
final sendsRecipientProvider = Provider<SendsRecipient>((ref) => SendsRecipient(clientFor: ref.watch(kemlockClientFactoryProvider)));

/// The owner's Sends of the vault's Kemlock Server account, or null when there is none to ask: no Kemlock Server sync,
/// or the sync's host isn't running (the vault is locked, or offline mode has stopped sync).
final sendsServiceProvider = Provider<SendsService?>((ref) {
  final host = ref.watch(kemlockHostProvider);
  final target = ref.watch(syncProvider.select((state) => state.settings?.kemlock));
  if (host == null || target == null) return null;
  return SendsService(host: host, target: target, clock: ref.watch(clockProvider));
});
