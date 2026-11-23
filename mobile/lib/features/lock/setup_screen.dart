import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_registry.dart';
import '../breaches/leak_check.dart';
import '../settings/prefs.dart';
import 'error_text.dart';
import 'gate_widgets.dart';
import 'master_password.dart';
import 'password_strength.dart';
import 'unlock_attempts.dart';

export 'password_strength.dart' show passwordScore, passwordStrength;

/// The labels of the five checks, in [passwordScore]'s order.
const _checkIds = ['setup.check.length', 'setup.check.uppercase', 'setup.check.lowercase', 'setup.check.number', 'setup.check.special'];

/// What making the vault does, as its steps show it.
const _steps = [
  (titleId: 'setup.step.derive', detail: 'scrypt · N=2¹⁷ · r=8 · p=1'),
  (titleId: 'setup.step.keypair', detail: 'ML-KEM-1024 · NIST FIPS 203'),
  (titleId: 'setup.step.seal', detail: 'AES-256-GCM'),
];

enum _Phase { form, forging, done }

/// First launch: choosing the master password and making the vault, as
/// `SetupScreen.tsx` did. The password is rated as it is typed, chip by
/// chip, and has to be twelve characters or more, pass three of the five
/// checks and be typed twice. While the vault is made its three steps tick
/// off; then it says the vault is ready and opens it.
///
/// The password can first be checked against the ones known from data
/// breaches (openspec: password-leak-check), if the person ticks the box:
/// off each time, since it is the one thing here that goes online.
///
/// After every vault was erased for wrong passwords, it says so, until a
/// vault is made (openspec: harden-unlock-and-clipboard).
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> with LeakChecking {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _confirmFocus = FocusNode();
  var _show = false;
  var _phase = _Phase.form;
  var _step = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _password.addListener(_rebuild);
    _confirm.addListener(_rebuild);
  }

  void _rebuild() => setState(() => leakPasswordEdited(_password.text));

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  bool get _match => _confirm.text.isNotEmpty && _password.text == _confirm.text;

  /// Twelve characters or more, whatever the other checks say, and three of the five.
  bool get _canCreate => masterPasswordLongEnough(_password.text) && passwordScore(_password.text).score >= 3 && _match && !leakChecking;

  /// Makes the vault, after the leak check when it is on. [unchecked] goes on
  /// without it: the person chose to keep a leaked password, or to continue
  /// when the check couldn't be made.
  Future<void> _create({bool unchecked = false}) async {
    if (!_canCreate || _phase != _Phase.form) return;
    final password = _password.text;
    final store = ref.read(vaultStoreProvider);
    final controller = ref.read(vaultControllerProvider.notifier);
    final prefs = ref.read(prefsProvider.notifier);
    final storage = ref.read(keyValueStoreProvider);
    final failed = context.t('setup.error.failed');
    FocusScope.of(context).unfocus();
    if (!await passesLeakCheck(password, skip: unchecked)) return;
    // The password was edited while the check was out: it has to be submitted again
    if (!mounted || password != _password.text || !_canCreate) return;
    setState(() {
      _error = null;
      _step = 0;
      _phase = _Phase.forging;
    });
    // Let the first step show before key derivation and the key pair get going
    await Future<void>.delayed(const Duration(milliseconds: 350));
    try {
      final session = await store.setupVault(password);
      // Said until a vault is made again
      storage.removeItem(keyErased);
      // The new vault remembers the choice, for when its password is changed
      if (leakCheckOn) prefs.update((prefs) => prefs.copyWith(leakCheck: true));
      for (var i = 1; i <= _steps.length; i++) {
        if (mounted) setState(() => _step = i);
        await Future<void>.delayed(const Duration(milliseconds: 280));
      }
      if (mounted) setState(() => _phase = _Phase.done);
      await Future<void>.delayed(const Duration(milliseconds: 650));
      await controller.open(session);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = errorText(error, failed);
        _phase = _Phase.form;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    Widget bar(Color color) => Container(
      width: 28,
      height: 4,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
    );
    return Scaffold(
      backgroundColor: p.background,
      body: GateLayout(
        maxWidth: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExcludeSemantics(
              child: Row(
                children: [
                  bar(p.primary),
                  const SizedBox(width: 6),
                  bar(b.line2),
                  const SizedBox(width: 12),
                  Text(
                    context.t('setup.stepOf', {'step': 1, 'total': 2}),
                    style: AppType.caption.copyWith(color: b.faint, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _phase == _Phase.form
                  ? Rise(key: const ValueKey(_Phase.form), child: _form(context))
                  : Rise(
                      key: const ValueKey(_Phase.forging),
                      child: _Forging(done: _phase == _Phase.done, step: _step),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final password = _password.text;
    final passed = passwordScore(password).passed;
    final mismatch = _confirm.text.isNotEmpty && !_match;
    final mono = TextStyle(fontFamily: fontMono, fontSize: 15, letterSpacing: 0.6, color: p.text);

    // Shown and copied, the password goes through the secret clipboard
    return SecretSelection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 28),
          Semantics(
            header: true,
            child: Text(context.t('setup.title'), style: AppType.h2.copyWith(color: p.text)),
          ),
          const SizedBox(height: 10),
          Text(context.t('setup.body'), style: AppType.body1.copyWith(color: p.textSecondary)),
          if (ref.watch(erasedNoteProvider) case final erased?) ...[
            const SizedBox(height: 16),
            AppAlert(severity: AlertSeverity.warning, child: Text(_erasedText(context, erased))),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final label in const ['ML-KEM-1024', 'AES-256-GCM', 'scrypt']) _Tag(label),
              _Tag(context.t('setup.tag.local'), accent: true),
            ],
          ),
          if (_error case final error?) ...[const SizedBox(height: 20), AppAlert(severity: AlertSeverity.error, child: Text(error))],
          const SizedBox(height: 28),
          TextField(
            controller: _password,
            autofocus: true,
            obscureText: !_show,
            autocorrect: false,
            enableSuggestions: false,
            // Null, not the empty default: the phone's password manager neither fills nor saves it
            autofillHints: null,
            enableIMEPersonalizedLearning: false,
            contextMenuBuilder: secretTextMenu,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _confirmFocus.requestFocus(),
            style: mono,
            decoration: InputDecoration(
              labelText: context.t('setup.field.password'),
              suffixIcon: RevealPasswordButton(shown: _show, onPressed: () => setState(() => _show = !_show)),
            ),
          ),
          const SizedBox(height: 12),
          PasswordStrengthBar(password: password),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final (i, id) in _checkIds.indexed) _CheckChip(label: context.t(id), passed: passed[i])],
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _confirm,
            focusNode: _confirmFocus,
            obscureText: !_show,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: null,
            enableIMEPersonalizedLearning: false,
            contextMenuBuilder: secretTextMenu,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _create(),
            style: mono,
            decoration: InputDecoration(
              labelText: context.t('setup.field.confirm'),
              errorText: mismatch ? context.t('setup.field.mismatch') : null,
              // Keeps the room the message takes, so nothing jumps when it shows
              helperText: ' ',
              suffixIcon: _match ? const _MatchMark() : null,
            ),
          ),
          LeakCheckOption(value: leakCheckOn, onChanged: leakChecking ? null : (on) => setState(() => leakCheckOn = on)),
          const Expanded(child: SizedBox(height: 24)),
          if (leakNotice case final finding?) ...[
            LeakFindingNotice(finding: finding, onUseAnyway: () => _create(unchecked: true), onRetry: _create),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            style: largeButtonStyle,
            onPressed: _canCreate ? _create : null,
            icon: const Icon(Icons.lock_rounded),
            label: Text(context.t(leakChecking ? 'leakCheck.checking' : 'setup.button')),
          ),
          const SizedBox(height: 12),
          Text(
            context.t('setup.footnote'),
            textAlign: TextAlign.center,
            style: AppType.caption.copyWith(color: b.faint),
          ),
        ],
      ),
    );
  }
}

