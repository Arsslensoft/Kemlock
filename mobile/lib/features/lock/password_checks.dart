import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_store.dart';
import 'unlock_attempts.dart';

/// Runs [change], which makes a vault with a password or gives the open
/// vault a password, and so checks first whether that password opens a
/// vault on this phone: it throws [PasswordInUseError] when it does.
///
/// One password opens one vault, or the lock screen couldn't tell which was
/// meant, so the change has to refuse a password in use, and in refusing it
/// says that the password opens another vault, a hidden one too. Whoever is
/// handed a decoy vault open could otherwise type password after password
/// at it, uncounted, where the lock screen counts each one. So each check
/// is counted as a try on the slot the lock screen counts the open vault's
/// tries on, its own count when it is listed, else the phone's, and reaches
/// the phone's storage before the password is checked, as on the lock
/// screen. A password that opens no vault, which the change then used, is
/// given back; one that another vault uses stays counted, as a wrong
/// password does. Once the count reaches the erase set in Settings, the
/// vault locks, and the lock screen erases every vault as it opens.
///
/// What stays, as on the lock screen: each check still tells whether a
/// password opens a vault, and opening the decoy from the lock screen sets
/// its count back to zero.
Future<T> countedPasswordCheck<T>(WidgetRef ref, Future<T> Function() change) async {
  final attempts = ref.read(unlockAttemptsProvider);
  final vaults = ref.read(vaultRegistryProvider);
  final open = vaults.active;
  final slot = vaults.isListed(open) ? open : null;
  final before = await attempts.countTry(slot);
  try {
    final changed = await change();
    attempts.restore(slot, before);
    return changed;
  } on PasswordInUseError {
    final eraseAfter = readUnlockErase(ref.read(keyValueStoreProvider));
    if (eraseAfter != null && attempts.read(slot).count >= eraseAfter) ref.read(vaultControllerProvider.notifier).lock();
    rethrow;
  } catch (_) {
    // Anything else is no answer about the password: nothing was learnt
    attempts.restore(slot, before);
    rethrow;
  }
}
