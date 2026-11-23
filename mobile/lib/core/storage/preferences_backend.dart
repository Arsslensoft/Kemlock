import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';

import 'preferences_interface.dart';

export 'preferences_interface.dart';

/// What the Capacitor app saved with `@capacitor/preferences`: the
/// `CapacitorStorage` SharedPreferences file on Android, and keys prefixed
/// `CapacitorStorage.` in the standard UserDefaults on iOS. The Flutter app
/// keeps reading and writing them there, so the vault never moves.
class CapacitorPreferences implements PreferencesBackend {
  CapacitorPreferences._(this._prefs, this._prefix);

  /// The preferences for this platform, or null where Capacitor never ran.
  static CapacitorPreferences? forPlatform() {
    if (Platform.isAndroid) {
      return CapacitorPreferences._(
        SharedPreferencesAsync(
          options: const SharedPreferencesAsyncAndroidOptions(
            backend: SharedPreferencesAndroidBackendLibrary.SharedPreferences,
            originalSharedPreferencesOptions: AndroidSharedPreferencesStoreOptions(fileName: _group),
          ),
        ),
        '',
      );
    }
    if (Platform.isIOS) return CapacitorPreferences._(SharedPreferencesAsync(), '$_group.');
    return null;
  }

  static const _group = 'CapacitorStorage';

  final SharedPreferencesAsync _prefs;
  final String _prefix;

  @override
  Future<Map<String, String>> readAll() async {
    final values = <String, String>{};
    for (final stored in await _prefs.getKeys()) {
      if (!stored.startsWith(_prefix)) continue;
      try {
        final value = await _prefs.getString(stored);
        if (value != null) values[stored.substring(_prefix.length)] = value;
      } catch (_) {
        // Not a string: Capacitor only wrote strings, so it isn't one of ours.
      }
    }
    return values;
  }

  @override
  Future<void> set(String key, String value) => _prefs.setString('$_prefix$key', value);

  @override
  Future<void> remove(String key) => _prefs.remove('$_prefix$key');
}