/// What the setup screen says after the erase: when, and after how many wrong passwords.
String _erasedText(BuildContext context, ErasedNote erased) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  return context.t('setup.erased', {
    'count': erased.after,
    'date': DateFormat.yMMMd(locale).format(erased.at),
    'time': DateFormat.Hm(locale).format(erased.at),
  });
}

/// A small outlined pill naming what keeps the vault safe.
class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: accent ? b.accentLine : b.line2),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(label, style: AppType.mono(fontSize: 11, color: accent ? b.accentText : context.palette.textSecondary)),
      ),
    );
  }
}

/// One of the password's checks, ticked once it passes.
class _CheckChip extends StatelessWidget {
  const _CheckChip({required this.label, required this.passed});

  final String label;
  final bool passed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final duration = Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 300);
    return Semantics(
      container: true,
      checked: passed,
      child: AnimatedContainer(
        duration: duration,
        height: 30,
        padding: const EdgeInsets.only(left: 7, right: 11),
        decoration: BoxDecoration(color: passed ? b.accentSoft : p.paper, borderRadius: BorderRadius.circular(15)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (passed)
              PopIn(
                duration: const Duration(milliseconds: 400),
                child: Container(
                  width: 17,
                  height: 17,
                  decoration: BoxDecoration(color: p.primary, shape: BoxShape.circle),
                  child: Icon(Icons.check_rounded, size: 12, color: p.onPrimary),
                ),
              )
            else
              Container(
                width: 17,
                height: 17,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: b.line2, width: 1.5),
                ),
              ),
            const SizedBox(width: 6),
            AnimatedDefaultTextStyle(
              duration: duration,
              style: TextStyle(
                fontFamily: fontSans,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: passed ? b.accentText : p.textSecondary,
              ),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}

/// The tick at the end of the confirmation once it matches.
class _MatchMark extends StatelessWidget {
  const _MatchMark();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      image: true,
      label: context.t('setup.field.match'),
      child: Center(
        widthFactor: 1,
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: PopIn(
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(color: p.primary, shape: BoxShape.circle),
              child: Icon(Icons.check_rounded, size: 15, color: p.onPrimary),
            ),
          ),
        ),
      ),
    );
  }
}

