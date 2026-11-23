/// The password leak check as the screens that take a master password use it (openspec:
/// password-leak-check): the control that turns it on, the check itself when the password
/// is submitted, and what it found.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/network.dart';
import '../../ui/ui.dart';
import 'pwned_passwords.dart';

/// What the check found that keeps a password from going straight through.
sealed class LeakFinding {
  const LeakFinding();
}

/// The password is among the leaked ones, [count] times over.
class PasswordLeaked extends LeakFinding {
  const PasswordLeaked(this.count);

  final int count;
}

/// The check couldn't be made, which says nothing of the password.
class PasswordUnchecked extends LeakFinding {
  const PasswordUnchecked();
}

/// The check was not made because offline mode is on, which says nothing
/// of the password and keeps nothing from going on (openspec:
/// add-offline-mode, decision 4).
class PasswordNotCheckedOffline extends LeakFinding {
  const PasswordNotCheckedOffline();
}

/// A screen's side of the leak check. It asks once, when the password is submitted, and
/// never while it is typed: a request per keystroke would send the hash prefix of every
/// beginning of the password.
mixin LeakChecking<W extends ConsumerStatefulWidget> on ConsumerState<W> {
  /// Whether the person turned the check on.
  bool leakCheckOn = false;

  /// A request is out.
  bool leakChecking = false;

  /// What the last check found, until the password is edited.
  LeakFinding? leakFinding;

  String? _checked;

  /// What the screen shows under the option: what the last check found, or,
  /// while the check is on and offline mode is too, that the password is not
  /// checked. Read it in `build`, which then follows the offline switch.
  LeakFinding? get leakNotice => leakCheckOn && ref.watch(offlineProvider) ? const PasswordNotCheckedOffline() : leakFinding;

  /// Call when the password field changes: a finding is about the password that was
  /// checked, so it goes once the field holds another.
  void leakPasswordEdited(String password) {
    if (leakFinding != null && password != _checked) leakFinding = null;
  }

  /// Whether [password] may go on to be used: the check is off, the person chose to go
  /// on without it ([skip]), offline mode is on, which makes no request, or it isn't
  /// among the leaked ones. Otherwise false, with [leakFinding] set for the screen to show.
  Future<bool> passesLeakCheck(String password, {bool skip = false}) async {
    if (!leakCheckOn || skip) {
      setState(() => leakFinding = null);
      return true;
    }
    if (ref.read(offlineProvider)) {
      // Not checked, and said so: the password goes through with no request
      setState(() {
        leakFinding = const PasswordNotCheckedOffline();
        _checked = password;
      });
      return true;
    }
    setState(() {
      leakChecking = true;
      leakFinding = null;
    });
    LeakFinding? finding;
    try {
      final count = await ref.read(pwnedPasswordsProvider).timesLeaked(password);
      if (count > 0) finding = PasswordLeaked(count);
    } on LeakCheckError {
      finding = const PasswordUnchecked();
    }
    if (!mounted) return false;
    setState(() {
      leakChecking = false;
      leakFinding = finding;
      _checked = password;
    });
    return finding == null;
  }
}

/// The checkbox that turns the check on, with the line that says what is sent and to
/// whom before anything is.
class LeakCheckOption extends StatelessWidget {
  const LeakCheckOption({super.key, required this.value, required this.onChanged});

  final bool value;

  /// Null while the choice can't be changed.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return MergeSemantics(
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: value,
                onChanged: onChanged == null ? null : (on) => onChanged!(on ?? false),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.t('leakCheck.option'), style: AppType.body2.copyWith(color: p.text)),
                    const SizedBox(height: 2),
                    Text(context.t('leakCheck.option.hint'), style: AppType.caption.copyWith(color: b.faint)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the check found, with the ways on: keep a leaked password with [onUseAnyway];
/// after a check that couldn't be made, [onRetry] or [onUseAnyway] to go on without it. A
/// check that offline mode held back is an info line with no button.
class LeakFindingNotice extends StatelessWidget {
  const LeakFindingNotice({super.key, required this.finding, required this.onUseAnyway, required this.onRetry});

  final LeakFinding finding;
  final VoidCallback onUseAnyway;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => switch (finding) {
    PasswordLeaked(:final count) => AppAlert(
      severity: AlertSeverity.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('leakCheck.leaked', {'count': count})),
          TextButton(onPressed: onUseAnyway, child: Text(context.t('leakCheck.useAnyway'))),
        ],
      ),
    ),
    PasswordNotCheckedOffline() => AppAlert(severity: AlertSeverity.info, child: Text(context.t('leakCheck.offline'))),
    PasswordUnchecked() => AppAlert(
      severity: AlertSeverity.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('leakCheck.failed')),
          Wrap(
            spacing: 8,
            children: [
              TextButton(onPressed: onRetry, child: Text(context.t('leakCheck.retry'))),
              TextButton(onPressed: onUseAnyway, child: Text(context.t('leakCheck.continue'))),
            ],
          ),
        ],
      ),
    ),
  };
}
