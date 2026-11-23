import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../vault/vault_registry.dart';

/// The look chosen in Settings: the phone's, light or dark, as MUI's
/// colour-scheme mode was ("system", "light", "dark"). It belongs to the
/// device, like the language, so every vault opens in it.
enum ThemeChoice {
  system(ThemeMode.system),
  light(ThemeMode.light),
  dark(ThemeMode.dark);

  const ThemeChoice(this.mode);

  final ThemeMode mode;

  static ThemeChoice? fromName(String? name) => values.where((c) => c.name == name).firstOrNull;
}

class ThemeChoiceNotifier extends Notifier<ThemeChoice> {
  @override
  ThemeChoice build() {
    watchKeys(ref, [keyTheme]);
    return ThemeChoice.fromName(ref.watch(keyValueStoreProvider).getItem(keyTheme)) ?? ThemeChoice.system;
  }

  void choose(ThemeChoice choice) => ref.read(keyValueStoreProvider).setItem(keyTheme, choice.name);
}

final themeChoiceProvider = NotifierProvider<ThemeChoiceNotifier, ThemeChoice>(ThemeChoiceNotifier.new);
