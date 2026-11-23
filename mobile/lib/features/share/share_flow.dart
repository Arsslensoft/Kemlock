/// What the open vault's shell does with a shared item (openspec:
/// add-share-extension, decisions 7 and 9): the sheet for what the item is.
/// A shared Send link goes to the Send sheet instead (`docs/plans/add-sends.md`,
/// decision 2).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/send_links.dart';
import '../../platform/shared_items.dart';
import '../pgp/decrypt_sheet.dart';
import '../pgp/verify_sheet.dart';
import 'share_sheet.dart';
import 'shared_kind.dart';

/// Takes the item waiting in [pendingShareProvider] and offers it in the
/// vault now open, whichever it is: an encrypted message opens Decrypt and
/// a signed one Verify, with no question asked; anything else opens
/// "Shared to Kemlock". The sheet it goes to deletes its file when done
/// with it.
Future<void> offerSharedItem(BuildContext context, WidgetRef ref) async {
  final pending = ref.read(pendingShareProvider.notifier);
  final item = pending.take();
  if (item == null) return;
  // A Send link opens a Send, which needs no account, so it goes to the Send sheet whatever vault is open
  if (item is SharedText && ref.read(pendingSendLinkProvider.notifier).offer(item.text)) return;
  if (!context.mounted) {
    if (item is SharedFile) deleteSharedFile(item.path);
    return;
  }
  if (item is SharedFile) pending.inUse(item.path);
  final file = item is SharedFile ? pickedOf(item) : null;
  final text = item is SharedText ? item.text : null;
  unawaited(switch (sharedKindOf(item)) {
    SharedKind.encrypted => showDecryptSheet(context, text: text, file: file),
    SharedKind.signed => showVerifySheet(context, text: text, file: file),
    // The signature is set; the file it signs is the person's to choose
    SharedKind.detachedSignature => showVerifySheet(context, text: text, signature: file),
    SharedKind.other => showShareSheet(context, item),
  });
}
