import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../core/public_suffixes.dart';
import '../../core/website_rules.dart';
import '../../i18n/messages.dart';
import '../../models/json.dart';
import '../../models/login.dart';
import '../../models/website_rule.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../accounts/account_sheet.dart' show displayName;
import '../accounts/tag_input.dart';
import '../autofill/website_hints.dart';
import '../autofill/website_rule_fields.dart';
import '../backup/two_factor_directory.dart';
import '../generator/generator_sheet.dart';
import '../lock/gate_widgets.dart';
import '../lock/password_strength.dart';
import '../settings/prefs.dart';
import '../spaces/hidden_passwords.dart';
import '../vault/owner_check.dart';
import 'code_picker.dart';
import 'login_sites.dart';

/// Opens the sheet that adds a login, or edits [login]. A new login can be
/// started with [accountId] as its code and [name], as the account sheet does.
Future<void> showLoginEditSheet(BuildContext context, {Login? login, String? accountId, String? name}) => showAppBottomSheet<void>(
  context,
  label: context.t(login == null ? 'logins.new.title' : 'logins.edit.title'),
  builder: (_) => LoginEditSheet(login: login, accountId: accountId, name: name),
);

/// A login's fields (openspec: logins; the approved mockup `NewLogin`): its
/// name, websites each with its rule, username and password with its strength,
/// the code linked to it, a note and tags. A new login is offered the account of
/// the vault whose service or website matches, marked "found in your codes",
/// until the person picks another. Save needs a name and a username or a
/// password, and every website field empty or holding a website its rule can take.
class LoginEditSheet extends ConsumerStatefulWidget {
  const LoginEditSheet({super.key, this.login, this.accountId, this.name});

  final Login? login;
  final String? accountId;

  /// The name a new login starts with.
  final String? name;

  @override
  ConsumerState<LoginEditSheet> createState() => _LoginEditSheetState();
}

class _LoginEditSheetState extends ConsumerState<LoginEditSheet> {
  late final _name = TextEditingController(text: widget.login?.name ?? widget.name ?? '');
  late final _username = TextEditingController(text: widget.login?.username ?? '');
  // A password hidden from this member by a space's grant never reaches the field
  late final _password = TextEditingController(text: _hidden ? '' : widget.login?.password ?? '');
  late final _note = TextEditingController(text: widget.login?.note ?? '');

  /// The websites, one row each, always at least one.
  late final _rows = <WebsiteRuleController>[
    for (final rule in widget.login?.rules ?? const <WebsiteRule>[]) WebsiteRuleController(rule),
    if (widget.login?.rules.isEmpty ?? true) WebsiteRuleController(),
  ];

  /// The row added last, which takes the focus.
  WebsiteRuleController? _fresh;
  late var _tags = <String>[...?widget.login?.tags];

  /// The account the person picked, '' for none; null while it hasn't been picked.
  late String? _picked = widget.login != null ? (widget.login!.accountId ?? '') : widget.accountId;
  var _show = false;
  var _saving = false;

  /// Whether the password field may still hold the saved password, or some
  /// of it: until the field is emptied or the generator fills it.
  late var _holdsSaved = !_hidden && widget.login?.password != null;

  /// Whether a grant of "passwords hidden" in a server space hides the password of the login being edited from this
  /// account: the sheet then shows no password field, no Show, no Generate, and saves the password as it is.
  bool get _hidden {
    final login = widget.login;
    return _hiddenAtOpen || (login != null && ref.read(hiddenPasswordsProvider).hides(login));
  }

  /// Whether the password was hidden when the sheet opened. It stays hidden for as long as the sheet is open, even when
  /// a chain then reports a grant that shows it: the field was never filled, so showing it empty would save the login
  /// with no password. Opening the sheet again shows it.
  late final bool _hiddenAtOpen = widget.login != null && ref.read(hiddenPasswordsProvider).hides(widget.login!);

