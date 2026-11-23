import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/providers.dart';
import '../../crypto/keys/pem.dart';
import '../../crypto/keys/x509.dart';
import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../security_key/piv/piv_commands.dart';
import '../../security_key/piv/piv_data.dart';
import '../../security_key/piv/piv_operations.dart';
import '../../security_key/piv/piv_session.dart';
import '../../ui/ui.dart';
import '../keys/key_standing.dart';
import '../keys/key_widgets.dart' show KeyStandingTag;
import 'key_widgets.dart';
import 'piv_controller.dart';
import 'piv_generate_sheet.dart';
import 'piv_key_prompt.dart';

/// Opens the sheet of [slot]: its certificate's details, and what can be
/// done with it.
Future<void> showPivSlotSheet(BuildContext context, PivController piv, PivSlot slot) => showAppBottomSheet<void>(
  context,
  label: pivSlotName(context, slot),
  builder: (_) => PivSlotSheet(piv: piv, slot: slot),
);

/// The standing of a certificate that ends at [notAfter], by [now]: in
/// order, ending within 30 days, or ended (openspec: add-piv-management,
/// "A certificate near its end is tagged").
KeyStanding certificateStanding(DateTime notAfter, DateTime now) {
  if (!now.isBefore(notAfter)) return KeyStanding(standing: Standing.expired, expires: notAfter);
  if (notAfter.difference(now) > expiringSoonWithin) return KeyStanding(standing: Standing.ok, expires: notAfter);
  final days = daysUntil(notAfter, now);
  return KeyStanding(standing: Standing.expiringSoon, expires: notAfter, daysLeft: days > 30 ? 30 : days);
}

