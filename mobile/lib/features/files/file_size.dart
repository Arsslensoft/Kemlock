import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../i18n/messages.dart';
import '../../models/secure_note.dart';
import '../notes/note_files.dart' show fileSizeText;

/// A day as the language writes it ("14 Mar 2031"), from epoch milliseconds.
String fileDateText(int millis, String locale) => DateFormat('d MMM y', locale).format(DateTime.fromMillisecondsSinceEpoch(millis));

/// The line under a File item in the vault list: its size and the day it was added.
String fileLine(BuildContext context, NoteAttachment file, String locale) =>
    context.t('files.line', {'size': fileSizeText(context, file.size), 'date': fileDateText(file.addedAt, locale)});
