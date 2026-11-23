import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../platform/security_keys.dart';
import '../../security_key/fido/client_pin.dart';
import '../../security_key/fido/ctap.dart';
import '../../ui/ui.dart';
import 'security_key_controller.dart';

/// The head of a security key sheet: its [title] and a close button.
class KeySheetHeader extends StatelessWidget {
  const KeySheetHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, style: AppType.h3.copyWith(color: p.text)),
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Icons.close_rounded, size: 20, color: p.textSecondary, semanticLabel: context.t('export.close')),
          ),
        ],
      ),
    );
  }
}

/// What a person is told when talking to a key failed with [error]. Null
/// for a cancellation, which is not an error to show.
String? keyErrorText(BuildContext context, Object error) => switch (error) {
  SecurityKeyCancelled() => null,
  SecurityKeyRemoved() => context.t('securityKeys.error.removed'),
  SecurityKeyTimeout() => context.t('securityKeys.error.timeout'),
  SecurityKeyNfcOff() => context.t('securityKeys.error.nfcOff'),
  SecurityKeyUnavailable() => context.t('securityKeys.wait.none'),
  SecurityKeyDenied() => context.t('securityKeys.denied'),
  PinLockedUntilReconnected() => context.t('securityKeys.pin.locked'),
  PinBlocked() => context.t('securityKeys.pin.blocked'),
  PinRefusedByKey() => context.t('securityKeys.pin.refused'),
  CtapError(:final status) => context.t('securityKeys.error.refused', {'code': status.toRadixString(16).toUpperCase().padLeft(2, '0')}),
  _ => context.t('securityKeys.error.failed'),
};

/// What the key is being asked to do right now, shown in each security
/// key sheet: present the key, the exchange under way, or a touch. It
/// takes no room while nothing is going on.
class KeyActivity extends StatelessWidget {
  const KeyActivity({super.key, required this.controller});

  final SecurityKeyController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.busy) return const SizedBox.shrink();
      final b = context.bmc;
      final String text;
      final Widget mark;
      if (controller.touchNeeded) {
        text = context.t('securityKeys.activity.touch');
        mark = Breathe(
          period: const Duration(milliseconds: 1600),
          scale: 1.18,
          child: Icon(Icons.touch_app_outlined, size: 22, color: b.accentText),
        );
      } else if (controller.waitingForKey && !controller.capabilities.readsOnRequest) {
        text = context.t(controller.capabilities.plugsIn ? 'securityKeys.activity.present' : 'securityKeys.wait.nfcOnly');
        mark = Icon(Icons.contactless_outlined, size: 22, color: b.accentText);
      } else {
        text = context.t('securityKeys.activity.working');
        mark = Spinner(color: b.accentText);
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Semantics(
          container: true,
          liveRegion: true,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            decoration: BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular(appRadius)),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: SizedBox(width: 24, height: 24, child: Center(child: mark)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(text, style: AppType.body2.copyWith(color: b.accentText)),
                ),
                TextButton(onPressed: () => unawaited(controller.cancel()), child: Text(context.t('export.cancel'))),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// A two-letter tile for a site or a name, as the passkey rows have.
String tileLetters(String name) {
  final letters = name.replaceAll(RegExp(r'^www\.'), '').replaceAll(RegExp('[^A-Za-z0-9]'), '');
  if (letters.isEmpty) return '?';
  return letters.length == 1 ? letters.toUpperCase() : '${letters[0].toUpperCase()}${letters[1].toLowerCase()}';
}
