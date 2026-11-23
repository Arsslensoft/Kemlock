/// Words and formats the Sends sheets share: what a refusal says, dates, day counts and sizes.
library;

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../../i18n/messages.dart';
import '../notes/note_files.dart' show fileSizeText;
import '../sync/kemlock/km_api.dart';
import '../sync/kemlock/km_failover.dart';
import '../sync/kemlock/km_sends_api.dart';
import 'sends_recipient.dart';
import 'sends_service.dart';

/// What the person is told of [error], a refusal of the Send routes or of the service's own checks. A policy's own
/// words, the largest file the server takes and the wait after too many tries are the server's, shown as it said them.
String sendsErrorText(BuildContext context, Object error) {
  switch (error) {
    case SendsInvalidInput(:final reason):
      return switch (reason) {
        SendsInvalid.noName => context.t('sends.error.noName'),
        SendsInvalid.noText => context.t('sends.error.noText'),
        SendsInvalid.textTooLong => context.t('sends.error.textTooLong'),
        SendsInvalid.notesTooLong => context.t('sends.error.notesTooLong'),
        SendsInvalid.fileTooBig => context.t('sends.file.tooBig', {'limit': fileSizeText(context, sendFileLimit)}),
        SendsInvalid.deletion => context.t('sends.error.deletion'),
        SendsInvalid.expiry => context.t('sends.error.expiry'),
        SendsInvalid.maxAccess => context.t('sends.error.maxAccess', {'min': 1}),
      };
    case SendsUploadFailed():
      return context.t('sends.error.upload');
    case SendsError(:final problem, :final detail, :final maxSize):
      return switch (problem) {
        SendsProblem.policy =>
          detail == null || detail.isEmpty ? context.t('sends.error.policyPlain') : context.t('sends.error.policy', {'reason': detail}),
        SendsProblem.fileTooLarge =>
          maxSize == null ? context.t('sends.error.server') : context.t('sends.error.tooLarge', {'size': fileSizeText(context, maxSize)}),
        SendsProblem.storage => context.t('sends.error.storage'),
        SendsProblem.notFound => context.t('sends.error.notFound'),
        SendsProblem.rateLimited => context.t('kemlock.problem.rateLimited'),
        _ => context.t('sends.error.server'),
      };
    case KmHomeAway(:final since):
      return context.t('sends.away', {'time': sendsTime(context, since)});
    case KmError(problem: KmProblem.sessionEnded):
      return context.t('sends.sessionEnded');
    case KmError(problem: KmProblem.network):
      return context.t('sends.error.network');
    case KmError(problem: KmProblem.rateLimited):
      return context.t('kemlock.problem.rateLimited');
    default:
      return context.t('sends.error.server');
  }
}

/// [time] as a clock time, for "offline since".
String sendsTime(BuildContext context, DateTime time) =>
    DateFormat.jm(Localizations.localeOf(context).toLanguageTag()).format(time.toLocal());

/// [time] as a date, in the phone's language and zone.
String sendsDate(BuildContext context, DateTime time) =>
    DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(time.toLocal());

/// "1 day", "7 days".
String sendsDays(BuildContext context, int days) => context.t('sends.days', {'days': days});

/// The wait a rate-limited answer asks for, in whole seconds, at least 1 and at most a minute: the server's limit is
/// per minute, and an answer with no wait is taken as one.
int sendsWaitSeconds(int? retryAfter) => (retryAfter ?? 60).clamp(1, 60);

/// Whether [error] is a Send the link can't open for being closed.
bool isNotAvailable(Object error) => error is SendsError && error.problem == SendsProblem.notFound;

/// Whether [error] is a link that opens nothing: a payload that isn't the Send's own.
bool isDoesntOpen(Object error) => error is SendsDoesntOpen;
