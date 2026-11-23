/// What the sync and spaces sheets say about a folder, a problem and how
/// the last sync went, ported from `syncMessages.ts`.
library;

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../../i18n/messages.dart';
import 'sync.dart';
import 'sync_store.dart';
import 'webdav.dart';

/// A folder and login with nothing typed in yet.
const emptyDav = DavAccount(url: '', username: '', password: '');

/// The host a target syncs with, for status lines: `cloud.example.com`,
/// with the port when it isn't https's own, or the address as typed when it
/// isn't a URL.
String davHost(DavAccount account) {
  final url = Uri.tryParse(account.url.trim());
  if (url == null || !url.hasScheme || url.host.isEmpty) return account.url;
  return url.hasPort ? '${url.host}:${url.port}' : url.host;
}

/// What went wrong, in words, for a sync problem. The app calls servers
/// directly, so the browser's CORS variant of `network` never applies.
String problemText(BuildContext context, SyncProblem problem) => context.t('sync.problem.${problem.name}');

/// "Last synced Oct 16, 2026 9:00 AM", "Not synced yet", or the problem.
String statusText(BuildContext context, ScopeStatus? status) {
  if (status?.problem case final problem?) return problemText(context, problem);
  final at = status?.lastSyncAt;
  if (at == null) return context.t('sync.status.never');
  return context.t('sync.status.synced', {'when': syncTime(context, at)});
}

/// [epochMs] as a medium date and a short time in the app's language, as
/// `formatDate(…, { dateStyle: 'medium', timeStyle: 'short' })` wrote it.
String syncTime(BuildContext context, int epochMs) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  return DateFormat.yMMMd(locale).add_jm().format(DateTime.fromMillisecondsSinceEpoch(epochMs));
}
