import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../models/secure_note.dart';
import '../../models/vault_file.dart';
import '../../platform/files.dart';
import '../../vault/attachment_seal.dart';
import '../../vault/attachment_store.dart';
import '../../vault/vault_controller.dart';

/// Seals [picked] as a note's attachment is, and stores the sealed bytes in the vault's attachment store under the entry's id. A file
/// over the limit is refused with the message notes give, and a failed write says so; null in both cases and nothing is stored.
Future<NoteAttachment?> sealAndStoreFile(ProviderContainer container, PickedFile picked) async {
  final messages = container.read(messagesProvider);
  final toasts = container.read(toastsProvider.notifier);
  if (picked.bytes.length > attachmentSizeLimit) {
    toasts.show(messages.t('notes.attach.tooLarge', {'size': attachmentSizeLimit ~/ (1024 * 1024)}), severity: ToastSeverity.error);
    return null;
  }
  final now = container.read(clockProvider)().millisecondsSinceEpoch;
  final vaultId = container.read(vaultControllerProvider).vault.id;
  try {
    final sealed = await sealAttachment(picked.bytes, name: picked.name, type: picked.mimeType, now: now);
    await container.read(attachmentStoreProvider).writeSealed(vaultId, sealed.entry.id, sealed.sealed);
    return sealed.entry;
  } on ArgumentError {
    toasts.show(messages.t('notes.attach.tooLarge', {'size': attachmentSizeLimit ~/ (1024 * 1024)}), severity: ToastSeverity.error);
    return null;
  } catch (_) {
    toasts.show(messages.t('files.add.failed'), severity: ToastSeverity.error);
    return null;
  }
}

/// "New file" in the vault's add menu: picks a file, seals and stores it, and saves a File item named after it. True once the item is
/// saved. A file that was stored and whose item then failed to save is left for the sweep at unlock.
Future<bool> addFileItem(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final picked = await container.read(fileServiceProvider).pickFile();
  if (picked == null) return false;
  final entry = await sealAndStoreFile(container, picked);
  if (entry == null) return false;
  final item = VaultFile(id: newUuid(), name: picked.name, file: entry, addedAt: entry.addedAt);
  return container.read(vaultControllerProvider.notifier).addFile(item);
}
