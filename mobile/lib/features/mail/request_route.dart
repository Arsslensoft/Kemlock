/// What a mail app's request screen shows (openspec: add-pgp-mail-provider,
/// decisions 3 and 11). When the request screen attaches to the engine,
/// [MailRequestHost] puts the request above everything else: while the
/// vault is locked, the app's own lock screen, which then carries
/// [MailRequestLine]; once a vault is open, the steps the handler asks
/// for, one after another, and then the request screen closes and the mail
/// app sends its request again. The app's own pages stay where they were,
/// out of sight.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/keys/pgp.dart' as pgp;
import '../../i18n/messages.dart';
import '../../platform/mail_requests.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../contacts/contact_check.dart';
import '../pgp/pgp_widgets.dart' show askPgpPassphrase;
import 'approve_screen.dart';
import 'mail_apps.dart';
import 'mail_handler.dart';
import 'mail_keys.dart';
import 'mail_service.dart';
import 'request_screens.dart';

/// Shows the request in front, if any, above [child], the app.
class MailRequestHost extends ConsumerWidget {
  const MailRequestHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final front = ref.watch(mailFrontProvider);
    final unlocked = ref.watch(vaultControllerProvider.select((state) => state.isUnlocked));
    // Locked, the app's own lock screen asks, with the line naming the app
    if (front == null || !unlocked) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          child: TickerMode(enabled: false, child: ExcludeFocus(child: child)),
        ),
        // A navigator of its own, for the dialogs of the steps
        Navigator(
          key: ValueKey('mail-request-${front.requestId}'),
          onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => MailRequestFlow(front: front)),
        ),
      ],
    );
  }
}

/// The lock screen's line while a request is in front: which app asks,
/// and Cancel, which tells the mail app the request was cancelled and
/// leaves the vault locked.
class MailRequestLine extends ConsumerWidget {
  const MailRequestLine({super.key, required this.front});

  final MailFront front;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AppAlert(
    key: const ValueKey('mail-request-line'),
    severity: AlertSeverity.info,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(context.t('mail.lock.request', {'app': front.caller.name})),
        Text(front.caller.package, style: AppType.caption.copyWith(color: context.palette.textSecondary)),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            onPressed: () => unawaited(ref.read(mailFrontProvider.notifier).finish(front.requestId, ok: false)),
            child: Text(context.t('mail.lock.cancel')),
          ),
        ),
      ],
    ),
  );
}

/// The steps of one request, in an open vault.
class MailRequestFlow extends ConsumerStatefulWidget {
  const MailRequestFlow({super.key, required this.front});

  final MailFront front;

  @override
  ConsumerState<MailRequestFlow> createState() => _MailRequestFlowState();
}

class _MailRequestFlowState extends ConsumerState<MailRequestFlow> {
  MailStep? _step;
  var _done = false;

  String get _id => widget.front.requestId;

  @override
  void initState() {
    super.initState();
    unawaited(_next());
  }

  /// Shows what is still to ask, or closes the screen when nothing is.
  Future<void> _next() async {
    final handler = ref.read(mailHandlerProvider);
    // A request this app never kept, or forgot: nothing to go on with
    if (handler.pending(_id) == null) return _finish(false);
    final step = await handler.stepFor(_id);
    if (!mounted || _done) return;
    if (step == null) return _finish(true);
    // Locked meanwhile: the host shows the lock screen
    if (step is UnlockStep) return;
    ref.read(mailFrontProvider.notifier).asked(_id);
    setState(() => _step = step);
    if (step is PassphraseStep) unawaited(_askPassphrase(step));
  }

  Future<void> _finish(bool ok, [Map<String, Object?> extras = const {}]) async {
    if (_done) return;
    _done = true;
    await ref.read(mailFrontProvider.notifier).finish(_id, ok: ok, extras: extras);
  }

  MailKeys _keys() => readMailKeys(ref.read);

  Future<void> _askPassphrase(PassphraseStep step) async {
    final key = _keys().ownByVaultId(step.vaultKeyId);
    if (key == null) return _next();
    final messages = ref.read(messagesProvider);
    String? error;
    while (!_done) {
      if (!mounted) return;
      final passphrase = await askPgpPassphrase(
        context,
        title: messages.t('pgp.keyPassphrase.title', {'name': key.title}),
        body: messages.t('mail.passphrase.body', {'app': widget.front.caller.name}),
        error: error,
      );
      if (!mounted || _done) return;
      if (passphrase == null) return _finish(false);
      try {
        await ref.read(mailHandlerProvider).openKey(step.vaultKeyId, passphrase);
      } on pgp.PgpException catch (e) {
        if (e.problem != pgp.PgpProblem.wrongPassphrase) return _finish(false);
        error = messages.t('pgp.error.wrongPassphrase');
        continue;
      }
      return _next();
    }
  }

  @override
  Widget build(BuildContext context) {
    final caller = widget.front.caller;
    final apps = ref.read(mailAppsProvider.notifier);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_finish(false));
      },
      child: switch (_step) {
        ApproveStep(:final otherCertificate) => MailApproveScreen(
          key: const ValueKey('mail-approve'),
          caller: caller,
          otherCertificate: otherCertificate,
          onAllowed: () => unawaited(_next()),
          onDenied: () => unawaited(_finish(false)),
        ),
        PickKeyStep(:final address, :final preselect) => MailKeyPicker(
          caller: caller,
          address: address,
          preselect: preselect,
          onPick: (key) async {
            await apps.allowKey(caller.package, key.key.id);
            await _finish(true, {'sign_key_id': key.keyId});
          },
          onCancel: () => unawaited(_finish(false)),
        ),
        AddKeyStep(:final vaultKeyId) => MailAddKeyScreen(
          caller: caller,
          keyTitle: _keys().ownByVaultId(vaultKeyId)?.title ?? vaultKeyId,
          onAllow: () async {
            await apps.allowKey(caller.package, vaultKeyId);
            await _next();
          },
          onDeny: () => unawaited(_finish(false)),
        ),
        MissingKeysStep(:final addresses) => MailMissingKeysScreen(addresses: addresses, onClose: () => unawaited(_finish(false))),
        UncheckedStep(:final contactIds) => _unchecked(contactIds),
        // Waiting for the handler, or the passphrase dialog over the page
        _ => MailRequestPage(
          title: context.t('mail.approve.title', {'app': caller.name}),
          children: const [Center(child: Spinner())],
        ),
      },
    );
  }

  Widget _unchecked(List<String> contactIds) {
    final keys = _keys();
    final contacts = [
      for (final id in contactIds)
        if (keys.contacts.firstWhereOrNull((k) => k.contact.id == id) case final k?) (contact: k.contact, fingerprint: k.fingerprint),
    ];
    if (contacts.isEmpty) {
      unawaited(_next());
      return const SizedBox.shrink();
    }
    return MailUncheckedScreen(
      caller: widget.front.caller,
      contacts: contacts,
      onCheck: (contact) async {
        if (await checkContactFingerprint(context, ref, contact)) await _next();
      },
      onGoOn: () async {
        await ref.read(mailAppsProvider.notifier).goOn(widget.front.caller.package, [for (final c in contacts) c.fingerprint]);
        await _next();
      },
      onCancel: () => unawaited(_finish(false)),
    );
  }
}
