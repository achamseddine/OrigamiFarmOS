import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists and broadcasts the manager's EN/AR choice.
///
/// Tech spec REQ (i18n): "Language toggle: EN/AR toggle persists user
/// preference." Arabic renders RTL automatically because [Locale('ar')] is
/// handed to [MaterialApp], and Flutter's GlobalWidgetsLocalizations resolves
/// `ar` to [TextDirection.rtl].
class LocaleController extends ChangeNotifier {
  LocaleController() {
    _restore();
  }

  static const _prefsKey = 'farmos.locale';

  Locale _locale = const Locale('en');
  Locale get locale => _locale;
  bool get isArabic => _locale.languageCode == 'ar';

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      if (saved == 'ar') {
        _locale = const Locale('ar');
        notifyListeners();
      }
    } catch (_) {
      // Preferences unavailable (e.g. first cold start with no storage yet).
      // Default to English; this is not a fatal path for an offline-first app.
    }
  }

  Future<void> setLocale(Locale locale) async {
    if (_locale == locale) return;
    _locale = locale;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, locale.languageCode);
    } catch (_) {
      // Best effort only.
    }
  }

  Future<void> toggle() =>
      setLocale(isArabic ? const Locale('en') : const Locale('ar'));
}
