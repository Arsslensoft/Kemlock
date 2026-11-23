/// Another app's export, handed over by the phone (openspec: plan add-credential-exchange, task
/// 3.4): the transfers the Import sheet takes, the rows it shows for them, and the line the lock
/// screen shows while an iOS hand-off waits for a vault.
///
/// On Android the sheet starts the transfer itself, through the build's [CredentialTransfer]. On
/// iOS the other app does, and the system launches Kemlock with a token: the token waits here, in
/// memory and nothing else, until a vault is open, and only then does the sheet ask the system for
/// the data, so the plain payload never sits in memory behind the lock screen (design decision 7).
/// Both end in the same preview as a file.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/build_kind.dart';
import '../../i18n/messages.dart';
import '../../platform/credential_exchange.dart';
import '../../ui/ui.dart';

export '../../platform/credential_exchange.dart' show CredentialTransfer, CredentialTransferException, CredentialTransferProblem;

/// The Credential Exchange credential types Kemlock keeps, which the Android request names: the
/// exporter lists only the apps that hold some of them and sends no more. Types Kemlock can't keep
/// (`file`, `wifi`, `api-key`, `generated-password`, `item-reference`) are left out of the ask.
const credentialTypesKept = {
  'basic-auth',
  'totp',
  'passkey',
  'note',
  'credit-card',
  'address',
  'person-name',
  'identity-document',
  'passport',
  'drivers-license',
  'ssh-key',
  'custom-fields',
};

/// What the Import sheet gets its payload from, in place of a file.
sealed class ImportTransfer {
  const ImportTransfer();
}

/// Android's list of exporters, which the sheet opens when the person taps its row.
final class PhoneTransfer extends ImportTransfer {
  const PhoneTransfer();
}

/// An iOS hand-off: the token of the export the system launched Kemlock for.
final class IosTransfer extends ImportTransfer {
  const IosTransfer(this.token);

  final String token;
}

/// The CXF JSON [transfer] gives, read only now; null when the person closed Android's list.
/// Throws a [CredentialTransferException], [NotInThisBuild] or [IosExchangeFailed].
Future<String?> fetchTransfer(WidgetRef ref, ImportTransfer transfer) => switch (transfer) {
  PhoneTransfer() => ref.read(credentialTransferProvider).importCredentials(credentialTypesKept),
  IosTransfer(:final token) => ref.read(iosCredentialExchangeProvider).fetch(token),
};

/// What a failed transfer says. Never the other app's data, which an error doesn't hold.
String transferError(BuildContext context, Object error) => switch (error) {
  CredentialTransferException(:final problem) => context.t('import.transfer.error.${problem.name}'),
  IosExchangeFailed() => context.t('import.transfer.error.ios'),
  NotInThisBuild() => context.t('import.transfer.error.unavailable'),
  _ => context.t('import.transfer.error.unknown'),
};

/// The row the Import sheet shows for another app on this phone.
enum ExchangeRow {
  /// Nothing: this phone can't take part (Android before 8, iOS before 26), or isn't a phone.
  none,

  /// Android, store build: a button that opens the system's list of exporters.
  phone,

  /// iOS 26 and later: the steps to start the export in the other app, which Kemlock can't start.
  iosSteps,

  /// Android, free build: no row, and the help that says why and what to do instead.
  freeHelp,
}

/// Which of the rows applies on this phone and in this build.
final exchangeRowProvider = FutureProvider<ExchangeRow>((ref) async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
      return await ref.read(iosCredentialExchangeProvider).supported() ? ExchangeRow.iosSteps : ExchangeRow.none;
    case TargetPlatform.android:
      if (ref.read(buildKindProvider) == BuildKind.free) {
        return ExchangeRow.freeHelp;
      }
      return await ref.read(credentialTransferProvider).isAvailable() ? ExchangeRow.phone : ExchangeRow.none;
    case TargetPlatform.fuchsia || TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows:
      return ExchangeRow.none;
  }
});

