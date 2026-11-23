import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../platform/security_keys.dart';
import '../../security_key/fido/get_info.dart';
import '../../ui/ui.dart';
import '../keys/card_keys.dart';
import '../lock/unlock_method_sheet.dart';
import '../settings/auto_lock.dart';
import 'key_codes.dart';
import 'key_fingerprints_sheet.dart';
import 'key_passkeys_sheet.dart';
import 'key_widgets.dart';
import 'openpgp_card_controller.dart';
import 'pin_forms.dart';
import 'piv_controller.dart';
import 'piv_sheet.dart';
import 'reset_flow.dart';
import 'security_key_controller.dart';

/// Opens the Security key sheet from Settings.
Future<void> showSecurityKeySheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('securityKeys.title'), builder: (_) => const SecurityKeySheet());

/// The Security key sheet: how to present a key on this phone, then what
/// the key says of itself and the FIDO2 features it reports (its PIN, its
/// passkeys, its fingerprints, reset). It looks for a key only while it
/// is open, keeps the PIN only while it is open, and stores nothing.
///
/// Later changes add their own sections (codes, PGP keys, certificates,
/// opening the vault) to the column [_KeyView] builds.
class SecurityKeySheet extends ConsumerStatefulWidget {
  const SecurityKeySheet({super.key});

  @override
  ConsumerState<SecurityKeySheet> createState() => _SecurityKeySheetState();
}

class _SecurityKeySheetState extends ConsumerState<SecurityKeySheet> {
  late final SecurityKeyController _controller = SecurityKeyController(
    keys: ref.read(securityKeysProvider),
    holds: ref.read(autoLockHoldsProvider),
    now: ref.read(clockProvider),
  );

  /// The key's OpenPGP card, read with the key (openspec: add-openpgp-card).
  late final OpenPgpCardController _openPgp;