/// [bytes] in hex, in pairs separated by colons, as a fingerprint is read.
String pivFingerprint(List<int> bytes) => [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0').toUpperCase()].join(':');

/// The sheet of one slot: who its certificate names, who issued it, its
/// dates, serial number, key and fingerprint, and what the slot is for;
/// then Export, Copy, Import, Generate and Remove. A slot holding
/// something Kemlock cannot read still offers export and replacement.
class PivSlotSheet extends ConsumerStatefulWidget {
  const PivSlotSheet({super.key, required this.piv, required this.slot});

  final PivController piv;
  final PivSlot slot;

  @override
  ConsumerState<PivSlotSheet> createState() => _PivSlotSheetState();
}

class _PivSlotSheetState extends ConsumerState<PivSlotSheet> {
  bool _working = false;

  PivController get _piv => widget.piv;
  PivSlot get _slot => widget.slot;

  PivSlotState? get _slotState => _piv.state?.slots[_slot];

  String _pem(List<int> der) => writePem('CERTIFICATE', der);

  Future<void> _export() async {
    final slot = _slotState;
    final bytes = slot?.certificate;
    if (slot == null || bytes == null) return;
    final certificate = pivSlotCertificate(slot);
    final files = ref.read(fileServiceProvider);
    if (certificate == null) {
      // Kept as it is: what Kemlock can't read, it doesn't change.
      await files.shareFile('${_slot.id}-slot.bin', bytes);
      return;
    }
    final name = _fileName(certificate.subject.display);
    await files.shareFile('${_slot.id}-$name.crt', Uint8List.fromList(utf8.encode(_pem(bytes))), mimeType: 'application/x-x509-user-cert');
  }

  Future<void> _copy() async {
    final bytes = _slotState?.certificate;
    if (bytes == null) return;
    await Clipboard.setData(ClipboardData(text: _pem(bytes)));
    if (mounted) showToast(context, context.t('piv.slot.copied'));
  }

  static String _fileName(String name) {
    final clean = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '').trim();
    return clean.isEmpty ? 'certificate' : clean;
  }

  /// Import: the certificate is read and checked on the phone first, and
  /// only then is the key asked for.
  Future<void> _import() async {
    final source = await showAppBottomSheet<_ImportSource>(
      context,
      label: context.t('piv.import.title'),
      builder: (_) => const _ImportChooser(),
    );
    if (source == null || !mounted) return;
    final Uint8List? bytes;
    switch (source) {
      case _ImportSource.file:
        bytes = (await ref.read(fileServiceProvider).pickFile())?.bytes;
      case _ImportSource.text:
        final text = await showAppBottomSheet<String>(context, label: context.t('piv.import.paste'), builder: (_) => const _PasteSheet());
        bytes = text == null ? null : Uint8List.fromList(utf8.encode(text));
    }
    if (bytes == null || !mounted) return;
    final read = readCertificateFile(bytes);
    final certificate = read.certificate;
    if (certificate == null) {
      await _tell(switch (read.kind) {
        CertificateFileKind.privateKey => context.t('piv.import.privateKey'),
        CertificateFileKind.request => context.t('piv.import.request'),
        CertificateFileKind.publicKey => context.t('piv.import.publicKey'),
        _ => context.t('piv.import.unreadable'),
      });
      return;
    }
    final slot = _slotState;
    final slotKey = slot == null ? null : pivSlotPublicKey(slot);
    final newKey = certificate.publicKey;
    if (slotKey != null && (newKey == null || !samePublicKey(slotKey, newKey))) {
      await _tell(context.t('piv.import.mismatch'));
      return;
    }
    if (!mounted) return;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final go = await showConfirmDialog(
      context,
      icon: const Icon(Icons.file_download_outlined),
      title: context.t('piv.import.confirm.title', {'slot': _slot.id}),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.t('piv.import.confirm.body', {
              'name': certificate.subject.display,
              'from': DateFormat.yMMMd(locale).format(certificate.notBefore.toLocal()),
              'until': DateFormat.yMMMd(locale).format(certificate.notAfter.toLocal()),
            }),
          ),
          if (slotKey == null) ...[const SizedBox(height: 10), Text(context.t('piv.import.unchecked'))],
        ],
      ),
      confirmLabel: context.t(slotKey == null ? 'piv.import.anyway' : 'piv.import.button'),
      cancelLabel: context.t('export.cancel'),
    );
    if (!go || !mounted) return;
    await _act((session) => pivImportCertificate(session, _slot, certificate), done: 'piv.import.done');
  }

  Future<void> _tell(String text) => showPivNotice(context, title: context.t('piv.import.refused'), body: text, danger: true);

  Future<void> _remove() async {
    final go = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('piv.remove.title', {'slot': _slot.id}),
      body: Text(context.t('piv.remove.body')),
      confirmLabel: context.t('piv.remove.button'),
      cancelLabel: context.t('export.cancel'),
      danger: true,
    );
    if (!go || !mounted) return;
    final removed = await _act((session) => pivStoreCertificate(session, _slot, null), done: 'piv.remove.done');
    if (removed && mounted) Navigator.of(context).pop();
  }

  /// Runs [action] with the management key, and says how it went.
  Future<bool> _act(Future<void> Function(PivSession session) action, {required String done}) async {
    setState(() => _working = true);
    try {
      final result = await runWithManagementKey(context, _piv, action);
      if (result == null || !mounted) return false;
      showToast(context, [context.t(done), pivUsedText(context, result.used)].join(' '));
      return true;
    } on PivNoRoom {
      if (mounted) showToast(context, context.t('piv.error.noRoom'), severity: ToastSeverity.error);
    } catch (error) {
      final text = mounted ? pivErrorText(context, error) : null;
      if (text != null && mounted) showToast(context, text, severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _piv, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final p = context.palette;
    final slot = _slotState;
    final certificate = slot == null ? null : pivSlotCertificate(slot);
    final busy = _working || _piv.busy;
    final now = ref.read(clockProvider)();
    final locale = Localizations.localeOf(context).toLanguageTag();
    String date(DateTime when) => DateFormat.yMMMd(locale).format(when.toLocal());
    final mono = AppType.mono(fontSize: 12.5, fontWeight: FontWeight.w500);
    VoidCallback? tap(Future<void> Function() action) => busy ? null : () => unawaited(action());

    final details = <Widget>[];
    if (certificate != null) {
      final standing = certificateStanding(certificate.notAfter, now);
      details.addAll([
        GroupRow(first: true, primary: context.t('piv.slot.names'), value: _Value(certificate.subject.display)),
        GroupRow(
          primary: context.t('piv.slot.issuer'),
          value: _Value(certificate.selfSigned ? context.t('piv.slot.selfSigned') : certificate.issuer.display),
        ),
        GroupRow(primary: context.t('piv.slot.from'), value: _Value(date(certificate.notBefore))),
        GroupRow(
          primary: context.t('piv.slot.until'),
          value: _Value(date(certificate.notAfter)),
          tag: standing.standing == Standing.ok ? null : KeyStandingTag(standing: standing),
        ),
        GroupRow(primary: context.t('piv.slot.algorithm'), value: _Value(certificate.keyAlgorithmName)),
        GroupRow(primary: context.t('piv.slot.serial'), secondary: certificate.serialText, secondaryStyle: mono),
        GroupRow(
          primary: context.t('piv.slot.fingerprint'),
          secondary: pivFingerprint(certificate.sha256Fingerprint),
          secondaryStyle: mono,
        ),
      ]);
    }
    final readable = certificate != null;
    final held = slot?.inUse ?? false;
    final actions = <GroupRow>[
      if (held)
        GroupRow(first: true, icon: const Icon(Icons.ios_share_rounded), primary: context.t('piv.slot.export'), onTap: tap(_export)),
      if (readable) GroupRow(icon: const Icon(Icons.copy_rounded), primary: context.t('piv.slot.copy'), onTap: tap(_copy)),
      GroupRow(
        first: !held,
        icon: const Icon(Icons.file_download_outlined),
        primary: context.t(certificate?.selfSigned ?? false ? 'piv.slot.importAuthority' : 'piv.slot.import'),
        onTap: tap(_import),
      ),
      GroupRow(
        icon: const Icon(Icons.add_rounded),
        primary: context.t('piv.slot.generate'),
        onTap: tap(() => showPivGenerateSheet(context, _piv, _slot)),
      ),
      if (held)
        GroupRow(icon: const Icon(Icons.delete_outline_rounded), primary: context.t('piv.remove.row'), danger: true, onTap: tap(_remove)),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('piv.slot.title', {'name': pivSlotName(context, _slot), 'slot': _slot.id})),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyActivity(controller: _piv.keys),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(pivSlotPurpose(context, _slot), style: AppType.body2.copyWith(color: p.textSecondary)),
                ),
                const SizedBox(height: 14),
                if (readable)
                  Rise(
                    child: GroupCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: details),
                    ),
                  )
                else if (held)
                  AppAlert(severity: AlertSeverity.warning, child: Text(context.t('piv.slot.unreadable.body')))
                else
                  AppAlert(severity: AlertSeverity.info, child: Text(context.t('piv.slot.empty.body'))),
                Rise(
                  delay: const Duration(milliseconds: 60),
                  child: Group(label: context.t('piv.slot.actions'), children: actions),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A detail's value, kept to the width the row leaves it.
class _Value extends StatelessWidget {
  const _Value(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 210),
    child: Text(text, textAlign: TextAlign.end, overflow: TextOverflow.ellipsis, maxLines: 2),
  );
}

