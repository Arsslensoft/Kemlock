import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/messages.dart';
import '../ui/ui.dart';
import 'network.dart';

/// Hands a web page to the phone's browser, as the web app's links with
/// `target="_blank" rel="noopener noreferrer"` did: outside the app, which
/// shares nothing with the page. Leaving the app this way is the person's
/// own doing, so it takes no auto-lock hold.
abstract interface class LinkLauncher {
  /// Opens [url] in the browser; false when nothing on the phone could.
  Future<bool> launch(Uri url);
}

/// [LinkLauncher] on the phone, through `url_launcher`.
class PlatformLinkLauncher implements LinkLauncher {
  const PlatformLinkLauncher();

  @override
  Future<bool> launch(Uri url) async {
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}

/// The phone's browser; tests put a fake in its place to see what was opened.
final linkLauncherProvider = Provider<LinkLauncher>((ref) => const PlatformLinkLauncher());

/// Opens a link the person tapped. While offline mode is on it asks first
/// (openspec: add-offline-mode, decision 6): the request would be the
/// browser's, not Kemlock's, but a tap that leaves for the browser is not
/// what "no network" reads as, so the person sees the address and chooses
/// to open it, copy it or stay.
class LinkOpener {
  const LinkOpener(this._launcher, this._gate);

  final LinkLauncher _launcher;
  final NetworkGate _gate;

  /// Opens [url] in the browser, at once while offline mode is off and
  /// after the person agrees while it is on. False when it was not opened.
  ///
  /// Only a web page opens: an address of any other scheme (`intent:`,
  /// `file:`, `tel:`, another app's own) is refused without a word, as a
  /// link from a synced entry or a downloaded list could name one.
  Future<bool> open(BuildContext context, Uri url) async {
    if (url.scheme != 'https' && url.scheme != 'http') return false;
    if (!_gate.offline) return _launcher.launch(url);
    final choice = await showAppDialog<_LinkChoice>(context, builder: (context) => _OfflineLinkDialog(url: url));
    switch (choice) {
      case _LinkChoice.open:
        return _launcher.launch(url);
      case _LinkChoice.copy:
        await Clipboard.setData(ClipboardData(text: url.toString()));
        if (context.mounted) showToast(context, context.t('offline.link.copied'));
        return false;
      case null:
        return false;
    }
  }
}

/// Opens links, asking first while offline mode is on.
final linkOpenerProvider = Provider<LinkOpener>((ref) => LinkOpener(ref.watch(linkLauncherProvider), ref.watch(networkGateProvider)));

enum _LinkChoice { open, copy }

/// Asks before a link opens the browser while offline mode is on: that the
/// browser will go online, the address, and "Open in browser", "Copy link"
/// and "Cancel".
class _OfflineLinkDialog extends StatelessWidget {
  const _OfflineLinkDialog({required this.url});

  final Uri url;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final title = context.t('offline.link.title');
    return AppDialog(
      semanticLabel: title,
      heading: DialogHeading(icon: const Icon(Icons.open_in_new_rounded), title: title, tone: DialogTone.accent),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text(context.t('offline.link.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
          SelectableText(url.toString(), style: AppType.mono(fontSize: 13.5, color: p.text)),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: p.text),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('changePw.cancel')),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(_LinkChoice.copy), child: Text(context.t('offline.link.copy'))),
        FilledButton(onPressed: () => Navigator.of(context).pop(_LinkChoice.open), child: Text(context.t('offline.link.open'))),
      ],
    );
  }
}