/// The Import sheet's rows for another app on this phone: a button on Android, the steps on iOS,
/// the free build's help, or nothing. [onStart] runs when the Android button is tapped, and the
/// button waits while [busy].
class ExchangeRows extends ConsumerWidget {
  const ExchangeRows({super.key, required this.onStart, required this.busy});

  final VoidCallback onStart;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final row = ref.watch(exchangeRowProvider).value ?? ExchangeRow.none;
    return switch (row) {
      ExchangeRow.none => const SizedBox.shrink(),
      ExchangeRow.phone => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t('import.transfer.android.title'), style: AppType.body2.copyWith(color: p.text)),
            const SizedBox(height: 4),
            Text(context.t('import.transfer.android.detail'), style: AppType.caption.copyWith(color: p.textSecondary)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: smallButtonStyle,
              onPressed: busy ? null : onStart,
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: Text(context.t('import.transfer.android.button')),
            ),
          ],
        ),
      ),
      ExchangeRow.iosSteps => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t('import.transfer.ios.title'), style: AppType.body2.copyWith(color: p.text)),
            const SizedBox(height: 4),
            Text(context.t('import.transfer.ios.steps'), style: AppType.caption.copyWith(color: p.textSecondary)),
          ],
        ),
      ),
      ExchangeRow.freeHelp => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text(context.t('import.transfer.free.help'), style: AppType.caption.copyWith(color: p.textSecondary)),
      ),
    };
  }
}

/// How long an iOS hand-off waits for a vault to be opened. Apple's page doesn't say how long a
/// token stays valid (plan task 4.4), so the wait is the one a shared item has.
const credentialExchangeLife = Duration(minutes: 10);

/// The token of an iOS hand-off, kept in memory until a vault is open: the lock screen shows that
/// one waits, and the open vault's shell takes it and opens the Import sheet on it. It is forgotten
/// when taken, dropped ("Not now"), [credentialExchangeLife] after it arrived, and when a newer one
/// replaces it. Nothing of the export is read until the sheet asks for it.
class PendingCredentialExchange extends Notifier<String?> {
  Timer? _timer;

  @override
  String? build() {
    final exchange = ref.watch(iosCredentialExchangeProvider);
    final sub = exchange.incoming.listen(_arrived);
    ref.onDispose(() {
      unawaited(sub.cancel());
      _timer?.cancel();
    });
    unawaited(
      exchange
          .initial()
          .then((token) {
            if (token != null) {
              _arrived(token);
            }
          })
          .catchError((Object _) {}),
    );
    return null;
  }

  void _arrived(String token) {
    state = token;
    _timer?.cancel();
    _timer = Timer(credentialExchangeLife, drop);
  }

  /// The token, now handed to the sheet, and forgotten.
  String? take() {
    final token = state;
    drop();
    return token;
  }

  /// Forgets the token.
  void drop() {
    _timer?.cancel();
    state = null;
  }
}

final pendingCredentialExchangeProvider = NotifierProvider<PendingCredentialExchange, String?>(PendingCredentialExchange.new);

/// Whether an iOS hand-off waits for a vault to be opened, for the lock screen to show
/// [CredentialExchangeWaiting].
bool credentialExchangeWaits(WidgetRef ref) => ref.watch(pendingCredentialExchangeProvider) != null;

/// The lock screen's line while an iOS hand-off waits. It says that an import waits and never from
/// which app or what it holds, since the lock screen can be seen by whoever the phone was handed to;
/// with several vaults it is the picker above that chooses the one to import into. "Not now" drops
/// the token, and unlocking then opens the vault with nothing offered.
class CredentialExchangeWaiting extends ConsumerWidget {
  const CredentialExchangeWaiting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AppAlert(
    severity: AlertSeverity.info,
    child: Row(
      children: [
        Expanded(child: Text(context.t('import.transfer.lock.waiting'))),
        const SizedBox(width: 8),
        TextButton(
          style: smallButtonStyle,
          onPressed: () => ref.read(pendingCredentialExchangeProvider.notifier).drop(),
          child: Text(context.t('import.transfer.lock.notNow')),
        ),
      ],
    ),
  );
}