enum _ImportSource { file, text }

class _ImportChooser extends StatelessWidget {
  const _ImportChooser();

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      KeySheetHeader(title: context.t('piv.import.title')),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Group(
          children: [
            GroupRow(
              first: true,
              icon: const Icon(Icons.folder_open_rounded),
              primary: context.t('piv.import.file'),
              secondary: context.t('piv.import.file.hint'),
              onTap: () => Navigator.of(context).pop(_ImportSource.file),
            ),
            GroupRow(
              icon: const Icon(Icons.content_paste_rounded),
              primary: context.t('piv.import.paste'),
              onTap: () => Navigator.of(context).pop(_ImportSource.text),
            ),
          ],
        ),
      ),
    ],
  );
}

class _PasteSheet extends StatefulWidget {
  const _PasteSheet();

  @override
  State<_PasteSheet> createState() => _PasteSheetState();
}

class _PasteSheetState extends State<_PasteSheet> {
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      KeySheetHeader(title: context.t('piv.import.paste')),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                enableIMEPersonalizedLearning: false,
                controller: _text,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 6,
                maxLines: 10,
                style: AppType.mono(fontSize: 12, fontWeight: FontWeight.w500),
                decoration: InputDecoration(hintText: '-----BEGIN CERTIFICATE-----'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                style: largeButtonStyle,
                onPressed: _text.text.trim().isEmpty ? null : () => Navigator.of(context).pop(_text.text),
                child: Text(context.t('piv.continue')),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}
