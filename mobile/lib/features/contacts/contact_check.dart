import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/contact.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../scan/qr_viewfinder.dart';
import 'contact_keys.dart';
import 'contact_standing.dart';
import 'contact_widgets.dart';

/// Marks [contact] as checked now, for the key it holds and the addresses
/// that key carries, and says so. False when its key can't be read or the
/// save failed.
Future<bool> _markChecked(BuildContext context, WidgetRef ref, Contact contact) async {
  final info = contactKeyInfo(contact);
  if (info == null) return false;
  final toasts = ref.read(toastsProvider.notifier);
  final done = context.t('contacts.sheet.checked', {'name': contact.name});
  final now = ref.read(clockProvider)().millisecondsSinceEpoch;
  final checked = contact.checked(info.primary.fingerprintHex, now, addresses: keyAddresses(info));
  final saved = await ref.read(vaultControllerProvider.notifier).updateContact(checked);
  if (saved) toasts.show(done);
  return saved;
}

/// Shows the fingerprint of [contact]'s key in groups, to compare with its
/// owner, and marks the contact checked today when the person says it
/// matches. True once it is checked. The contact's sheet and the warning
/// about unchecked recipients both check through here.
Future<bool> checkContactFingerprint(BuildContext context, WidgetRef ref, Contact contact) async {
  final info = contactKeyInfo(contact);
  if (info == null) return false;
  final groups = crypto.fingerprintGroups(info.primary.fingerprintHex).length;
  final matches = await showAppDialog<bool>(
    context,
    builder: (dialog) => AppDialog(
      semanticLabel: dialog.t('contacts.sheet.checkNow'),
      heading: DialogHeading(title: dialog.t('contacts.sheet.checkNow')),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FingerprintCard(key: const ValueKey('check-fingerprint'), fingerprint: info.primary.fingerprintHex),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(dialog.t('contacts.review.advice', {'name': contact.name, 'count': groups})),
          ),
          ..._covers(dialog, info),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(dialog.t('export.cancel'))),
        FilledButton(onPressed: () => Navigator.of(dialog).pop(true), child: Text(dialog.t('contacts.sheet.check.confirm'))),
      ],
    ),
  );
  if (matches != true || !context.mounted) return false;
  return _markChecked(context, ref, contact);
}

/// The line of a check's dialog that says which addresses the check will
/// cover: those the key names now, and none it names later. Nothing for a
/// key that names none.
List<Widget> _covers(BuildContext context, crypto.PgpKeyInfo info) {
  final addresses = keyAddresses(info);
  if (addresses.isEmpty) return const [];
  return [
    const SizedBox(height: 8),
    Padding(
      key: const ValueKey('check-covers'),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(context.t('contacts.sheet.check.covers', {'addresses': addresses.join(', ')})),
    ),
  ];
}

/// Checks [contact] by scanning the code its owner shows: the armored key
/// a Kemlock key sheet shows, or a fingerprint-only code. A code with the
/// contact's fingerprint marks it checked today; any other leaves it as it
/// was and says the code belongs to another key. True once it is checked.
Future<bool> checkContactByScanning(BuildContext context, WidgetRef ref, Contact contact) async {
  final info = contactKeyInfo(contact);
  if (info == null) return false;
  final matches = await showAppDialog<bool>(
    context,
    builder: (_) => _ScanCheckDialog(name: contact.name, info: info),
  );
  if (matches != true || !context.mounted) return false;
  return _markChecked(context, ref, contact);
}

/// The viewfinder of [checkContactByScanning]: pops true when a scanned
/// code holds the fingerprint of [info], and says why any other code does
/// not count.
class _ScanCheckDialog extends ConsumerStatefulWidget {
  const _ScanCheckDialog({required this.name, required this.info});

  final String name;
  final crypto.PgpKeyInfo info;

  String get fingerprint => info.primary.fingerprintHex;

  @override
  ConsumerState<_ScanCheckDialog> createState() => _ScanCheckDialogState();
}

class _ScanCheckDialogState extends ConsumerState<_ScanCheckDialog> {
  String? _error;
  var _reading = false;

  /// The fingerprints [code] holds: the one after `OPENPGP4FPR:`, or those
  /// of the keys in it. Empty when it holds neither.
  Future<List<String>> _fingerprints(String code) async {
    final named = fingerprintOfCode(code);
    if (named != null) return [if (named.isNotEmpty) named];
    try {
      return [for (final key in await ref.read(publicKeyReaderProvider)(code)) key.info.primary.fingerprintHex];
    } on crypto.KeyFormatException {
      return const [];
    }
  }

  Future<void> _take(String code) async {
    if (_reading) return;
    _reading = true;
    final found = await _fingerprints(code);
    _reading = false;
    if (!mounted) return;
    if (found.contains(widget.fingerprint)) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _error = found.isEmpty ? 'contacts.sheet.scan.notAKey' : 'contacts.sheet.scan.differs');
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    semanticLabel: context.t('contacts.sheet.scan.title'),
    heading: DialogHeading(title: context.t('contacts.sheet.scan.title')),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(context.t('contacts.sheet.scan.body', {'name': widget.name})),
        ..._covers(context, widget.info),
        const SizedBox(height: 12),
        QrViewfinder(onScan: (code) => unawaited(_take(code))),
        if (_error != null) ...[
          const SizedBox(height: 12),
          AppAlert(key: const ValueKey('scan-check-error'), severity: AlertSeverity.error, child: Text(context.t(_error!))),
        ],
      ],
    ),
    actions: [TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t('export.cancel')))],
  );
}
