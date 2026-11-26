import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/contact.dart';
import '../../models/json.dart';
import '../../models/vault_key.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../keys/key_standing.dart';
import 'contact_keys.dart';
import 'contact_standing.dart';
import 'contact_widgets.dart';

/// Shows the public keys just read, one at a time, before anything is
/// stored: "Add this key?". [source] is one of `ContactSource`. With
/// [replacingId], the keys were given to update that contact: one with
/// another fingerprint is shown beside the key it would replace. A key found
/// by email carries [sourceEmail], the address it was found for.
Future<void> showContactReviewSheet(
  BuildContext context,
  List<crypto.PgpPublicKey> keys,
  String source, {
  String? replacingId,
  String? sourceEmail,
}) => showAppBottomSheet<void>(
  context,
  label: context.t('contacts.review.title'),
  builder: (_) => ContactReviewSheet(keys: keys, source: source, replacingId: replacingId, sourceEmail: sourceEmail),
);

/// What the review does with the key in front of it.
sealed class _Plan {
  const _Plan();
}

/// The key is one of the person's own PGP keys: refused.
class _Own extends _Plan {
  const _Own(this.own);

  final VaultKey own;
}

/// A contact already holds this key: the two copies are merged.
class _Update extends _Plan {
  const _Update(this.contact);

  final Contact contact;
}

/// The key would take the place of another key of [contact].
class _Replace extends _Plan {
  const _Replace(this.contact);

  final Contact contact;
}

/// A key the vault doesn't hold. [sameEmail] is a contact whose key names
/// the address [email] too.
class _New extends _Plan {
  const _New({this.sameEmail, this.email});

  final Contact? sameEmail;
  final String? email;
}

/// The review of one key after another (openspec: add-pgp-contacts,
/// decisions 9, 10 and 16). For each, in order: a key that is the person's
/// own is refused; a key a contact already holds updates that contact,
/// keeping everything either copy has; otherwise the sheet shows whose key
/// it says it is, where it came from, its algorithm and expiry and its
/// fingerprint in groups, and adds it as checked or as not checked. Closing
/// the sheet adds nothing more.
class ContactReviewSheet extends ConsumerStatefulWidget {
  const ContactReviewSheet({super.key, required this.keys, required this.source, this.replacingId, this.sourceEmail});

  final List<crypto.PgpPublicKey> keys;
  final String source;
  final String? replacingId;
  final String? sourceEmail;

  @override
  ConsumerState<ContactReviewSheet> createState() => _ContactReviewSheetState();
}

class _ContactReviewSheetState extends ConsumerState<ContactReviewSheet> {
  var _index = 0;
  var _busy = false;
  late _Plan _plan;

  /// For an update: the two copies merged, once worked out, or why they
  /// could not be.
  Uint8List? _merged;
  bool _mergeFailed = false;

  crypto.PgpPublicKey get _key => widget.keys[_index];
  String get _fingerprint => _key.info.primary.fingerprintHex;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  /// Decides what to do with the key in front, from what the vault holds now.
  void _prepare() {
    final state = ref.read(vaultControllerProvider);
    _merged = null;
    _mergeFailed = false;
    final own = state.keys.firstWhereOrNull(
      (key) => key.kind == KeyKind.pgp && ref.read(pgpKeyInfoProvider(key.id))?.primary.fingerprintHex == _fingerprint,
    );
    if (own != null) {
      _plan = _Own(own);
      return;
    }
    String? fingerprintOf(Contact contact) => ref.read(contactKeyInfoProvider(contact.id))?.primary.fingerprintHex;
    final held = state.contacts.firstWhereOrNull((contact) => fingerprintOf(contact) == _fingerprint);
    if (held != null) {
      _plan = _Update(held);
      unawaited(_merge(held));
      return;
    }
    final replacing = state.contacts.firstWhereOrNull((contact) => contact.id == widget.replacingId);
    if (replacing != null) {
      _plan = _Replace(replacing);
      return;
    }
    final addresses = keyAddresses(_key.info);
    for (final contact in state.contacts) {
      final shared = keyAddresses(ref.read(contactKeyInfoProvider(contact.id))).intersection(addresses);
      if (shared.isNotEmpty) {
        _plan = _New(sameEmail: contact, email: shared.first);
        return;
      }
    }
    _plan = const _New();
  }

