/// Opening a Send a link names, with no account (`docs/plans/add-sends.md`, design 7 and tasks 7.3, 8 and 10.1). The
/// sheet opens the link with [SendsRecipient], asks for the password only when the server says the Send has one (the
/// proof is made off the UI thread, and a 429 disables the field for the wait), and then shows what the Send holds:
///
/// - a text, in a selection that copies through the secret clipboard and leaves out Share, Look Up and Search Web,
///   with Copy and "Save as note";
/// - a file's name, type and size, with Save and Share. The file's bytes are fetched once, on the first of them, which
///   spends an open, and are held in memory only: a second Save or a Share uses them, and nothing is written to disk
///   but what the system's own save or share sheet takes.
///
/// The sender's email is the server's word and is shown as that. Offline mode says so with no request, and offers
/// "Open in browser", which asks first as every link does. A file over 50 MB isn't downloaded: the browser is offered.
/// Everything held (the link's key, the proof, the file's bytes and the text) is dropped when the sheet closes or the
/// vault locks.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../core/toasts.dart';
import '../../crypto/account/encoding.dart' show wipe;
import '../../i18n/messages.dart';
import '../../models/secure_note.dart';
import '../../platform/files.dart';
import '../../platform/links.dart';
import '../../platform/network.dart';
import '../../platform/secret_clipboard.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../lock/gate_widgets.dart';
import '../notes/note_files.dart' show fileSizeText;
import '../settings/offline_alert.dart';
import '../sync/kemlock/km_api.dart';
import '../sync/kemlock/km_sends_api.dart';
import '../sync/sync_sheet_frame.dart';
import 'send_link.dart';
import 'sends_providers.dart';
import 'sends_recipient.dart';
import 'sends_service.dart' show sendFileLimit;
import 'sends_support.dart';

/// Reads [text] for a Send link and opens it: a Kemlock Send in its sheet, a Bitwarden one in the browser (which asks
/// first while offline mode is on). False when [text] holds no Send link; the link is never read from the clipboard
/// here, only from what the person pasted or another app shared.
Future<bool> openSendLinkText(BuildContext context, WidgetRef ref, String text) async {
  final link = SendLink.parse(text);
  if (link == null) return false;
  switch (link) {
    case BitwardenSendLink(:final url):
      final uri = Uri.tryParse(url);
      if (uri != null) await ref.read(linkOpenerProvider).open(context, uri);
    case final SendLink send:
      await showReceivedSendSheet(context, send);
  }
  return true;
}

/// Shows the sheet that opens [link].
Future<void> showReceivedSendSheet(BuildContext context, SendLink link) => showAppBottomSheet<void>(
  context,
  label: context.t('sends.received.title'),
  builder: (_) => ReceivedSendSheet(link: link),
);

enum _Stage { loading, password, shown, failed, offline }

/// The sheet that opens a Send from its link.
class ReceivedSendSheet extends ConsumerStatefulWidget {
  const ReceivedSendSheet({super.key, required this.link});

  final SendLink link;

  @override
  ConsumerState<ReceivedSendSheet> createState() => _ReceivedSendSheetState();
}

class _ReceivedSendSheetState extends ConsumerState<ReceivedSendSheet> {
  var _stage = _Stage.loading;
  final _password = TextEditingController();
  var _showPassword = false;
  ReceivedSend? _received;
  Uint8List? _plain;
  String? _failure;
  String? _hint;
  String? _passwordNote;
  var _wait = 0;
  Timer? _timer;
  var _busy = false;
  var _browserOffered = false;

  @override
  void initState() {
    super.initState();
    // A vault that locks takes the sheet with it
    ref.listenManual(vaultControllerProvider.select((state) => state.phase), (_, phase) {
      if (phase != VaultPhase.unlocked && mounted) Navigator.of(context).maybePop();
    });
    unawaited(_open());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _password.clear();
    _password.dispose();
    final plain = _plain;
    if (plain != null) wipe(plain);
    _plain = null;
    _received?.dispose();
    widget.link.wipeKey();
    super.dispose();
  }

