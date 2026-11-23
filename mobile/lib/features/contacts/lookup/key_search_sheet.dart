import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../i18n/messages.dart';
import '../../../platform/network.dart';
import '../../../ui/ui.dart';
import '../../settings/offline_alert.dart';
import '../contact_review_sheet.dart';
import 'key_search.dart';
import 'lookup_http.dart';
import 'vks.dart';
import 'wkd.dart';

/// "Find a key by email" (openspec: add-key-lookup, decision 8). [address]
/// fills the field, as a contact's "Look for a newer copy" does, and still
/// nothing is sent before "Search". A key found opens "Add this key?", or
/// with [replacingId] the update of that contact.
Future<void> showKeySearchSheet(BuildContext context, {String? address, String? replacingId}) => showAppBottomSheet<void>(
  context,
  label: context.t('contacts.lookup.title'),
  builder: (_) => KeySearchSheet(address: address, replacingId: replacingId),
);

/// The sheet [showKeySearchSheet] opens: one address field, a statement of
/// who will be asked and what they learn, and the search's two steps, the
/// domain on "Search" and keys.openpgp.org on its own button once the
/// domain had no key. Closing it drops a request under way; nothing of a
/// search is kept.
class KeySearchSheet extends ConsumerStatefulWidget {
  const KeySearchSheet({super.key, this.address, this.replacingId});

  final String? address;
  final String? replacingId;

  @override
  ConsumerState<KeySearchSheet> createState() => _KeySearchSheetState();
}

class _KeySearchSheetState extends ConsumerState<KeySearchSheet> {
  late final _field = TextEditingController(text: widget.address ?? '');
  late final KeySearch _search = KeySearch(
    gate: ref.read(networkGateProvider),
    client: ref.read(keyLookupClientProvider),
    resolve: ref.read(hostResolverProvider),
    read: ref.read(keyLookupReaderProvider),
    now: ref.read(clockProvider),
  );
  late String _text = _field.text;

  /// Whether to say why the text is not an address: after a search was
  /// asked for it, or at once for a reason typing on won't mend.
  var _tried = false;

  @override
  void initState() {
    super.initState();
    _field.addListener(_edited);
    _search.addListener(_changed);
  }

  @override
  void dispose() {
    _search.dispose();
    _field.dispose();
    super.dispose();
  }

  /// A changed address is a new search: what the last one reached, its key
  /// server offer included, goes.
  void _edited() {
    if (_field.text == _text) return;
    _text = _field.text;
    _search.reset();
    setState(() => _tried = false);
  }

  void _changed() {
    final state = _search.value;
    if (state is SearchFound) {
      final root = Navigator.of(context, rootNavigator: true).context;
      Navigator.of(context).pop();
      if (root.mounted) {
        unawaited(
          showContactReviewSheet(root, state.keys, state.source, replacingId: widget.replacingId, sourceEmail: state.address.address),
        );
      }
      return;
    }
    setState(() {});
  }

  void _submit() {
    final address = readLookupAddress(_field.text).address;
    if (address == null) {
      setState(() => _tried = true);
      return;
    }
    if (ref.read(offlineProvider)) return;
    FocusScope.of(context).unfocus();
    unawaited(_search.search(address));
  }

  /// Why the field's text is not an address, when it is time to say so.
  String? _problem(AddressProblem? problem) => switch (problem) {
    null || AddressProblem.empty => null,
    AddressProblem.internationalDomain => context.t('contacts.lookup.international'),
    AddressProblem.tooLong => context.t('contacts.lookup.tooLong'),
    _ when _tried => context.t('contacts.lookup.invalid'),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final offline = ref.watch(offlineProvider);
    final read = readLookupAddress(_field.text);
    final address = read.address;
    final state = _search.value;
    final busy = _search.busy;
    // A step offline mode paused reads as before it, once offline mode is off
    final shown = switch (state) {
      SearchPaused(step: KeySearchStep.domain) => const SearchIdle(),
      SearchPaused(step: KeySearchStep.server, :final address) => SearchDomainHasNone(address),
      _ => state,
    };

    Widget alert(AlertSeverity severity, String text, {required String key}) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: AppAlert(key: ValueKey(key), severity: severity, child: Text(text)),
    );
    Widget asking(String host) => Padding(
      key: const ValueKey('lookup-asking'),
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spinner(),
          const SizedBox(width: 10),
          Flexible(
            child: Text(context.t('contacts.lookup.asking', {'host': host}), style: AppType.body2.copyWith(color: p.textSecondary)),
          ),
        ],
      ),
    );
    Widget retry() => Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton(onPressed: offline ? null : () => unawaited(_search.retry()), child: Text(context.t('contacts.lookup.retry'))),
    );
    final canSearch = address != null && !offline && !busy;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.alternate_email_rounded), title: context.t('contacts.lookup.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  enableIMEPersonalizedLearning: false,
                  key: const ValueKey('lookup-address'),
                  controller: _field,
                  readOnly: busy,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.search,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: context.t('contacts.lookup.field'),
                    hintText: 'grace@example.org',
                    errorText: _problem(read.problem),
                    errorMaxLines: 3,
                  ),
                ),
                // What leaves the phone, said before it does; or that nothing will
                if (offline)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: OfflineAlert(context.t('contacts.lookup.offline'), key: const ValueKey('lookup-offline')),
                  )
                else if (shown is SearchIdle || shown is SearchAskingDomain)
                  alert(
                    AlertSeverity.info,
                    address == null
                        ? context.t('contacts.lookup.info')
                        : context.t('contacts.lookup.info.domain', {'domain': address.domain}),
                    key: 'lookup-info',
                  ),
                ...switch (shown) {
                  SearchIdle() => [
                    const SizedBox(height: 16),
                    Sheen(
                      enabled: canSearch,
                      child: FilledButton(
                        style: largeButtonStyle,
                        onPressed: canSearch ? _submit : null,
                        child: Text(context.t('contacts.lookup.search')),
                      ),
                    ),
                  ],
                  SearchAskingDomain(:final address) => [asking(address.domain)],
                  SearchDomainHasNone(:final address) || SearchAskingServer(:final address) => [
                    alert(
                      AlertSeverity.info,
                      context.t('contacts.lookup.domainHasNone', {'domain': address.domain}),
                      key: 'lookup-domain-has-none',
                    ),
                    if (shown is SearchAskingServer)
                      asking(vksHost)
                    else ...[
                      const SizedBox(height: 16),
                      OutlinedButton(
                        style: largeButtonStyle,
                        onPressed: offline ? null : () => unawaited(_search.askKeyServer()),
                        child: Text(context.t('contacts.lookup.askServer')),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        context.t('contacts.lookup.askServer.caption'),
                        key: const ValueKey('lookup-server-caption'),
                        textAlign: TextAlign.center,
                        style: AppType.caption.copyWith(color: p.textSecondary),
                      ),
                    ],
                  ],
                  SearchNowhere() => [alert(AlertSeverity.info, context.t('contacts.lookup.nowhere'), key: 'lookup-nowhere')],
                  SearchCouldNotAsk(:final address, :final step) => [
                    alert(
                      AlertSeverity.error,
                      context.t('contacts.lookup.unreachable', {'host': step == KeySearchStep.domain ? address.domain : vksHost}),
                      key: 'lookup-unreachable',
                    ),
                    retry(),
                  ],
                  SearchSlowDown() => [alert(AlertSeverity.error, context.t('contacts.lookup.slowDown'), key: 'lookup-slow-down'), retry()],
                  SearchFound() || SearchPaused() => const <Widget>[],
                },
              ],
            ),
          ),
        ),
      ],
    );
  }
}
