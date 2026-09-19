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