  /// Forgets the PIN as the app goes out of sight, as the PGP keys do theirs.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) _controller.forgetPin();
      },
    );
    _openPgp = OpenPgpCardController.attach(_controller, onSnapshot: (snapshot) => ref.read(cardsSeenProvider.notifier).seen(snapshot));
    // Reads the key's PIV application whenever the key is read.
    PivController.of(_controller);
    // And which code application it has, for the Codes row's count.
    final codes = ref.read(keyCodesProvider.notifier);
    _controller.readers.add((connection) async {
      if (mounted) await codes.peek(connection);
    });
    unawaited(_controller.start());
    // When the vault locks, the session with the key ends and the PIN is forgotten.
    ref.listenManual(keySheetVaultOpenProvider, (_, open) {
      if (!open) unawaited(_controller.lock());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller
      ..nfcMessage = context.t('securityKeys.nfc.hold')
      ..nfcFailure = context.t('securityKeys.nfc.failed');
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _openPgp.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      KeySheetHeader(title: context.t('securityKeys.title')),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyActivity(controller: _controller),
                if (_controller.key == null) _Waiting(controller: _controller) else _KeyView(controller: _controller),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

/// What the sheet shows with no key read: how to present one on this
/// phone, or why this phone cannot reach one.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.controller});

  final SecurityKeyController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final capabilities = controller.capabilities;
    final hub = controller.hub;
    if (!controller.ready) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: Spinner()),
      );
    }

    final notices = <Widget>[
      if (controller.removedNotice) AppAlert(severity: AlertSeverity.info, child: Text(context.t('securityKeys.removed'))),
      if (controller.readError case final error?)
        if (keyErrorText(context, error) case final text?) AppAlert(severity: AlertSeverity.error, child: Text(text)),
    ];

    if (hub.denied != null) {
      return _block(
        context,
        notices: notices,
        icon: Icons.usb_off_rounded,
        text: context.t('securityKeys.denied'),
        action: FilledButton(onPressed: () => unawaited(hub.askAgain()), child: Text(context.t('securityKeys.denied.again'))),
      );
    }
    if (hub.choices.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 12),
            child: Text(context.t('securityKeys.choose.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
          ),
          Group(
            label: context.t('securityKeys.choose.title'),
            children: [
              for (final (index, device) in hub.choices.indexed)
                GroupRow(
                  first: index == 0,
                  icon: const Icon(Icons.usb_rounded),
                  primary: device.productName ?? context.t('securityKeys.model.unknown'),
                  onTap: () => unawaited(hub.pick(device)),
                ),
            ],
          ),
        ],
      );
    }
    if (!capabilities.any) {
      return _block(context, notices: notices, icon: Icons.block_rounded, text: context.t('securityKeys.wait.none'));
    }
    if (capabilities.readsOnRequest) {
      // An iPad has no NFC: only a plugged-in key is looked for.
      if (!capabilities.nfc) {
        return _block(context, notices: notices, icon: Icons.usb_rounded, text: context.t('securityKeys.wait.ipad'));
      }
      return _block(
        context,
        notices: notices,
        icon: Icons.contactless_outlined,
        text: context.t('securityKeys.wait.iphone'),
        action: FilledButton(
          style: largeButtonStyle,
          onPressed: controller.busy ? null : () => unawaited(guardKey(context, () => controller.read(viaNfc: true))),
          child: Text(context.t('securityKeys.wait.iphone.read')),
        ),
        footer: _NoNfcKeyNote(),
      );
    }
    final nfcOff = capabilities.nfc && !capabilities.nfcOn;
    final String text;
    if (nfcOff) {
      text = context.t(capabilities.usb ? 'securityKeys.wait.nfcOff' : 'securityKeys.wait.nfcOffOnly');
    } else if (capabilities.nfc && capabilities.usb) {
      text = context.t('securityKeys.wait.android');
    } else if (capabilities.nfc) {
      text = context.t('securityKeys.wait.nfcOnly');
    } else {
      text = context.t('securityKeys.wait.usbOnly');
    }
    return _block(context, notices: notices, icon: nfcOff ? Icons.portable_wifi_off_rounded : Icons.contactless_outlined, text: text);
  }

  Widget _block(
    BuildContext context, {
    required List<Widget> notices,
    required IconData icon,
    required String text,
    Widget? action,
    Widget? footer,
  }) {
    final p = context.palette;
    final b = context.bmc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final notice in notices) Padding(padding: const EdgeInsets.only(bottom: 12), child: notice),
        Rise(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 20, 8, 12),
            child: Column(
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 64,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: b.accentSoft,
                      borderRadius: BorderRadius.circular(21),
                      border: Border.all(color: p.divider),
                    ),
                    child: Icon(icon, size: 28, color: b.accentText),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  context.t('securityKeys.wait.title'),
                  textAlign: TextAlign.center,
                  style: AppType.h4.copyWith(color: p.text),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: AppType.body2.copyWith(color: p.textSecondary),
                  ),
                ),
                if (action != null) ...[const SizedBox(height: 22), action],
              ],
            ),
          ),
        ),
        ?footer,
      ],
    );
  }
}

/// The note for keys without NFC on an iPhone, opened by a tap.
class _NoNfcKeyNote extends StatefulWidget {
  @override
  State<_NoNfcKeyNote> createState() => _NoNfcKeyNoteState();
}

class _NoNfcKeyNoteState extends State<_NoNfcKeyNote> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Center(
        child: TextButton(
          onPressed: () => setState(() => _open = !_open),
          child: Text(context.t('securityKeys.wait.iphone.noNfcKey.title')),
        ),
      ),
      if (_open) AppAlert(severity: AlertSeverity.info, child: Text(context.t('securityKeys.wait.iphone.noNfcKey'))),
    ],
  );
}

/// The key that was read: its card, then its sections.
class _KeyView extends StatelessWidget {
  const _KeyView({required this.controller});

