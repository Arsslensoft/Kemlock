/// Joins the mail provider's channel to the handler, from launch and
/// outside any screen (openspec: add-pgp-mail-provider, decisions 1 and
/// 3): `main` reads [mailServiceProvider] once. It also keeps which
/// request screen is in front, for the request route and the lock
/// screen's line, and closes request screens.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/mail_requests.dart';
import '../../vault/vault_controller.dart';
import 'mail_grants.dart';
import 'mail_handler.dart';

/// The request screen in front, or null while the app's own screen is.
class MailFrontNotifier extends Notifier<MailFront?> {
  /// The request screens that asked the person something: a step, or the
  /// vault's password, as it opened while they were in front.
  final _asked = <String>{};

  @override
  MailFront? build() {
    // The vault opened while a request screen was in front: the person unlocked for it
    ref.listen(vaultControllerProvider.select((vault) => vault.isUnlocked), (was, unlocked) {
      final front = state;
      if (unlocked && was == false && front != null) _asked.add(front.requestId);
    });
    return null;
  }

  void show(MailFront? front) => state = front;

  /// The request screen [requestId] asks the person a step.
  void asked(String requestId) => _asked.add(requestId);

  /// The request screen [requestId] went away without being finished.
  void left(String requestId) {
    _asked.remove(requestId);
    if (state?.requestId == requestId) state = null;
  }

  /// Closes the request screen [requestId]: with [ok], the mail app gets
  /// its request back, with [extras] added, to send again, and the request
  /// a grant (decision 7) when the screen asked the person something; else
  /// it is told the request was cancelled. A screen that asked nothing gets
  /// no grant: a mail app that fires a request screen of its own accord
  /// must not hold auto-lock off with it. The request is forgotten either way.
  Future<void> finish(String requestId, {required bool ok, Map<String, Object?> extras = const {}}) async {
    if (state?.requestId == requestId) state = null;
    ref.read(mailHandlerProvider).forget(requestId);
    final asked = _asked.remove(requestId);
    final grants = ref.read(mailGrantsProvider);
    if (!ok) {
      grants.end(requestId);
    } else if (asked) {
      grants.record(requestId);
    }
    await ref.read(mailRequestsProvider).finish(requestId, ok: ok, extras: extras);
  }
}

final mailFrontProvider = NotifierProvider<MailFrontNotifier, MailFront?>(MailFrontNotifier.new);

/// Serves the channel for as long as the app runs.
final mailServiceProvider = Provider<void>((ref) {
  final handler = ref.watch(mailHandlerProvider);
  ref
      .watch(mailRequestsProvider)
      .serve(
        answer: (call) async {
          try {
            final answer = await handler.answer(call);
            // Not answered yet: the same request comes again with its input
            if (!answer.wantsInput) ref.read(mailGrantsProvider).answered(call, answer);
            return answer;
          } on Object catch (error) {
            // An answer always goes back: the binder thread waits for it
            final message = ref.read(messagesProvider).t('mail.error.unsupported', {'action': '$error'});
            return MailAnswer({
              'result_code': OpenPgp.resultError,
              'error': {'id': OpenPgp.genericError, 'message': message},
            });
          }
        },
        front: (front) => ref.read(mailFrontProvider.notifier).show(front),
        left: (requestId) => ref.read(mailFrontProvider.notifier).left(requestId),
      );
});