/// The vault being made: the emblem, what is happening, and the three
/// steps ticking off; then, once [done], that it is ready.
class _Forging extends StatelessWidget {
  const _Forging({required this.done, required this.step});

  final bool done;

  /// The steps finished so far.
  final int step;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final duration = Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 500);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 64),
          Center(
            child: ExcludeSemantics(
              child: Breathe(
                period: const Duration(milliseconds: 1800),
                child: AnimatedContainer(
                  duration: duration,
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: done ? p.primary : p.paper,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: b.line2),
                  ),
                  child: done
                      ? PopIn(
                          duration: const Duration(milliseconds: 550),
                          child: Icon(Icons.check_rounded, size: 44, color: p.onPrimary),
                        )
                      : Icon(Icons.lock_rounded, size: 40, color: b.accentText),
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          Semantics(
            header: true,
            child: Text(
              context.t(done ? 'setup.ready.title' : 'setup.forging.title'),
              textAlign: TextAlign.center,
              style: AppType.h2.copyWith(fontSize: 28, letterSpacing: -0.98, color: p.text),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                context.t(done ? 'setup.ready.body' : 'setup.forging.body'),
                textAlign: TextAlign.center,
                style: AppType.body1.copyWith(color: p.textSecondary),
              ),
            ),
          ),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: p.paper,
              border: Border.all(color: p.divider),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              children: [
                for (final (i, s) in _steps.indexed)
                  _StepRow(title: context.t(s.titleId), detail: s.detail, first: i == 0, done: i < step, active: i == step && !done),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One step of making the vault: waiting, under way (a spinning arc) or
/// done (a tick).
class _StepRow extends StatelessWidget {
  const _StepRow({required this.title, required this.detail, required this.first, required this.done, required this.active});

  final String title;
  final String detail;
  final bool first;
  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final lit = done || active;
    final duration = Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 300);
    return Container(
      height: 66,
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: p.divider)),
      ),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 30,
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedContainer(
                    duration: duration,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: lit ? b.accentLine : b.line2, width: 1.5),
                    ),
                  ),
                ),
                if (active) Positioned.fill(child: SpinningArc(color: b.accentText, radius: 13.5, strokeWidth: 2, length: 22)),
                if (done)
                  Positioned.fill(
                    child: PopIn(
                      child: Container(
                        decoration: BoxDecoration(color: p.primary, shape: BoxShape.circle),
                        child: Icon(Icons.check_rounded, size: 16, color: p.onPrimary),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedDefaultTextStyle(
                  duration: duration,
                  style: TextStyle(fontFamily: fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: lit ? p.text : b.faint),
                  child: Text(title),
                ),
                Text(detail, style: AppType.mono(fontSize: 11.5, color: b.faint)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
