import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../vault/vault_registry.dart';
import 'icu.dart';

/// The languages the app comes in, as Settings lists them. The names are
/// what `backmycodes_locale` stores.
enum AppLocale {
  en('English'),
  fr('Français');

  const AppLocale(this.label);

  /// The language's own name.
  final String label;

  /// The language until someone picks another, and for a message missing from the others' files.
  static const fallback = en;

  /// The language with [code], or null for one the app doesn't have.
  static AppLocale? fromCode(String? code) {
    for (final locale in values) {
      if (locale.name == code) return locale;
    }
    return null;
  }

  Locale get locale => Locale(name);
}

/// Something wrong with a message: missing, or not formatting with the arguments given.
class MessageError implements Exception {
  MessageError(this.message, {required this.id, required this.locale, this.cause});

  final String message;
  final String id;
  final AppLocale locale;

  /// The parser's or formatter's error, when there was one.
  final Object? cause;

  @override
  String toString() => cause == null ? 'MessageError: $message' : 'MessageError: $message\n$cause';
}

/// What happens to a [MessageError]. Tests can throw it to fail on a missing message.
typedef MessageErrorHandler = void Function(MessageError error);

/// Logged in debug builds and otherwise ignored, as react-intl does by default.
void _logError(MessageError error) {
  if (kDebugMode) debugPrint('$error');
}

/// The copy in one language: `en.json` or `fr.json`, read by id.
class Messages {
  Messages(this.locale, Map<String, String> messages, {MessageErrorHandler? onError})
    : _messages = messages,
      _onError = onError ?? _logError;

  final AppLocale locale;
  final Map<String, String> _messages;
  final MessageErrorHandler _onError;
  final Map<String, IcuMessage> _parsed = {};

  /// Every message id, in the file's order.
  Iterable<String> get ids => _messages.keys;

  /// The message [id] as written, or null when there's none.
  String? pattern(String id) => _messages[id];

  /// The message [id] with [args] filled in, as react-intl's `formatMessage`
  /// gives it: the id itself when the message is missing or empty, and the
  /// message as written when it doesn't format (an argument missing, or not
  /// valid ICU). Either is reported to the error handler.
  String t(String id, [Map<String, Object?> args = const {}]) {
    final pattern = _messages[id];
    if (pattern == null || pattern.isEmpty) {
      _onError(MessageError('Missing message: "$id" for locale "${locale.name}", using id as fallback.', id: id, locale: locale));
      return id;
    }
    try {
      return (_parsed[id] ??= IcuMessage.parse(pattern)).format(locale.name, args);
    } on Exception catch (error) {
      _onError(MessageError('Error formatting message: "$id", using the message as written.', id: id, locale: locale, cause: error));
      return pattern;
    }
  }
}

/// The copy in every language.
class MessageCatalog {
  MessageCatalog(Map<AppLocale, Map<String, String>> messages, {MessageErrorHandler? onError})
    : _byLocale = {for (final locale in AppLocale.values) locale: Messages(locale, messages[locale] ?? const {}, onError: onError)};

  /// Reads `assets/i18n/<code>.json` for every language.
  static Future<MessageCatalog> load({AssetBundle? bundle, MessageErrorHandler? onError}) async {
    final assets = bundle ?? rootBundle;
    final messages = <AppLocale, Map<String, String>>{};
    for (final locale in AppLocale.values) {
      // Decoded here rather than with loadString, which moves big files to
      // another isolate, which a widget test's fake clock never lets finish.
      final data = await assets.load('assets/i18n/${locale.name}.json');
      messages[locale] = decode(utf8.decode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)));
    }
    return MessageCatalog(messages, onError: onError);
  }

  /// One language's file: an object of message ids to ICU messages.
  static Map<String, String> decode(String json) => {
    for (final MapEntry(:key, :value) in (jsonDecode(json) as Map<String, Object?>).entries) key: value! as String,
  };

  final Map<AppLocale, Messages> _byLocale;

  Messages of(AppLocale locale) => _byLocale[locale]!;
}

/// The copy, loaded in `main` before the first frame and passed in with an override.
final messageCatalogProvider = Provider<MessageCatalog>(
  (ref) => throw UnimplementedError('messageCatalogProvider is overridden in main and in tests.'),
);

/// The language picked in Settings. It belongs to the device, not to a
/// vault, and survives deleting every vault.
class LocaleNotifier extends Notifier<AppLocale> {
  @override
  AppLocale build() {
    watchKeys(ref, const [keyLocale]);
    return AppLocale.fromCode(ref.watch(keyValueStoreProvider).getItem(keyLocale)) ?? AppLocale.fallback;
  }

  void setLocale(AppLocale locale) => ref.read(keyValueStoreProvider).setItem(keyLocale, locale.name);
}

final localeProvider = NotifierProvider<LocaleNotifier, AppLocale>(LocaleNotifier.new);

/// The copy in the language picked, for code outside widgets. Widgets use [MessagesContext.t].
final messagesProvider = Provider<Messages>((ref) => ref.watch(messageCatalogProvider).of(ref.watch(localeProvider)));

/// Hands the copy to [Localizations], so widgets read it from their context
/// and rebuild when the language changes.
class MessagesDelegate extends LocalizationsDelegate<Messages> {
  const MessagesDelegate(this.catalog);

  final MessageCatalog catalog;

  @override
  bool isSupported(Locale locale) => AppLocale.fromCode(locale.languageCode) != null;

  @override
  Future<Messages> load(Locale locale) => SynchronousFuture(catalog.of(AppLocale.fromCode(locale.languageCode) ?? AppLocale.fallback));

  @override
  bool shouldReload(MessagesDelegate old) => old.catalog != catalog;
}

/// The locales to give `MaterialApp.supportedLocales`.
final List<Locale> supportedLocales = [for (final locale in AppLocale.values) locale.locale];

/// The delegates to give `MaterialApp.localizationsDelegates`: the copy,
/// and Flutter's own strings and text direction in the same language.
///
/// ```dart
/// MaterialApp.router(
///   locale: ref.watch(localeProvider).locale,
///   supportedLocales: supportedLocales,
///   localizationsDelegates: localizationsDelegates(ref.watch(messageCatalogProvider)),
/// )
/// ```
List<LocalizationsDelegate<Object?>> localizationsDelegates(MessageCatalog catalog) => [
  MessagesDelegate(catalog),
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// The copy from a widget's context: `context.t('nav.settings')`,
/// `context.t('accounts.search', {'count': accounts.length})`.
extension MessagesContext on BuildContext {
  /// The copy in the app's language. Needs [MessagesDelegate] above, which [localizationsDelegates] includes.
  Messages get messages {
    final messages = Localizations.of<Messages>(this, Messages);
    if (messages == null) throw FlutterError('No Messages here: give MaterialApp the localizationsDelegates from messages.dart.');
    return messages;
  }

  /// The message [id] with [args] filled in; see [Messages.t].
  String t(String id, [Map<String, Object?> args = const {}]) => messages.t(id, args);
}
