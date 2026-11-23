// Brand logos for the services people protect with 2FA, bundled so the app never fetches anything.
// The paths come from simple-icons (CC0); the brands themselves stay their owners' trademarks.
// assets/data/service_icons.json is generated from the table in src/lib/serviceIcons.ts by
// tool/service_icons/build.mjs; change the table there and run it again.

import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'service_names.dart';

/// A brand logo.
class ServiceIcon {
  const ServiceIcon({required this.title, required this.hex, required this.path});

  final String title;

  /// Brand colour: six hex digits, no '#'.
  final String hex;

  /// SVG path data for a 24×24 viewBox.
  final String path;

  /// The logo as an SVG document for `SvgPicture.string`, filled with [fill]. The tiles fill
  /// it with #0A0B0D on a light brand colour (see [isLightBrand]) and with white otherwise.
  String svg({String fill = '#FFFFFF'}) =>
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="$path" fill="$fill"/></svg>';

  @override
  String toString() => 'ServiceIcon($title)';
}

/// A bundled logo with the names that select it, its title first.
typedef ServiceIconRow = ({ServiceIcon icon, List<String> names});

/// The bundled logos and the names each goes by.
class ServiceIcons {
  ServiceIcons._(this.rows, this._byKey);

  /// Reads the asset's JSON: `{"icons": [{"title", "hex", "path", "names"}, …]}`, in the
  /// table's order. A name goes to the first logo that has it.
  factory ServiceIcons.fromJson(Map<String, Object?> json) {
    final rows = <ServiceIconRow>[];
    final byKey = <String, ServiceIcon>{};
    for (final row in (json['icons'] as List<Object?>? ?? const []).cast<Map<String, Object?>>()) {
      final icon = ServiceIcon(title: row['title']! as String, hex: row['hex']! as String, path: row['path']! as String);
      final names = List<String>.unmodifiable((row['names']! as List<Object?>).cast<String>());
      rows.add((icon: icon, names: names));
      for (final name in names) {
        byKey.putIfAbsent(squash(fold(name)), () => icon);
      }
    }
    return ServiceIcons._(List.unmodifiable(rows), byKey);
  }

  static const asset = 'assets/data/service_icons.json';

  /// Every bundled logo with the names that select it (its title first).
  final List<ServiceIconRow> rows;

  final Map<String, ServiceIcon> _byKey;

  static Future<ServiceIcons>? _bundled;

  /// The logos, read from [bundle] (the app's own by default) the first time a tile needs
  /// them, rather than with the app; every tile shares the one read.
  static Future<ServiceIcons> load({AssetBundle? bundle}) async {
    if (bundle != null) return _read(bundle);
    try {
      return await (_bundled ??= _read(rootBundle));
    } catch (_) {
      _bundled = null;
      rethrow;
    }
  }

  static Future<ServiceIcons> _read(AssetBundle bundle) async =>
      ServiceIcons.fromJson(jsonDecode(await bundle.loadString(asset, cache: false)) as Map<String, Object?>);

  ServiceIcon? _lookup(String name) {
    for (final key in keysFor(name)) {
      final icon = _byKey[key];
      if (icon != null) return icon;
    }
    return null;
  }

  /// Logo for an account's issuer or a backup-code service name, or null when we don't bundle one.
  ServiceIcon? iconFor(String name) {
    final colon = name.indexOf(':');
    // Exact names only: an unknown service gets no logo rather than a lookalike's.
    return _lookup(name) ?? (colon > 0 ? _lookup(name.substring(0, colon)) : null);
  }
}

/// The logo catalogue, loaded the first time a widget watches it and kept.
final serviceIconsProvider = FutureProvider<ServiceIcons>((ref) => ServiceIcons.load());

final _leadingHexDigits = RegExp('^[0-9a-fA-F]+');

/// WCAG relative luminance of a "rrggbb" colour, 0 (black) to 1 (white).
double _luminance(String hex) {
  final digits = _leadingHexDigits.stringMatch(hex.startsWith('#') ? hex.substring(1) : hex) ?? '0';
  final rgb = int.parse(digits, radix: 16);
  double channel(int shift) {
    final c = ((rgb >> shift) & 0xff) / 255;
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
}

/// True when the brand colour is light enough that a white glyph on it would be hard to read.
bool isLightBrand(String hex) {
  // Past 0.5 white is under 1.9:1 against the colour (Snapchat or Binance yellow, Klarna pink),
  // while brands just below it, like WhatsApp green, keep the white mark they use themselves.
  return _luminance(hex) > 0.5;
}