  final SecurityKeyController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final key = controller.key!;
    final info = key.info;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Rise(
          child: _KeyCard(details: key, connected: controller.connected),
        ),
        if (info != null) ...[
          Rise(
            delay: const Duration(milliseconds: 60),
            child: _FidoSection(controller: controller, details: key, info: info),
          ),
        ] else
          Rise(
            delay: const Duration(milliseconds: 60),
            child: Padding(padding: const EdgeInsets.only(top: 14), child: _problem(context, key.problem)),
          ),
        Rise(
          delay: const Duration(milliseconds: 120),
          child: PivSection(keys: controller),
        ),
        // openspec: add-security-key-unlock
        if (info != null) const Rise(delay: Duration(milliseconds: 120), child: VaultKeysGroup()),
        const SizedBox(height: 22),
        if (info != null) ...[
          Rise(
            delay: const Duration(milliseconds: 180),
            child: FilledButton(
              style: largeButtonStyle.merge(filledButtonColors(background: p.error, foreground: p.onError)),
              onPressed: controller.busy ? null : () => unawaited(startKeyReset(context, controller)),
              child: Text(context.t('securityKeys.reset.button')),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Text(
          context.t('securityKeys.footnote'),
          textAlign: TextAlign.center,
          style: AppType.caption.copyWith(color: p.textSecondary),
        ),
      ],
    );
  }

  Widget _problem(BuildContext context, KeyFidoProblem problem) => switch (problem) {
    KeyFidoProblem.u2fOnly => AppAlert(severity: AlertSeverity.info, child: Text(context.t('securityKeys.u2fOnly'))),
    KeyFidoProblem.needsNfc => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppAlert(severity: AlertSeverity.info, child: Text(context.t('securityKeys.needsNfc'))),
        const SizedBox(height: 4),
        _FidoRows(rows: _unreachableRows(context)),
        const SizedBox(height: 14),
        FilledButton(
          style: largeButtonStyle,
          onPressed: controller.busy ? null : () => unawaited(guardKey(context, () => controller.read(viaNfc: true))),
          child: Text(context.t('securityKeys.needsNfc.read')),
        ),
      ],
    ),
    _ => AppAlert(severity: AlertSeverity.info, child: Text(context.t('securityKeys.noFido'))),
  };

  /// The FIDO2 rows as they stay visible while this connection cannot carry them.
  List<GroupRow> _unreachableRows(BuildContext context) => [
    GroupRow(first: true, muted: true, primary: context.t('securityKeys.passkeys.row')),
    GroupRow(muted: true, primary: context.t('securityKeys.pin.row')),
    GroupRow(muted: true, primary: context.t('securityKeys.fingerprints.row')),
  ];
}

/// The card that says what the key is: its model when it can be known, its
/// firmware when it reports one, how it is connected, and a "Connected"
/// mark while the link is live.
class _KeyCard extends StatelessWidget {
  const _KeyCard({required this.details, required this.connected});

