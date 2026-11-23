import 'package:intl/intl.dart';

/// A message in ICU MessageFormat, read the way intl-messageformat (behind
/// react-intl) reads the app's copy, so `en.json` and `fr.json` come out the
/// same as in the web app.
///
/// It reads the part of ICU the copy uses: text with ICU's apostrophe
/// quoting, `{name}` arguments, `{n, plural, …}` with `=N` cases, `offset:`
/// and `#`, and `{key, select, …}`. Number, date and time arguments,
/// `selectordinal` and rich-text tags other than `<tag/>` are not supported
/// and fail to parse.
class IcuMessage {
  IcuMessage._(this.pattern, this._nodes);

  /// Parses [pattern], or throws a [FormatException] where it isn't valid
  /// ICU or uses something this reader doesn't support.
  factory IcuMessage.parse(String pattern) => IcuMessage._(pattern, _Parser(pattern).parse());

  /// The message as written.
  final String pattern;

  final List<_Node> _nodes;

  /// The names of the arguments the message takes, sorted.
  List<String> get argumentNames {
    final names = <String>{};
    void walk(List<_Node> nodes) {
      for (final node in nodes) {
        switch (node) {
          case _Argument(:final name):
            names.add(name);
          case _Select(:final name, :final options) || _Plural(:final name, :final options):
            names.add(name);
            options.values.forEach(walk);
          case _Literal() || _Pound():
            break;
        }
      }
    }

    walk(_nodes);
    return names.toList()..sort();
  }

  /// The message in [locale] (`en`, `fr`) with [args] filled in.
  ///
  /// `#` and nothing else is a localised number, as in react-intl: French
  /// groups thousands with a narrow no-break space ("1 000"), while a
  /// number in a plain `{n}` is written as JavaScript's `String(n)` would,
  /// without grouping. Throws an [IcuFormatError] when an argument the
  /// message uses is missing from [args]; a null argument counts as given
  /// and is written as nothing.
  String format(String locale, [Map<String, Object?> args = const {}]) {
    final out = StringBuffer();
    _write(_nodes, locale, args, null, out);
    return out.toString();
  }

  void _write(List<_Node> nodes, String locale, Map<String, Object?> args, num? pluralValue, StringBuffer out) {
    for (final node in nodes) {
      switch (node) {
        case _Literal(:final text):
          out.write(text);
        case _Pound():
          if (pluralValue != null) out.write(_formatNumber(pluralValue, locale));
        case _Argument(:final name):
          out.write(_plainText(_value(name, args)));
        case _Select(:final name, :final options):
          final key = _jsString(_value(name, args));
          _write(options[key] ?? options['other']!, locale, args, null, out);
        case _Plural(:final name, :final offset, :final options):
          final value = _value(name, args);
          final n = _jsNumber(value) - offset;
          // An exact case matches the value before the offset, as ICU says.
          final option = options['=${_jsString(value)}'] ?? options[pluralCategory(n, locale)] ?? options['other']!;
          _write(option, locale, args, n, out);
      }
    }
  }

  Object? _value(String name, Map<String, Object?> args) {
    if (!args.containsKey(name)) throw IcuFormatError('The argument "$name" was not provided to "$pattern"');
    return args[name];
  }

  @override
  String toString() => 'IcuMessage($pattern)';
}

/// An argument a message needs is missing.
class IcuFormatError implements Exception {
  IcuFormatError(this.message);

  final String message;

  @override
  String toString() => 'IcuFormatError: $message';
}

/// The CLDR plural category of [n] in [locale]: `zero`, `one`, `two`,
/// `few`, `many` or `other`, as `Intl.PluralRules` gives it.
String pluralCategory(num n, String locale) {
  // Intl.PluralRules answers "other" for these; package:intl would throw.
  if (!n.isFinite) return 'other';
  // CLDR's operands are those of the absolute value.
  num x = n.abs();
  // package:intl takes the integer operand by rounding (1.5 counts as 2)
  // where CLDR truncates it. A number with the same integer part and a
  // visible fraction falls in the same category under the English and
  // French rules, which depend on nothing else.
  if (x is double && x != x.truncateToDouble()) x = x.truncateToDouble() + 0.25;
  return Intl.pluralLogic(
    x,
    locale: locale,
    zero: 'zero',
    one: 'one',
    two: 'two',
    few: 'few',
    many: 'many',
    other: 'other',
    useExplicitNumberCases: false,
  );
}

final _numberFormats = <String, NumberFormat>{};

/// [n] as `Intl.NumberFormat(locale)` writes it: grouped, at most three decimals.
String _formatNumber(num n, String locale) => (_numberFormats[locale] ??= NumberFormat.decimalPattern(locale)).format(n);

/// A plain argument as intl-messageformat writes it: text as is, a number
/// as `String(n)`, and nothing for null or false.
String _plainText(Object? value) => switch (value) {
  null || false => '',
  _ => _jsString(value),
};

