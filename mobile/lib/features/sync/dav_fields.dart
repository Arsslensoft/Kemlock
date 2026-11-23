import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import 'webdav.dart';

/// The WebDAV folder's address and the login for it, shared by the sync and
/// spaces sheets, ported from `DavFields.tsx`: the folder address, the
/// username and the app password, each reported through [onChanged] as
/// it's typed.
///
/// Only https addresses are accepted, but that's checked when the sheet
/// talks to the server (`sync.problem.insecure`), as in the web app, so a
/// half-typed address isn't flagged.
class DavFields extends StatefulWidget {
  const DavFields({super.key, required this.value, required this.onChanged, this.enabled = true, this.urlHelper});

  final DavAccount value;
  final ValueChanged<DavAccount> onChanged;
  final bool enabled;

  /// Says which folder to pick, instead of the vault sync's own words.
  final String? urlHelper;

  @override
  State<DavFields> createState() => _DavFieldsState();
}

class _DavFieldsState extends State<DavFields> {
  late final _url = TextEditingController(text: widget.value.url);
  late final _username = TextEditingController(text: widget.value.username);
  late final _password = TextEditingController(text: widget.value.password);

  @override
  void didUpdateWidget(DavFields old) {
    super.didUpdateWidget(old);
    // A value set from outside, such as the folder of the vault's own sync, shows in the fields.
    void follow(TextEditingController controller, String text) {
      if (controller.text == text) return;
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }

    follow(_url, widget.value.url);
    follow(_username, widget.value.username);
    follow(_password, widget.value.password);
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AutofillGroup(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: _url,
          enabled: widget.enabled,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.url],
          onChanged: (url) => widget.onChanged(widget.value.copyWith(url: url)),
          decoration: InputDecoration(
            labelText: context.t('sync.field.url'),
            hintText: 'https://cloud.example.com/remote.php/dav/files/you/Kemlock/',
            helperText: widget.urlHelper ?? context.t('sync.field.urlHelper'),
            helperMaxLines: 3,
          ),
        ),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: _username,
          enabled: widget.enabled,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.username],
          onChanged: (username) => widget.onChanged(widget.value.copyWith(username: username)),
          decoration: InputDecoration(labelText: context.t('sync.field.username')),
        ),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: _password,
          enabled: widget.enabled,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.password],
          onChanged: (password) => widget.onChanged(widget.value.copyWith(password: password)),
          decoration: InputDecoration(
            labelText: context.t('sync.field.password'),
            helperText: context.t('sync.field.passwordHelper'),
            helperMaxLines: 3,
          ),
        ),
      ],
    ),
  );
}