  final KeyDetails details;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final firmware = details.info?.firmwareVersion;
    final version = {'version': '$firmware'};
    final String secondary;
    if (!details.isNfc) {
      secondary = firmware == null ? context.t('securityKeys.detail.usb') : context.t('securityKeys.detail.firmware.usb', version);
    } else if (connected) {
      secondary = firmware == null ? context.t('securityKeys.detail.nfc') : context.t('securityKeys.detail.firmware.nfc', version);
    } else {
      // The key was taken away: what was read stays, without saying it is connected.
      secondary = firmware == null
          ? context.t('securityKeys.detail.nfc.gone')
          : context.t('securityKeys.detail.firmware.nfc.gone', version);
    }
    return GroupCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            ExcludeSemantics(
              child: PopIn(
                delay: const Duration(milliseconds: 120),
                child: Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular(14)),
                  child: Icon(Icons.key_rounded, size: 22, color: b.accentText),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    details.productName ?? context.t('securityKeys.model.unknown'),
                    style: AppType.body1.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0, color: p.text),
                  ),
                  Text(secondary, style: AppType.caption.copyWith(color: p.textSecondary)),
                ],
              ),
            ),
            if (connected) ...[
              const SizedBox(width: 14),
              PopIn(
                delay: const Duration(milliseconds: 180),
                child: AccentTag(label: context.t('securityKeys.connected')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FidoRows extends StatelessWidget {
  const _FidoRows({required this.rows});

  final List<GroupRow> rows;

  @override
  Widget build(BuildContext context) => Group(label: context.t('securityKeys.section.fido'), children: rows);
}

/// "Passkeys and sign-in": a row for each FIDO2 feature, as the key's own
/// answer to "what do you support?" decides it.
class _FidoSection extends StatelessWidget {
  const _FidoSection({required this.controller, required this.details, required this.info});

  final SecurityKeyController controller;
  final KeyDetails details;
  final AuthenticatorInfo info;

  @override
  Widget build(BuildContext context) {
    final mono = AppType.mono(fontSize: 14, fontWeight: FontWeight.w500);
    final busy = controller.busy;
    final pinSet = info.pin == KeyPinState.set;
    final canUsePin = details.pinManageable && pinSet;
    final needsPin = details.pinManageable && !pinSet;
    final storage = controller.storage;
    final blocked = controller.pinBlocked;

    VoidCallback? tap(Future<void> Function() action) => busy ? null : () => unawaited(action());
    Future<void> explainBlocked() => showKeyPinBlocked(context);

    final rows = <GroupRow>[
      if (info.credentialManagementCommand == null)
        GroupRow(
          first: true,
          muted: true,
          primary: context.t('securityKeys.passkeys.row'),
          secondary: context.t('securityKeys.passkeys.cannotList'),
        )
      else if (!canUsePin)
        GroupRow(
          first: true,
          muted: true,
          primary: context.t('securityKeys.passkeys.row'),
          secondary: context.t(needsPin ? 'securityKeys.needsPin' : 'securityKeys.pin.unmanageable'),
        )
      else
        GroupRow(
          first: true,
          primary: context.t('securityKeys.passkeys.row'),
          value: storage == null
              ? null
              : Text(context.t('securityKeys.passkeys.count', {'used': storage.used, 'total': storage.total}), style: mono),
          onTap: tap(blocked ? explainBlocked : () => openKeyPasskeys(context, controller)),
        ),
      if (info.pin != KeyPinState.unsupported)
        if (!details.pinManageable)
          GroupRow(muted: true, primary: context.t('securityKeys.pin.row'), secondary: context.t('securityKeys.pin.unmanageable'))
        else if (!pinSet)
          GroupRow(primary: context.t('securityKeys.pin.set'), onTap: tap(() => showKeyPinForm(context, controller)))
        else
          GroupRow(
            primary: context.t('securityKeys.pin.change'),
            value: Text(context.t(blocked ? 'securityKeys.pin.blocked.row' : 'securityKeys.pin.isSet')),
            onTap: tap(blocked ? explainBlocked : () => showKeyPinForm(context, controller)),
          ),
      if (info.bioEnrollmentCommand == null)
        GroupRow(
          muted: true,
          primary: context.t('securityKeys.fingerprints.row'),
          value: Text(context.t('securityKeys.fingerprints.noReader')),
        )
      else if (!canUsePin)
        GroupRow(
          muted: true,
          primary: context.t('securityKeys.fingerprints.row'),
          secondary: context.t(needsPin ? 'securityKeys.needsPin' : 'securityKeys.pin.unmanageable'),
        )
      else
        GroupRow(
          primary: context.t('securityKeys.fingerprints.row'),
          onTap: tap(blocked ? explainBlocked : () => openKeyFingerprints(context, controller)),
        ),
    ];
    return _FidoRows(rows: rows);
  }
}