  @override
  void initState() {
    super.initState();
    for (final field in [_name, _username, _password, _note]) {
      field.addListener(() => setState(() {}));
    }
    _rows.forEach(_watch);
    _password.addListener(() {
      if (_password.text.isEmpty) _holdsSaved = false;
    });
  }

  @override
  void dispose() {
    for (final field in [_name, _username, _password, _note]) {
      field.dispose();
    }
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _watch(WebsiteRuleController row) => row.addListener(() {
    if (mounted) setState(() {});
  });

  /// The websites typed, with their rules, in order and each once.
  List<WebsiteRule> get _rules => websiteRulesOf(_rows);

  /// The account linked when saved: the one picked, else for a new login the one found.
  String? _accountId(String? found) => switch (_picked) {
    null => found,
    '' => null,
    final id => id,
  };

  Login _draft(String? found) {
    String? text(TextEditingController field) => field.text.trim().isEmpty ? null : field.text.trim();
    final websites = websitesOf(_rules);
    final base = widget.login ?? Login(id: newUuid(), name: '', addedAt: 0);
    final edited = base.copyWith(
      name: _name.text.trim(),
      username: text(_username) ?? unset,
      websites: websites.websites ?? unset,
      uris: websites.uris ?? unset,
      note: text(_note) ?? unset,
      tags: _tags.isEmpty ? unset : [..._tags],
      accountId: _accountId(found) ?? unset,
    );
    // A hidden password is never touched; any other is kept as typed, spaces too
    if (_hidden) {
      return edited;
    }
    return edited.copyWith(password: _password.text.isEmpty ? unset : _password.text);
  }

  void _addWebsite() {
    final row = WebsiteRuleController();
    _watch(row);
    setState(() {
      _rows.add(row);
      _fresh = row;
    });
  }

  void _removeWebsite(WebsiteRuleController row) {
    setState(() => _rows.remove(row));
    // Disposed once the row has left the tree, which still listens to it until then
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
  }

  /// Opens the generator, and puts the password picked there in the field, shown.
  Future<void> _generate() async {
    final password = await showGeneratorSheet(context);
    if (password == null || !mounted) return;
    setState(() {
      _password.text = password;
      _holdsSaved = false;
      _show = true;
    });
  }

  /// Shows or hides the password. Showing the saved one asks first who it
  /// is when Settings says so, as the login's sheet does; what the person
  /// typed, or the generator made, shows at once.
  Future<void> _toggleShow() async {
    if (!_show && _holdsSaved && ref.read(prefsProvider).askBeforeSecret) {
      final reason = context.t('logins.reveal.confirm');
      if (!await ref.read(ownerCheckProvider)(context, ref, reason) || !mounted) return;
    }
    setState(() => _show = !_show);
  }

  Future<void> _pickCode(String? current) async {
    final picked = await showCodePicker(context, selected: current);
    if (picked != null) setState(() => _picked = picked);
  }

  Future<void> _save(Login draft) async {
    setState(() => _saving = true);
    final controller = ref.read(vaultControllerProvider.notifier);
    final saved = widget.login == null ? await controller.addLogin(draft) : await controller.updateLogin(draft);
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    final editing = widget.login;
    final hiddenNow = editing != null && ref.watch(hiddenPasswordsProvider.select((spaces) => spaces.hides(editing)));
    final hidden = _hiddenAtOpen || hiddenNow;
    final accounts = ref.watch(vaultControllerProvider.select((state) => state.accounts));
    final directory = ref.watch(twoFactorDirectoryProvider).value;
    final suffixes = ref.watch(publicSuffixListProvider).value;
    final rules = _rules;
    final found = widget.login == null && _picked == null
        ? offeredAccount(_name.text, fillHosts(rules), accounts, directory: directory, suffixes: suffixes, rules: rules)?.id
        : null;
    final draft = _draft(found);
    final linked = accounts.firstWhereOrNull((account) => account.id == draft.accountId);
    final websiteOk = _rows.every((row) => row.isValid);
    final otherApps = otherAppsLines(context.t, rules, WebsiteKind.login, suffixes: suffixes);
    final incomplete = _name.text.trim().isNotEmpty && !draft.isComplete;
    final changed = widget.login == null || draft != widget.login;
    final allTags = {for (final login in ref.watch(vaultControllerProvider.select((state) => state.logins))) ...?login.tags}.toList()
      ..sort();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(
          icon: const Icon(Icons.password_rounded),
          title: context.t(widget.login == null ? 'logins.new.title' : 'logins.edit.title'),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 14,
              children: [
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _name,
                  autofocus: widget.login == null,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(labelText: context.t('logins.field.name')),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 14,
                  children: [
                    for (final row in _rows)
                      WebsiteRuleFields(
                        key: ObjectKey(row),
                        controller: row,
                        kind: WebsiteKind.login,
                        label: context.t('logins.field.website'),
                        suffixes: suffixes,
                        autofocus: identical(row, _fresh),
                        onRemove: _rows.length > 1 ? () => _removeWebsite(row) : null,
                      ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(onPressed: _addWebsite, child: Text(context.t('logins.field.moreWebsite'))),
                    ),
                    if (rules.isNotEmpty)
                      Text(
                        phonesLine(context.t, rules, WebsiteKind.login, suffixes: suffixes),
                        style: AppType.caption.copyWith(color: b.faint),
                      ),
                    if (otherApps.isNotEmpty) ...[
                      Text(
                        context.t('websiteRules.other.title'),
                        style: AppType.caption.copyWith(color: b.faint, fontWeight: FontWeight.w600),
                      ),
                      for (final line in otherApps) Text(line, style: AppType.caption.copyWith(color: b.faint)),
                    ],
                  ],
                ),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _username,
                  autocorrect: false,
                  enableSuggestions: false,
                  // Null, as for the website: kept from the phone's password manager
                  autofillHints: null,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(labelText: context.t('logins.field.username')),
                ),
                if (hidden)
                  Padding(
                    key: const ValueKey('login-edit-password-space-hidden'),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(context.t('logins.password.spaceHidden'), style: AppType.caption.copyWith(color: b.faint)),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 10,
                    children: [
                      // Shown and copied, the password goes through the secret clipboard as the login's Copy does
                      SecretSelection(
                        child: TextField(
                          enableIMEPersonalizedLearning: false,
                          controller: _password,
                          obscureText: !_show,
                          autocorrect: false,
                          enableSuggestions: false,
                          // Null, as for the website: kept from the phone's password manager
                          autofillHints: null,
                          contextMenuBuilder: secretTextMenu,
                          style: AppType.mono(),
                          decoration: InputDecoration(
                            labelText: context.t('logins.field.password'),
                            suffixIcon: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                RevealPasswordButton(shown: _show, onPressed: () => unawaited(_toggleShow())),
                                Padding(
                                  padding: const EdgeInsetsDirectional.only(end: 6),
                                  child: TextButton(onPressed: () => unawaited(_generate()), child: Text(context.t('generator.open'))),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (_password.text.isNotEmpty) PasswordStrengthBar(password: _password.text),
                    ],
                  ),
                if (incomplete) AppAlert(severity: AlertSeverity.info, child: Text(context.t('logins.needsSecret'))),
                Group(
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.pin_outlined),
                      primary: context.t('logins.code'),
                      secondary: linked == null
                          ? context.t('logins.code.none')
                          : found != null
                          ? context.t('logins.code.found', {'name': displayName(linked)})
                          : displayName(linked),
                      secondaryStyle: found != null ? TextStyle(color: b.accentText) : null,
                      onTap: () => unawaited(_pickCode(linked?.id)),
                    ),
                  ],
                ),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _note,
                  minLines: 2,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: context.t('logins.field.note'), alignLabelWithHint: true),
                ),
                TagInput(value: _tags, onChanged: (tags) => setState(() => _tags = tags), suggestions: allTags),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: draft.isComplete && websiteOk && changed && !_saving ? () => unawaited(_save(draft)) : null,
                  child: Text(context.t('logins.save')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