/// [value] as JavaScript's `String(value)`: `1.0` is "1", like the number it is there.
String _jsString(Object? value) {
  if (value is! double) return '$value';
  if (value == 0) return '0';
  final text = value.toString();
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// [value] as JavaScript's `Number(value)`, which a plural applies to whatever it is given.
num _jsNumber(Object? value) => switch (value) {
  num() => value,
  null || false => 0,
  true => 1,
  final String text when text.trim().isEmpty => 0,
  final String text => double.tryParse(text.trim()) ?? double.nan,
  _ => double.nan,
};

sealed class _Node {
  const _Node();
}

class _Literal extends _Node {
  const _Literal(this.text);
  final String text;
}

class _Argument extends _Node {
  const _Argument(this.name);
  final String name;
}

/// `#` in a plural: the count, less the offset.
class _Pound extends _Node {
  const _Pound();
}

class _Select extends _Node {
  const _Select(this.name, this.options);
  final String name;
  final Map<String, List<_Node>> options;
}

class _Plural extends _Node {
  const _Plural(this.name, this.offset, this.options);
  final String name;
  final int offset;
  final Map<String, List<_Node>> options;
}

const _apostrophe = 0x27;
const _openBrace = 0x7B;
const _closeBrace = 0x7D;
const _hash = 0x23;
const _lessThan = 0x3C;
const _greaterThan = 0x3E;
const _slash = 0x2F;
const _comma = 0x2C;

/// What ICU allows in a name: anything but white space and pattern syntax.
final _identifier = RegExp(r'[^\p{White_Space}\p{Pattern_Syntax}]*', unicode: true);

/// The parser of @formatjs/icu-messageformat-parser, step for step, for
/// the subset [IcuMessage] supports.
class _Parser {
  _Parser(this.message);

  final String message;
  int _pos = 0;

  List<_Node> parse() => _parseMessage(0, null);

  bool get _eof => _pos >= message.length;

  int get _char => message.codeUnitAt(_pos);

  int? get _peek => _pos + 1 < message.length ? message.codeUnitAt(_pos + 1) : null;

  FormatException _error(String what, [int? at]) => FormatException(what, message, at ?? _pos);

  /// Text and arguments up to the end, or to the `}` closing a plural or select case.
  List<_Node> _parseMessage(int nesting, String? parentType) {
    final nodes = <_Node>[];
    while (!_eof) {
      final char = _char;
      if (char == _openBrace) {
        nodes.add(_parseArgument(nesting));
      } else if (char == _closeBrace && nesting > 0) {
        break;
      } else if (char == _hash && parentType == 'plural') {
        _pos++;
        nodes.add(const _Pound());
      } else if (char == _lessThan && _peek == _slash) {
        throw _error('Unmatched closing tag');
      } else if (char == _lessThan && _isAlpha(_peek)) {
        nodes.add(_parseTag());
      } else {
        nodes.add(_Literal(_parseLiteral(nesting, parentType)));
      }
    }
    return nodes;
  }

  /// `<tag/>` is text; a tag with content would need a function to render it.
  _Node _parseTag() {
    final start = _pos;
    _pos++;
    final nameStart = _pos;
    _pos++;
    while (!_eof && _isTagNameChar(_char)) {
      _pos++;
    }
    final name = message.substring(nameStart, _pos);
    _skipSpace();
    if (_skip('/>')) return _Literal('<$name/>');
    throw _error('Rich-text tags are not supported', start);
  }

  String _parseLiteral(int nesting, String? parentType) {
    final out = StringBuffer();
    while (_quoted(out, parentType) || _unquoted(out, nesting, parentType) || _leftAngle(out)) {}
    return out.toString();
  }

  /// An apostrophe quotes text only before a character that would mean
  /// something else (`{`, `}`, `<`, `>`, and `#` in a plural); `''` is one
  /// apostrophe; any other apostrophe is itself.
  bool _quoted(StringBuffer out, String? parentType) {
    if (_eof || _char != _apostrophe) return false;
    switch (_peek) {
      case _apostrophe:
        _pos += 2;
        out.write("'");
        return true;
      case _openBrace || _lessThan || _greaterThan || _closeBrace:
        break;
      case _hash when parentType == 'plural':
        break;
      default:
        return false;
    }
    _pos++;
    out.writeCharCode(_char);
    _pos++;
    // The quote runs to the next lone apostrophe, or to the end.
    while (!_eof) {
      final char = _char;
      if (char == _apostrophe) {
        if (_peek == _apostrophe) {
          out.write("'");
          _pos++;
        } else {
          _pos++;
          break;
        }
      } else {
        out.writeCharCode(char);
      }
      _pos++;
    }
    return true;
  }

  bool _unquoted(StringBuffer out, int nesting, String? parentType) {
    if (_eof) return false;
    final char = _char;
    if (char == _lessThan || char == _openBrace || (char == _hash && parentType == 'plural') || (char == _closeBrace && nesting > 0)) {
      return false;
    }
    out.writeCharCode(char);
    _pos++;
    return true;
  }

  bool _leftAngle(StringBuffer out) {
    if (_eof || _char != _lessThan || _isAlpha(_peek) || _peek == _slash) return false;
    out.write('<');
    _pos++;
    return true;
  }

  _Node _parseArgument(int nesting) {
    final start = _pos;
    _pos++;
    _skipSpace();
    if (_eof) throw _error('Expected the argument to be closed with }', start);
    if (_char == _closeBrace) throw _error('Empty argument', start);
    final name = _parseIdentifier();
    if (name.isEmpty) throw _error('Malformed argument', start);
    _skipSpace();
    if (_eof) throw _error('Expected the argument to be closed with }', start);
    switch (_char) {
      case _closeBrace:
        _pos++;
        return _Argument(name);
      case _comma:
        _pos++;
        _skipSpace();
        if (_eof) throw _error('Expected the argument to be closed with }', start);
        return _parseArgumentOptions(nesting, name, start);
      default:
        throw _error('Malformed argument', start);
    }
  }

  _Node _parseArgumentOptions(int nesting, String name, int start) {
    final typeStart = _pos;
    final type = _parseIdentifier();
    switch (type) {
      case '':
        throw _error('Expected an argument type', typeStart);
      case 'plural' || 'select':
        _skipSpace();
        if (!_skip(',')) throw _error('Expected the $type options', _pos);
        _skipSpace();
        var selector = _parseIdentifier();
        var offset = 0;
        if (type == 'plural' && selector == 'offset') {
          if (!_skip(':')) throw _error('Expected the offset value');
          _skipSpace();
          offset = _parseInteger();
          _skipSpace();
          selector = _parseIdentifier();
        }
        final options = _parseOptions(nesting, type, selector);
        _closeArgument(start);
        return type == 'plural' ? _Plural(name, offset, options) : _Select(name, options);
      case 'number' || 'date' || 'time' || 'selectordinal':
        throw _error('"$type" arguments are not supported', typeStart);
      default:
        throw _error('Invalid argument type "$type"', typeStart);
    }
  }

  Map<String, List<_Node>> _parseOptions(int nesting, String type, String firstSelector) {
    final options = <String, List<_Node>>{};
    var selector = firstSelector;
    while (true) {
      if (selector.isEmpty) {
        final selectorStart = _pos;
        if (type == 'select' || !_skip('=')) break;
        _parseInteger();
        selector = message.substring(selectorStart, _pos);
      }
      if (options.containsKey(selector)) throw _error('Duplicate $type selector "$selector"');
      _skipSpace();
      final caseStart = _pos;
      if (!_skip('{')) throw _error('Expected a {…} case after "$selector"');
      options[selector] = _parseMessage(nesting + 1, type);
      _closeArgument(caseStart);
      _skipSpace();
      selector = _parseIdentifier();
    }
    if (options.isEmpty) throw _error('Expected a $type selector');
    if (!options.containsKey('other')) throw _error('The $type has no "other" case');
    return options;
  }

  void _closeArgument(int start) {
    if (_eof || _char != _closeBrace) throw _error('Expected the argument to be closed with }', start);
    _pos++;
  }

  int _parseInteger() {
    final start = _pos;
    var sign = 1;
    if (!_skip('+') && _skip('-')) sign = -1;
    var value = 0;
    var digits = false;
    while (!_eof && _char >= 0x30 && _char <= 0x39) {
      digits = true;
      value = value * 10 + (_char - 0x30);
      // Number.isSafeInteger, as the JavaScript parser checks.
      if (value > 9007199254740991) throw _error('Invalid number', start);
      _pos++;
    }
    if (!digits) throw _error('Expected a number', start);
    return sign * value;
  }

  String _parseIdentifier() {
    final name = _identifier.matchAsPrefix(message, _pos)![0]!;
    _pos += name.length;
    return name;
  }

  bool _skip(String prefix) {
    if (!message.startsWith(prefix, _pos)) return false;
    _pos += prefix.length;
    return true;
  }

  void _skipSpace() {
    while (!_eof && _isWhiteSpace(_char)) {
      _pos++;
    }
  }
}

bool _isAlpha(int? c) => c != null && ((c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A));

bool _isWhiteSpace(int c) => (c >= 9 && c <= 13) || c == 32 || c == 0x85 || c == 0x200E || c == 0x200F || c == 0x2028 || c == 0x2029;

/// The custom-element name characters the JavaScript parser accepts in a tag name.
bool _isTagNameChar(int c) =>
    c == 0x2D ||
    c == 0x2E ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x5F ||
    _isAlpha(c) ||
    c == 0xB7 ||
    (c >= 0xC0 && c <= 0xD6) ||
    (c >= 0xD8 && c <= 0xF6) ||
    (c >= 0xF8 && c <= 0x37D) ||
    (c >= 0x37F && c <= 0x1FFF) ||
    (c >= 0x200C && c <= 0x200D) ||
    (c >= 0x203F && c <= 0x2040) ||
    (c >= 0x2070 && c <= 0x218F) ||
    (c >= 0x2C00 && c <= 0x2FEF) ||
    (c >= 0x3001 && c <= 0xD7FF) ||
    (c >= 0xF900 && c <= 0xFDCF) ||
    (c >= 0xFDF0 && c <= 0xFFFD);