  Future<void> _merge(Contact held) async {
    final index = _index;
    Uint8List? merged;
    try {
      merged = await ref.read(publicKeyMergerProvider)(unb64(held.publicKey), _key.bytes);
    } on crypto.KeyFormatException {
      merged = null;
    } on FormatException {
      merged = null;
    } on ArgumentError {
      merged = null;
    }
    if (!mounted || index != _index) return;
    setState(() {
      _merged = merged;
      _mergeFailed = merged == null;
    });
  }

  /// On to the next key, or closes after the last.
  void _next() {
    if (_index + 1 >= widget.keys.length) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _index++;
      _busy = false;
      _prepare();
    });
  }

  Future<void> _run(Future<bool> Function() change) async {
    if (_busy) return;
    setState(() => _busy = true);
    final done = await change();
    if (!mounted) return;
    if (done) {
      _next();
    } else {
      setState(() => _busy = false);
    }
  }

  int get _now => ref.read(clockProvider)().millisecondsSinceEpoch;

  /// Adds the key as a new contact, checked now when [checked].
  Future<void> _add({required bool checked}) => _run(() {
    final contact = Contact(
      id: newUuid(),
      name: defaultContactName(_key.info, context.messages),
      publicKey: b64(_key.bytes),
      source: widget.source,
      sourceEmail: widget.sourceEmail,
      addedAt: 0,
    );
    return ref.read(vaultControllerProvider.notifier).addContact(checked ? _checked(contact) : contact);
  });

  /// [contact] checked now for the key in front, and the addresses it carries.
  Contact _checked(Contact contact) => contact.checked(_fingerprint, _now, addresses: keyAddresses(_key.info));

  /// Puts the key in the place of [contact]'s, which keeps its id, name and
  /// note; checked only when the person confirmed the new fingerprint here.
  Future<void> _replace(Contact contact, {required bool checked}) => _run(() {
    final next = contact.copyWith(publicKey: b64(_key.bytes), source: widget.source, sourceEmail: widget.sourceEmail ?? unset);
    return ref.read(vaultControllerProvider.notifier).updateContact(checked ? _checked(next) : next.unchecked());
  });

  /// Saves the merged copy of a key [contact] already holds. Its check
  /// keeps covering the addresses it covered, and no address the copy adds.
  Future<void> _update(Contact contact, Uint8List merged) => _run(() async {
    final toasts = ref.read(toastsProvider.notifier);
    final done = context.t('contacts.update.done', {'name': contact.name});
    final saved = await ref
        .read(vaultControllerProvider.notifier)
        .updateContact(withCheckedAddresses(contact).copyWith(publicKey: b64(merged)));
    if (saved) toasts.show(done);
    return saved;
  });

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final many = widget.keys.length > 1;
    final title = switch (plan) {
      _Update() => 'contacts.update.title',
      _Replace(:final contact) => contact.hasKey ? 'contacts.replace.title' : 'contacts.person.addKey.title',
      _ => 'contacts.review.title',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ContactSheetHead(
          title: context.t(title),
          step: many ? context.t('contacts.review.step', {'index': _index + 1, 'count': widget.keys.length}) : null,
        ),
        Flexible(
          child: SingleChildScrollView(
            // A new subtree for each key, so its rows rise in again
            key: ValueKey(_index),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ..._body(context, plan),
                if (many && _index + 1 < widget.keys.length && plan is! _Own) ...[
                  const SizedBox(height: 4),
                  TextButton(onPressed: _busy ? null : _next, child: Text(context.t('contacts.review.skip'))),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _body(BuildContext context, _Plan plan) {
    final p = context.palette;
    final info = _key.info;
    final now = ref.watch(clockProvider)();
    final name = info.userIds.isEmpty ? null : userIdName(info.userIds.first);
    final shown = defaultContactName(info, context.messages);
    final address = keyAddresses(info).firstOrNull;
    final standing = contactStanding(
      Contact(id: '', name: shown, publicKey: '', source: widget.source, addedAt: 0),
      now,
      info: info,
    );
    final groups = crypto.fingerprintGroups(_fingerprint).length;

    final facts = Rise(
      child: Group(
        key: const ValueKey('review-facts'),
        children: [
          GroupRow(first: true, icon: Text(contactInitials(shown)), accent: true, primary: shown, secondary: address),
          GroupRow(
            primary: context.t('contacts.review.source'),
            value: RowValue(contactSourceText(context.messages, widget.source, widget.sourceEmail)),
          ),
          GroupRow(primary: context.t('contacts.review.key'), value: RowValue(contactKeyLine(context, info, standing.key))),
        ],
      ),
    );
    // Every name and address the key carries, each in full: checking it covers these and no address added later.
    // [added] are those an update brings.
    List<Widget> userIds(List<String> all, {Set<String> added = const {}}) => [
      if (all.isNotEmpty)
        Rise(
          delay: const Duration(milliseconds: 60),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionLabel(context.t('contacts.sheet.userIds')),
              Group(
                key: const ValueKey('review-user-ids'),
                children: [
                  for (final (i, user) in all.indexed)
                    GroupRow(
                      first: i == 0,
                      primary: user,
                      tag: added.contains(user) ? StatusTag(label: context.t('contacts.review.new'), tone: StatusTone.warning) : null,
                    ),
                ],
              ),
            ],
          ),
        ),
    ];
    Widget alert(AlertSeverity severity, String text, {String? key, int delay = 240}) => Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Rise(
        delay: Duration(milliseconds: delay),
        child: AppAlert(key: key == null ? null : ValueKey(key), severity: severity, child: Text(text)),
      ),
    );
    // What the key can no longer do, said before it is added
    final over = switch (standing.key.standing) {
      Standing.revoked => alert(AlertSeverity.error, context.t('contacts.review.revokedBody'), key: 'review-standing'),
      Standing.expired => alert(
        AlertSeverity.error,
        context.t('contacts.review.expired', {'date': contactDate(context, standing.key.expires!)}),
        key: 'review-standing',
      ),
      _ when !standing.canEncrypt => alert(AlertSeverity.info, context.t('contacts.review.cannotEncrypt'), key: 'review-standing'),
      _ => null,
    };
    Widget fingerprint(String hex, {String? label, String? key}) => Rise(
      delay: const Duration(milliseconds: 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel(label ?? context.t('contacts.review.fingerprint')),
          FingerprintCard(key: key == null ? null : ValueKey(key), fingerprint: hex),
        ],
      ),
    );
    final advice = alert(
      AlertSeverity.warning,
      name == null || name.isEmpty
          ? context.t('contacts.review.advice.unnamed', {'count': groups})
          : context.t('contacts.review.advice', {'name': name, 'count': groups}),
      key: 'review-advice',
    );
    List<Widget> answers({required VoidCallback onChecked, required VoidCallback onUnchecked}) => [
      const SizedBox(height: 18),
      Rise(
        delay: const Duration(milliseconds: 360),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(style: largeButtonStyle, onPressed: _busy ? null : onChecked, child: Text(context.t('contacts.review.checked'))),
            const SizedBox(height: 10),
            OutlinedButton(
              style: largeButtonStyle,
              onPressed: _busy ? null : onUnchecked,
              child: Text(context.t('contacts.review.unchecked')),
            ),
            const SizedBox(height: 10),
            Text(
              context.t('contacts.review.caption'),
              textAlign: TextAlign.center,
              style: AppType.caption.copyWith(color: p.textSecondary),
            ),
          ],
        ),
      ),
    ];
    Widget close() => Padding(
      padding: const EdgeInsets.only(top: 18),
      child: FilledButton(style: largeButtonStyle, onPressed: _busy ? null : _next, child: Text(context.t('contacts.review.close'))),
    );

    switch (plan) {
      case _Own(:final own):
        return [
          facts,
          fingerprint(_fingerprint),
          alert(AlertSeverity.error, context.t('contacts.review.own', {'name': own.name}), key: 'review-own'),
          close(),
        ];
      case _New(:final sameEmail, :final email):
        return [
          facts,
          ...userIds(info.userIds),
          fingerprint(_fingerprint, key: 'review-fingerprint'),
          ?over,
          if (sameEmail != null)
            alert(
              AlertSeverity.info,
              context.t(
                contactStanding(sameEmail, now).checked ? 'contacts.review.sameEmail.checked' : 'contacts.review.sameEmail.unchecked',
                {'email': email ?? '', 'name': sameEmail.name},
              ),
              key: 'review-same-email',
            ),
          advice,
          ...answers(onChecked: () => unawaited(_add(checked: true)), onUnchecked: () => unawaited(_add(checked: false))),
        ];
      case _Replace(:final contact):
        final current = ref.watch(contactKeyInfoProvider(contact.id))?.primary.fingerprintHex;
        return [
          facts,
          ...userIds(info.userIds),
          if (current != null) fingerprint(current, label: context.t('contacts.replace.current'), key: 'replace-current'),
          fingerprint(_fingerprint, label: context.t('contacts.replace.next'), key: 'replace-next'),
          if (contact.hasKey)
            alert(AlertSeverity.error, context.t('contacts.replace.warning', {'name': contact.name}), key: 'replace-warning')
          else
            alert(AlertSeverity.info, context.t('contacts.person.addKey.review', {'name': contact.name}), key: 'add-key-info'),
          ?over,
          advice,
          ...answers(
            onChecked: () => unawaited(_replace(contact, checked: true)),
            onUnchecked: () => unawaited(_replace(contact, checked: false)),
          ),
        ];
      case _Update(:final contact):
        final merged = _merged;
        if (_mergeFailed) {
          return [facts, alert(AlertSeverity.error, context.t('contacts.error.failsChecks'), key: 'update-failed'), close()];
        }
        if (merged == null) {
          return [
            facts,
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Spinner()),
            ),
          ];
        }
        if (b64(merged) == contact.publicKey) {
          return [
            facts,
            fingerprint(_fingerprint),
            alert(AlertSeverity.info, context.t('contacts.update.same', {'name': contact.name}), key: 'update-same'),
            close(),
          ];
        }
        final before = contactStanding(contact, now, info: ref.watch(contactKeyInfoProvider(contact.id)));
        final after = contactStanding(contact, now, info: crypto.readPgpKeyInfo(merged));
        final added = (after.info?.subkeys.length ?? 0) - (before.info?.subkeys.length ?? 0);
        final newUserIds = {...?after.info?.userIds}.difference({...?before.info?.userIds});
        final newAddresses = keyAddresses(after.info).difference(keyAddresses(before.info));
        // The check stays with what it covered, so an address the copy brings is not checked
        final notCovered = keyAddresses(after.info).difference(before.confirmedAddresses);
        final changes = [
          if (after.key.standing == Standing.revoked && before.key.standing != Standing.revoked) context.t('contacts.update.revoked'),
          if (after.key.expires != before.key.expires)
            after.key.expires == null
                ? context.t('contacts.update.neverExpires')
                : context.t('contacts.update.expiry', {'date': contactDate(context, after.key.expires!)}),
          if (added > 0) context.t('contacts.update.subkeys', {'count': added}),
          if (newAddresses.isNotEmpty) context.t('contacts.update.addresses', {'addresses': newAddresses.join(', ')}),
        ];
        return [
          facts,
          ...userIds(after.info?.userIds ?? const [], added: newUserIds),
          fingerprint(_fingerprint),
          alert(
            newAddresses.isEmpty ? AlertSeverity.info : AlertSeverity.warning,
            [
              context.t('contacts.update.intro', {'name': contact.name}),
              ...changes.isEmpty ? [context.t('contacts.update.other')] : changes,
              if (before.checked && notCovered.isEmpty) context.t('contacts.update.keepsCheck'),
              if (before.checked && notCovered.isNotEmpty)
                context.t('contacts.update.keepsCheckNotFor', {'addresses': notCovered.join(', ')}),
            ].join(' '),
            key: 'update-changes',
          ),
          const SizedBox(height: 18),
          FilledButton(
            style: largeButtonStyle,
            onPressed: _busy ? null : () => unawaited(_update(contact, merged)),
            child: Text(context.t('contacts.update.confirm')),
          ),
        ];
    }
  }
}
