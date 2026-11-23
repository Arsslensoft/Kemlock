/// Signing and decrypting with a vault key whose private half is on a
/// security key (openspec: add-openpgp-card, design decisions 6, 8 and
/// 14). A PGP job asks [CardKeyBridge] for the private step; the bridge
/// opens a sheet that waits for the security key, asks for its PIN when
/// the card wants it, shows the touch prompt, and names the card to use
/// when another is presented. What stopped a step is kept in
/// [CardKeyBridge.failure] for the sheet that started the job to say.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../crypto/keys/pgp.dart' as pgp;
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../platform/security_keys.dart';
import '../../security_key/connection.dart';
import '../../security_key/openpgp_card/card_commands.dart';
import '../../security_key/openpgp_card/card_data.dart';
import '../../security_key/openpgp_card/card_operations.dart';
import '../../security_key/openpgp_card/card_session.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../pgp/pgp_job.dart';
import '../security_keys/card_pin_forms.dart';
import '../security_keys/key_widgets.dart' show keyErrorText;
import '../security_keys/openpgp_card_sheet.dart' show cardErrorText;
import '../security_keys/security_key_sheet.dart';
import '../settings/auto_lock.dart';
import 'card_keys.dart';

/// Why a step on a card did not happen.
enum CardUseFailure {
  /// The person cancelled.
  cancelled,

  /// The card answered with a signature that did not verify.
  badSignature,

  /// Another failure, which the card sheet showed.
  failed,
}

/// The private step of the vault's card keys, for a PGP job: one bridge per
/// job.
class CardKeyBridge implements PgpCardBridge {
  CardKeyBridge(this._context, this._ref);

  final BuildContext _context;
  final WidgetRef _ref;

  /// What stopped the last step, when one was stopped.
  CardUseFailure? failure;

  /// Whether any of [keys] is on a card, so that a job needs a bridge.
  static bool needed(Iterable<VaultKey> keys) => keys.any((key) => key.isOnCard);

  @override
  Future<Uint8List> sign(Uint8List keyPacket, Uint8List digest) =>
      _step(keyPacket, signs: true, (session, key) => cardSign(session, key, digest));

  @override
  Future<Uint8List> decipher(Uint8List keyPacket, Uint8List input) =>
      _step(keyPacket, signs: false, (session, key) => cardDecipher(session, key, input));

  Future<Uint8List> _step(Uint8List keyPacket, CardKeyStep action, {required bool signs}) async {
    const stopped = pgp.PgpException(pgp.PgpProblem.cancelled);
    final (packet, fingerprint) = cardStepKey(keyPacket);
    final vaultKey = _ref
        .read(vaultControllerProvider)
        .keys
        .firstWhereOrNull((k) => k.isOnCard && cardKeyFingerprints(k).contains(fingerprint));
    final context = _context;
    if (!context.mounted) throw stopped;
    final result = await showAppBottomSheet<_CardUseResult>(
      context,
      label: context.t('securityKeys.openpgp.use.title'),
      builder: (_) => CardUseSheet(
        name: vaultKey?.name ?? '',
        serial: vaultKey == null ? null : cardKeySerial(vaultKey),
        signs: signs,
        key: ValueKey('card-use-$fingerprint'),
        action: (session) => action(session, packet),
      ),
    );
    if (result?.bytes case final bytes?) return bytes;
    failure = result?.failure ?? CardUseFailure.cancelled;
    throw stopped;
  }

  /// The words the sheet that started the job shows for [failure]; null
  /// when there is nothing to say.
  String? failureText(BuildContext context) => switch (failure) {
    CardUseFailure.badSignature => context.t('securityKeys.openpgp.use.badSignature'),
    _ => null,
  };
}

class _CardUseResult {
  const _CardUseResult({this.bytes, this.failure});

  final Uint8List? bytes;
  final CardUseFailure? failure;
}

