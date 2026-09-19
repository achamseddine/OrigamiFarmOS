import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists and broadcasts the EN/AR choice.
///
/// **Arabic is the default.** The people who hold this tablet all day are
/// farm workers, not the owner — they read Arabic, many of them read it
/// slowly, and none of them should have to find a language setting before
/// the app makes sense. English is the second language here, not the
/// first: a tablet that boots into English is unusable to the person it
/// was bought for.
///
/// Arabic renders RTL automatically because [Locale('ar')] is handed to
/// [MaterialApp], and Flutter's GlobalWidgetsLocalizations resolves `ar`
/// to [TextDirection.rtl].
class LocaleController extends ChangeNotifier {
  LocaleController() {
    _restore();
  }

  static const _prefsKey = 'farmos.locale';

  Locale _locale = const Locale('ar');
  Locale get locale => _locale;
  bool get isArabic => _locale.languageCode == 'ar';

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      // Only an explicit switch to English moves it off the default, so a
      // tablet with no stored preference — a fresh one, or one whose
      // storage is unreadable — still opens in Arabic.
      if (saved == 'en') {
        _locale = const Locale('en');
        notifyListeners();
      }
    } catch (_) {
      // Preferences unavailable (e.g. first cold start with no storage
      // yet). Arabic stands; this is not a fatal path for an
      // offline-first app.
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
