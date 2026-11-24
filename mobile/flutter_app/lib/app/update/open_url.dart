/// Opening a link outside the app, and reloading the web app — on the
/// tablet through MainActivity's `farmos/system` channel, in a browser
/// through the page itself. No plugin: the two calls are all the app needs.
library;

export 'open_url_io.dart' if (dart.library.js_interop) 'open_url_web.dart';