/// The sheet over a PGP sheet while a card does a key's private step: it
/// waits for the security key, asks for the PIN, shows the touch prompt,
/// and pops with what the card gave.
class CardUseSheet extends ConsumerStatefulWidget {
  const CardUseSheet({super.key, required this.name, required this.serial, required this.signs, required this.action});

  /// The vault key's name, and the serial of the card it was put on.
  final String name;
  final String? serial;

  /// Whether the step is a signature, rather than opening a message.
  final bool signs;
  final Future<Uint8List> Function(OpenPgpCardSession session) action;

  @override
  ConsumerState<CardUseSheet> createState() => _CardUseSheetState();
}

enum _Phase { waiting, working, touch, failed }

class _CardUseSheetState extends ConsumerState<CardUseSheet> {
  late final SecurityKeyHub _hub;
  final Map<CardPin, Uint8List> _pins = {};
  _Phase _phase = _Phase.waiting;
  String? _error;
  bool _wrongCard = false;
  bool _blocked = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _hub = SecurityKeyHub(ref.read(securityKeysProvider), now: ref.read(clockProvider), hold: ref.read(autoLockHoldsProvider).hold)
      ..onChanged = () {
        if (mounted) setState(() {});
      };
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_attempt()));
  }

  @override
  void dispose() {
    _wipe();
    unawaited(_hub.stop());
    super.dispose();
  }

  void _wipe() {
    for (final value in _pins.values) {
      value.fillRange(0, value.length, 0);
    }
    _pins.clear();
  }

  void _finish(_CardUseResult result) {
    if (_done || !mounted) return;
    _done = true;
    _wipe();
    Navigator.of(context).pop(result);
  }

  Future<void> _attempt() async {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.waiting;
      _error = null;
      _wrongCard = false;
      _blocked = false;
    });
    try {
      final bytes = await _hub.runOnKey(
        (connection) async {
          if (mounted) setState(() => _phase = _Phase.working);
          final session = await OpenPgpCardSession.open(connection);
          try {
            for (final MapEntry(key: pin, value: value) in _pins.entries) {
              session.holdPin(pin, value);
            }
            // The card says nothing while it waits for a touch: the prompt is shown before
            final place = widget.signs ? CardPlace.signature : CardPlace.decryption;
            final touch = session.snapshot?.touch[place]?.policy?.needsTouch ?? false;
            if (touch && mounted) setState(() => _phase = _Phase.touch);
            return await widget.action(session);
          } finally {
            session.close();
          }
        },
        nfcMessage: _message('securityKeys.nfc.hold'),
        nfcFailure: _message('securityKeys.nfc.failed'),
      );
      _finish(_CardUseResult(bytes: bytes));
    } on CardPinNeeded catch (needed) {
      await _askPin(needed.pin, needed.triesLeft, wrong: false);
    } on CardWrongPin catch (wrong) {
      await _askPin(wrong.pin, wrong.triesLeft, wrong: true);
    } on CardPinBlocked {
      _show(_message('securityKeys.openpgp.use.blocked'), blocked: true);
    } on CardWrongCard {
      final serial = widget.serial;
      _show(
        serial == null
            ? _message('securityKeys.openpgp.use.otherCard', {'name': widget.name})
            : _message('securityKeys.openpgp.use.wrongCard', {'name': widget.name, 'serial': serial}),
        wrongCard: true,
      );
    } on CardBadSignature {
      _finish(const _CardUseResult(failure: CardUseFailure.badSignature));
    } on SecurityKeyCancelled {
      _finish(const _CardUseResult(failure: CardUseFailure.cancelled));
    } on SecurityKeyNoApplication {
      _show(_message('securityKeys.openpgp.error.noApplication'), wrongCard: true);
    } catch (error) {
      if (!mounted) return;
      _show(cardErrorText(context, error) ?? keyErrorText(context, error) ?? _message('securityKeys.error.failed'), wrongCard: true);
    }
  }

  String _message(String id, [Map<String, Object?> args = const {}]) => mounted ? context.t(id, args) : '';

  /// Shows why the step did not happen. Whatever went wrong, the PIN typed
  /// is dropped: the card may have counted it as a wrong one in a way the
  /// app did not read, and "Try again" must never send it a second time.
  void _show(String text, {bool wrongCard = false, bool blocked = false}) {
    _wipe();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _error = text;
      _wrongCard = wrongCard;
      _blocked = blocked;
    });
  }

  Future<void> _askPin(CardPin pin, int triesLeft, {required bool wrong}) async {
    // The one the card refused, if any, is gone before another is typed
    _wipe();
    if (!mounted) return;
    setState(() => _phase = _Phase.waiting);
    final typed = await showCardPinPrompt(context, pin: pin, triesLeft: triesLeft, wrong: wrong);
    if (typed == null) {
      _finish(const _CardUseResult(failure: CardUseFailure.cancelled));
      return;
    }
    final key = pin == CardPin.pinToSign ? CardPin.pin : pin;
    final before = _pins.remove(key);
    before?.fillRange(0, before.length, 0);
    _pins[key] = typed;
    await _attempt();
  }

  Future<void> _cancel() async {
    await _hub.cancel();
    _finish(const _CardUseResult(failure: CardUseFailure.cancelled));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final (String text, Widget mark) = switch (_phase) {
      _Phase.touch => (
        context.t('securityKeys.activity.touch'),
        Breathe(
          period: const Duration(milliseconds: 1600),
          scale: 1.18,
          child: Icon(Icons.touch_app_outlined, size: 28, color: b.accentText),
        ),
      ),
      _Phase.working => (context.t('securityKeys.activity.working'), Spinner(color: b.accentText)),
      _ => (context.t('securityKeys.activity.present'), Icon(Icons.contactless_outlined, size: 28, color: b.accentText)),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeaderTitle(title: context.t('securityKeys.openpgp.use.title')),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.t(widget.signs ? 'securityKeys.openpgp.use.sign' : 'securityKeys.openpgp.use.decrypt', {'name': widget.name}),
                style: AppType.body2.copyWith(color: p.textSecondary),
              ),
              const SizedBox(height: 18),
              if (_phase == _Phase.failed && _error != null) ...[
                AppAlert(key: const ValueKey('card-use-error'), severity: AlertSeverity.error, child: Text(_error!)),
                const SizedBox(height: 14),
                if (_blocked)
                  FilledButton(
                    style: largeButtonStyle,
                    onPressed: () {
                      final under = Navigator.of(context, rootNavigator: true).context;
                      _finish(const _CardUseResult(failure: CardUseFailure.failed));
                      unawaited(showSecurityKeySheet(under));
                    },
                    child: Text(context.t('securityKeys.openpgp.use.unblock')),
                  )
                else if (_wrongCard)
                  FilledButton(
                    style: largeButtonStyle,
                    onPressed: () => unawaited(_attempt()),
                    child: Text(context.t('securityKeys.openpgp.use.tryAgain')),
                  ),
              ] else
                Semantics(
                  container: true,
                  liveRegion: true,
                  child: Row(
                    children: [
                      ExcludeSemantics(
                        child: SizedBox(width: 32, height: 32, child: Center(child: mark)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          text,
                          key: const ValueKey('card-use-activity'),
                          style: AppType.body1.copyWith(color: p.text),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              TextButton(onPressed: () => unawaited(_cancel()), child: Text(context.t('export.cancel'))),
            ],
          ),
        ),
      ],
    );
  }
}

/// The title row of a card sheet, without a close button: closing is
/// cancelling, which has its own button.
class KeySheetHeaderTitle extends StatelessWidget {
  const KeySheetHeaderTitle({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
    child: Semantics(
      header: true,
      child: Text(title, style: AppType.h3.copyWith(color: context.palette.text)),
    ),
  );
}
