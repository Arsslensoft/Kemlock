/// An account's name on a key, `[period/]issuer:label`, the form Yubico's
/// own apps write (openspec: add-security-key-codes, decision 3).
library;

import 'dart:convert';

import 'oath_messages.dart';

/// The start of a name Yubico's apps keep out of their lists.
const oathHiddenPrefix = '_hidden:';

/// The period a time-based account has when its name gives none.
const oathDefaultPeriod = 30;

/// Whether the account [name] is one the apps do not list.
bool isHiddenOathName(String name) => name.startsWith(oathHiddenPrefix);

/// The parts of a name.
class OathName {
  const OathName({this.issuer = '', required this.label, this.period = oathDefaultPeriod});

  /// Empty when the name has no `issuer:` part.
  final String issuer;
  final String label;

  /// Seconds per code. Always [oathDefaultPeriod] for a counter-based account.
  final int period;

  @override
  bool operator ==(Object other) => other is OathName && other.issuer == issuer && other.label == label && other.period == period;

  @override
  int get hashCode => Object.hash(issuer, label, period);

  @override
  String toString() => 'OathName($issuer, $label, $period)';
}

final _period = RegExp(r'^([1-9][0-9]*)/(.+)$', dotAll: true);

/// Reads [name]. A time-based account ([timeBased]) may start with its
/// period and a slash. The issuer is what stands before the first colon;
/// a name with no colon, or with nothing before or after it, is a label
/// alone.
OathName parseOathName(String name, {required bool timeBased}) {
  var rest = name;
  var period = oathDefaultPeriod;
  if (timeBased) {
    final match = _period.firstMatch(name);
    if (match != null) {
      period = int.tryParse(match[1]!) ?? oathDefaultPeriod;
      rest = match[2]!;
    }
  }
  final colon = rest.indexOf(':');
  if (colon <= 0 || colon == rest.length - 1) return OathName(label: rest, period: period);
  return OathName(issuer: rest.substring(0, colon), label: rest.substring(colon + 1), period: period);
}

/// The name of an account of [issuer] and [label]: the period first when a
/// time-based account ([timeBased]) has another than 30 seconds, and the
/// issuer when there is one.
String buildOathName({required String issuer, required String label, int period = oathDefaultPeriod, required bool timeBased}) =>
    '${timeBased && period != oathDefaultPeriod ? '$period/' : ''}${issuer.isEmpty ? '' : '$issuer:'}$label';

/// Whether [name] fits the key: at most [oathNameMax] bytes of UTF-8, and not empty.
bool oathNameFits(String name) {
  final length = utf8.encode(name).length;
  return length > 0 && length <= oathNameMax;
}
