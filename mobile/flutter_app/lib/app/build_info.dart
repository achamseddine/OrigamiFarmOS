/// Which build of the app this is.
///
/// Shown on the sign-in screen so that "is the new APK actually on this
/// tablet?" is answered by looking at it, rather than by remembering
/// which file was sideloaded last. The server answers the same question
/// about itself at `GET /health`, and between the two every
/// "no change, same behaviour" report can be checked instead of guessed.
///
/// Supplied by CI as `--dart-define=APP_VERSION=<commit>`; a local
/// `flutter run` reports "dev" rather than pretending to know.
const String kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// The human-readable build number, `0.1.<CI run number>`.
///
/// A commit hash tells a developer which code is on the tablet; it tells
/// a farm worker nothing about whether this build is newer than the last
/// one. The run number only ever goes up, so "is 0.1.31 newer than 0.1.28"
/// has an obvious answer. It is also the Android `versionCode`, which is
/// why an older APK will no longer install over a newer one by accident.
const String kAppBuild = String.fromEnvironment('APP_BUILD', defaultValue: 'dev');

/// What the sign-in screen prints: `App 0.1.31 · a1b2c3d` from CI, and a
/// plain `App dev` from a laptop.
String get kAppStamp => kAppBuild == 'dev' ? 'App $kAppVersion' : 'App $kAppBuild · $kAppVersion';
