import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/sends/send_link.dart';
import '../vault/vault_controller.dart';

/// A Send link another app shared, waiting for the open vault's shell to show it (`docs/plans/add-sends.md`, design
/// 9), in the shape of `PendingSetupLink`. A shared text that [SendLink.parse] reads is put here by
/// `offerSharedItem`, because opening a Send needs no account, and the shell
/// takes it and opens the Send sheet.
///
/// It holds the text the link came in, which holds the key, in memory only, and forgets it when taken and whenever
/// the vault locks or opens.
class PendingSendLink extends Notifier<String?> {
  @override
  String? build() {
    ref.watch(vaultControllerProvider.select((state) => state.session));
    return null;
  }

  /// Keeps [text] when it holds a Send link, a Kemlock one or a Bitwarden one; false for anything else.
  bool offer(String text) {
    final link = SendLink.parse(text);
    if (link == null) return false;
    // A parsed Kemlock link holds its own copy of the key, which isn't needed here
    if (link is SendLink) link.wipeKey();
    state = text;
    return true;
  }

  /// The text, now shown, and forgotten.
  String? take() {
    final text = state;
    state = null;
    return text;
  }
}

final pendingSendLinkProvider = NotifierProvider<PendingSendLink, String?>(PendingSendLink.new);
