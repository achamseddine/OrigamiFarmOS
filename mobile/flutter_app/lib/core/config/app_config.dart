/// Server connection defaults. The Origami FarmOS tablet talks to the real
/// Origami Server (see ../../../../OrigamiFarmServer, `docs/FARMOS_API.md`)
/// over this base URL; [SessionManager] lets a farm override it from
/// Settings without a rebuild (e.g. pointing at a local dev server).
class AppConfig {
  AppConfig._();

  /// `10.0.2.2` is the Android emulator's alias for the host machine's
  /// `localhost`, where `uvicorn app.main:app` listens per the server's own
  /// README. A physical tablet or iOS simulator needs a real host address,
  /// which is exactly what the Settings screen's base-URL field is for.
  static const String defaultApiBaseUrl = 'http://10.0.2.2:8000/api/v1';

  /// Kept short and separate from a page-load timeout: this app treats "the
  /// server didn't answer quickly" the same as "we're offline" (Constitution:
  /// offline-first, so a slow network must never block a worker's write).
  static const Duration requestTimeout = Duration(seconds: 8);
}
