import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Modo claro u oscuro de la app.
///
/// La primera vez sigue el modo del teléfono; desde que el usuario lo cambia
/// en el menú de opciones, queda guardado su elección.
class ThemeProvider extends ChangeNotifier {
  static const String _darkModeKey = 'dark_mode';

  bool _isDark =
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
      Brightness.dark;
  bool get isDark => _isDark;

  ThemeMode get themeMode => _isDark ? ThemeMode.dark : ThemeMode.light;

  Future<void> load() async {
    final saved = (await SharedPreferences.getInstance()).getBool(_darkModeKey);
    if (saved != null && saved != _isDark) {
      _isDark = saved;
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    _isDark = !_isDark;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(
      _darkModeKey,
      _isDark,
    );
  }
}