  Future<void> _open({String? password}) async {
    if (ref.read(offlineProvider)) {
      setState(() => _stage = _Stage.offline);
      return;
    }
    setState(() {
      _busy = true;
      _passwordNote = null;
    });
    try {
      final received = await ref.read(sendsRecipientProvider).open(widget.link, password: password);
      if (!mounted) {
        received.dispose();
        return;
      }
      setState(() {
        _received = received;
        _stage = _Stage.shown;
      });
    } on SendsError catch (e) {
      if (!mounted) return;
      switch (e.problem) {
        case SendsProblem.passwordRequired:
          setState(() => _stage = _Stage.password);
        case SendsProblem.wrongPassword:
          setState(() {
            _stage = _Stage.password;
            _passwordNote = context.t('sends.received.wrongPassword');
            _password.clear();
          });
        case SendsProblem.rateLimited:
          _startWait(sendsWaitSeconds(e.retryAfter));
        case SendsProblem.notFound:
          _fail(context.t('sends.received.notAvailable'), hint: context.t('sends.received.notAvailable.hint'));
        default:
          _fail(sendsErrorText(context, e));
      }
    } on SendsDoesntOpen {
      if (mounted) _fail(context.t('sends.received.doesntOpen'));
    } on KmError catch (e) {
      if (!mounted) return;
      if (e.problem == KmProblem.insecure) {
        _fail(context.t('sends.received.insecure'));
      } else if (ref.read(offlineProvider)) {
        setState(() => _stage = _Stage.offline);
      } else {
        _fail(context.t('sends.received.network', {'host': widget.link.host}), browser: true);
      }
    } on Object {
      if (mounted) _fail(context.t('sends.received.doesntOpen'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fail(String message, {String? hint, bool browser = false}) {
    setState(() {
      _stage = _Stage.failed;
      _failure = message;
      _hint = hint;
      _browserOffered = browser;
    });
  }

  void _startWait(int seconds) {
    _timer?.cancel();
    setState(() {
      _stage = _Stage.password;
      _wait = seconds;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _wait--);
      if (_wait <= 0) timer.cancel();
    });
  }

  Future<void> _browser() async {
    final uri = Uri.tryParse(widget.link.toLinkText());
    if (uri != null) await ref.read(linkOpenerProvider).open(context, uri);
  }

  Future<void> _copy(String text) async {
    final copied = await ref.read(secretClipboardProvider).copy(text);
    if (!mounted) return;
    ref
        .read(toastsProvider.notifier)
        .show(
          context.t(copied ? 'sends.received.copied' : 'sends.copyFailed'),
          severity: copied ? ToastSeverity.success : ToastSeverity.error,
        );
  }

  Future<void> _saveNote(ReceivedSend received) async {
    final saved = await ref
        .read(vaultControllerProvider.notifier)
        .addNote(SecureNote(id: newUuid(), title: received.payload.name, text: received.payload.text ?? '', addedAt: 0));
    if (saved && mounted) ref.read(toastsProvider.notifier).show(context.t('sends.received.noteSaved'));
  }

  /// The file's bytes, fetched on the first call (which spends an open) and held for the next.
  Future<Uint8List?> _bytes(ReceivedSend received) async {
    final held = _plain;
    if (held != null) return held;
    setState(() => _busy = true);
    try {
      final plain = await ref.read(sendsRecipientProvider).download(received);
      if (!mounted) {
        wipe(plain);
        return null;
      }
      _plain = plain;
      return plain;
    } on Object catch (e) {
      if (mounted) {
        ref
            .read(toastsProvider.notifier)
            .show(
              e is SendsError && e.problem == SendsProblem.notFound
                  ? context.t('sends.received.notAvailable')
                  : (e is SendsDoesntOpen
                        ? context.t('sends.received.doesntOpen')
                        : context.t('sends.received.network', {'host': widget.link.host})),
              severity: ToastSeverity.error,
            );
      }
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveFile(ReceivedSend received, {required bool share}) async {
    if (_busy) return;
    final bytes = await _bytes(received);
    if (bytes == null || !mounted) return;
    final name = received.payload.name;
    final mime = received.payload.mime ?? 'application/octet-stream';
    final files = ref.read(fileServiceProvider);
    if (share) {
      await files.shareFile(name, bytes, mimeType: mime);
    } else {
      final result = await files.saveFile(name, bytes, mimeType: mime);
      if (result is! SaveCancelled && mounted) ref.read(toastsProvider.notifier).show(context.t('sends.received.saved'));
    }
  }

  Widget _frame(List<Widget> children, {List<Widget> actions = const []}) => SyncSheetFrame(
    icon: const Icon(Icons.link_rounded),
    title: _received?.payload.name ?? context.t('sends.received.title'),
    actions: [
      ...actions,
      FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('sends.received.close'))),
    ],
    children: children,
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    switch (_stage) {
      case _Stage.loading:
        return _frame([SheetText(context.t('sends.received.loading')), const LinearProgressIndicator()]);
      case _Stage.offline:
        return _frame(
          [OfflineAlert(context.t('sends.received.offline'))],
          actions: [TextButton(onPressed: () => unawaited(_browser()), child: Text(context.t('sends.received.browser')))],
        );
      case _Stage.failed:
        return _frame(
          [
            AppAlert(severity: AlertSeverity.error, child: Text(_failure ?? context.t('sends.received.doesntOpen'))),
            if (_hint != null) SheetText(_hint!),
          ],
          actions: [
            if (_browserOffered) TextButton(onPressed: () => unawaited(_browser()), child: Text(context.t('sends.received.browser'))),
          ],
        );
      case _Stage.password:
        final waiting = _wait > 0;
        return _frame(
          [
            SheetText(context.t('sends.received.password.title')),
            SecretSelection(
              child: TextField(
                enableIMEPersonalizedLearning: false,
                controller: _password,
                enabled: !_busy && !waiting,
                autofocus: true,
                obscureText: !_showPassword,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: null,
                contextMenuBuilder: secretTextMenu,
                // Open is enabled by what is typed, so the sheet is built again for each change
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (_password.text.isNotEmpty && !_busy && !waiting) unawaited(_open(password: _password.text));
                },
                decoration: InputDecoration(
                  labelText: context.t('sends.received.password.field'),
                  suffixIcon: RevealPasswordButton(shown: _showPassword, onPressed: () => setState(() => _showPassword = !_showPassword)),
                ),
              ),
            ),
            if (_passwordNote != null) AppAlert(severity: AlertSeverity.error, child: Text(_passwordNote!)),
            if (waiting) AppAlert(severity: AlertSeverity.warning, child: Text(context.t('sends.received.tooMany', {'seconds': _wait}))),
            if (_busy)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  const LinearProgressIndicator(),
                  Text(context.t('sends.deriving'), style: AppType.caption.copyWith(color: p.textSecondary)),
                ],
              ),
          ],
          actions: [
            FilledButton(
              onPressed: _busy || waiting || _password.text.isEmpty ? null : () => unawaited(_open(password: _password.text)),
              child: Text(context.t('sends.received.password.open')),
            ),
          ],
        );
      case _Stage.shown:
        final received = _received!;
        final payload = received.payload;
        final text = payload.text;
        final email = received.senderEmail;
        return _frame(
          [
            if (email != null) SheetText(context.t('sends.received.from', {'email': email})),
            SheetText(context.t('sends.received.deletes', {'date': sendsDate(context, received.deletionAt)})),
            if (text != null)
              SecretSelection(
                child: SelectableText(
                  text,
                  contextMenuBuilder: secretTextMenu,
                  style: AppType.mono(fontSize: 14, color: p.text),
                ),
              )
            else ...[
              Text(
                context.t('sends.received.file', {'type': payload.mime ?? '', 'size': fileSizeText(context, payload.size ?? 0)}),
                style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w600),
              ),
              if (received.tooBig)
                AppAlert(
                  severity: AlertSeverity.warning,
                  child: Text(context.t('sends.received.tooBig', {'limit': fileSizeText(context, sendFileLimit)})),
                )
              else
                SheetText(context.t('sends.received.fileUses')),
              if (_busy) ...[const LinearProgressIndicator(), SheetText(context.t('sends.received.downloading'))],
            ],
          ],
          actions: [
            if (text != null) ...[
              if (text.length <= noteTextLimit)
                TextButton(onPressed: () => unawaited(_saveNote(received)), child: Text(context.t('sends.received.saveNote'))),
              FilledButton.tonal(onPressed: () => unawaited(_copy(text)), child: Text(context.t('sends.received.copy'))),
            ] else if (received.tooBig)
              TextButton(onPressed: () => unawaited(_browser()), child: Text(context.t('sends.received.browser')))
            else ...[
              TextButton(
                onPressed: _busy ? null : () => unawaited(_saveFile(received, share: true)),
                child: Text(context.t('sends.received.share')),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : () => unawaited(_saveFile(received, share: false)),
                child: Text(context.t('sends.received.save')),
              ),
            ],
          ],
        );
    }
  }
}
