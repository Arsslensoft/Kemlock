import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';

/// Where the key-value store keeps its strings on the phone.
abstract interface class PreferencesBackend {
  /// Every string value, by key.
  Future<Map<String, String>> readAll();

  Future<void> set(String key, String value);

  Future<void> remove(String key);
}

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

/// Preferences in memory, for tests and where no phone storage exists.
class MemoryPreferences implements PreferencesBackend {
  MemoryPreferences([Map<String, String> values = const {}]) : values = {...values};

  /// What is "on the phone", for tests to look at.
  final Map<String, String> values;

  /// When set, the next write throws it, as a full disk would.
  Object? failNextWrite;

  /// The writes in the order they reached storage, as `set key=value` and `remove key`.
  final List<String> log = [];

  @override
  Future<Map<String, String>> readAll() async => {...values};

  @override
  Future<void> set(String key, String value) async {
    _maybeFail();
    log.add('set $key=$value');
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _maybeFail();
    log.add('remove $key');
    values.remove(key);
  }

  void _maybeFail() {
    final error = failNextWrite;
    if (error == null) return;
    failNextWrite = null;
    throw error;
  }
}
